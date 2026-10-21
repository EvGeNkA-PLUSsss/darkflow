import 'dart:convert';
import 'dart:typed_data';

import 'crypto_engine.dart';

/// A sealed blob: the on-disk representation of anything secret.
///
/// Layout: `[version:1][nonce:12][ciphertext || tag]`. The version byte lets a
/// future release migrate to a different AEAD without guessing at the format of
/// existing rows, and the associated data binds the blob to its location so a
/// ciphertext cannot be moved between records, tables or accounts.
abstract final class Cipher {
  /// The only format version currently produced.
  static const int version = 1;

  /// Nonce length for both AES-256-GCM and XChaCha20-Poly1305 is fixed at 12
  /// bytes here; XChaCha accepts 24 but 12 is equally safe with a random nonce
  /// and keeps one code path.
  static const int nonceLength = 12;

  /// Overhead of the authentication tag.
  static const int tagLength = 16;

  /// Encrypts [plaintext] under [key] with [aad] as associated data.
  static Uint8List seal({
    required CryptoEngine engine,
    required Uint8List key,
    required List<int> plaintext,
    required List<int> aad,
    Uint8List? nonce,
  }) {
    _requireKey(key);
    final nonceBytes = nonce ?? engine.randomBytes(nonceLength);
    if (nonceBytes.length != nonceLength) {
      throw ArgumentError.value(nonceBytes.length, 'nonce', 'must be $nonceLength bytes');
    }
    final body = engine.aesGcmEncrypt(
      key: key,
      nonce: nonceBytes,
      plaintext: Uint8List.fromList(plaintext),
      aad: Uint8List.fromList(aad),
    );
    final out = Uint8List(1 + nonceLength + body.length);
    out[0] = version;
    out.setRange(1, 1 + nonceLength, nonceBytes);
    out.setRange(1 + nonceLength, out.length, body);
    return out;
  }

  /// Opens a blob produced by [seal]. Throws [CryptoFailure] when the blob was
  /// tampered with, truncated, or belongs to a different context.
  static Uint8List open({
    required CryptoEngine engine,
    required Uint8List key,
    required List<int> sealed,
    required List<int> aad,
  }) {
    _requireKey(key);
    if (sealed.length < 1 + nonceLength + tagLength) {
      throw const CryptoFailure('sealed blob is too short to contain a nonce and tag');
    }
    if (sealed[0] != version) {
      throw CryptoFailure('unsupported sealed blob version ${sealed[0]}');
    }
    final nonce = Uint8List.fromList(sealed.sublist(1, 1 + nonceLength));
    final body = Uint8List.fromList(sealed.sublist(1 + nonceLength));
    return engine.aesGcmDecrypt(
      key: key,
      nonce: nonce,
      ciphertext: body,
      aad: Uint8List.fromList(aad),
    );
  }

  /// Convenience wrapper for string payloads.
  static Uint8List sealString({
    required CryptoEngine engine,
    required Uint8List key,
    required String plaintext,
    required List<int> aad,
  }) =>
      seal(engine: engine, key: key, plaintext: utf8.encode(plaintext), aad: aad);

  static String openString({
    required CryptoEngine engine,
    required Uint8List key,
    required List<int> sealed,
    required List<int> aad,
  }) =>
      utf8.decode(open(engine: engine, key: key, sealed: sealed, aad: aad));

  /// Encrypts a file body in independent chunks so a multi-gigabyte attachment
  /// can be streamed without holding it all in memory.
  ///
  /// Every chunk carries its own nonce and its index in the associated data,
  /// which prevents chunks from being reordered or truncated undetectably.
  static Uint8List sealChunk({
    required CryptoEngine engine,
    required Uint8List key,
    required List<int> plaintext,
    required String fileId,
    required int index,
  }) =>
      seal(
        engine: engine,
        key: key,
        plaintext: plaintext,
        aad: _chunkAad(fileId, index),
      );

  static Uint8List openChunk({
    required CryptoEngine engine,
    required Uint8List key,
    required List<int> sealed,
    required String fileId,
    required int index,
  }) =>
      open(
        engine: engine,
        key: key,
        sealed: sealed,
        aad: _chunkAad(fileId, index),
      );

  /// Builds the associated-data string for a record in the encrypted store.
  static List<int> recordAad(String table, String id) =>
      utf8.encode('darkflow/$table/$id/v1');

  static List<int> _chunkAad(String fileId, int index) =>
      utf8.encode('darkflow/chunk/$fileId/$index/v1');

  static void _requireKey(Uint8List key) {
    if (key.length != 32) {
      throw ArgumentError.value(
        key.length,
        'key',
        'DarkFlow keys are 256-bit; got a ${key.length}-byte key',
      );
    }
  }
}
