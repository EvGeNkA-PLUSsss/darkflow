import 'dart:io';

import 'package:darkflow/src/app/app_controller.dart';
import 'package:darkflow/src/crypto/onion_address.dart';
import 'package:darkflow/src/data/vault_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// What survives a session, end to end.
///
/// ## What this adds over the single-purpose tests
///
/// Each storage fix has its own test: the write queue, the drain on close, the ordering in one
/// method. Those prove one property each, and they all pass while an *interaction* between them
/// is still broken — which is the shape the reported symptoms kept taking. A contact appeared
/// after a restart; a name did not load; a chat did not show. All three are statements about what
/// survives a session, not about one method's behaviour.
///
/// So this file exercises the sequence a person performs and then checks the state from disk:
/// add a contact, receive a handshake, write a message, rename, block, lock, unlock, and read
/// everything back. It is deliberately the same assertions the chat list makes, because that is
/// what "the contact does not appear" means.
void main() {
  const password = 'a session passphrase';

  late Directory sandbox;
  late AppController controller;

  /// A fresh controller over the same directory, so state has to come from the file.
  Future<AppController> reopen(AppController previous) async {
    previous.dispose();
    // Released the way the application releases it: the log file lives inside the vault directory,
    // and a handle left open makes the directory undeletable on Windows.
    final next = AppController(paths: VaultPaths(sandbox));
    await next.bootstrap();
    await next.unlockWithPassword(password);
    return next;
  }

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('df-lifecycle-');
    final paths = VaultPaths(sandbox);
    await paths.ensureCreated();
    controller = AppController(paths: paths);
    await controller.bootstrap();
    await controller.createAccount(
      displayName: 'Owner',
      about: '',
      password: password,
    );
  });

  tearDown(() async {
    controller.dispose();
    if (sandbox.existsSync()) {
      try {
        await sandbox.delete(recursive: true);
      } on FileSystemException {
        // Best effort; the assertions have already run.
      }
    }
  });

  /// A peer address derived from a real key, so the checksum is valid.
  Future<(String onion, Future<dynamic> Function() key)> peer() async {
    final signing = await controller.engine.generateEd25519();
    return (OnionAddress.fromPublicKey(signing.publicKey), controller.engine.generateX25519);
  }

  test('a handshaked contact, its conversation and its name survive a restart', () async {
    final (onion, keyOf) = await peer();
    final exchange = await keyOf() as dynamic;

    await controller.debugRememberPeer(
      onionAddress: onion,
      exchangePublicKey: exchange.publicKey,
      displayName: 'Alice',
    );

    controller = await reopen(controller);

    // The three things the report was about, checked where the list checks them.
    expect(controller.contactFor(onion), isNotNull, reason: 'the contact is on disk');
    expect(controller.contactFor(onion)!.displayName, 'Alice', reason: 'and so is the name');
    expect(
      controller.conversations.where((c) => c.peerOnion == onion),
      isNotEmpty,
      reason: 'and the conversation that makes it visible in the chat list',
    );
  });

  test('a manually added contact survives a restart', () async {
    // The path a user takes by pasting or typing an address, as opposed to being dialled.
    final (onion, _) = await peer();

    final added = await controller.addContact(onionAddress: onion, displayName: 'Bob');
    expect(added, isNotNull);

    controller = await reopen(controller);

    expect(controller.contactFor(onion), isNotNull);
    expect(controller.contactFor(onion)!.displayName, 'Bob');
    expect(controller.conversations.where((c) => c.peerOnion == onion), isNotEmpty);
  });

  test('a message, a rename and a block all survive a restart', () async {
    final (onion, keyOf) = await peer();
    final exchange = await keyOf() as dynamic;
    await controller.debugRememberPeer(
      onionAddress: onion,
      exchangePublicKey: exchange.publicKey,
      displayName: 'Alice',
    );

    expect(await controller.sendText(onion, 'first'), isTrue);
    expect(await controller.renameContact(onion, 'Alice the builder'), isTrue);
    await controller.setBlocked(onion, true);

    controller = await reopen(controller);

    expect(controller.contactFor(onion)!.displayName, 'Alice the builder',
        reason: 'a rename that reverts was displayed and then lost');
    expect(controller.contactFor(onion)!.blocked, isTrue,
        reason: 'a block that reverts lets the contact write again');
    await controller.loadMessages(onion);
    expect(
      controller.messagesFor(onion).map((m) => m.body),
      contains('first'),
      reason: 'the message has to be in the thread the list opens',
    );
  });

  test('a conversation is not duplicated by a restart', () async {
    // The chat list is built from conversations, so a duplicate is two rows for one contact. The
    // write queue and the shared creation future both exist to prevent it, and a restart is where
    // a duplicate written earlier becomes visible.
    final (onion, keyOf) = await peer();
    final exchange = await keyOf() as dynamic;

    // Several handshakes, as a retrying mesh produces.
    for (var i = 0; i < 4; i++) {
      await controller.debugRememberPeer(
        onionAddress: onion,
        exchangePublicKey: exchange.publicKey,
        displayName: 'Alice $i',
      );
    }
    expect(await controller.sendText(onion, 'hi'), isTrue);

    controller = await reopen(controller);

    expect(controller.conversations.where((c) => c.peerOnion == onion), hasLength(1),
        reason: 'one contact, one row in the list');
  });

  test('an attachment record and its message survive together', () async {
    // The pair that a placeholder-for-ever comes from: the message refers to an attachment id, and
    // if the attachment record did not reach the disk the bubble has nothing to resolve.
    final (onion, keyOf) = await peer();
    final exchange = await keyOf() as dynamic;
    await controller.debugRememberPeer(
      onionAddress: onion,
      exchangePublicKey: exchange.publicKey,
      displayName: 'Alice',
    );

    final source = File('${sandbox.path}${Platform.pathSeparator}note.txt');
    await source.writeAsString('a small file');
    expect(await controller.sendFile(onion, source), isTrue);

    controller = await reopen(controller);

    await controller.loadMessages(onion);
    final sent = controller.messagesFor(onion).where((m) => m.attachmentId != null).toList();
    expect(sent, hasLength(1), reason: 'the message is on disk');
    expect(controller.attachmentFor(sent.single.attachmentId), isNotNull,
        reason: 'and so is the record it points at, or the bubble draws a placeholder for ever');
  });
}
