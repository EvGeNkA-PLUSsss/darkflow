import 'dart:async';
import 'dart:io';

import '../app/log_book.dart';
import 'peer_stream.dart';

/// The TCP port Tor forwards the onion service to.
///
/// Tor publishes `HiddenServicePort 80 127.0.0.1:<port>`, so every inbound
/// connection to the account's `.onion` address arrives here as an ordinary
/// loopback socket. Binding to the loopback interface only is deliberate: the
/// port must never be reachable from the local network, because the onion
/// service is the sole intended entrance.
///
/// ## The port is held for the life of the object
///
/// It used to ask the operating system for a fresh ephemeral port on every [start], and
/// that was a silent way to break every inbound connection. `TorManager` is handed the
/// port *once*, when it is constructed, and writes it into the `torrc`; the daemon then
/// forwards the onion service there for as long as it runs. A later [start] — after a lock
/// and unlock, or a reconnection — bound a different port while the daemon kept forwarding
/// to the old one. The result was an address that looked published and accepted nothing:
/// every peer's handshake timed out, and nothing anywhere said why.
///
/// Holding the first port removes the possibility rather than documenting it. The small
/// cost is that a port taken by another process after a stop cannot be recovered, which is
/// reported by the bind failing rather than by silently using a different one.
class PeerServer {
  PeerServer({required this.onConnection});

  /// Called for each accepted connection. The handler owns the stream and is
  /// responsible for closing it.
  final Future<void> Function(PeerStream stream) onConnection;

  ServerSocket? _server;

  /// The first port bound, kept so every later [start] uses the same one.
  int? _fixedPort;

  /// One subscription per accepted socket, so they can all be cancelled together.
  ///
  /// A single-subscription listener on the server socket would be simpler, but a
  /// subscription that throws and is not cancelled leaks the socket and its file
  /// descriptor, and the mesh dials constantly.
  final List<StreamSubscription<Socket>> _subscriptions = <StreamSubscription<Socket>>[];

  /// The port Tor should forward to, or null before [start].
  int? get port => _server?.port ?? _fixedPort;

  bool get isRunning => _server != null;

  /// Binds the loopback port, or returns the one already bound.
  ///
  /// Idempotent across stops: the port chosen the first time is reused, so the value
  /// `TorManager` was constructed with stays correct. See the class doc for what went
  /// wrong when it did not.
  Future<int> start() async {
    final existing = _server;
    if (existing != null) return existing.port;

    final wanted = _fixedPort;
    final server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      // Zero asks the operating system for a free port, so a hand-picked one cannot
      // collide with something already on the machine.
      wanted ?? 0,
      shared: false,
    );
    _server = server;
    _fixedPort = server.port;
    _subscriptions.add(
      server.listen(
        (socket) {
          socket.setOption(SocketOption.tcpNoDelay, true);
          // Recorded for every accepted connection, because an inbound handshake that never
          // arrives looks identical to a peer that never dialled: the contact never gains a key,
          // nothing is logged, and the only visible symptom is on the *other* device. This line
          // is what tells the two apart — it is the first point at which "the daemon forwarded
          // something to us" is a fact.
          logNetwork(
            'inbound connection accepted on 127.0.0.1:$_fixedPort',
            detail: 'from ${socket.remoteAddress.address}',
          );
          unawaited(onConnection(PeerStream.attach(socket)));
        },
        onError: (Object error) {
          // A failed accept is not fatal; the listener stays up. Worth recording, though: a
          // listener that keeps erroring accepts nothing, which looks like the peer never
          // dialled.
          logError('accept failed on the peer server', detail: '$error');
        },
        cancelOnError: false,
      ),
    );
    logNetwork('peer server listening on 127.0.0.1:${server.port}',
        detail: 'the onion service forwards here');
    return server.port;
  }

  /// Closes the listener. Existing connections are left to their handlers.
  ///
  /// Takes the subscriptions out of the list before cancelling any of them, and is safe
  /// to call more than once.
  ///
  /// The version this replaces iterated the live list and then cleared it. Cancelling a
  /// subscription can run code that stops the server again — `lock()` stops the peer
  /// server and so does shutdown, and they can overlap — and the second call then cleared
  /// a list the first was still walking, which throws `Concurrent modification during
  /// iteration`. It surfaced as a crash while locking, which is the worst moment for one:
  /// the user asked DarkFlow to close and it threw instead.
  Future<void> stop() async {
    final subscriptions = List<StreamSubscription<Socket>>.of(_subscriptions);
    _subscriptions.clear();
    for (final subscription in subscriptions) {
      try {
        await subscription.cancel();
      } on Object {
        // Already cancelled by whoever got here first.
      }
    }
    final server = _server;
    _server = null;
    try {
      await server?.close();
    } on Object {
      // Already closed.
    }
  }
}
