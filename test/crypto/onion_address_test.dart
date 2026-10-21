import 'dart:typed_data';

import 'package:darkflow/src/crypto/dart_crypto_engine.dart';
import 'package:darkflow/src/crypto/onion_address.dart';
import 'package:flutter_test/flutter_test.dart';

/// Onion address derivation is the single function that makes "your onion
/// address is your username" true, so it gets tested from both directions:
/// derivation from a key, and recovery of the key from an address.
void main() {
  final engine = DartCryptoEngine();

  group('derivation', () {
    test('an address is 56 base32 characters plus the suffix', () async {
      final pair = await engine.generateEd25519();
      final address = OnionAddress.fromPublicKey(pair.publicKey);

      expect(address.endsWith('.onion'), isTrue);
      expect(address.length, 56 + '.onion'.length);
      expect(RegExp(r'^[a-z2-7]{56}\.onion$').hasMatch(address), isTrue);
    });

    test('is deterministic for a given key', () async {
      final pair = await engine.ed25519KeyPairFromSeed(
        Uint8List.fromList(List<int>.generate(32, (i) => i)),
      );
      final first = OnionAddress.fromPublicKey(pair.publicKey);
      final second = OnionAddress.fromPublicKey(pair.publicKey);
      expect(first, second);
    });

    test('the public key round-trips through the address', () async {
      final pair = await engine.generateEd25519();
      final address = OnionAddress.fromPublicKey(pair.publicKey);
      expect(OnionAddress.publicKeyOf(address), equals(pair.publicKey));
    });

    test('a single flipped bit in the key gives a different address', () async {
      final pair = await engine.generateEd25519();
      final altered = Uint8List.fromList(pair.publicKey);
      altered[0] ^= 0x01;
      expect(
        OnionAddress.fromPublicKey(altered),
        isNot(OnionAddress.fromPublicKey(pair.publicKey)),
      );
    });

    test('rejects a key of the wrong length', () {
      expect(
        () => OnionAddress.fromPublicKey(Uint8List(31)),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('validation', () {
    test('accepts a real, publicly known v3 address', () {
      // DuckDuckGo's onion service. A wrong checksum algorithm would reject it,
      // which makes this a genuine end-to-end check of the derivation.
      const address = 'duckduckgogg42xjoc72x3sjasowoarfbgcmvfimaftt6twagswzczad.onion';
      expect(OnionAddress.isValid(address), isTrue);
      expect(OnionAddress.publicKeyOf(address), isNotNull);
    });

    test('rejects a corrupted checksum', () async {
      final pair = await engine.generateEd25519();
      final address = OnionAddress.fromPublicKey(pair.publicKey);
      final body = address.substring(0, 56);

      // The checksum occupies body[53] and body[54], immediately before the
      // version byte at body[55]. Replacing a character there with a
      // definitely-different one must break validation — an earlier version of
      // this test swapped two neighbours, which silently does nothing when they
      // happen to be equal.
      final original = body[53];
      final replacement = original == 'a' ? 'b' : 'a';
      final corrupted =
          '${body.substring(0, 53)}$replacement${body.substring(54)}.onion';

      expect(corrupted, isNot(address));
      expect(OnionAddress.isValid(corrupted), isFalse);
    });

    test('rejects a flipped version byte', () async {
      final pair = await engine.generateEd25519();
      final body = OnionAddress.fromPublicKey(pair.publicKey).substring(0, 56);
      final corrupted = '${body.substring(0, 55)}a.onion';
      expect(OnionAddress.isValid(corrupted), isFalse);
    });

    test('rejects addresses with the wrong shape', () {
      expect(OnionAddress.isValid(''), isFalse);
      expect(OnionAddress.isValid('short.onion'), isFalse);
      expect(OnionAddress.isValid('${'a' * 56}.onion'), isFalse);
      expect(OnionAddress.isValid('${'8' * 56}.onion'), isFalse); // 8 is not base32
      expect(OnionAddress.isValid('${'a' * 55}.onion'), isFalse);
      expect(
        OnionAddress.isValid('duckduckgogg42xjoc72x3sjasowoarfbgcmvfimaftt6twagswzczad'),
        isFalse,
      );
    });
  });

  group('normalisation and display', () {
    test('accepts the forms a user might paste', () {
      const body = 'duckduckgogg42xjoc72x3sjasowoarfbgcmvfimaftt6twagswzczad';
      const expected = '$body.onion';
      expect(OnionAddress.normalise(body), expected);
      expect(OnionAddress.normalise('$body.onion'), expected);
      expect(OnionAddress.normalise('  HTTP://$body.onion/  '), expected);
      expect(OnionAddress.normalise('https://${body.toUpperCase()}.onion/path'), expected);
    });

    test('shortening keeps both ends so two addresses stay distinguishable', () {
      const address = 'duckduckgogg42xjoc72x3sjasowoarfbgcmvfimaftt6twagswzczad.onion';
      final short = OnionAddress.shorten(address);
      // Both ends are taken from the address itself rather than hard-coded, so
      // the assertion describes the rule instead of one string.
      expect(short.startsWith(address.substring(0, 8)), isTrue);
      expect(short.endsWith(address.substring(address.length - '.onion'.length - 4)), isTrue);
      expect(short.length, lessThan(address.length));
    });
  });
}
