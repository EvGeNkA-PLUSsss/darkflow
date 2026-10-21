import 'dart:convert';

import 'package:darkflow/src/crypto/crypto_engine.dart';
import 'package:darkflow/src/crypto/dart_crypto_engine.dart';
import 'package:darkflow/src/crypto/key_vault.dart';
import 'package:flutter_test/flutter_test.dart';

/// The vault is the one place where a mistake costs the user everything: too
/// weak and the master key falls; too strict and a correct password is refused.
/// These tests cover both directions.
///
/// The Argon2id parameters are lowered to the test profile so the suite stays
/// fast; the production cost is measured separately by `tool/bench_crypto.dart`.
void main() {
  final vault = KeyVault(DartCryptoEngine());
  const password = 'correct horse battery staple';

  group('password wrapping', () {
    test('creates a vault that the same password opens', () async {
      final (header, ring) = await vault.create(
        password: password,
        params: Argon2Params.fast,
      );
      expect(header.passwordWrap.blob, isNotEmpty);

      final reopened = await vault.unlockWithPassword(header, password);
      expect(reopened.masterKey, equals(ring.masterKey));
    });

    test('the header survives a JSON round trip', () async {
      final (header, ring) = await vault.create(
        password: password,
        params: Argon2Params.fast,
      );
      final decoded = VaultHeader.decode(header.encode());
      final reopened = await vault.unlockWithPassword(decoded, password);
      expect(reopened.masterKey, equals(ring.masterKey));
    });

    test('a wrong password is refused', () async {
      final (header, _) = await vault.create(
        password: password,
        params: Argon2Params.fast,
      );
      expect(
        () => vault.unlockWithPassword(header, 'not the password'),
        throwsA(isA<WrongSecretException>()),
      );
    });

    test('the master key never appears in the header', () async {
      final (header, ring) = await vault.create(
        password: password,
        params: Argon2Params.fast,
      );
      final encoded = header.encode();
      final hex = ring.masterKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      expect(encoded.contains(hex), isFalse);
      expect(encoded.contains(password), isFalse);
    });

    test('two vaults created with the same password differ', () async {
      final (first, firstRing) = await vault.create(
        password: password,
        params: Argon2Params.fast,
      );
      final (second, secondRing) = await vault.create(
        password: password,
        params: Argon2Params.fast,
      );
      // Distinct salts mean distinct keys, so an attacker cannot amortise one
      // derivation across two accounts.
      expect(first.passwordKdf.salt, isNot(equals(second.passwordKdf.salt)));
      expect(firstRing.masterKey, isNot(equals(secondRing.masterKey)));
    });

    test('a short password is rejected at creation', () {
      expect(
        () => vault.create(password: 'short', params: Argon2Params.fast),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('a header written by an older build', () {
    // Older vaults carried `pinKdf` and `pinWrap` beside the password wrap.
    // Those fields are gone from the format, but a file on disk may still have
    // them, and parsing has to ignore them rather than refuse the file: the
    // password wrap was always the authority and it is untouched. These tests
    // keep that deliberate tolerance covered.
    Map<String, dynamic> withLegacyPinFields(String encoded) {
      final fields = jsonDecode(encoded) as Map<String, dynamic>;
      return <String, dynamic>{
        ...fields,
        'pinKdf': fields['passwordKdf'],
        'pinWrap': fields['passwordWrap'],
      };
    }

    test('ignores the legacy fields and still opens with the password', () async {
      final (header, ring) = await vault.create(
        password: password,
        params: Argon2Params.fast,
      );

      final decoded = VaultHeader.decode(jsonEncode(withLegacyPinFields(header.encode())));
      final reopened = await vault.unlockWithPassword(decoded, password);
      expect(reopened.masterKey, equals(ring.masterKey));
    });

    test('drops the legacy fields when the header is written back', () async {
      final (header, _) = await vault.create(
        password: password,
        params: Argon2Params.fast,
      );

      final decoded = VaultHeader.decode(jsonEncode(withLegacyPinFields(header.encode())));
      final rewritten = decoded.encode();
      expect(rewritten, isNot(contains('pinKdf')));
      expect(rewritten, isNot(contains('pinWrap')));
    });
  });

  group('password change', () {
    test('re-wraps the master key without changing it', () async {
      final (header, ring) = await vault.create(
        password: password,
        params: Argon2Params.fast,
      );
      final changed = await vault.changePassword(
        header: header,
        ring: ring,
        newPassword: 'a completely different passphrase',
        params: Argon2Params.fast,
      );

      final reopened = await vault.unlockWithPassword(changed, 'a completely different passphrase');
      expect(reopened.masterKey, equals(ring.masterKey));

      expect(
        () => vault.unlockWithPassword(changed, password),
        throwsA(isA<WrongSecretException>()),
      );
    });
  });

  group('subkeys', () {
    test('different labels give different keys, the same label is stable', () async {
      final (_, ring) = await vault.create(
        password: password,
        params: Argon2Params.fast,
      );
      final db = ring.databaseKey;
      final files = ring.fileKey;
      expect(db, isNot(equals(files)));
      expect(ring.databaseKey, equals(db));
      expect(ring.subkey('db').length, 32);
    });

    test('destroying the ring zeroes the master key', () async {
      final (_, ring) = await vault.create(
        password: password,
        params: Argon2Params.fast,
      );
      ring.destroy();
      expect(ring.masterKey.every((byte) => byte == 0), isTrue);
    });
  });

  group('benchmark', () {
    test('reports a duration for the given parameters', () async {
      final elapsed = await vault.benchmark(Argon2Params.fast);
      expect(elapsed, greaterThan(Duration.zero));
    });
  });
}
