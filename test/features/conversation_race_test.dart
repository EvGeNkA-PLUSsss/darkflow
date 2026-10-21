import 'dart:io';

import 'package:darkflow/src/app/app_controller.dart';
import 'package:darkflow/src/crypto/onion_address.dart';
import 'package:darkflow/src/data/vault_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// One contact, one conversation — even when two handshakes arrive at once.
///
/// ## Why this is worth a test
///
/// `_ensureConversation` awaits a store write, and it is called from two places that can
/// interleave: the receiving side of a handshake, which fires whenever a peer dials or redials,
/// and the send path. The mesh retries a failed dial on a twenty-second timer, so two
/// announcements for the same peer is ordinary rather than exotic.
///
/// The property that makes it safe is the order of two lines: the new conversation is registered
/// in the map **before** anything is awaited, so a second caller finds it and returns it instead
/// of building a rival. Move that assignment below the `await` and the window opens — the second
/// caller sees an empty map, creates a second conversation with a fresh id, and writes it too.
/// Both rows then exist on disk, and after the next restart the chat list shows the same contact
/// twice.
///
/// The test exists because this is a shape that looks correct and is one line away from being
/// wrong, and because a duplicate is invisible until the application is reopened.
void main() {
  const password = 'a test passphrase';

  late Directory sandbox;
  late AppController controller;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('df-conv-race-');
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

  test('concurrent handshakes with the same peer yield one conversation', () async {
    final identity = await controller.engine.generateEd25519();
    final peer = OnionAddress.fromPublicKey(identity.publicKey);
    final exchange = await controller.engine.generateX25519();

    // Started together, not awaited one at a time: this is the interleaving the mesh produces
    // when a retry and a reconnect land in the same tick.
    await Future.wait<void>(<Future<void>>[
      for (var i = 0; i < 6; i++)
        controller.debugRememberPeer(
          onionAddress: peer,
          exchangePublicKey: exchange.publicKey,
          displayName: 'Peer $i',
        ),
    ]);

    final matching = controller.conversations.where((c) => c.peerOnion == peer).toList();
    expect(matching, hasLength(1),
        reason: 'a second conversation for the same peer shows the contact twice after a '
            'restart');
  });

  test('the single conversation survives a reload', () async {
    // The in-memory map agreeing is not enough: duplicates come back from storage on the next
    // unlock, which is exactly when a user would notice.
    final identity = await controller.engine.generateEd25519();
    final peer = OnionAddress.fromPublicKey(identity.publicKey);
    final exchange = await controller.engine.generateX25519();

    await Future.wait<void>(<Future<void>>[
      for (var i = 0; i < 6; i++)
        controller.debugRememberPeer(
          onionAddress: peer,
          exchangePublicKey: exchange.publicKey,
        ),
    ]);

    await controller.lock();
    await controller.unlockWithPassword(password);

    final matching = controller.conversations.where((c) => c.peerOnion == peer).toList();
    expect(matching, hasLength(1),
        reason: 'one row on disk, or the list grows by one per handshake');
  });

  test('a message sent at the same time does not create a second conversation', () async {
    // The other caller. Sending to a peer whose conversation does not exist yet goes through the
    // same method, so a handshake and a first message arriving together is the interleaving that
    // matters most in practice.
    final identity = await controller.engine.generateEd25519();
    final peer = OnionAddress.fromPublicKey(identity.publicKey);
    final exchange = await controller.engine.generateX25519();

    await Future.wait<void>(<Future<void>>[
      controller.debugRememberPeer(
        onionAddress: peer,
        exchangePublicKey: exchange.publicKey,
        displayName: 'Peer',
      ),
      controller.sendText(peer, 'hello'),
    ]);

    final matching = controller.conversations.where((c) => c.peerOnion == peer).toList();
    expect(matching, hasLength(1),
        reason: 'duplicates=${matching.length} ids=${matching.map((c) => c.id).join(',')}');
    // And the message is in the thread the list will open.
    final thread = controller.messagesFor(peer);
    expect(thread, isNotEmpty,
        reason: 'the message must be filed under the conversation the list opens; '
            'conversationIds=${thread.map((m) => m.conversationId).join(',')} '
            'expected=${matching.isEmpty ? 'n/a' : matching.single.id}');
  });

  test('a record accepted before the lock is on disk after it', () async {
    // What the queue and the drain are for: a write that `put` has already accepted must survive
    // a lock that follows immediately. This is the "type a message, put the phone down" case.
    //
    // The write is awaited, and that is the honest form of the test rather than a convenience.
    // `sendText` documents that it returns false when the vault is closing so the caller can keep
    // the draft — a message refused *because* the vault closed is not a lost message, it is one
    // the user still has in the box. What must never happen is a write that was accepted and then
    // dropped by the teardown, and that is what this pins.
    final identity = await controller.engine.generateEd25519();
    final peer = OnionAddress.fromPublicKey(identity.publicKey);
    final exchange = await controller.engine.generateX25519();
    await controller.debugRememberPeer(
      onionAddress: peer,
      exchangePublicKey: exchange.publicKey,
      displayName: 'Peer',
    );

    expect(await controller.sendText(peer, 'the last thing I typed'), isTrue);

    await controller.lock();
    await controller.unlockWithPassword(password);

    // Read from disk explicitly: `messagesFor` returns the in-memory thread, which an unlock
    // leaves empty until the screen asks for it. Asserting on it without this would pass for the
    // wrong reason — an empty list "not containing" the message.
    await controller.loadMessages(peer);

    final bodies = controller.messagesFor(peer).map((m) => m.body).toList();
    expect(bodies, contains('the last thing I typed'),
        reason: 'a record accepted before the lock has to be on disk after it');
    expect(controller.conversations.where((c) => c.peerOnion == peer), hasLength(1));
  });

  test('a refused write leaves neither a contact nor a conversation behind', () async {
    // The divergence that produced "the contact only appears after a restart", in its cleanest
    // form: memory is updated and storage is not.
    //
    // The order in `_rememberPeer` used to be memory first, storage second. When the write was
    // refused — the vault closing, which a lock during a handshake makes ordinary — the contact
    // and its conversation stayed in the maps. The list drew them, the user saw them, and they
    // were gone at the next launch. Locking and reading back from disk is what makes that visible
    // here: the assertion is not about what is in memory, it is about what survived.
    final identity = await controller.engine.generateEd25519();
    final peer = OnionAddress.fromPublicKey(identity.publicKey);
    final exchange = await controller.engine.generateX25519();

    // Close the vault, then attempt the handshake into it. Every write must be refused.
    await controller.lock();
    await expectLater(
      controller.debugRememberPeer(
        onionAddress: peer,
        exchangePublicKey: exchange.publicKey,
        displayName: 'Never written',
      ),
      throwsA(isA<Object>()),
      reason: 'a write into a closed vault has to fail loudly, not silently',
    );

    // Nothing was left claiming a row exists.
    expect(controller.contactFor(peer), isNull,
        reason: 'a contact that storage refused must not be in memory either');
    expect(controller.conversations.where((c) => c.peerOnion == peer), isEmpty);
  });

  test('a contact written before the lock is on disk after it', () async {
    // The other half, and the property the ordering exists to preserve: what was accepted has to
    // survive. Asserted by reading back through a genuine lock and unlock, so the check is against
    // the file rather than against the map that was just populated.
    final identity = await controller.engine.generateEd25519();
    final peer = OnionAddress.fromPublicKey(identity.publicKey);
    final exchange = await controller.engine.generateX25519();

    await controller.debugRememberPeer(
      onionAddress: peer,
      exchangePublicKey: exchange.publicKey,
      displayName: 'Survives',
    );

    await controller.lock();
    await controller.unlockWithPassword(password);

    expect(controller.contactFor(peer), isNotNull,
        reason: 'the contact and the name come from storage after an unlock');
    expect(controller.contactFor(peer)!.displayName, 'Survives');
    expect(controller.conversations.where((c) => c.peerOnion == peer), isNotEmpty,
        reason: 'the conversation is what makes the contact visible in the list');
  });

  test('a send refused because the vault closed does not half-record itself', () async {
    // The other side of the same coin, and the failure this actually prevents.
    //
    // `sendText` used to insert the message into the in-memory thread *before* writing it. When
    // the vault closed in between, the write threw and the message stayed in memory: drawn in the
    // conversation, absent from disk, gone at the next launch. A user would see their message and
    // then watch it disappear.
    //
    // Storage is now written first, so a refusal leaves memory untouched. The assertion is that
    // the two agree — whatever the thread shows had to have been stored.
    final identity = await controller.engine.generateEd25519();
    final peer = OnionAddress.fromPublicKey(identity.publicKey);
    final exchange = await controller.engine.generateX25519();
    await controller.debugRememberPeer(
      onionAddress: peer,
      exchangePublicKey: exchange.publicKey,
    );

    await controller.lock();

    // Everything after the lock is refused, and nothing is remembered.
    final accepted = await controller.sendText(peer, 'written after the lock');
    expect(accepted, isFalse, reason: 'a locked vault cannot accept a message');
    expect(controller.messagesFor(peer), isEmpty,
        reason: 'a refused message must not appear in a thread it was never stored in');
  });
}
