import 'dart:convert';

import 'package:darkflow/src/crypto/sha3.dart';
import 'package:flutter_test/flutter_test.dart';

/// The SHA3-256 implementation is hand-written because the Dart ecosystem does
/// not ship one, and Tor's v3 onion addresses are defined in terms of it. These
/// are the official NIST FIPS 202 test vectors, so a regression here is
/// unambiguous.
void main() {
  group('SHA3-256 NIST vectors', () {
    test('the empty message', () {
      expect(
        _hex(Sha3.hash(const <int>[])),
        'a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a',
      );
    });

    test('"abc"', () {
      expect(
        _hex(Sha3.hash(utf8.encode('abc'))),
        '3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532',
      );
    });

    test('448-bit message', () {
      // FIPS 202: a message of 448 bits, i.e. exactly 56 bytes.
      final message = utf8.encode(
        'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
      );
      expect(
        _hex(Sha3.hash(message)),
        '41c0dba2a9d6240849100376a8235e2c82e1b9998a999e21db32dd97496d3376',
      );
    });

    test('896-bit message', () {
      final message = utf8.encode(
        'abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmn'
        'hijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu',
      );
      expect(
        _hex(Sha3.hash(message)),
        '916f6061fe879741ca6469b43971dfdb28b1a32dc36cb3254e812be27aad1d18',
      );
    });

    test('a million "a" characters', () {
      final message = List<int>.filled(1000000, 0x61);
      expect(
        _hex(Sha3.hash(message)),
        '5c8875ae474a3634ba4fd55ec85bffd661f32aca75c6d699d0cdcb6c115891c1',
      );
    });
  });

  group('incremental hashing', () {
    test('matches the one-shot digest across arbitrary chunk boundaries', () {
      final message = List<int>.generate(4096, (i) => (i * 37) & 0xff);
      final expected = _hex(Sha3.hash(message));

      // 136 is the sponge rate, so these sizes deliberately straddle a block
      // boundary and land exactly on one.
      for (final chunkSize in <int>[1, 7, 135, 136, 137, 272, 4096]) {
        final digest = Sha3Digest();
        for (var offset = 0; offset < message.length; offset += chunkSize) {
          final end = (offset + chunkSize).clamp(0, message.length);
          digest.update(message.sublist(offset, end));
        }
        expect(_hex(digest.digest()), expected, reason: 'chunk size $chunkSize');
      }
    });

    test('refuses to be reused', () {
      final digest = Sha3Digest()..update(utf8.encode('once'));
      digest.digest();
      expect(digest.digest, throwsStateError);
      expect(() => digest.update(const <int>[]), throwsStateError);
    });
  });
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
