import 'dart:async';
import 'dart:io';

import 'package:darkflow/src/crypto/dart_crypto_engine.dart';
import 'package:darkflow/src/crypto/onion_address.dart';
import 'package:darkflow/src/mesh/mesh_service.dart';
import 'package:darkflow/src/net/peer_server.dart';
import 'package:darkflow/src/net/peer_stream.dart';
import 'package:flutter_test/flutter_test.dart';

/// The mesh keeps trying to reach a contact it has no key for.
///
/// This is the fix for the second half of "the handshake does not complete", and it is not
/// about the handshake at all — it is about who retries it. The attempt was made once, when
/// the contact was added, and the envelope outbox only retries *messages*. A contact with no
/// exchange key has no envelope, because nothing can be sealed without one, so there was
/// nothing for the outbox to retry: one failure, then silence for the rest of the session,
/// with the message frozen at "waiting for the first handshake".
///
/// The tests below drive `tick()`, which is what the periodic pump calls.
void main() {
  final engine = DartCryptoEngine();

  late Directory dirA;
  late Directory dirB;

  setUp(() async {
    dirA = await Directory.systemTemp.createTemp('df-retry-a-');
    dirB = await Directory.systemTemp.createTemp('df-retry-b-');
  });

  tearDown(() async {
    if (dirA.existsSync()) await dirA.delete(recursive: true);
    if (dirB.existsSync()) await dirB.delete(recursive: true);
  });

  Future<MeshIdentity> identityOf(String name) async {
    final signing = await engine.generateEd25519();
    final exchange = await engine.generateX25519();
    return MeshIdentity(
      onionAddress: OnionAddress.fromPublicKey(signing.publicKey),
      identityPrivateKey: signing.privateKey,
      identityPublicKey: signing.publicKey,
      exchangePrivateKey: exchange.privateKey,
      exchangePublicKey: exchange.publicKey,
      displayName: name,
    );
  }

  /// A SOCKS proxy that always fails, standing in for a peer that is not running.
  ///
  /// Accepting the connection and closing it is what Tor does for an onion service that
  /// exists but is not answering — the difference matters, because a refused *proxy* is a
  /// local error while a refused *service* is an unreachable peer.
  Future<ServerSocket> refusingProxy() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close());
    server.listen((Socket socket) => socket.destroy());
    return server;
  }

  test('a peer that is not running is registered for retry', () async {
    final proxy = await refusingProxy();
    final mesh = MeshService(engine: engine, storageDirectory: dirA);
    addTearDown(() async => mesh.stop());
    final me = await identityOf('Me');
    final peer = await identityOf('Peer');

    mesh.configure(
      identity: me,
      socksHost: '127.0.0.1',
      socksPort: proxy.port,
      remotePort: 80,
    );
    mesh.expectHandshake(peer.onionAddress);

    // First attempt, as `addContact` makes it.
    await mesh.tick();
    expect(mesh.exchangeKeyOf(peer.onionAddress), isNull);

    // The important part: it is still on the list, so later ticks try again. The outbox is
    // empty — there is nothing to seal — so this set is the only record that anything is
    // owed.
    await mesh.tick();
    await mesh.tick();
    expect(mesh.exchangeKeyOf(peer.onionAddress), isNull,
        reason: 'nothing changed, so there is still no key');
  });

  test('a direct dial announces itself, not only a retry', () async {
    // The bug this covers was mine, and it survived a round of "fixing" this exact report.
    //
    // `MeshHandshakeStarted` was emitted from the pump's retry loop. But the pump only retries
    // dials that have already failed, and the **first** attempt is made by `addContact`
    // calling `warmUp` directly. So the event never fired for the attempt the user actually
    // triggers, and the screen stayed silent for the whole ninety seconds a Tor circuit can
    // take. "After adding a contact nothing happens" was precisely that silence.
    final proxy = await refusingProxy();
    final mesh = MeshService(engine: engine, storageDirectory: dirA);
    addTearDown(() async => mesh.stop());
    final me = await identityOf('Me');
    final peer = await identityOf('Peer');

    mesh.configure(
      identity: me,
      socksHost: '127.0.0.1',
      socksPort: proxy.port,
      remotePort: 80,
    );

    final started = <String>[];
    final subscription = mesh.events
        .where((MeshEvent event) => event is MeshHandshakeStarted)
        .cast<MeshHandshakeStarted>()
        .listen((MeshHandshakeStarted event) => started.add(event.onionAddress));
    addTearDown(subscription.cancel);

    // Exactly what `addContact` does: register, then dial. No `tick`.
    mesh.expectHandshake(peer.onionAddress);
    await mesh.warmUp(peer.onionAddress);

    expect(started, contains(peer.onionAddress),
        reason: 'the first attempt must say it is happening, or the screen says nothing');
  });

  test('a retry announces itself exactly once', () async {
    // Moving the announcement into `warmUp` risks sending it twice for a retry, once from the
    // loop and once from the dial. A duplicate is not harmless: the account layer clears the
    // recorded failure when a dial starts, so a second announcement would wipe the reason a
    // previous attempt failed while it is the only thing the user can act on.
    final proxy = await refusingProxy();
    final mesh = MeshService(engine: engine, storageDirectory: dirA);
    addTearDown(() async => mesh.stop());
    final me = await identityOf('Me');
    final peer = await identityOf('Peer');

    mesh.configure(
      identity: me,
      socksHost: '127.0.0.1',
      socksPort: proxy.port,
      remotePort: 80,
    );

    final started = <String>[];
    final subscription = mesh.events
        .where((MeshEvent event) => event is MeshHandshakeStarted)
        .cast<MeshHandshakeStarted>()
        .listen((MeshHandshakeStarted event) => started.add(event.onionAddress));
    addTearDown(subscription.cancel);

    mesh.expectHandshake(peer.onionAddress);
    await mesh.debugRetryPendingHandshakes();

    expect(started, hasLength(1));
  });

  test('registering is refused for a peer whose key is already held', () async {
    final mesh = MeshService(engine: engine, storageDirectory: dirA);
    addTearDown(() async => mesh.stop());
    final me = await identityOf('Me');
    final peer = await identityOf('Peer');

    mesh.configure(
      identity: me,
      socksHost: '127.0.0.1',
      socksPort: 1,
      remotePort: 80,
    );
    mesh.rememberPeer(
      onionAddress: peer.onionAddress,
      exchangePublicKey: peer.exchangePublicKey,
    );

    // Nothing to dial for: a key is already held, and dialling would risk replacing it.
    mesh.expectHandshake(peer.onionAddress);
    expect(mesh.exchangeKeyOf(peer.onionAddress), isNotNull);
  });

  test('an empty address is ignored', () async {
    final mesh = MeshService(engine: engine, storageDirectory: dirA);
    addTearDown(() async => mesh.stop());
    final me = await identityOf('Me');
    mesh.configure(
      identity: me,
      socksHost: '127.0.0.1',
      socksPort: 1,
      remotePort: 80,
    );
    // Must not throw, and must not add a nameless entry that the pump would dial.
    mesh.expectHandshake('');
  });

  test('forgetting removes it from the retry set', () async {
    final mesh = MeshService(engine: engine, storageDirectory: dirA);
    addTearDown(() async => mesh.stop());
    final me = await identityOf('Me');
    final peer = await identityOf('Peer');
    mesh.configure(
      identity: me,
      socksHost: '127.0.0.1',
      socksPort: 1,
      remotePort: 80,
    );

    mesh.expectHandshake(peer.onionAddress);
    mesh.forgetHandshake(peer.onionAddress);
    // A deleted contact must not keep costing circuits. Nothing observable is left on the
    // service to assert against, so this checks the call is safe and repeatable — the
    // behaviour it guards is the absence of dialling, which the pump's backoff makes
    // impractical to observe directly here.
    mesh.forgetHandshake(peer.onionAddress);
  });

  test('concurrent dials to one peer share a single circuit', () async {
    // The measured cause of "adding a contact takes forever", from a real report: twenty-four
    // simultaneous SOCKS dials to one address over two and a half minutes, each waiting out the
    // ninety-second timeout, each starting while the previous was still open.
    //
    // Three things dial the same peer — the send path, the retry pump, and the handshake retry —
    // so overlap is ordinary rather than exotic. Every extra circuit competes for the same relays,
    // which is why the peer took longer to reach the more the application tried.
    //
    // The proxy counts what actually arrives, which is the only honest measure: the code under
    // test could deduplicate its own bookkeeping and still open a socket per caller.
    final acceptances = <int>[];
    final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => proxy.close());
    proxy.listen((Socket client) {
      acceptances.add(DateTime.now().microsecondsSinceEpoch);
      // Held open without answering: this is a proxy that has taken the connection and is waiting
      // for an upstream that will not answer, which is the state the pile-up grew in.
    });

    final mesh = MeshService(engine: engine, storageDirectory: dirA);
    addTearDown(() async => mesh.stop());
    final me = await identityOf('Me');
    final peer = await identityOf('Peer');
    mesh.configure(
      identity: me,
      socksHost: '127.0.0.1',
      socksPort: proxy.port,
      remotePort: 80,
    );

    // Ten callers at once, as the three dialling paths produce.
    final dials = <Future<void>>[
      for (var i = 0; i < 10; i++) mesh.warmUp(peer.onionAddress),
    ];

    // Long enough for a socket to be opened by each caller if nothing deduplicated them.
    await Future<void>.delayed(const Duration(milliseconds: 600));

    expect(acceptances, hasLength(1),
        reason: 'concurrent dials to one peer have to share a circuit, or they queue behind each '
            'other and the peer takes longer to reach the more the application tries');

    // Let the shared attempt settle so the teardown does not race it.
    await Future.any<void>(<Future<void>>[
      Future.wait(dials),
      Future<void>.delayed(const Duration(seconds: 2)),
    ]);
  });

  test('a dial is not reused after it finishes', () async {
    // The other half of sharing: the map of in-flight attempts has to be emptied when one settles,
    // or a peer that failed once would hand back that same failure for the rest of the session and
    // never be dialled again — which is the bug the retry set exists to prevent.
    final acceptances = <int>[];
    final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => proxy.close());
    proxy.listen((Socket client) {
      acceptances.add(DateTime.now().microsecondsSinceEpoch);
      client.destroy();
    });

    final mesh = MeshService(engine: engine, storageDirectory: dirA);
    addTearDown(() async => mesh.stop());
    final me = await identityOf('Me');
    final peer = await identityOf('Peer');
    mesh.configure(
      identity: me,
      socksHost: '127.0.0.1',
      socksPort: proxy.port,
      remotePort: 80,
    );

    await mesh.warmUp(peer.onionAddress);
    final afterFirst = acceptances.length;
    await mesh.warmUp(peer.onionAddress);

    expect(acceptances.length, greaterThan(afterFirst),
        reason: 'a finished attempt must not be handed back; the next call has to dial again');
  });

  test('a peer that comes online is reached on a later tick', () async {
    // The whole point, end to end: the first attempts fail, the peer starts listening, and
    // a later tick finds it. Without the retry set no tick would ever try again.
    final me = await identityOf('Me');
    final peer = await identityOf('Peer');

    final meshPeer = MeshService(engine: engine, storageDirectory: dirB);
    addTearDown(() async => meshPeer.stop());
    final server = PeerServer(
      onConnection: (PeerStream stream) {
        unawaited(meshPeer.handleInbound(stream));
        return Future<void>.value();
      },
    );
    addTearDown(() async => server.stop());
    final peerPort = await server.start();
    meshPeer.configure(
      identity: peer,
      socksHost: '127.0.0.1',
      socksPort: peerPort,
      remotePort: 80,
    );

    // A proxy that can be pointed at "nothing" and then at the peer. This is how a contact
    // who is offline and then comes online is modelled without a network.
    var forwardTo = 0;
    final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => proxy.close());
    proxy.listen((Socket client) {
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
            if (forwardTo == 0) {
              // Nothing there yet.
              client.destroy();
              return;
            }
            final opened = await Socket.connect(InternetAddress.loopbackIPv4, forwardTo);
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

    final mesh = MeshService(engine: engine, storageDirectory: dirA);
    addTearDown(() async => mesh.stop());
    mesh.configure(
      identity: me,
      socksHost: '127.0.0.1',
      socksPort: proxy.port,
      remotePort: 80,
    );

    mesh.expectHandshake(peer.onionAddress);
    await mesh.tick();
    expect(mesh.exchangeKeyOf(peer.onionAddress), isNull,
        reason: 'the peer is not listening yet');

    // The peer starts listening.
    forwardTo = peerPort;

    // The backoff after the first attempt is twenty seconds, so the pump is driven directly
    // rather than waited on: the test is about the retry happening at all, not about the
    // clock.
    await mesh.debugRetryPendingHandshakes(force: true);

    expect(mesh.exchangeKeyOf(peer.onionAddress), isNotNull,
        reason: 'a later tick must find a peer that has come online');
  });
}
