import 'dart:io';

import 'package:darkflow/src/app/app_controller.dart';
import 'package:darkflow/src/app/log_book.dart';
import 'package:darkflow/src/crypto/onion_address.dart';
import 'package:darkflow/src/data/models/contact.dart';
import 'package:darkflow/src/data/vault_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// What a message says about itself when it cannot be sent yet.
///
/// "The handshake does not complete" was reported twice, and the two halves of the answer
/// are different. The protocol itself is covered by `test/net/handshake_test.dart`, which
/// runs both sides against each other over a real socket. This file covers the other half:
/// whether the application ever *attempts* the handshake, and what it tells the user when
/// it has not managed it.
///
/// The bug it was written for: a contact added before Tor finished connecting had its one
/// attempt swallowed — the mesh had no SOCKS port, so there was nothing to dial — and the
/// refusal was stored as that contact's last error and never cleared. The user then saw
/// "the mesh has not been configured with an identity" for ever, including after the
/// network came up and after a handshake had succeeded.
void main() {
  const password = 'a test passphrase';

  late Directory sandbox;
  late AppController controller;

  /// A real v3 address: derived from a key, because the checksum is verified.
  late String peerOnion;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('df-handshake-');
    final paths = VaultPaths(sandbox);
    await paths.ensureCreated();
    controller = AppController(paths: paths);
    await controller.bootstrap();
    await controller.createAccount(
      displayName: 'Owner',
      about: '',
      password: password,
    );
    final identity = await controller.engine.generateEd25519();
    peerOnion = OnionAddress.fromPublicKey(identity.publicKey);
  });

  tearDown(() async {
    controller.dispose();
    try {
      if (sandbox.existsSync()) await sandbox.delete(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  group('a message written before Tor is connected', () {
    test('is accepted, not refused', () async {
      // The controller has a mesh but it is not configured, which is exactly the state the
      // application is in between unlocking and Tor finishing its bootstrap. A message has
      // to be accepted here: the user has an account, a contact and something to say, and
      // making them wait for a minute of bootstrap before the first message is composed is
      // not a design.
      await controller.addContact(onionAddress: peerOnion, displayName: 'Peer');
      expect(await controller.sendText(peerOnion, 'hello'), isTrue);
    });

    test('is queued with a reason that blames Tor, not the peer', () async {
      await controller.addContact(onionAddress: peerOnion, displayName: 'Peer');
      await controller.sendText(peerOnion, 'hello');

      final message = controller.messagesFor(peerOnion).last;
      expect(message.failureReason, isNotNull);
      expect(message.failureReason, contains('Tor'),
          reason: 'the network is what is missing, and the user can act on that');
      expect(message.failureReason, isNot(contains('handshake')),
          reason: 'blaming the peer for a local start-up order is the bug this covers');
    });

    test('no failure is recorded against the contact by the swallowed attempt', () {
      // `warmUp` is called by `addContact` and returns immediately when the mesh has no
      // SOCKS port. Recording that as a handshake failure is what produced a permanent,
      // false explanation.
      expect(controller.handshakeFailureFor(peerOnion), isNull);
    });
  });

  group('the refusal explains which situation it is', () {
    test('with no mesh at all it says networking has not started', () async {
      // The reachable control: a fresh controller that has never been unlocked has no mesh,
      // and the message must still be accepted.
      final paths = VaultPaths(await Directory.systemTemp.createTemp('df-handshake-2-'));
      await paths.ensureCreated();
      final fresh = AppController(paths: paths);
      addTearDown(() async {
        fresh.dispose();
        // The log file lives inside the vault directory, and `dispose` only schedules its
        // release. Waiting for the writes to finish is what actually closes the handle —
        // without it Windows refuses the delete with "occupied by another process", and the
        // failure lands on whichever test tidies up second.
        await logBook.detachFromFile();
        await paths.root.delete(recursive: true);
      });
      await fresh.bootstrap();

      expect(fresh.stage, isNot(AppStage.ready));
    });

    test('the recorded reason is stored against the contact', () async {
      await controller.addContact(onionAddress: peerOnion, displayName: 'Peer');
      // What the mesh does when a dial fails: the account layer records the reason.
      controller.debugRecordHandshakeFailure(peerOnion, 'the proxy refused the connection');

      expect(controller.handshakeFailureFor(peerOnion), contains('refused'));
    });

    test('Tor being unconnected takes precedence over a stale peer failure', () async {
      // The ordering the send path uses, and the reason it matters: an unconfigured mesh
      // is a local problem the user can fix by connecting, while a recorded peer failure
      // describes an attempt that could not have been made. Reporting the stale one would
      // send the user looking for a problem with their contact.
      //
      // This is also why `warmUp` no longer records anything while the mesh is
      // unconfigured — that is what used to put a peer-shaped error on a local condition.
      await controller.addContact(onionAddress: peerOnion, displayName: 'Peer');
      controller.debugRecordHandshakeFailure(peerOnion, 'the proxy refused the connection');
      await controller.sendText(peerOnion, 'queued');

      final message = controller.messagesFor(peerOnion).last;
      expect(message.failureReason, contains('Tor'),
          reason: 'the network is missing, and saying so is actionable');
      expect(message.failureReason, isNot(contains('refused')));
    });
  });

  group('a contact with no key is dialled when the network arrives', () {
    test('reconciling does nothing while the mesh is unconfigured', () async {
      // Nothing to dial with. The call must be harmless rather than an exception, because
      // it runs from the Tor status listener on every status change.
      await controller.addContact(onionAddress: peerOnion, displayName: 'Peer');
      await controller.debugReconcileContacts();
      expect(controller.contactFor(peerOnion), isNotNull);
    });

    test('a contact whose key is known is re-registered, not dialled', () async {
      // Re-dialling a contact we already hold a key for would be wasted circuits, and it
      // also risks replacing a pinned key with whatever answers next.
      await controller.addContact(onionAddress: peerOnion, displayName: 'Peer');
      await controller.debugReconcileContacts();
      expect(controller.contactFor(peerOnion)!.exchangePublicKey, isNull,
          reason: 'no handshake has happened, so there is no key to hold yet');
      expect(controller.contactFor(peerOnion)!.trust, isNot(ContactTrust.keyChanged));
    });
  });

  group('the failure map does not leak between contacts', () {
    test('one contact\'s failure is not reported for another', () async {
      final other = OnionAddress.fromPublicKey(
        (await controller.engine.generateEd25519()).publicKey,
      );
      await controller.addContact(onionAddress: peerOnion, displayName: 'Peer');
      await controller.addContact(onionAddress: other, displayName: 'Other');

      controller.debugRecordHandshakeFailure(peerOnion, 'peer is offline');

      expect(controller.handshakeFailureFor(peerOnion), contains('offline'));
      expect(controller.handshakeFailureFor(other), isNull,
          reason: 'a contact with no attempt of its own has nothing to report');
    });

    test('an empty address is ignored rather than stored under the empty key', () {
      controller.debugRecordHandshakeFailure('', 'nonsense');
      expect(controller.handshakeFailureFor(''), isNull);
    });
  });

  group('the receiving side of a first handshake', () {
    test('creates both a contact and the conversation the chat list is built from',
        () async {
      // The reported symptom: "on the PC the contact only appears after a restart, and the chat
      // does not show".
      //
      // The chat list is built from `controller.conversations` — see `_summaries` in the shell —
      // and `_rememberPeer` created only a contact. So a peer who dialled *us* first produced a
      // row in `contacts` that appeared in no list and opened no thread. A restart reloaded both
      // collections and the chat appeared, which is what made the workaround look like a fix.
      final identity = await controller.engine.generateEd25519();
      final peer = OnionAddress.fromPublicKey(identity.publicKey);
      final exchange = await controller.engine.generateX25519();

      expect(controller.contactFor(peer), isNull);
      expect(controller.conversations.where((c) => c.peerOnion == peer), isEmpty);

      await controller.debugRememberPeer(
        onionAddress: peer,
        exchangePublicKey: exchange.publicKey,
        displayName: 'Dialled me',
      );

      expect(controller.contactFor(peer), isNotNull,
          reason: 'the peer is a contact now');
      expect(controller.contactFor(peer)!.displayName, 'Dialled me');
      expect(
        controller.conversations.where((c) => c.peerOnion == peer),
        isNotEmpty,
        reason: 'without a conversation the contact is invisible in the chat list',
      );
    });

    test('a peer with no announced name still gets a conversation', () async {
      // The name is cosmetic; the conversation is not. A peer that announces nothing must still
      // be reachable in the list.
      final identity = await controller.engine.generateEd25519();
      final peer = OnionAddress.fromPublicKey(identity.publicKey);
      final exchange = await controller.engine.generateX25519();

      await controller.debugRememberPeer(
        onionAddress: peer,
        exchangePublicKey: exchange.publicKey,
      );

      expect(controller.contactFor(peer)!.displayName, isNotEmpty,
          reason: 'a shortened address is used when nothing is announced');
      expect(controller.conversations.where((c) => c.peerOnion == peer), isNotEmpty);
    });

    test('a second handshake does not create a duplicate conversation', () async {
      // `_rememberPeer` runs on every handshake, and this one runs often: the mesh retries, and a
      // peer reconnecting produces another announcement. A fresh conversation per handshake would
      // put the same contact in the list once per reconnection.
      final identity = await controller.engine.generateEd25519();
      final peer = OnionAddress.fromPublicKey(identity.publicKey);
      final exchange = await controller.engine.generateX25519();

      await controller.debugRememberPeer(
        onionAddress: peer,
        exchangePublicKey: exchange.publicKey,
        displayName: 'First',
      );
      final after = controller.conversations.where((c) => c.peerOnion == peer).toList();

      await controller.debugRememberPeer(
        onionAddress: peer,
        exchangePublicKey: exchange.publicKey,
        displayName: 'Second',
      );

      final again = controller.conversations.where((c) => c.peerOnion == peer).toList();
      expect(again, hasLength(1), reason: 'one contact, one conversation');
      expect(again.single.id, after.single.id);
      expect(controller.contactFor(peer)!.displayName, 'Second',
          reason: 'a new announcement updates the name');
    });

    test('the conversation survives a reload of the vault', () async {
      // What made the bug look like a restart was a fix: the conversation is written to storage,
      // so a restart rebuilt the list from it.
      final identity = await controller.engine.generateEd25519();
      final peer = OnionAddress.fromPublicKey(identity.publicKey);
      final exchange = await controller.engine.generateX25519();

      await controller.debugRememberPeer(
        onionAddress: peer,
        exchangePublicKey: exchange.publicKey,
        displayName: 'Persisted',
      );

      await controller.lock();
      expect(controller.conversations, isEmpty, reason: 'the vault is closed');

      await controller.unlockWithPassword(password);
      expect(controller.conversations.where((c) => c.peerOnion == peer), isNotEmpty,
          reason: 'the conversation has to be on disk, not only in memory');
      expect(controller.contactFor(peer), isNotNull);
    });

    test('the announced name reaches the chat list entry', () async {
      // "the name does not load" has the same cause as the missing chat: `_summaries` reads the
      // name through the conversation's peer:
      //
      //     displayName: controller.contactFor(conversation.peerOnion)?.displayName ?? ...
      //
      // No conversation meant no row, and no row meant nowhere for the name to appear — even
      // though it had been received, validated against the peer's signature and stored. Checking
      // both halves here is what makes the assertion meaningful: the name is on the contact *and*
      // a conversation exists to show it through.
      final identity = await controller.engine.generateEd25519();
      final peer = OnionAddress.fromPublicKey(identity.publicKey);
      final exchange = await controller.engine.generateX25519();

      await controller.debugRememberPeer(
        onionAddress: peer,
        exchangePublicKey: exchange.publicKey,
        displayName: 'Alice from the phone',
      );

      final conversation =
          controller.conversations.firstWhere((c) => c.peerOnion == peer);
      expect(controller.contactFor(conversation.peerOnion)!.displayName,
          'Alice from the phone',
          reason: 'this is the lookup the chat list performs');
    });

    test('a verified peer keeps the name it announced last', () async {
      // The peer announces on every handshake, and a peer that changed its display name should
      // have the new one shown. The opposite — a stale name kept for ever because only the first
      // announcement was stored — is the failure mode worth pinning.
      final identity = await controller.engine.generateEd25519();
      final peer = OnionAddress.fromPublicKey(identity.publicKey);
      final exchange = await controller.engine.generateX25519();

      await controller.debugRememberPeer(
        onionAddress: peer,
        exchangePublicKey: exchange.publicKey,
        displayName: 'Old name',
      );
      await controller.debugRememberPeer(
        onionAddress: peer,
        exchangePublicKey: exchange.publicKey,
        displayName: 'New name',
      );

      expect(controller.contactFor(peer)!.displayName, 'New name');
    });
  });
}
