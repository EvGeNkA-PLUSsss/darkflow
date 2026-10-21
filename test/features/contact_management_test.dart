import 'dart:io';

import 'package:darkflow/src/app/app_controller.dart';
import 'package:darkflow/src/crypto/dart_crypto_engine.dart';
import 'package:darkflow/src/crypto/onion_address.dart';
import 'package:darkflow/src/data/vault_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// Renaming, clearing and deleting are the only ways a user can destroy something
/// in a conversation, and the store is an append-only log: a delete that never
/// reached the log would look correct until the app was restarted, when the
/// messages would come back. These tests drive the real account layer against a
/// real vault in a temporary directory, assert against the records themselves, and
/// then lock and re-open the vault so the surviving state is proved to be the one
/// on disk.
///
/// The Argon2id cost is the production one, which measures at roughly a quarter of
/// a second here; lowering it would mean testing a vault that is not the one the
/// app builds.
void main() {
  const password = 'a test passphrase';

  late Directory sandbox;
  late AppController controller;
  late String peer;

  setUp(() async {
    // A real onion address rather than a made-up one: `addContact` validates the
    // checksum, so a hand-written address would be rejected and half of these
    // tests would pass for the wrong reason.
    final key = await DartCryptoEngine().generateEd25519();
    peer = OnionAddress.fromPublicKey(key.publicKey);

    sandbox = await Directory.systemTemp.createTemp('darkflow-contacts-');
    final paths = VaultPaths(sandbox);
    await paths.ensureCreated();
    controller = AppController(paths: paths);
    await controller.bootstrap();
    expect(controller.stage, AppStage.needsAccount);
    await controller.createAccount(
      displayName: 'Test Owner',
      about: '',
      password: password,
    );
    expect(controller.stage, AppStage.torSetup, reason: controller.failure ?? '');
  });

  tearDown(() async {
    // Locking first stops Tor and the peer server properly; `dispose` only
    // schedules that work, and a test ends before the schedule runs.
    await controller.lock();
    controller.dispose();
    try {
      if (sandbox.existsSync()) await sandbox.delete(recursive: true);
    } on FileSystemException {
      // A temporary directory the platform still holds open is not worth failing
      // an assertion over; the operating system cleans it up.
    }
  });

  /// Locks and re-opens the vault, which is the only way to prove that what the
  /// controller still shows is what survived on disk rather than what it kept in
  /// its own maps.
  Future<void> restart() async {
    await controller.lock();
    await controller.unlockWithPassword(password);
    expect(controller.stage, AppStage.ready, reason: controller.failure ?? '');
  }

  test('a chat message reaches the log, so the assertions below mean something',
      () async {
    await controller.addContact(onionAddress: peer);
    await controller.sendText(peer, 'first');
    await controller.sendText(peer, 'second');
    await controller.loadMessages(peer);

    expect(controller.messagesFor(peer), hasLength(2));
    final rows = await controller.store!.readAll('messages');
    expect(
      rows.where((row) => row['peerOnion'] == peer),
      hasLength(2),
      reason: 'VaultStore flushes on every record',
    );
  });

  test('renaming writes through and refuses a blank or overlong name', () async {
    await controller.addContact(onionAddress: peer, displayName: 'Bob');
    // Contact and conversation records are keyed by their own id — the onion
    // address is a field, not the key — so the id has to be carried along.
    final contactId = controller.contactFor(peer)!.id;

    expect(await controller.renameContact(peer, '  Robert  '), isTrue);
    expect(controller.contactFor(peer)!.displayName, 'Robert');
    expect(
      (await controller.store!.read('contacts', contactId))!['displayName'],
      'Robert',
    );

    expect(await controller.renameContact(peer, '   '), isFalse);
    expect(await controller.renameContact(peer, 'x' * 100), isFalse);
    expect(await controller.renameContact('nobody.onion', 'Nobody'), isFalse);
    expect(
      (await controller.store!.read('contacts', contactId))!['displayName'],
      'Robert',
      reason: 'a refused rename must not touch the record',
    );

    await restart();
    expect(controller.contactFor(peer)!.displayName, 'Robert');
  });

  test('clearing the history drops the messages, the attachments and the bytes',
      () async {
    await controller.addContact(onionAddress: peer);
    await controller.sendText(peer, 'keep me nowhere');

    // A file message, built the way `sendFile` builds one: the attachment is
    // written to the vault, then named by the message that carries it.
    final message = controller.messagesFor(peer).single;
    const attachmentId = 'attachment-1';
    final digest = await controller.fileVault!.importCiphertext(
      attachmentId: attachmentId,
      ciphertext: const <int>[1, 2, 3, 4],
    );
    expect(digest, isNotNull);
    final ciphertext = controller.fileVault!.ciphertextFile(attachmentId);
    expect(ciphertext.existsSync(), isTrue);
    await controller.store!.put('attachments', <String, dynamic>{
      'id': attachmentId,
      'messageId': message.id,
      'fileName': 'note.txt',
      'mimeType': 'text/plain',
      'sizeBytes': 4,
      'sha256Hex': '00',
      'createdAt': 0,
    });
    await controller.store!.put('messages', <String, dynamic>{
      ...message.toJson(),
      'attachmentId': attachmentId,
    });

    await controller.clearConversation(peer);

    expect(controller.messagesFor(peer), isEmpty);
    expect(
      (await controller.store!.readAll('messages')).where((row) => row['peerOnion'] == peer),
      isEmpty,
    );
    expect(await controller.store!.read('attachments', attachmentId), isNull);
    expect(
      ciphertext.existsSync(),
      isFalse,
      reason: 'the encrypted bytes must go too, not only the row',
    );
    // Clearing is not deleting: the contact is the point of keeping.
    expect(controller.contactFor(peer), isNotNull);

    await restart();
    await controller.loadMessages(peer);
    expect(
      controller.messagesFor(peer),
      isEmpty,
      reason: 'a thread that a restart brings back was never really cleared',
    );
    expect(controller.contactFor(peer), isNotNull);
  });

  test('clearing leaves the conversation row for the next message', () async {
    await controller.addContact(onionAddress: peer);
    await controller.sendText(peer, 'hello');
    await controller.clearConversation(peer);

    final rows = controller.conversations.where((row) => row.peerOnion == peer).toList();
    expect(rows, hasLength(1));
    expect(rows.single.lastMessagePreview, isEmpty);
    expect(rows.single.lastMessageAt, isNull);
  });

  test('deleting a contact removes it from every collection it appears in',
      () async {
    await controller.addContact(onionAddress: peer);
    final contactId = controller.contactFor(peer)!.id;
    final conversationId = controller.conversations.single.id;
    await controller.sendText(peer, 'gone with the contact');
    await controller.loadMessages(peer);
    expect(controller.messagesFor(peer), isNotEmpty);

    expect(await controller.deleteContact(peer), isTrue);

    expect(controller.contactFor(peer), isNull);
    expect(controller.messagesFor(peer), isEmpty);
    expect(
      controller.conversations.any((row) => row.peerOnion == peer),
      isFalse,
    );
    expect(await controller.store!.read('contacts', contactId), isNull);
    expect(await controller.store!.read('conversations', conversationId), isNull);
    expect(
      (await controller.store!.readAll('messages')).where((row) => row['peerOnion'] == peer),
      isEmpty,
    );

    await restart();
    await controller.loadMessages(peer);
    expect(controller.contactFor(peer), isNull);
    expect(controller.messagesFor(peer), isEmpty);
    expect(controller.conversations.any((row) => row.peerOnion == peer), isFalse);

    // The account is untouched: deleting a contact is not deleting a vault, and a
    // second delete of the same address has nothing left to do.
    expect(controller.account, isNotNull);
    expect(controller.isUnlocked, isTrue);
    expect(await controller.deleteContact(peer), isFalse);
  });
}
