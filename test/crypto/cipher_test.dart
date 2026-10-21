import 'dart:typed_data';

import 'package:darkflow/src/crypto/cipher.dart';
import 'package:darkflow/src/crypto/crypto_engine.dart';
import 'package:darkflow/src/crypto/dart_crypto_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// The sealed-blob format is the only container DarkFlow writes secrets into,
/// so its failure modes matter as much as its happy path: a blob that opens
/// after being tampered with would silently defeat every other protection.
void main() {
  final engine = DartCryptoEngine();
  final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
  final aad = Cipher.recordAad('messages', 'abc123');

  group('sealed blobs', () {
    test('round-trip', () {
      final sealed = Cipher.seal(
        engine: engine,
        key: key,
        plaintext: <int>[1, 2, 3, 4, 5],
        aad: aad,
      );
      expect(
        Cipher.open(engine: engine, key: key, sealed: sealed, aad: aad),
        equals(<int>[1, 2, 3, 4, 5]),
      );
    });

    test('the layout carries a version byte and a twelve-byte nonce', () {
      final sealed = Cipher.seal(engine: engine, key: key, plaintext: <int>[0], aad: aad);
      expect(sealed[0], Cipher.version);
      expect(sealed.length, 1 + Cipher.nonceLength + 1 + Cipher.tagLength);
    });

    test('two seals of the same plaintext differ', () {
      final first = Cipher.seal(engine: engine, key: key, plaintext: <int>[7], aad: aad);
      final second = Cipher.seal(engine: engine, key: key, plaintext: <int>[7], aad: aad);
      expect(first, isNot(equals(second)));
    });

    test('a flipped ciphertext bit is rejected', () {
      final sealed = Cipher.seal(
        engine: engine,
        key: key,
        plaintext: List<int>.filled(64, 9),
        aad: aad,
      );
      final tampered = Uint8List.fromList(sealed);
      tampered[tampered.length - 20] ^= 0x01;
      expect(
        () => Cipher.open(engine: engine, key: key, sealed: tampered, aad: aad),
        throwsA(isA<CryptoFailure>()),
      );
    });

    test('a flipped tag bit is rejected', () {
      final sealed = Cipher.seal(engine: engine, key: key, plaintext: <int>[1], aad: aad);
      final tampered = Uint8List.fromList(sealed);
      tampered[tampered.length - 1] ^= 0x01;
      expect(
        () => Cipher.open(engine: engine, key: key, sealed: tampered, aad: aad),
        throwsA(isA<CryptoFailure>()),
      );
    });

    test('a different associated data is rejected', () {
      final sealed = Cipher.seal(engine: engine, key: key, plaintext: <int>[1], aad: aad);
      expect(
        () => Cipher.open(
          engine: engine,
          key: key,
          sealed: sealed,
          aad: Cipher.recordAad('messages', 'somewhere-else'),
        ),
        throwsA(isA<CryptoFailure>()),
      );
    });

    test('a different key is rejected', () {
      final sealed = Cipher.seal(engine: engine, key: key, plaintext: <int>[1], aad: aad);
      final otherKey = Uint8List.fromList(List<int>.generate(32, (i) => 255 - i));
      expect(
        () => Cipher.open(engine: engine, key: otherKey, sealed: sealed, aad: aad),
        throwsA(isA<CryptoFailure>()),
      );
    });

    test('a truncated blob is rejected before any decryption is attempted', () {
      final sealed = Cipher.seal(engine: engine, key: key, plaintext: <int>[1], aad: aad);
      expect(
        () => Cipher.open(
          engine: engine,
          key: key,
          sealed: Uint8List.sublistView(sealed, 0, 10),
          aad: aad,
        ),
        throwsA(isA<CryptoFailure>()),
      );
    });

    test('an unknown format version is refused', () {
      final sealed = Uint8List.fromList(
        Cipher.seal(engine: engine, key: key, plaintext: <int>[1], aad: aad),
      );
      sealed[0] = 99;
      expect(
        () => Cipher.open(engine: engine, key: key, sealed: sealed, aad: aad),
        throwsA(isA<CryptoFailure>()),
      );
    });

    test('a key of the wrong size is refused up front', () {
      expect(
        () => Cipher.seal(engine: engine, key: Uint8List(16), plaintext: <int>[1], aad: aad),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('file chunks', () {
    test('reordering two chunks is detected', () {
      final first = Cipher.sealChunk(
        engine: engine,
        key: key,
        plaintext: List<int>.filled(32, 1),
        fileId: 'file-1',
        index: 0,
      );
      final second = Cipher.sealChunk(
        engine: engine,
        key: key,
        plaintext: List<int>.filled(32, 2),
        fileId: 'file-1',
        index: 1,
      );
      // Opening chunk 1 with the ciphertext of chunk 0 must fail, which is what
      // stops an attacker from shuffling a file's contents.
      expect(
        () => Cipher.openChunk(
          engine: engine,
          key: key,
          sealed: second,
          fileId: 'file-1',
          index: 0,
        ),
        throwsA(isA<CryptoFailure>()),
      );
      expect(
        Cipher.openChunk(engine: engine, key: key, sealed: first, fileId: 'file-1', index: 0),
        equals(List<int>.filled(32, 1)),
      );
    });

    test('a chunk cannot be moved to another file', () {
      final chunk = Cipher.sealChunk(
        engine: engine,
        key: key,
        plaintext: <int>[1, 2, 3],
        fileId: 'file-1',
        index: 0,
      );
      expect(
        () => Cipher.openChunk(
          engine: engine,
          key: key,
          sealed: chunk,
          fileId: 'file-2',
          index: 0,
        ),
        throwsA(isA<CryptoFailure>()),
      );
    });
  });

  group('HMAC-SHA256', () {
    // RFC 4231 test case 2: key "Jefe", data "what do ya want for nothing?".
    test('matches RFC 4231', () {
      final mac = engine.hmacSha256(
        key: Uint8List.fromList('Jefe'.codeUnits),
        data: Uint8List.fromList('what do ya want for nothing?'.codeUnits),
      );
      expect(
        mac.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843',
      );
    });

    test('a key longer than the block size is hashed first, per the RFC', () {
      // RFC 4231 test case 6.
      final mac = engine.hmacSha256(
        key: Uint8List.fromList(List<int>.filled(131, 0xaa)),
        data: Uint8List.fromList(
          'Test Using Larger Than Block-Size Key - Hash Key First'.codeUnits,
        ),
      );
      expect(
        mac.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        '60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54',
      );
    });
  });

  group('HKDF-SHA256', () {
    // RFC 5869 test case 1.
    test('matches RFC 5869', () {
      final okm = Hkdf.derive(
        engine: engine,
        ikm: Uint8List.fromList(List<int>.filled(22, 0x0b)),
        salt: Uint8List.fromList(
          List<int>.generate(13, (i) => i),
        ),
        info: Uint8List.fromList(List<int>.generate(10, (i) => 0xf0 + i)),
        length: 42,
      );
      expect(
        okm.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        '3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865',
      );
    });

    test('an empty salt behaves as a string of zero bytes', () {
      final withEmpty = Hkdf.derive(
        engine: engine,
        ikm: Uint8List.fromList(const <int>[1, 2, 3]),
        salt: Uint8List(0),
        info: const <int>[],
        length: 32,
      );
      final withZeros = Hkdf.derive(
        engine: engine,
        ikm: Uint8List.fromList(const <int>[1, 2, 3]),
        salt: Uint8List(Hkdf.hashLength),
        info: const <int>[],
        length: 32,
      );
      expect(withEmpty, equals(withZeros));
    });
  });
}
