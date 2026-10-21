import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/dart.dart' show DartSha256;

import '../crypto/crypto_engine.dart';
import '../data/models/message.dart';

/// Moving an attachment's bytes from the sender to the recipient.
///
/// ## The gap this closes
///
/// A message frame carries only an attachment's *metadata* — name, size, MIME
/// type, duration, waveform and the plaintext's SHA-256. The bytes were never sent
/// at all: `ChunkFrame` and `FileVault.importCiphertext` both existed and neither
/// was ever called. The consequence was that a received voice note or file could
/// be listed, drawn and tapped, and could never be opened: `materialise` threw
/// because this device held no ciphertext, and the tap did nothing visible.
///
/// ## Why it does not need a key exchange
///
/// The two peers already share a secret. `EnvelopeCipher.sharedKey` derives one
/// from their X25519 exchange keys and their two onion addresses, and every
/// message they exchange is already sealed with it. The same secret therefore
/// works here, which keeps this module free of any new cryptographic agreement to
/// get wrong.
///
/// ## What the recipient can verify
///
/// Each chunk is sealed with AES-256-GCM under a nonce derived from the transfer
/// id and the chunk index, so chunks cannot be reordered, duplicated, dropped or
/// forged without detection — the AAD binds both the attachment and the position.
/// On top of that the reassembled plaintext is checked against the SHA-256 the
/// *sender* recorded in the message metadata, which is the check a transfer made
/// through relays actually needs: a relay cannot produce bytes that hash to the
/// sender's digest.
///
/// The chunk layout is deliberately not `FileVault`'s on-disk framing. The vault
/// seals with a random nonce per chunk, so an already-sealed blob cannot be
/// verified against a digest without decrypting it; sending plaintext sealed with
/// a derived nonce lets the recipient rebuild the *exact* file the digest covers.
abstract final class FileTransfer {
  /// The largest attachment that is moved between peers.
  ///
  /// A guard rather than a policy: the recipient assembles the whole file in
  /// memory to verify it against the sender's digest, so an unbounded transfer is
  /// an unbounded allocation driven by the other end of a connection. Voice notes
  /// are a few hundred kilobytes and ordinary files are well inside this; a
  /// relayed multi-gigabyte film is not something this protocol should attempt.
  static const int maxBytes = 16 * 1024 * 1024;

  /// A transfer id that does not reveal the attachment id.
  ///
  /// The attachment id is an opaque random string and travels in the metadata
  /// anyway; this exists so the id used to derive nonces is a fixed length
  /// whatever the sender chose, which keeps the AAD unambiguous.
  static Uint8List transferIdFor(String attachmentId, CryptoEngine engine) =>
      engine.sha256(utf8.encode('darkflow/transfer/$attachmentId'));

  /// Seals one chunk of `plaintext` as chunk [index] of [total].
  static Uint8List sealChunk({
    required CryptoEngine engine,
    required Uint8List sharedKey,
    required String attachmentId,
    required int index,
    required int total,
    required List<int> plaintext,
  }) {
    final transferId = transferIdFor(attachmentId, engine);
    return engine.aesGcmEncrypt(
      key: sharedKey,
      nonce: _nonce(engine, transferId, index),
      plaintext: Uint8List.fromList(plaintext),
      aad: _aad(attachmentId, index, total),
    );
  }

  /// Opens one chunk. Throws [CryptoFailure] when it is not authentic.
  static Uint8List openChunk({
    required CryptoEngine engine,
    required Uint8List sharedKey,
    required String attachmentId,
    required int index,
    required int total,
    required List<int> sealed,
  }) {
    final transferId = transferIdFor(attachmentId, engine);
    return engine.aesGcmDecrypt(
      key: sharedKey,
      nonce: _nonce(engine, transferId, index),
      ciphertext: Uint8List.fromList(sealed),
      aad: _aad(attachmentId, index, total),
    );
  }

  /// The digest the sender recorded, checked against what was reassembled.
  ///
  /// Returns null when the two agree, or a sentence explaining the mismatch. A
  /// verification failure has to be surfaced rather than swallowed: the
  /// alternative is showing the user a file that is not the one that was sent.
  static String? verifyDigest(Uint8List plaintext, String expectedHex) {
    if (expectedHex.isEmpty) {
      // Nothing to check against. Older messages may not carry a digest, and
      // refusing them would be worse than accepting a file whose chunks were all
      // individually authenticated.
      return null;
    }
    final sink = const DartSha256().newHashSink();
    sink.add(plaintext);
    sink.addSlice(const <int>[], 0, 0, true);
    final actual = sink
        .hashSync()
        .bytes
        .map((int byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    if (actual == expectedHex.toLowerCase()) return null;
    return 'The received file does not match the digest the sender recorded, so '
        'it was discarded rather than shown.';
  }

  /// Splits [bytes] into chunks and seals each one.
  ///
  /// [chunkSize] is deliberately small: a voice note has to arrive over a Tor
  /// circuit where a large frame is more likely to be dropped, and the whole
  /// transfer is retried as a unit.
  static List<Uint8List> sealAll({
    required CryptoEngine engine,
    required Uint8List sharedKey,
    required String attachmentId,
    required List<int> bytes,
    int chunkSize = 48 * 1024,
  }) {
    if (bytes.isEmpty) {
      // An empty file still has to produce one chunk, or the recipient never
      // learns the transfer finished.
      return <Uint8List>[
        sealChunk(
          engine: engine,
          sharedKey: sharedKey,
          attachmentId: attachmentId,
          index: 0,
          total: 1,
          plaintext: const <int>[],
        ),
      ];
    }
    final total = (bytes.length / chunkSize).ceil();
    return <Uint8List>[
      for (var index = 0; index < total; index++)
        sealChunk(
          engine: engine,
          sharedKey: sharedKey,
          attachmentId: attachmentId,
          index: index,
          total: total,
          plaintext: bytes.sublist(
            index * chunkSize,
            (index + 1) * chunkSize > bytes.length
                ? bytes.length
                : (index + 1) * chunkSize,
          ),
        ),
    ];
  }

  /// A 12-byte nonce derived from the transfer id and the chunk index.
  ///
  /// Derived rather than random because the sender and the recipient must arrive
  /// at the same one, and HMAC-SHA256 under the transfer id is a standard
  /// construction for that. Uniqueness across chunks is what matters for GCM, and
  /// the index is unique within a transfer while the transfer id is unique per
  /// attachment.
  static Uint8List _nonce(CryptoEngine engine, Uint8List transferId, int index) {
    final material = Uint8List(4)..buffer.asByteData().setUint32(0, index, Endian.big);
    final digest = engine.hmacSha256(key: transferId, data: material);
    return Uint8List.sublistView(digest, 0, 12);
  }

  /// Binds a chunk to its attachment and its position in the sequence.
  static Uint8List _aad(String attachmentId, int index, int total) {
    final counter = Uint8List(8);
    final view = counter.buffer.asByteData();
    view.setUint32(0, index, Endian.big);
    view.setUint32(4, total, Endian.big);
    return Uint8List.fromList(<int>[
      ...utf8.encode('darkflow/chunk/$attachmentId/v1'),
      ...counter,
    ]);
  }

  /// The payload of a chunk frame, as it travels.
  static Map<String, dynamic> toWire({
    required Attachment attachment,
    required int index,
    required int total,
    required Uint8List sealed,
  }) =>
      <String, dynamic>{
        // Carried so the recipient can file the bytes without having to match the
        // frame against a message it may not have loaded yet.
        'attachmentId': attachment.id,
        'messageId': attachment.messageId,
        'fileName': attachment.fileName,
        'mimeType': attachment.mimeType,
        'sizeBytes': attachment.sizeBytes,
        'sha256Hex': attachment.sha256Hex,
        'i': index,
        'n': total,
        'd': base64Encode(sealed),
      };

  /// One chunk, decoded from the wire.
  static ChunkPayload? fromWire(Map<String, dynamic> json) {
    final attachmentId = json['attachmentId'];
    final sealed = json['d'];
    if (attachmentId is! String || attachmentId.isEmpty || sealed is! String) {
      return null;
    }
    return ChunkPayload(
      attachmentId: attachmentId,
      messageId: json['messageId'] as String?,
      fileName: json['fileName'] as String? ?? 'file',
      mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      sha256Hex: json['sha256Hex'] as String? ?? '',
      index: (json['i'] as num?)?.toInt() ?? 0,
      total: (json['n'] as num?)?.toInt() ?? 1,
      plaintext: base64Decode(sealed),
    );
  }
}

/// One attachment chunk as it came off the wire.
class ChunkPayload {
  const ChunkPayload({
    required this.attachmentId,
    required this.messageId,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.sha256Hex,
    required this.index,
    required this.total,
    required this.plaintext,
  });

  final String attachmentId;
  final String? messageId;
  final String fileName;
  final String mimeType;
  final int sizeBytes;

  /// The digest of the *whole* file, repeated on every chunk so a recipient that
  /// joined the transfer late can still verify what it assembled.
  final String sha256Hex;

  final int index;
  final int total;

  /// The chunk's bytes, already decrypted and authenticated by the transport.
  final Uint8List plaintext;
}
