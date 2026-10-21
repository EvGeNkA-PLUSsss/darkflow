import 'dart:io';
import 'dart:typed_data';

import 'package:darkflow/src/crypto/dart_crypto_engine.dart';
import 'package:darkflow/src/data/models/message.dart';
import 'package:darkflow/src/mesh/mesh_service.dart';
import 'package:darkflow/src/net/protocol/frames.dart' as frames;
import 'package:flutter_test/flutter_test.dart';

/// Regression tests for the message pipeline.
///
/// Every case here is a bug that was found by reading the code and confirmed by
/// the shape of the fix, rather than a property somebody always knew. Each one
/// documents what used to happen, because the *why* is the part that stops it
/// coming back.
void main() {
  group('delivery status is monotonic', () {
    test('a message cannot fall back to an earlier stage', () {
      expect(MessageStatus.delivered.rank, greaterThan(MessageStatus.sending.rank));
      expect(MessageStatus.read.rank, greaterThan(MessageStatus.delivered.rank));
      expect(MessageStatus.sent.rank, greaterThan(MessageStatus.sending.rank));
      expect(MessageStatus.queued.rank, lessThan(MessageStatus.sending.rank));

      // The failure state sits outside the progression, so it never wins a
      // "which of these two is later" comparison — `AppController._applyStatus`
      // moves a message to `failed` explicitly instead.
      expect(MessageStatus.failed.rank, lessThan(MessageStatus.queued.rank));
    });

    test('reading the ranks the way the controller does', () {
      // Guards the exact comparison the controller relies on. Delivery races
      // sending: the mesh reports its outcome from a callback, so `delivered` can
      // land before the `sending` write that follows the send call. The old code
      // applied both unconditionally, which pushed a delivered message back to
      // `sending` — a bubble showing an upward arrow for ever, with the outbox
      // already finished and nothing left to ever correct it.
      bool wins(MessageStatus current, MessageStatus next) =>
          next == MessageStatus.failed || next.rank >= current.rank;

      expect(wins(MessageStatus.delivered, MessageStatus.sending), isFalse);
      expect(wins(MessageStatus.read, MessageStatus.delivered), isFalse);
      expect(wins(MessageStatus.sending, MessageStatus.delivered), isTrue);
      expect(wins(MessageStatus.queued, MessageStatus.sending), isTrue);
      expect(wins(MessageStatus.delivered, MessageStatus.failed), isTrue);
    });

    test('a reason still lands when the status does not move', () {
      // The mesh reports `queued` *with* an explanation when it has nowhere to
      // leave an envelope. The controller resolves the status to the current one
      // and writes the reason anyway, so the bubble can show a clock with the
      // sentence under it. Returning early on "status unchanged" — which is what
      // the first version of this guard did — threw the sentence away and left the
      // user with a clock and no reason.
      MessageStatus resolve(MessageStatus current, MessageStatus reported) =>
          (reported == MessageStatus.failed || reported.rank >= current.rank)
              ? reported
              : current;

      expect(resolve(MessageStatus.queued, MessageStatus.queued), MessageStatus.queued);
      expect(resolve(MessageStatus.sending, MessageStatus.queued), MessageStatus.sending);
      expect(resolve(MessageStatus.sending, MessageStatus.failed), MessageStatus.failed);
    });
  });

  group('failure reasons can be cleared', () {
    Message failed() => Message(
          id: 'm1',
          conversationId: 'c1',
          peerOnion: 'peer.onion',
          direction: MessageDirection.outgoing,
          kind: MessageKind.text,
          createdAt: DateTime.utc(2026, 1, 1),
          body: 'hello',
          status: MessageStatus.failed,
          failureReason: 'No route yet.',
        );

    test('clearFailureReason removes the explanation', () {
      final delivered = failed().copyWith(
        status: MessageStatus.delivered,
        clearFailureReason: true,
      );
      expect(delivered.failureReason, isNull);
      expect(delivered.status, MessageStatus.delivered);
      // The rest of the record survives.
      expect(delivered.body, 'hello');
      expect(delivered.peerOnion, 'peer.onion');
      expect(delivered.id, 'm1');
    });

    test('omitting the flag keeps the explanation, as before', () {
      // The flag has to be opt-in: many call sites pass a status and nothing
      // else, and silently wiping the reason there would hide why a message
      // failed.
      expect(failed().copyWith(status: MessageStatus.sending).failureReason,
          'No route yet.');
    });

    test('a null failureReason without the flag leaves the old text in place', () {
      // This is the trap the flag exists for: `copyWith(failureReason: null)`
      // cannot be told apart from "not provided".
      expect(failed().copyWith(status: MessageStatus.sending, failureReason: null)
          .failureReason, 'No route yet.');
    });
  });

  group('an incoming message knows who wrote it', () {
    test('the frame carries the sender from the envelope, not the payload', () {
      final sent = Message(
        id: 'm-1',
        conversationId: 'c-1',
        peerOnion: 'bob.onion',
        direction: MessageDirection.outgoing,
        kind: MessageKind.text,
        createdAt: DateTime.utc(2026, 2, 3, 4, 5),
        body: 'hello Bob',
      );

      final wire = frames.MessageFrame(message: sent).encode();
      final decoded = frames.Frame.decode(
        wire.codeUnits,
        peerOnion: 'alice.onion',
      );

      expect(decoded, isA<frames.MessageFrame>());
      final message = (decoded as frames.MessageFrame).message;
      // The sender's address is the one thing the payload deliberately omits: the
      // envelope is already addressed and sealed, so the writer has no reason to
      // say who they are — and the receiver cannot guess. Hard-coding it empty is
      // what made a received text message unfileable, because the account layer
      // had no conversation to put it in.
      expect(message.peerOnion, 'alice.onion');
      expect(message.direction, MessageDirection.incoming);
      // `fromWireJson` gives an incoming message the delivered status, which is
      // what the thread renders.
      expect(message.status, MessageStatus.delivered);
      expect(message.body, 'hello Bob');
      expect(message.createdAt, DateTime.utc(2026, 2, 3, 4, 5));
    });

    test('a receipt round-trips its ids, flag and timestamp', () {
      final at = DateTime.utc(2026, 2, 3, 4, 5, 6);
      final decoded = frames.Frame.decode(
        frames.ReceiptFrame(
          messageIds: const <String>['a', 'b'],
          read: true,
          at: at,
        ).encode().codeUnits,
      );
      expect(decoded, isA<frames.ReceiptFrame>());
      final receipt = decoded as frames.ReceiptFrame;
      expect(receipt.messageIds, <String>['a', 'b']);
      expect(receipt.read, isTrue);
      expect(receipt.at, at);
    });

    test('a decoded frame with no sender stays empty rather than inventing one',
        () {
      // The account layer treats an empty origin as "cannot be filed" and drops
      // it, which is the honest outcome — better than filing it under a made-up
      // address.
      final decoded = frames.Frame.decode(
        frames.MessageFrame(
          message: Message(
            id: 'm-2',
            conversationId: '',
            peerOnion: '',
            direction: MessageDirection.outgoing,
            kind: MessageKind.text,
            createdAt: DateTime.utc(2026),
            body: 'x',
          ),
        ).encode().codeUnits,
      );
      expect((decoded as frames.MessageFrame).message.peerOnion, isEmpty);
    });
  });

  group('outbound envelopes', () {
    test('are keyed by the message id, which is what delivery reports name', () async {
      final engine = DartCryptoEngine();
      final mine = await engine.generateX25519();
      final theirs = await engine.generateX25519();

      final service = MeshService(engine: engine, storageDirectory: _scratch());
      service.configure(
        identity: MeshIdentity(
          onionAddress: 'me.onion',
          identityPrivateKey: Uint8List(32),
          identityPublicKey: Uint8List(32),
          exchangePrivateKey: mine.privateKey,
          exchangePublicKey: mine.publicKey,
          displayName: 'Me',
        ),
        socksHost: '127.0.0.1',
        // Nothing is listening, so delivery fails — which is fine: this asserts
        // the identifier, not the delivery.
        socksPort: 9,
        remotePort: 80,
      );
      service.rememberPeer(
        onionAddress: 'peer.onion',
        exchangePublicKey: theirs.publicKey,
      );

      final message = Message(
        id: 'message-42',
        conversationId: 'c',
        peerOnion: 'peer.onion',
        direction: MessageDirection.outgoing,
        kind: MessageKind.text,
        createdAt: DateTime.utc(2026),
        body: 'hi',
      );

      final envelope = await service.sendMessage(message: message);
      // `MeshDeliveryChanged.messageId` is read straight off `envelope.id` and
      // looked up in the account layer's threads by message id. If these two ever
      // diverge, every status update silently targets nothing.
      expect(envelope.id, message.id);
      expect(envelope.destinationOnion, 'peer.onion');
      expect(envelope.originOnion, 'me.onion');
      expect(service.outboxSize, 1);

      await service.dispose();
    });

    test('refuse to send without an exchange key', () async {
      final engine = DartCryptoEngine();
      final mine = await engine.generateX25519();
      final service = MeshService(engine: engine, storageDirectory: _scratch());
      service.configure(
        identity: MeshIdentity(
          onionAddress: 'me.onion',
          identityPrivateKey: Uint8List(32),
          identityPublicKey: Uint8List(32),
          exchangePrivateKey: mine.privateKey,
          exchangePublicKey: mine.publicKey,
          displayName: 'Me',
        ),
        socksHost: '127.0.0.1',
        socksPort: 9,
        remotePort: 80,
      );

      await expectLater(
        service.sendMessage(
          message: Message(
            id: 'm',
            conversationId: 'c',
            peerOnion: 'stranger.onion',
            direction: MessageDirection.outgoing,
            kind: MessageKind.text,
            createdAt: DateTime.utc(2026),
            body: 'hi',
          ),
        ),
        throwsA(isA<StateError>()),
      );
      await service.dispose();
    });
  });

  group('a peer key is never silently replaced', () {
    Future<MeshService> configured() async {
      final engine = DartCryptoEngine();
      final mine = await engine.generateX25519();
      final service = MeshService(engine: engine, storageDirectory: _scratch());
      service.configure(
        identity: MeshIdentity(
          onionAddress: 'me.onion',
          identityPrivateKey: Uint8List(32),
          identityPublicKey: Uint8List(32),
          exchangePrivateKey: mine.privateKey,
          exchangePublicKey: mine.publicKey,
          displayName: 'Me',
        ),
        socksHost: '127.0.0.1',
        socksPort: 9,
        remotePort: 80,
      );
      return service;
    }

    test('a rejected key is not stored', () async {
      final service = await configured();
      final first = await DartCryptoEngine().generateX25519();
      final impostor = await DartCryptoEngine().generateX25519();

      service.rememberPeer(onionAddress: 'peer.onion', exchangePublicKey: first.publicKey);
      expect(service.exchangeKeyOf('peer.onion'), first.publicKey);

      // This is the account layer saying "the identity key that signed this is not
      // the one pinned for this address". The key has to be refused, because the
      // next `sendText` seals to whatever is stored here — the impersonation was
      // warned about on the profile screen and then ignored at the one moment it
      // mattered.
      service.rememberPeer(
        onionAddress: 'peer.onion',
        exchangePublicKey: impostor.publicKey,
        keyAccepted: false,
      );
      expect(service.exchangeKeyOf('peer.onion'), first.publicKey);

      await service.dispose();
    });

    test('an accepted first key is stored', () async {
      final service = await configured();
      final key = await DartCryptoEngine().generateX25519();
      service.rememberPeer(onionAddress: 'peer.onion', exchangePublicKey: key.publicKey);
      expect(service.exchangeKeyOf('peer.onion'), key.publicKey);
      // Remembering a peer is also what makes it a delivery candidate.
      expect(service.isReachable('peer.onion'), isTrue);
      await service.dispose();
    });

    test('the same key may be re-announced', () async {
      final service = await configured();
      final key = await DartCryptoEngine().generateX25519();
      service.rememberPeer(onionAddress: 'peer.onion', exchangePublicKey: key.publicKey);
      service.rememberPeer(onionAddress: 'peer.onion', exchangePublicKey: key.publicKey);
      expect(service.exchangeKeyOf('peer.onion'), key.publicKey);
      await service.dispose();
    });

    test('a key already held is sticky, even when the rotation is accepted', () async {
      final service = await configured();
      final first = await DartCryptoEngine().generateX25519();
      final second = await DartCryptoEngine().generateX25519();
      service.rememberPeer(onionAddress: 'peer.onion', exchangePublicKey: first.publicKey);

      // `keyAccepted` is the account layer's verdict on the *identity* key, and it
      // can only be yes when the pinned identity still matches. The mesh still does
      // not replace a key it holds, because the two layers reach the same answer
      // from different evidence and the consequence of disagreeing is a message
      // sealed to an address the user did not intend to write to. A genuine
      // rotation is therefore a first-contact event (or a deleted contact), not a
      // silent overwrite of a live session.
      service.rememberPeer(
        onionAddress: 'peer.onion',
        exchangePublicKey: second.publicKey,
        keyAccepted: true,
      );
      expect(service.exchangeKeyOf('peer.onion'), first.publicKey);

      // Forgetting the peer is what makes a new key take effect, which is exactly
      // what deleting and re-adding a contact does.
      service.removePeer('peer.onion');
      service.rememberPeer(onionAddress: 'peer.onion', exchangePublicKey: second.publicKey);
      expect(service.exchangeKeyOf('peer.onion'), second.publicKey);

      await service.dispose();
    });
  });
}

/// A scratch directory for a mesh that never writes to it.
///
/// `MeshService` takes a directory for bookkeeping none of these tests exercise,
/// and a real temporary one keeps the tests free of a hand-written stub.
Directory _scratch() =>
    Directory('${Directory.systemTemp.path}${Platform.pathSeparator}darkflow-send-test');
