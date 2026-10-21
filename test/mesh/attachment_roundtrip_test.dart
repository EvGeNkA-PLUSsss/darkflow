import 'dart:io';
import 'dart:typed_data';

import 'package:darkflow/src/crypto/dart_crypto_engine.dart';
import 'package:darkflow/src/crypto/key_vault.dart';
import 'package:darkflow/src/data/file_vault.dart';
import 'package:darkflow/src/data/vault_store.dart';
import 'package:darkflow/src/mesh/file_transfer.dart';
import 'package:flutter_test/flutter_test.dart';

/// The attachment path end to end, through two separate encrypted vaults.
///
/// The unit tests above cover the sealing. This covers the part that was actually
/// missing: a file written by one vault, sent as chunks, and landing in another
/// vault in a state that can be read back. Two real vaults are used because the
/// interesting failure is not a bad ciphertext — it is a recipient whose stored
/// file cannot be decrypted, which only shows up when the bytes go through
/// `import` and `readPlaintext` on different keys.
void main() {
  late Directory senderDir;
  late Directory recipientDir;
  late FileVault senderVault;
  late FileVault recipientVault;
  late DartCryptoEngine engine;
  late Uint8List sharedKey;

  setUp(() async {
    engine = DartCryptoEngine();

    final senderPaths = VaultPaths(
      await Directory.systemTemp.createTemp('df-send-vault-'),
    );
    final recipientPaths = VaultPaths(
      await Directory.systemTemp.createTemp('df-recv-vault-'),
    );
    senderDir = senderPaths.root;
    recipientDir = recipientPaths.root;
    await senderPaths.ensureCreated();
    await recipientPaths.ensureCreated();

    // Different master keys on purpose: the recipient must never depend on the
    // sender's key, and the transport must not either.
    final senderRing = await KeyVault(engine).create(password: 'sender passphrase');
    final recipientRing = await KeyVault(engine).create(password: 'recipient passphrase');
    senderVault = FileVault(engine: engine, paths: senderPaths)..unlock(senderRing.$2);
    recipientVault = FileVault(engine: engine, paths: recipientPaths)
      ..unlock(recipientRing.$2);

    sharedKey = Uint8List.fromList(List<int>.generate(32, (int i) => (i * 31) % 256));
  });

  tearDown(() async {
    for (final directory in <Directory>[senderDir, recipientDir]) {
      if (directory.existsSync()) await directory.delete(recursive: true);
    }
  });

  test('a file sealed by one vault survives the trip into another', () async {
    // The sender records a voice note.
    final source = File('${senderDir.path}${Platform.pathSeparator}note.m4a');
    final body = List<int>.generate(180 * 1024, (int i) => (i * 13) % 256);
    await source.writeAsBytes(body);
    final digest = await senderVault.import(attachmentId: 'att-1', source: source);

    // What the transfer sends is the plaintext, because the digest covers the
    // plaintext: re-sealing with the sender's random nonces would produce bytes
    // the recipient could never check.
    final plaintext = await senderVault.readPlaintext('att-1');
    expect(plaintext, body);

    final chunks = FileTransfer.sealAll(
      engine: engine,
      sharedKey: sharedKey,
      attachmentId: 'att-1',
      bytes: plaintext,
    );

    // The recipient opens each chunk and reassembles in index order.
    final assembled = BytesBuilder(copy: false);
    for (var index = 0; index < chunks.length; index++) {
      assembled.add(FileTransfer.openChunk(
        engine: engine,
        sharedKey: sharedKey,
        attachmentId: 'att-1',
        index: index,
        total: chunks.length,
        sealed: chunks[index],
      ));
    }
    final received = assembled.takeBytes();

    // The digest the sender published is the check the recipient performs.
    expect(FileTransfer.verifyDigest(received, digest), isNull);

    // And the file is then sealed under the *recipient's* key.
    final storedDigest = await recipientVault.importBytes(
      attachmentId: 'att-1',
      bytes: received,
    );
    // Identical digests: the same plaintext under a different key.
    expect(storedDigest, digest);

    // The part that was broken: the recipient has to be able to read it back.
    expect(await recipientVault.readPlaintext('att-1'), body);
  });

  test('a file the recipient never receives cannot be read', () async {
    // The state a voice note was stuck in: a record exists, the bytes do not.
    // `readPlaintext` has to fail loudly rather than return something empty.
    await expectLater(
      recipientVault.readPlaintext('never-received'),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('an empty file round-trips', () async {
    // Zero-byte payloads are the edge that tends to produce a file the walker
    // cannot read.
    final source = File('${senderDir.path}${Platform.pathSeparator}empty.bin');
    await source.writeAsBytes(const <int>[]);
    await senderVault.import(attachmentId: 'att-empty', source: source);
    expect(await senderVault.readPlaintext('att-empty'), isEmpty);

    await recipientVault.importBytes(attachmentId: 'att-empty', bytes: const <int>[]);
    expect(await recipientVault.readPlaintext('att-empty'), isEmpty);
  });

  test('a truncated ciphertext is refused rather than read short', () async {
    final source = File('${senderDir.path}${Platform.pathSeparator}big.bin');
    await source.writeAsBytes(List<int>.generate(300 * 1024, (int i) => i % 256));
    await senderVault.import(attachmentId: 'att-big', source: source);

    // Cut the file mid-chunk, which is what a crash during a write leaves behind.
    final ciphertext = senderVault.ciphertextFile('att-big');
    final bytes = await ciphertext.readAsBytes();
    await ciphertext.writeAsBytes(bytes.sublist(0, bytes.length - 100), flush: true);

    await expectLater(
      senderVault.readPlaintext('att-big'),
      throwsA(predicate((Object error) => '$error'.contains('truncated'))),
    );
  });
}
