import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/dart.dart' show DartSha256;

import '../crypto/cipher.dart';
import '../crypto/crypto_engine.dart';
import '../crypto/key_vault.dart';
import 'vault_store.dart';

/// Encrypted storage for attachments and for the user's protected files.
///
/// A file never exists on disk in the clear. When it is imported, it is streamed
/// through AES-256-GCM in fixed-size chunks and only the ciphertext is written;
/// when it is opened, a decrypted copy is materialised in the cache directory,
/// which is wiped on every lock. That is the mechanism behind the promise that
/// everything in DarkFlow is protected by the account password.
///
/// Each chunk carries its own nonce and its index in the associated data, so
/// chunks cannot be reordered, duplicated or dropped without the failure being
/// detected.
class FileVault {
  FileVault({
    required this._engine,
    required this._paths,
  });

  final CryptoEngine _engine;
  final VaultPaths _paths;

  /// 256 KiB keeps a chunk well under the frame ceiling while staying large
  /// enough that pure-Dart AES-GCM is not dominated by per-call overhead.
  static const int chunkSize = 256 * 1024;

  MasterKeyRing? _ring;
  Uint8List? _fileKey;

  bool get isUnlocked => _ring != null;

  /// Unlocks the vault. Attachments use a subkey of the master key, so a
  /// compromise of one subsystem does not expose the other.
  void unlock(MasterKeyRing ring) {
    _ring = ring;
    _fileKey = ring.fileKey;
  }

  /// Forgets the keys.
  void lock() {
    _ring = null;
    _fileKey = null;
  }

  /// The path the ciphertext of [attachmentId] lives at.
  File ciphertextFile(String attachmentId) => File(
        '${_paths.filesDirectory.path}${Platform.pathSeparator}$attachmentId.df',
      );

  /// Encrypts [source] into the vault and returns the plaintext's SHA-256.
  ///
  /// [onProgress] receives 0..1 so a large import can show a bar; pure-Dart
  /// AES-GCM runs at roughly 14 MiB/s, which is slow enough that silence would
  /// look like a hang.
  Future<String> import({
    required String attachmentId,
    required File source,
    void Function(double progress)? onProgress,
  }) async {
    final total = await source.length();
    var processed = 0;
    return _importStream(
      attachmentId: attachmentId,
      pieces: source.openRead(),
      total: total,
      onProgress: onProgress,
      onChunk: (int length) {
        processed += length;
        return total == 0 ? 1.0 : processed / total;
      },
    );
  }

  /// Seals [bytes] into the vault and returns their SHA-256.
  ///
  /// The same operation as [import] without a file behind it, which is what a
  /// received attachment needs: its bytes arrive over the network, are verified
  /// against the sender's digest, and only then are sealed under this device's own
  /// key.
  Future<String> importBytes({
    required String attachmentId,
    required List<int> bytes,
    void Function(double progress)? onProgress,
  }) {
    final data = Uint8List.fromList(bytes);
    return _importStream(
      attachmentId: attachmentId,
      pieces: Stream<List<int>>.value(data),
      total: data.length,
      onProgress: onProgress,
      onChunk: (int length) => 1,
    );
  }

  /// The shared body of both imports: chunk, seal, digest, write.
  Future<String> _importStream({
    required String attachmentId,
    required Stream<List<int>> pieces,
    required int total,
    required void Function(double progress)? onProgress,
    required double Function(int chunkLength) onChunk,
  }) async {
    final key = _requireKey();
    await _paths.filesDirectory.create(recursive: true);

    final target = ciphertextFile(attachmentId);
    final sink = target.openWrite();
    // An incremental digest, so the plaintext is never held in memory twice and
    // a multi-gigabyte file costs the same as a small one.
    final hashSink = const DartSha256().newHashSink();
    var index = 0;

    try {
      final buffer = BytesBuilder(copy: false);
      await for (final piece in pieces) {
        buffer.add(piece);
        while (buffer.length >= chunkSize) {
          final all = buffer.takeBytes();
          final chunk = Uint8List.sublistView(all, 0, chunkSize);
          if (all.length > chunkSize) buffer.add(Uint8List.sublistView(all, chunkSize));
          hashSink.add(chunk);
          sink.add(frameChunk(Cipher.sealChunk(
            engine: _engine,
            key: key,
            plaintext: chunk,
            fileId: attachmentId,
            index: index++,
          )));
          onProgress?.call(onChunk(chunk.length));
        }
      }
      if (buffer.length > 0) {
        final chunk = buffer.takeBytes();
        hashSink.add(chunk);
        sink.add(frameChunk(Cipher.sealChunk(
          engine: _engine,
          key: key,
          plaintext: chunk,
          fileId: attachmentId,
          index: index++,
        )));
        onProgress?.call(1);
      } else if (total == 0) {
        // An empty file produces no chunks at all, which would leave a ciphertext
        // that cannot be walked. One empty frame makes it readable and keeps the
        // digest meaningful.
        hashSink.add(const <int>[]);
        sink.add(frameChunk(Cipher.sealChunk(
          engine: _engine,
          key: key,
          plaintext: const <int>[],
          fileId: attachmentId,
          index: index++,
        )));
        onProgress?.call(1);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    // `cryptography`'s hash sink only allows the digest to be read once it has
    // been told that no more input is coming, which an empty final slice does.
    hashSink.addSlice(const <int>[], 0, 0, true);
    final digest = hashSink.hashSync().bytes;
    return digest.map(_hex).join();
  }

  /// Appends already-framed ciphertext that arrived from a peer.
  ///
  /// The caller passes bytes in the same `[uint32 length][sealed]` framing that
  /// [import] produces, so a received file is byte-identical to a local one and
  /// is verified chunk by chunk on first open rather than trusted.
  Future<File> importCiphertext({
    required String attachmentId,
    required List<int> ciphertext,
    bool append = false,
  }) async {
    await _paths.filesDirectory.create(recursive: true);
    final target = ciphertextFile(attachmentId);
    if (append && target.existsSync()) {
      await target.writeAsBytes(ciphertext, mode: FileMode.append, flush: true);
    } else {
      await target.writeAsBytes(ciphertext, flush: true);
    }
    return target;
  }

  /// Decrypts the vault entry into the cache directory and returns it.
  ///
  /// The result is a plaintext file, so it lives in the cache, which is purged
  /// whenever the vault locks.
  Future<File> materialise({
    required String attachmentId,
    required String fileName,
    void Function(double progress)? onProgress,
  }) async {
    final key = _requireKey();
    final source = ciphertextFile(attachmentId);
    if (!source.existsSync()) {
      throw FileSystemException('the encrypted copy of "$fileName" is missing', source.path);
    }

    await _paths.cacheDirectory.create(recursive: true);
    final target = File(
      '${_paths.cacheDirectory.path}${Platform.pathSeparator}${_safeName(fileName)}',
    );
    final sink = target.openWrite();
    final total = await source.length();
    var processed = 0;

    try {
      final bytes = await source.readAsBytes();
      var offset = 0;
      var index = 0;
      while (offset < bytes.length) {
        // Each frame is `[uint32 length][sealed]`, and the length prefix is what
        // makes a partially written tail detectable — which it only is if
        // something actually detects it.
        //
        // These two checks used to `break`, so a torn tail was *dropped* and the
        // method returned normally with a valid-looking `File`. A crash during an
        // import, a power loss, a partially received attachment, or disk
        // corruption therefore handed the user a silently truncated photo,
        // document or voice note — or a zero-byte file when the very first frame
        // was incomplete — with nothing to distinguish it from success. The class
        // doc promises the opposite ("chunks cannot be reordered, duplicated or
        // dropped without the failure being detected"); this is that promise.
        if (offset + 4 > bytes.length) {
          throw CryptoFailure(
            'the encrypted copy of "$fileName" is truncated in the middle of a '
            'frame at byte $offset',
          );
        }
        final length = ByteData.sublistView(bytes, offset, offset + 4).getUint32(0, Endian.big);
        final start = offset + 4;
        final end = start + length;
        if (length == 0 || end > bytes.length) {
          throw CryptoFailure(
            'the encrypted copy of "$fileName" is truncated: a frame claims '
            '$length bytes but only ${bytes.length - start} remain from byte $start',
          );
        }
        final chunk = Cipher.openChunk(
          engine: _engine,
          key: key,
          sealed: Uint8List.sublistView(bytes, start, end),
          fileId: attachmentId,
          index: index++,
        );
        sink.add(chunk);
        offset = end;
        processed += length;
        onProgress?.call(total == 0 ? 1 : processed / total);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    return target;
  }

  /// Decrypts an attachment into memory without writing anything to disk.
  ///
  /// Used when the bytes have to travel somewhere rather than be shown: a
  /// transfer sends the *plaintext* and lets the recipient re-import it, because
  /// the digest an attachment carries covers its plaintext — re-sealing it here
  /// with this device's own random nonces would produce bytes whose digest the
  /// recipient could never check against what the sender recorded. See
  /// `FileTransfer`.
  ///
  /// The whole file is held in memory, which is why transfers are capped well
  /// below anything that would threaten it.
  Future<Uint8List> readPlaintext(String attachmentId) async {
    final key = _requireKey();
    final source = ciphertextFile(attachmentId);
    if (!source.existsSync()) {
      throw FileSystemException(
        'the encrypted copy of attachment "$attachmentId" is missing',
        source.path,
      );
    }

    final bytes = await source.readAsBytes();
    final out = BytesBuilder(copy: false);
    var offset = 0;
    var index = 0;
    while (offset < bytes.length) {
      // Same framing as `materialise`, and the same refusal to guess: a torn tail
      // is an error rather than a short file.
      if (offset + 4 > bytes.length) {
        throw CryptoFailure('attachment "$attachmentId" is truncated mid-frame');
      }
      final length = ByteData.sublistView(bytes, offset, offset + 4).getUint32(0, Endian.big);
      final start = offset + 4;
      final end = start + length;
      if (length == 0 || end > bytes.length) {
        throw CryptoFailure('attachment "$attachmentId" is truncated at byte $offset');
      }
      out.add(Cipher.openChunk(
        engine: _engine,
        key: key,
        sealed: Uint8List.sublistView(bytes, start, end),
        fileId: attachmentId,
        index: index++,
      ));
      offset = end;
    }
    return out.takeBytes();
  }

  /// Removes the ciphertext of an attachment, and its decrypted working copy.
  ///
  /// Both halves have to go. `materialise` writes the plaintext into the cache
  /// under the user's own file name, so deleting only the ciphertext left a
  /// readable copy of the very file the user had just deleted sitting in the
  /// cache — for as long as the vault stayed unlocked, which is indefinitely in
  /// practice — and the caller's own comment claimed both were removed.
  Future<void> delete(String attachmentId, {String? fileName}) async {
    final file = ciphertextFile(attachmentId);
    if (file.existsSync()) await file.delete();
    if (fileName != null) {
      final cached = File(
        '${_paths.cacheDirectory.path}${Platform.pathSeparator}${_safeName(fileName)}',
      );
      if (cached.existsSync()) await cached.delete();
    }
  }

  /// Total bytes held in the encrypted attachment store.
  Future<int> usedBytes() async {
    if (!_paths.filesDirectory.existsSync()) return 0;
    var total = 0;
    await for (final entity in _paths.filesDirectory.list()) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }

  Uint8List _requireKey() {
    final key = _fileKey;
    if (key == null) {
      throw StateError('The file vault is locked.');
    }
    return key;
  }

  static String _safeName(String name) {
    // Path separators and traversal sequences must not survive into the cache
    // directory, or a hostile file name could write outside it.
    final cleaned = name
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll('..', '_')
        .trim();
    return cleaned.isEmpty ? 'file' : cleaned;
  }

  static String _hex(int byte) => byte.toRadixString(16).padLeft(2, '0');
}

/// Wraps a plaintext chunk in a length prefix so the vault file can be walked
/// without decoding anything first.
Uint8List frameChunk(Uint8List sealed) {
  final out = Uint8List(4 + sealed.length);
  ByteData.sublistView(out).setUint32(0, sealed.length, Endian.big);
  out.setRange(4, out.length, sealed);
  return out;
}
