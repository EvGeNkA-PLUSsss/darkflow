import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:darkflow/src/crypto/dart_crypto_engine.dart';
import 'package:darkflow/src/crypto/onion_address.dart';
import 'package:darkflow/src/data/models/message.dart';
import 'package:darkflow/src/data/models/relay.dart';
import 'package:darkflow/src/mesh/mesh_service.dart';
import 'package:darkflow/src/net/peer_server.dart';
import 'package:darkflow/src/net/peer_stream.dart';
import 'package:flutter_test/flutter_test.dart';

/// Two mesh services, talking to each other.
///
/// ## Why this is not the protocol test
///
/// `handshake_test.dart` covers `PeerConnection` to `PeerConnection`. It proves the
/// handshake and the cipher are right, and it proves nothing about `MeshService`: whether
/// `warmUp` is even called, whether the exchange key reaches the key map the send path
/// reads, whether `rememberPeer` refuses a key it should accept, whether the peer record
/// counts as reachable afterwards. Every one of those is a wiring mistake that leaves a
/// handshake which *works* producing no usable contact — which is what "the handshake does
/// not complete" looks like from the outside.
///
/// A loopback SOCKS5 proxy stands in for Tor's `SocksPort`. The onion addresses are real
/// (derived from real keys, because `isValid` checks the checksum) but nothing resolves
/// them: the proxy connects to a fixed local port, exactly as the test in `handshake_test`
/// does. That is the one thing this file cannot verify, and it is stated rather than
/// implied.
void main() {
  final engine = DartCryptoEngine();

  /// A pair of identities with real onion addresses.
  Future<({MeshIdentity identity, String onion})> identity(String name) async {
    final signing = await engine.generateEd25519();
    final exchange = await engine.generateX25519();
    return (
      identity: MeshIdentity(
        onionAddress: OnionAddress.fromPublicKey(signing.publicKey),
        identityPrivateKey: signing.privateKey,
        identityPublicKey: signing.publicKey,
        exchangePrivateKey: exchange.privateKey,
        exchangePublicKey: exchange.publicKey,
        displayName: name,
      ),
      onion: OnionAddress.fromPublicKey(signing.publicKey),
    );
  }

  /// A SOCKS5 proxy that sends every request to [upstream].
  ///
  /// Deliberately the same minimal implementation the handshake test uses: the point is to
  /// get the client past its SOCKS negotiation so the mesh layers above can be exercised.
  Future<ServerSocket> socksRelay(int upstream) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close());

    server.listen((Socket client) {
      var greeting = true;
      Socket? target;
      var pending = <int>[];

      client.listen(
        (List<int> data) async {
          if (greeting) {
            client.add(<int>[5, 0]);
            await client.flush();
            greeting = false;
            return;
          }
          if (target == null) {
            pending = <int>[...pending, ...data];
            if (pending.length < 4) return;
            final length = switch (pending[3]) {
              1 => 10,
              4 => 22,
              3 => pending.length < 5 ? 0 : 7 + pending[4],
              _ => -1,
            };
            if (length < 0) {
              client.destroy();
              return;
            }
            if (pending.length < length) return;
            final leftover = pending.sublist(length);
            final opened = await Socket.connect(InternetAddress.loopbackIPv4, upstream);
            target = opened;
            client.add(<int>[5, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
            await client.flush();
            opened.listen(client.add, onError: (Object _) => client.destroy());
            if (leftover.isNotEmpty) opened.add(leftover);
            return;
          }
          target?.add(data);
        },
        onError: (Object _) => client.destroy(),
        onDone: () => target?.destroy(),
      );
    });

    return server;
  }

  /// Runs two meshes on loopback, wired so that A can dial B.
  Future<
      ({
        MeshService a,
        MeshService b,
        String aOnion,
        String bOnion,
        MeshIdentity aIdentity,
        int aSocksPort,
      })> pair() async {
    final dirA = await Directory.systemTemp.createTemp('df-mesh-a-');
    final dirB = await Directory.systemTemp.createTemp('df-mesh-b-');
    addTearDown(() async {
      if (dirA.existsSync()) await dirA.delete(recursive: true);
      if (dirB.existsSync()) await dirB.delete(recursive: true);
    });

    final alice = await identity('Alice');
    final bob = await identity('Bob');

    // B's peer server, as Tor would forward its onion service to.
    //
    // The callback's type is `Future<void>`, so it has to hand one back even though the
    // work inside is fired and forgotten — the same shape `PeerServer.onConnection` has in
    // the application, which is why this is not merely a test convenience.
    final meshB = MeshService(engine: engine, storageDirectory: dirB);
    final serverB = PeerServer(
      onConnection: (PeerStream stream) {
        unawaited(meshB.handleInbound(stream));
        return Future<void>.value();
      },
    );
    final portB = await serverB.start();
    addTearDown(() async => serverB.stop());

    // One proxy, shared: the mesh dials `_socksPort` and the proxy forwards to B.
    final proxy = await socksRelay(portB);

    final meshA = MeshService(engine: engine, storageDirectory: dirA);
    addTearDown(() async {
      await meshA.stop();
      await meshB.stop();
    });

    meshA.configure(
      identity: alice.identity,
      socksHost: '127.0.0.1',
      socksPort: proxy.port,
      remotePort: 80,
      policy: const RelayPolicy(enabled: false),
    );
    meshB.configure(
      identity: bob.identity,
      socksHost: '127.0.0.1',
      socksPort: proxy.port,
      remotePort: 80,
      policy: const RelayPolicy(enabled: false),
    );

    return (a: meshA, b: meshB, aOnion: alice.onion, bOnion: bob.onion,
        aIdentity: alice.identity, aSocksPort: proxy.port);
  }

  group('mesh configuration', () {
    test('an unconfigured mesh refuses to dial', () async {
      // `warmUp` is called by the account layer the moment a contact is added, which can
      // be before Tor has published anything. Returning quietly is the behaviour the send
      // path relies on: nothing is reported against a peer for a problem that is local.
      final directory = await Directory.systemTemp.createTemp('df-mesh-idle-');
      addTearDown(() => directory.delete(recursive: true));
      final mesh = MeshService(engine: engine, storageDirectory: directory);
      addTearDown(() async => mesh.stop());

      expect(mesh.isConfigured, isFalse);
      // Must not throw, and must not record anything.
      await mesh.warmUp('whatever.onion');
    });

    test('configuring makes it usable', () async {
      final p = await pair();
      expect(p.a.isConfigured, isTrue);
      expect(p.b.isConfigured, isTrue);
    });
  });

  group('a handshake through the mesh', () {
    test('produces an exchange key the send path can use', () async {
      // This is the assertion that matters most. `sendText` refuses with "waiting for the
      // first handshake" when `exchangeKeyOf` is null, so a handshake that completed
      // without filling this map is a contact that can never be written to.
      final p = await pair();
      final learned = <MeshPeerLearned>[];
      final subscription = p.a.events
          .where((MeshEvent event) => event is MeshPeerLearned)
          .cast<MeshPeerLearned>()
          .listen(learned.add);
      addTearDown(subscription.cancel);

      await p.a.warmUp(p.bOnion);

      // The learn event is delivered through the mesh's own event stream, so it arrives on
      // a later microtask than the `warmUp` future completing. Waiting for it is the point:
      // a handshake that fills the key map without telling the account layer leaves the
      // contact's stored record without a key, and the send path refuses on the next launch.
      for (var attempt = 0; attempt < 60 && learned.isEmpty; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }

      expect(p.a.exchangeKeyOf(p.bOnion), isNotNull,
          reason: 'the key must reach the map the send path reads');
      expect(p.a.exchangeKeyOf(p.bOnion)!.length, 32);
      expect(learned, isNotEmpty,
          reason: 'the account layer learns the peer only through this event');
      expect(learned.first.onionAddress, p.bOnion);
      expect(learned.first.exchangePublicKey, isNotEmpty);
      expect(learned.first.displayName, 'Bob');
    });

    test('marks the peer reachable', () async {
      // `canReach` drives the online badge and, more importantly, whether a contact is
      // considered a delivery candidate.
      final p = await pair();
      await p.a.warmUp(p.bOnion);
      expect(p.a.isReachable(p.bOnion), isTrue);
    });

    test('a changed SOCKS port drops the connections opened through the old one', () async {
      // The reported symptom, at the level it actually happens.
      //
      // `configure` runs on every Tor status change, and a restart produces several with
      // different ports. A connection opened through the previous port was left in `_live`, and
      // `_connectionTo` hands back anything that is not closed — so every later request went
      // into a socket whose proxy had gone. The peer looked connected and answered nothing.
      final p = await pair();
      await p.a.warmUp(p.bOnion);
      expect(p.a.isReachable(p.bOnion), isTrue);

      // The same identity and policy, a different proxy port: what a Tor restart looks like.
      final movedProxy = await socksRelay(1);
      p.a.configure(
        identity: p.aIdentity,
        socksHost: '127.0.0.1',
        socksPort: movedProxy.port,
        remotePort: 80,
      );

      // The peer record survives — the key is still known, so the contact is not forgotten —
      // but the dead connection does not, so the next dial builds a real one.
      expect(p.a.exchangeKeyOf(p.bOnion), isNotNull,
          reason: 'a restart must not discard the keys it already paid for');
      expect(p.a.hasLiveConnection(p.bOnion), isFalse,
          reason: 'the connection that carried the old port must be gone, or every later '
              'request is written into a socket whose proxy has moved');
    });

    test('reconfiguring with the same transport keeps the connection', () async {
      // The other half: `configure` is called on every status change, and tearing down working
      // connections on each one would make the mesh unusable.
      final p = await pair();
      await p.a.warmUp(p.bOnion);
      expect(p.a.hasLiveConnection(p.bOnion), isTrue);
      expect(p.a.isReachable(p.bOnion), isTrue);

      p.a.configure(
        identity: p.aIdentity,
        socksHost: '127.0.0.1',
        socksPort: p.aSocksPort,
        remotePort: 80,
      );

      expect(p.a.hasLiveConnection(p.bOnion), isTrue,
          reason: 'an unchanged port must not cost a working connection');
    });

    test('an inbound handshake that fails is reported, not swallowed', () async {
      // The bug this covers was a `catch` with an empty body:
      //
      //     try { await connection.ready; } on Object { await connection.close(); return; }
      //
      // Nothing was logged and no event was emitted, so a peer whose handshake *arrived* and
      // failed was indistinguishable from a peer that never dialled. On the dialling side the
      // contact never gained a key and never appeared; on the receiving side there was no trace
      // at all. That is the shape of "generally there is no connection, and on the PC the contact
      // only appears after a restart".
      final dir = await Directory.systemTemp.createTemp('df-inbound-fail-');
      addTearDown(() async {
        if (dir.existsSync()) await dir.delete(recursive: true);
      });

      final me = await identity('Me');
      final mesh = MeshService(engine: engine, storageDirectory: dir);
      addTearDown(() async => mesh.stop());
      mesh.configure(
        identity: me.identity,
        socksHost: '127.0.0.1',
        socksPort: 1,
        remotePort: 80,
      );

      final failures = <MeshHandshakeFailed>[];
      final subscription = mesh.events
          .where((MeshEvent event) => event is MeshHandshakeFailed)
          .cast<MeshHandshakeFailed>()
          .listen(failures.add);
      addTearDown(subscription.cancel);

      // Something that is not a handshake: the socket opens, sends nonsense, and goes away.
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async => listener.close());
      final accepted = listener.first;
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, listener.port);
      final inbound = await accepted;
      socket.add(<int>[0x00, 0x01, 0x02, 0x03, 0x04, 0x05]);
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      socket.destroy();

      await mesh.handleInbound(PeerStream.attach(inbound));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(failures, isNotEmpty,
          reason: 'a handshake that reached this device and failed has to be reported');
      expect(failures.single.reason, contains('did not complete'));
      // Nothing was learned, so nothing is claimed to be known.
      expect(mesh.liveConnectionCount, 0);
    });

    test('an inbound handshake with no identity is refused and recorded', () async {
      // The vault locks between the socket being accepted and the mesh being asked to handle it.
      // The connection cannot be answered, and that is worth a line: the peer will report a
      // failure and this is the explanation for it.
      final dir = await Directory.systemTemp.createTemp('df-inbound-noident-');
      addTearDown(() async {
        if (dir.existsSync()) await dir.delete(recursive: true);
      });
      final mesh = MeshService(engine: engine, storageDirectory: dir);
      addTearDown(() async => mesh.stop());

      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async => listener.close());
      final accepted = listener.first;
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, listener.port);
      final inbound = await accepted;

      // Must not throw, and must not leave the socket open.
      await mesh.handleInbound(PeerStream.attach(inbound));
      socket.destroy();
      expect(mesh.liveConnectionCount, 0);
    });

    test('the dialled side learns the dialler', () async {
      final p = await pair();
      final learned = <MeshPeerLearned>[];
      final subscription = p.b.events
          .where((MeshEvent event) => event is MeshPeerLearned)
          .cast<MeshPeerLearned>()
          .listen(learned.add);
      addTearDown(subscription.cancel);

      await p.a.warmUp(p.bOnion);

      expect(p.b.exchangeKeyOf(p.aOnion), isNotNull);
      expect(p.b.isReachable(p.aOnion), isTrue);
      expect(learned.map((MeshPeerLearned e) => e.onionAddress), contains(p.aOnion));
    });

    test('a second handshake with the same peer is not refused', () async {
      // `rememberPeer` refuses to replace a key it holds, and it also refuses when the
      // existing key differs. A second connection must not be treated as an attack: the
      // key is the same, so it is accepted and the connection reused or rebuilt.
      final p = await pair();
      await p.a.warmUp(p.bOnion);
      final first = Uint8List.fromList(p.a.exchangeKeyOf(p.bOnion)!);

      await p.a.warmUp(p.bOnion);

      expect(p.a.exchangeKeyOf(p.bOnion), first,
          reason: 'the same peer must present the same key twice');
      expect(p.a.isReachable(p.bOnion), isTrue);
    });

    test('a peer that is not there fails without recording a false success', () async {
      final p = await pair();
      // Nothing is listening on the proxy port, so the SOCKS dial itself fails. That is the
      // same shape as Tor refusing a connection to an offline onion service, and it is the
      // ordinary outcome for a contact who is not running DarkFlow right now.
      //
      // An ephemeral port with no listener rather than a fixed one: port 1 is reserved and
      // a machine may refuse it in a way that never reaches the connect call at all.
      final deadProxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = deadProxy.port;
      await deadProxy.close();

      final dead = MeshService(
        engine: engine,
        storageDirectory: await Directory.systemTemp.createTemp('df-mesh-dead-'),
      );
      addTearDown(() async => dead.stop());
      final alice = await identity('Alice');
      dead.configure(
        identity: alice.identity,
        socksHost: '127.0.0.1',
        socksPort: deadPort,
        remotePort: 80,
      );

      final failures = <MeshHandshakeFailed>[];
      final subscription = dead.events
          .where((MeshEvent event) => event is MeshHandshakeFailed)
          .cast<MeshHandshakeFailed>()
          .listen(failures.add);
      addTearDown(subscription.cancel);

      await dead.warmUp(p.bOnion);

      expect(dead.exchangeKeyOf(p.bOnion), isNull);
      expect(dead.isReachable(p.bOnion), isFalse);

      // The failure travels through the event stream, so it lands a microtask later than
      // `warmUp` completing. Waiting is not a workaround for flakiness: the account layer
      // is told through this stream, and a failure that never reaches it is the bug this
      // checks for.
      for (var attempt = 0; attempt < 60 && failures.isEmpty; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }

      expect(failures, hasLength(1),
          reason: 'a failure the user can act on has to be reported, not swallowed');
      expect(failures.single.onionAddress, p.bOnion);
    });
  });

  group('delivery through the mesh', () {
    test('a message reaches the other side', () async {
      // The end-to-end path the whole application exists for: a handshake, then a sealed
      // message, then the event the account layer files into a conversation.
      final p = await pair();
      final received = <MeshMessageReceived>[];
      final subscription = p.b.events
          .where((MeshEvent event) => event is MeshMessageReceived)
          .cast<MeshMessageReceived>()
          .listen(received.add);
      addTearDown(subscription.cancel);

      await p.a.warmUp(p.bOnion);

      await p.a.sendMessage(
        message: _textMessage(
          id: 'm1',
          body: 'hello from Alice',
          peerOnion: p.bOnion,
        ),
      );

      // Delivery is asynchronous: the envelope is sealed, queued and dialled.
      for (var attempt = 0; attempt < 100 && received.isEmpty; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      expect(received, hasLength(1), reason: 'the message must arrive');
      expect(received.single.message.body, 'hello from Alice');
      expect(received.single.message.id, 'm1');
      expect(received.single.peerOnion, p.aOnion,
          reason: 'the envelope origin is how the recipient files it');
    });

    test('the sender is told the message was delivered', () async {
      // The receipt is what turns one tick into two, and it is the only feedback the
      // sender gets. A handshake that works while receipts never arrive leaves every
      // message looking unsent.
      final p = await pair();
      final statuses = <MeshDeliveryChanged>[];
      final subscription = p.a.events
          .where((MeshEvent event) => event is MeshDeliveryChanged)
          .cast<MeshDeliveryChanged>()
          .listen(statuses.add);
      addTearDown(subscription.cancel);

      await p.a.warmUp(p.bOnion);
      await p.a.sendMessage(
        message: _textMessage(
          id: 'm2',
          body: 'are you there',
          peerOnion: p.bOnion,
        ),
      );

      bool delivered() => statuses.any(
            (MeshDeliveryChanged change) => change.status == MessageStatus.delivered,
          );
      for (var attempt = 0; attempt < 100 && !delivered(); attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      expect(delivered(), isTrue,
          reason: 'direct delivery to a reachable peer must report success');
    });
  });
}

/// A text message, built here rather than through the account layer so this file
/// exercises the mesh alone.
///
/// [peerOnion] is what `sendMessage` looks the exchange key up by, so it has to be the
/// recipient's real address — an empty one fails with "no exchange key for" and looks like
/// a handshake that never happened.
Message _textMessage({
  required String id,
  required String body,
  required String peerOnion,
}) =>
    Message(
      id: id,
      conversationId: 'c1',
      peerOnion: peerOnion,
      direction: MessageDirection.outgoing,
      kind: MessageKind.text,
      createdAt: DateTime.now().toUtc(),
      body: body,
    );
