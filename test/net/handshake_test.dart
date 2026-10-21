import 'dart:io';
import 'dart:typed_data';

import 'package:darkflow/src/crypto/dart_crypto_engine.dart';
import 'package:darkflow/src/crypto/onion_address.dart';
import 'package:darkflow/src/net/peer_connection.dart';
import 'package:darkflow/src/net/peer_stream.dart';
import 'package:flutter_test/flutter_test.dart';

/// Which part of the SOCKS5 conversation a connection is in.
enum _SocksStage { greeting, request, streaming }

/// The handshake, over a real socket.
///
/// ## Why this test exists
///
/// "The handshake does not complete" was reported twice and could not be reproduced
/// from the code alone. Reading it is not enough: the initiator and the responder are
/// separate code paths that each derive keys from different private material, and the
/// only way to know they agree is to run both against each other. Everything below the
/// transport — the offer, the signature, the key derivation, the cipher's first frame —
/// is exercised here without Tor, because Tor is not what decides whether two peers can
/// understand each other.
///
/// What is *not* covered: the SOCKS5 hop and the onion service. A failure there is a
/// network problem, and it looks like a timeout rather than a completed handshake that
/// cannot decrypt.
void main() {
  final engine = DartCryptoEngine();

  /// One side of the conversation, with its own identities.
  Future<
      ({
        Uint8List identityPrivate,
        Uint8List identityPublic,
        Uint8List exchangePrivate,
        Uint8List exchangePublic,
        String onion,
      })> peer() async {
    final identity = await engine.generateEd25519();
    final exchange = await engine.generateX25519();
    return (
      identityPrivate: identity.privateKey,
      identityPublic: identity.publicKey,
      exchangePrivate: exchange.privateKey,
      exchangePublic: exchange.publicKey,
      onion: OnionAddress.fromPublicKey(identity.publicKey),
    );
  }

  /// A minimal SOCKS5 proxy that connects every request to [upstream].
  ///
  /// The client insists on SOCKS5 — that is how it reaches an onion service — and the
  /// SOCKS hop is deliberately *not* what these tests are about. This stands in for Tor's
  /// `SOCKS` port so the handshake can be exercised without a network: it speaks just
  /// enough of RFC 1928 to get out of the way, and forwards bytes unchanged once the
  /// connection is up.
  Future<ServerSocket> socksRelay(int upstream) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close());

    server.listen((Socket client) {
      // State per connection: the greeting, then the request.
      var stage = _SocksStage.greeting;
      late Socket target;
      final buffered = <int>[];

      client.listen(
        (List<int> data) async {
          if (stage == _SocksStage.greeting) {
            // VER, NMETHODS, METHODS…
            if (data.length < 3 || data[0] != 5) {
              client.destroy();
              return;
            }
            client.add(<int>[5, 0]); // no authentication
            await client.flush();
            stage = _SocksStage.request;
            return;
          }

          if (stage == _SocksStage.request) {
            buffered.addAll(data);
            // VER CMD RSV ATYP then the address, then two bytes of port.
            if (buffered.length < 4) return;
            final atyp = buffered[3];
            int headerLength;
            switch (atyp) {
              case 1:
                headerLength = 4 + 4 + 2;
              case 4:
                headerLength = 4 + 16 + 2;
              case 3:
                if (buffered.length < 5) return;
                headerLength = 4 + 1 + buffered[4] + 2;
              default:
                client.destroy();
                return;
            }
            if (buffered.length < headerLength) return;

            final leftover = buffered.sublist(headerLength);
            buffered.clear();

            target = await Socket.connect(InternetAddress.loopbackIPv4, upstream);
            // A success reply with a null bound address.
            client.add(<int>[5, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
            await client.flush();
            stage = _SocksStage.streaming;

            target.listen(client.add, onError: (Object _) => client.destroy());
            if (leftover.isNotEmpty) target.add(leftover);
            return;
          }

          target.add(data);
        },
        onError: (Object _) => client.destroy(),
        onDone: () {
          if (stage == _SocksStage.streaming) target.destroy();
        },
      );
    });

    return server;
  }

  /// Runs a loopback handshake and returns both connections.
  Future<({PeerConnection initiator, PeerConnection responder})> handshake({
    String responderName = 'Bob',
  }) async {
    final alice = await peer();
    final bob = await peer();

    final service = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => service.close());

    final accepted = service.first.then(
      (Socket socket) => PeerConnection.accept(
        engine: engine,
        stream: PeerStream.attach(socket),
        myOnion: bob.onion,
        myIdentityPrivateKey: bob.identityPrivate,
        myIdentityPublicKey: bob.identityPublic,
        myExchangePrivateKey: bob.exchangePrivate,
        myExchangePublicKey: bob.exchangePublic,
        myDisplayName: responderName,
      ),
    );

    final proxy = await socksRelay(service.port);

    final initiator = await PeerConnection.connect(
      engine: engine,
      peerOnion: bob.onion,
      myOnion: alice.onion,
      myIdentityPrivateKey: alice.identityPrivate,
      myIdentityPublicKey: alice.identityPublic,
      myExchangePrivateKey: alice.exchangePrivate,
      myExchangePublicKey: alice.exchangePublic,
      myDisplayName: 'Alice',
      socksHost: '127.0.0.1',
      socksPort: proxy.port,
      remotePort: 80,
      timeout: const Duration(seconds: 20),
    );

    final responder = await accepted.timeout(const Duration(seconds: 20));
    await responder.ready.timeout(const Duration(seconds: 20));
    return (initiator: initiator, responder: responder);
  }

  group('two peers complete a handshake', () {
    test('the initiator learns who it reached', () async {
      final pair = await handshake();
      addTearDown(() async {
        await pair.initiator.close();
        await pair.responder.close();
      });

      expect(pair.initiator.isEstablished, isTrue);
      expect(pair.initiator.peer, isNotNull);
      expect(pair.initiator.peer!.displayName, 'Bob');
    });

    test('the responder learns who dialled it', () async {
      final pair = await handshake();
      addTearDown(() async {
        await pair.initiator.close();
        await pair.responder.close();
      });

      expect(pair.responder.isEstablished, isTrue);
      expect(pair.responder.peer, isNotNull);
      expect(pair.responder.peer!.displayName, 'Alice');
    });

    test('each side holds the other exchange key', () async {
      // This is the key the account layer stores as the contact's, and the one every
      // message is sealed to. A handshake that "succeeds" without it leaves the send path
      // permanently refusing with "waiting for the first handshake".
      final pair = await handshake();
      addTearDown(() async {
        await pair.initiator.close();
        await pair.responder.close();
      });

      expect(pair.initiator.peer!.exchangePublicKey, isNotEmpty);
      expect(pair.initiator.peer!.exchangePublicKey.length, 32);
      expect(pair.responder.peer!.exchangePublicKey.length, 32);
      expect(
        pair.initiator.peer!.exchangePublicKey,
        isNot(equals(pair.responder.peer!.exchangePublicKey)),
        reason: 'each side must learn the other key, not its own',
      );
    });

    test('the initiator can make a request and get an answer', () async {
      // The real proof: a frame sealed under the derived session key, answered under
      // the same key. A mismatched root key shows up here as a timeout or a protocol
      // error rather than as two sides that both believe they succeeded.
      final pair = await handshake();
      addTearDown(() async {
        await pair.initiator.close();
        await pair.responder.close();
      });

      // The responder answers the operations it knows; `pull` with an empty body is a
      // harmless round trip.
      pair.responder.incomingRequests.listen((Map<String, dynamic> request) {
        pair.responder.respond(request['id'] as int? ?? 1, <String, dynamic>{
          'ok': true,
          'echo': request['op'],
        });
      });

      final response = await pair.initiator
          .request('pull', <String, dynamic>{})
          .timeout(const Duration(seconds: 20));
      expect(response['ok'], isTrue);
      expect(response['echo'], 'pull');
    });

    test('the responder can make a request too', () async {
      // The two directions use independent ratchet chains, so a mistake can make one
      // direction work and the other not.
      final pair = await handshake();
      addTearDown(() async {
        await pair.initiator.close();
        await pair.responder.close();
      });

      pair.initiator.incomingRequests.listen((Map<String, dynamic> request) {
        pair.initiator.respond(request['id'] as int? ?? 1, <String, dynamic>{
          'ok': true,
          'echo': request['op'],
        });
      });

      final response = await pair.responder
          .request('pull', <String, dynamic>{})
          .timeout(const Duration(seconds: 20));
      expect(response['ok'], isTrue);
    });

    test('several frames in a row survive', () async {
      // The ratchet advances per frame, so an off-by-one shows up on the second frame
      // rather than the first.
      final pair = await handshake();
      addTearDown(() async {
        await pair.initiator.close();
        await pair.responder.close();
      });

      pair.responder.incomingRequests.listen((Map<String, dynamic> request) {
        pair.responder.respond(request['id'] as int? ?? 1, <String, dynamic>{
          'ok': true,
          'n': request['n'],
        });
      });

      for (var i = 0; i < 5; i++) {
        final response = await pair.initiator
            .request('pull', <String, dynamic>{'n': i})
            .timeout(const Duration(seconds: 20));
        expect(response['n'], i);
      }
    });
  });

  group('the handshake refuses what it should', () {
    test('a peer that claims another address is rejected', () async {
      // The initiator is connecting to `bob.onion`, and the responder signs its offer with
      // its own identity. Claiming a different address must fail, because that is the whole
      // point of binding the address to the key.
      final alice = await peer();
      final bob = await peer();
      final mallory = await peer();

      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async => server.close());

      // A responder that answers with Mallory's onion address while sitting on Bob's
      // socket. Its signature is valid — it is genuinely Mallory — so the only thing that
      // can reject it is the address check.
      final accepted = server.first.then(
        (Socket socket) => PeerConnection.accept(
          engine: engine,
          stream: PeerStream.attach(socket),
          myOnion: mallory.onion,
          myIdentityPrivateKey: mallory.identityPrivate,
          myIdentityPublicKey: mallory.identityPublic,
          myExchangePrivateKey: mallory.exchangePrivate,
          myExchangePublicKey: mallory.exchangePublic,
          myDisplayName: 'Mallory',
        ),
      );

      // The SOCKS hop stands in for Tor, so the dialling side behaves exactly as it does
      // in the application.
      final proxy = await socksRelay(server.port);

      // The initiator must refuse the connection. A failure is the point, and which
      // failure is deliberately not pinned: the address check rejects the offer, the
      // responder then tears the socket down, and the initiator may observe either the
      // rejection or the closed connection depending on which arrives first. Pinning one
      // of them made this test fail on the other.
      Object? refusal;
      try {
        await PeerConnection.connect(
          engine: engine,
          peerOnion: bob.onion,
          myOnion: alice.onion,
          myIdentityPrivateKey: alice.identityPrivate,
          myIdentityPublicKey: alice.identityPublic,
          myExchangePrivateKey: alice.exchangePrivate,
          myExchangePublicKey: alice.exchangePublic,
          myDisplayName: 'Alice',
          socksHost: '127.0.0.1',
          socksPort: proxy.port,
          remotePort: 80,
          timeout: const Duration(seconds: 20),
        );
      } on Object catch (error) {
        refusal = error;
      }
      expect(refusal, isNotNull,
          reason: 'a peer that claims the wrong address must not be accepted');

      // The responder does finish its own side, because nothing in the protocol tells it
      // that the initiator refused — it sent a valid, signed offer and had no reason to
      // doubt it. That is safe rather than a hole: the initiator holds no session, so
      // nothing it sends can be understood, and the responder's first frame fails to
      // authenticate and tears the connection down.
      //
      // The property that matters is therefore the initiator's, and it is checked above.
      // What is asserted here is the second half: the connection does not survive. A peer
      // that kept believing the session was up would be indistinguishable from a working
      // connection until the first frame, which is exactly the failure this test exists to
      // rule out.
      final responder = await accepted.timeout(const Duration(seconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(responder.isClosed, isTrue,
          reason: 'the connection must not outlive the refusal');
      await responder.close();
    });

    test('a peer that closes immediately is reported, not hung on', () async {
      // A refused dial — Tor agreeing to a connection the service immediately drops —
      // must fail fast. Hanging here is what makes a contact look permanently
      // unreachable while the application waits 90 seconds per attempt.
      final alice = await peer();
      final bob = await peer();

      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async => server.close());
      server.listen((Socket socket) => socket.destroy());

      await expectLater(
        PeerConnection.connect(
          engine: engine,
          peerOnion: bob.onion,
          myOnion: alice.onion,
          myIdentityPrivateKey: alice.identityPrivate,
          myIdentityPublicKey: alice.identityPublic,
          myExchangePrivateKey: alice.exchangePrivate,
          myExchangePublicKey: alice.exchangePublic,
          myDisplayName: 'Alice',
          socksHost: '127.0.0.1',
          socksPort: server.port,
          remotePort: 0,
          timeout: const Duration(seconds: 10),
        ),
        throwsA(isA<Object>()),
      );
    });
  });
}
