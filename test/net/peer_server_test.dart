import 'dart:io';

import 'package:darkflow/src/net/peer_server.dart';
import 'package:darkflow/src/net/peer_stream.dart';
import 'package:flutter_test/flutter_test.dart';

/// The loopback port Tor forwards the onion service to.
///
/// This is the shortest path to "the handshake does not complete", and it does not look
/// like one: `TorManager` is constructed with a port and writes it into the `torrc` once.
/// The daemon then forwards `HiddenServicePort 80 127.0.0.1:<port>` there for as long as it
/// runs. A `PeerServer` that bound a fresh ephemeral port on a later `start` — after a lock
/// and unlock, or a reconnection — left the daemon forwarding to the old one, so the
/// published address accepted connections and delivered them nowhere. Every peer's
/// handshake timed out, and nothing in the application said why.
void main() {
  Future<PeerServer> server() async {
    final created = PeerServer(
      onConnection: (PeerStream stream) {
        stream.destroy();
        return Future<void>.value();
      },
    );
    addTearDown(() async => created.stop());
    return created;
  }

  test('the first start binds a port', () async {
    final s = await server();
    final port = await s.start();
    expect(port, greaterThan(0));
    expect(s.isRunning, isTrue);
    expect(s.port, port);
  });

  test('starting twice does not rebind', () async {
    final s = await server();
    final first = await s.start();
    final second = await s.start();
    expect(second, first);
  });

  test('the port survives a stop and start', () async {
    // The case that broke inbound connections: Tor holds the port it was told about, so a
    // server that moved to a new one after a reconnect was forwarding into nothing.
    final s = await server();
    final first = await s.start();
    await s.stop();
    expect(s.isRunning, isFalse);

    final second = await s.start();
    expect(second, first,
        reason: 'Tor was told this port once and cannot be told again without a restart');
    expect(s.port, first);
  });

  test('the port survives several cycles', () async {
    final s = await server();
    final first = await s.start();
    for (var cycle = 0; cycle < 3; cycle++) {
      await s.stop();
      expect(await s.start(), first);
    }
  });

  test('stopping twice is harmless', () async {
    final s = await server();
    await s.start();
    await s.stop();
    await s.stop();
    expect(s.isRunning, isFalse);
  });

  test('it accepts a connection, and stops accepting after a stop', () async {
    var accepted = 0;
    final s = PeerServer(
      onConnection: (PeerStream stream) {
        accepted++;
        stream.destroy();
        return Future<void>.value();
      },
    );
    addTearDown(() async => s.stop());

    final port = await s.start();
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(accepted, 1);
    socket.destroy();

    await s.stop();
    // Nothing is listening on the port now. The connect either fails or is closed
    // immediately; what must not happen is a second accept.
    try {
      final again = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 2),
      );
      again.destroy();
    } on Object {
      // Expected on a port with no listener.
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(accepted, 1, reason: 'the listener is gone once stopped');
  });

  test('the port is bound on the loopback interface only', () async {
    // Not reachable from the local network. The onion service is the only intended
    // entrance, and a server listening on every interface would be a second one.
    final s = await server();
    final port = await s.start();

    final loopback = await Socket.connect(InternetAddress.loopbackIPv4, port);
    loopback.destroy();

    // A connection to the machine's own LAN address on the same port must be refused when
    // the bind is loopback-only. Skipped when there is no non-loopback address to try.
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    final external = interfaces
        .expand((NetworkInterface interface) => interface.addresses)
        .where((InternetAddress address) => !address.isLoopback)
        .firstOrNull;
    if (external == null) return;

    await expectLater(
      Socket.connect(external, port, timeout: const Duration(seconds: 2)),
      throwsA(isA<Object>()),
    );
  });
}
