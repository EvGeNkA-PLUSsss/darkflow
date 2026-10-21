import 'dart:io';
import 'dart:typed_data';

import 'package:darkflow/src/crypto/crypto_engine.dart';
import 'package:darkflow/src/crypto/dart_crypto_engine.dart';
import 'package:darkflow/src/crypto/key_vault.dart';
import 'package:darkflow/src/data/file_vault.dart';
import 'package:darkflow/src/data/vault_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// The encrypted store is what makes the promise "everything is protected by
/// your password" literal, so these tests check the on-disk format from the
/// outside: what survives a restart, what a stolen file reveals, and what
/// happens when a record is tampered with.
void main() {
  late Directory sandbox;
  late VaultPaths paths;
  final engine = DartCryptoEngine();
  final vault = KeyVault(DartCryptoEngine());

  /// Argon2id at test cost: the format is under test here, not the KDF.
  Future<MasterKeyRing> newRing() async {
    final (_, ring) = await vault.create(
      password: 'a test passphrase',
      params: Argon2Params.fast,
    );
    return ring;
  }

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('darkflow-test-');
    paths = VaultPaths(sandbox);
    await paths.ensureCreated();
  });

  tearDown(() async {
    if (sandbox.existsSync()) await sandbox.delete(recursive: true);
  });

  group('records', () {
    test('write, read back and delete', () async {
      final store = VaultStore(paths: paths, engine: engine);
      await store.open(await newRing());

      await store.put('contacts', <String, dynamic>{'id': 'a', 'name': 'Alice'});
      await store.put('contacts', <String, dynamic>{'id': 'b', 'name': 'Bob'});

      expect(await store.read('contacts', 'a'), containsPair('name', 'Alice'));
      expect((await store.readAll('contacts')), hasLength(2));

      await store.delete('contacts', 'a');
      expect(await store.read('contacts', 'a'), isNull);
      expect(await store.readAll('contacts'), hasLength(1));

      await store.close();
    });

    test('a later write to the same id wins', () async {
      final store = VaultStore(paths: paths, engine: engine);
      await store.open(await newRing());

      await store.put('contacts', <String, dynamic>{'id': 'a', 'name': 'Alice'});
      await store.put('contacts', <String, dynamic>{'id': 'a', 'name': 'Alicia'});
      expect(await store.read('contacts', 'a'), containsPair('name', 'Alicia'));

      await store.close();
    });

    test('a record without an id is refused', () async {
      final store = VaultStore(paths: paths, engine: engine);
      await store.open(await newRing());
      expect(
        () => store.put('contacts', <String, dynamic>{'name': 'nobody'}),
        throwsA(isA<ArgumentError>()),
      );
      await store.close();
    });

    test('reading before unlocking fails loudly', () async {
      final store = VaultStore(paths: paths, engine: engine);
      expect(() => store.readAll('contacts'), throwsA(isA<StateError>()));
    });

    test('collections are independent', () async {
      final store = VaultStore(paths: paths, engine: engine);
      await store.open(await newRing());
      await store.put('contacts', <String, dynamic>{'id': 'a', 'v': 1});
      await store.put('messages', <String, dynamic>{'id': 'a', 'v': 2});
      expect(await store.read('contacts', 'a'), containsPair('v', 1));
      expect(await store.read('messages', 'a'), containsPair('v', 2));
      await store.close();
    });
  });

  group('persistence', () {
    test('records survive a close and reopen with the same key', () async {
      final ring = await newRing();

      final first = VaultStore(paths: paths, engine: engine);
      await first.open(ring);
      await first.put('messages', <String, dynamic>{'id': 'm1', 'body': 'hello'});
      await first.put('messages', <String, dynamic>{'id': 'm2', 'body': 'world'});
      await first.delete('messages', 'm1');
      await first.close();

      final second = VaultStore(paths: paths, engine: engine);
      await second.open(ring);
      final messages = await second.readAll('messages');
      expect(messages, hasLength(1));
      expect(messages.single['body'], 'world');
      await second.close();
    });

    test('a different master key opens nothing', () async {
      final first = VaultStore(paths: paths, engine: engine);
      await first.open(await newRing());
      await first.put('messages', <String, dynamic>{'id': 'm1', 'body': 'secret'});
      await first.close();

      final second = VaultStore(paths: paths, engine: engine);
      await second.open(await newRing());
      // Not an exception: an unauthenticated record is skipped, because the
      // associated data and the AEAD tag make it indistinguishable from noise.
      expect(await second.readAll('messages'), isEmpty);
      await second.close();
    });

    test('a record reaches the disk before the store is closed', () async {
      // The store used to buffer writes in an `IOSink` and only flush on
      // close, so a record written a moment before the process died was lost:
      // the account record sat in the buffer and the log on disk stayed at zero
      // bytes. This test reads the file directly, with no flush and no close,
      // which is the situation a crash creates.
      final store = VaultStore(paths: paths, engine: engine);
      await store.open(await newRing());
      await store.put('account', <String, dynamic>{'id': 'a', 'name': 'Alice'});

      final onDisk = await paths.collectionLog('account').readAsBytes();
      expect(
        onDisk,
        isNotEmpty,
        reason: 'the write must be durable without an explicit close()',
      );
      await store.close();
    });

    test('deleting is durable too', () async {
      final store = VaultStore(paths: paths, engine: engine);
      await store.open(await newRing());
      await store.put('contacts', <String, dynamic>{'id': 'a'});
      await store.delete('contacts', 'a');

      // Two frames on disk: the record and its tombstone.
      final onDisk = await paths.collectionLog('contacts').readAsBytes();
      expect(onDisk.length, greaterThan(8));
      await store.close();
    });

    test('nothing readable is written to disk', () async {
      final store = VaultStore(paths: paths, engine: engine);
      await store.open(await newRing());
      await store.put('messages', <String, dynamic>{
        'id': 'm1',
        'body': 'the launch code is hunter2',
      });
      await store.flush();
      await store.close();

      final raw = await paths.collectionLog('messages').readAsBytes();
      final asText = String.fromCharCodes(raw);
      expect(raw, isNotEmpty);
      expect(asText.contains('hunter2'), isFalse);
      expect(asText.contains('launch'), isFalse);
      expect(asText.contains('body'), isFalse);
    });

    test('a truncated final record is dropped, earlier ones are kept', () async {
      final ring = await newRing();
      final store = VaultStore(paths: paths, engine: engine);
      await store.open(ring);
      await store.put('messages', <String, dynamic>{'id': 'm1', 'body': 'one'});
      await store.put('messages', <String, dynamic>{'id': 'm2', 'body': 'two'});
      await store.close();

      // Simulate a power loss halfway through the last append.
      final file = paths.collectionLog('messages');
      final bytes = await file.readAsBytes();
      await file.writeAsBytes(bytes.sublist(0, bytes.length - 7));

      final reopened = VaultStore(paths: paths, engine: engine);
      await reopened.open(ring);
      final messages = await reopened.readAll('messages');
      expect(messages, hasLength(1));
      expect(messages.single['body'], 'one');
      await reopened.close();
    });
  });

  group('compaction', () {
    test('rewrites the log to the live set and stays readable', () async {
      final ring = await newRing();
      final store = VaultStore(paths: paths, engine: engine);
      await store.open(ring);

      for (var i = 0; i < 200; i++) {
        await store.put('messages', <String, dynamic>{
          'id': 'm$i',
          'body': 'x' * 200,
        });
      }
      for (var i = 0; i < 190; i++) {
        await store.delete('messages', 'm$i');
      }
      await store.compact('messages');
      await store.close();

      // After compaction the file holds exactly the ten survivors.
      final reopened = VaultStore(paths: paths, engine: engine);
      await reopened.open(ring);
      expect(await reopened.readAll('messages'), hasLength(10));
      await reopened.close();
    });

    test('replaceAll leaves only the new set', () async {
      final store = VaultStore(paths: paths, engine: engine);
      await store.open(await newRing());
      await store.put('messages', <String, dynamic>{'id': 'old', 'body': 'gone'});
      await store.replaceAll('messages', <Map<String, dynamic>>[
        <String, dynamic>{'id': 'new1', 'body': 'kept'},
        <String, dynamic>{'id': 'new2', 'body': 'kept too'},
      ]);
      final messages = await store.readAll('messages');
      expect(messages.map((m) => m['id']), containsAll(<String>['new1', 'new2']));
      expect(messages, hasLength(2));
      await store.close();
    });
  });

  group('file vault', () {
    test('a file survives an import and a materialise', () async {
      final ring = await newRing();
      final store = VaultStore(paths: paths, engine: engine);
      await store.open(ring);

      final fileVault = FileVault(engine: engine, paths: paths)..unlock(ring);

      final source = File('${sandbox.path}${Platform.pathSeparator}original.bin');
      final content = Uint8List.fromList(List<int>.generate(700000, (i) => (i * 31) & 0xff));
      await source.writeAsBytes(content);

      final digest = await fileVault.import(attachmentId: 'file-1', source: source);
      expect(digest, hasLength(64));

      // The ciphertext on disk must not contain the plaintext.
      final ciphertext = await fileVault.ciphertextFile('file-1').readAsBytes();
      expect(ciphertext.length, greaterThan(content.length));
      expect(_contains(ciphertext, content.sublist(0, 64)), isFalse);

      final restored = await fileVault.materialise(
        attachmentId: 'file-1',
        fileName: 'original.bin',
      );
      expect(await restored.readAsBytes(), equals(content));

      await store.close();
    });

    test('a tampered chunk is detected', () async {
      final ring = await newRing();
      final store = VaultStore(paths: paths, engine: engine);
      await store.open(ring);
      final fileVault = FileVault(engine: engine, paths: paths)..unlock(ring);

      final source = File('${sandbox.path}${Platform.pathSeparator}small.bin');
      await source.writeAsBytes(List<int>.filled(1000, 7));
      await fileVault.import(attachmentId: 'file-2', source: source);

      final file = fileVault.ciphertextFile('file-2');
      final bytes = await file.readAsBytes();
      bytes[bytes.length - 5] ^= 0x01;
      await file.writeAsBytes(bytes);

      expect(
        () => fileVault.materialise(attachmentId: 'file-2', fileName: 'small.bin'),
        throwsA(isA<CryptoFailure>()),
      );
      await store.close();
    });

    test('a locked vault refuses to decrypt', () async {
      final ring = await newRing();
      final fileVault = FileVault(engine: engine, paths: paths);
      expect(fileVault.isUnlocked, isFalse);
      expect(
        () => fileVault.materialise(attachmentId: 'nope', fileName: 'x'),
        throwsA(isA<StateError>()),
      );
      ring.destroy();
    });

    test('a hostile file name cannot escape the cache directory', () async {
      final ring = await newRing();
      final store = VaultStore(paths: paths, engine: engine);
      await store.open(ring);
      final fileVault = FileVault(engine: engine, paths: paths)..unlock(ring);

      final source = File('${sandbox.path}${Platform.pathSeparator}payload.bin');
      await source.writeAsBytes(List<int>.filled(16, 1));
      await fileVault.import(attachmentId: 'file-3', source: source);

      final restored = await fileVault.materialise(
        attachmentId: 'file-3',
        fileName: r'..\..\..\Windows\System32\evil.dll',
      );
      expect(
        restored.path.startsWith(paths.cacheDirectory.path),
        isTrue,
        reason: 'the decrypted copy must stay inside the cache directory',
      );
      expect(restored.path.contains('..'), isFalse);
      await store.close();
    });

    test('purging the cache removes decrypted copies', () async {
      final ring = await newRing();
      final store = VaultStore(paths: paths, engine: engine);
      await store.open(ring);
      final fileVault = FileVault(engine: engine, paths: paths)..unlock(ring);

      final source = File('${sandbox.path}${Platform.pathSeparator}c.bin');
      await source.writeAsBytes(List<int>.filled(32, 3));
      await fileVault.import(attachmentId: 'file-4', source: source);
      final restored = await fileVault.materialise(attachmentId: 'file-4', fileName: 'c.bin');
      expect(restored.existsSync(), isTrue);

      await paths.purgeCache();
      expect(restored.existsSync(), isFalse);
      // The ciphertext is untouched: only the working copy goes.
      expect(fileVault.ciphertextFile('file-4').existsSync(), isTrue);
      await store.close();
    });
  });
}

/// A naive substring search, used only to assert that plaintext is absent from
/// a ciphertext file.
bool _contains(List<int> haystack, List<int> needle) {
  if (needle.isEmpty || haystack.length < needle.length) return false;
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}
