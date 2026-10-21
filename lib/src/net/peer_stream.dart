import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// A bidirectional byte stream to another DarkFlow node.
///
/// This exists because of a hard constraint in `dart:io`: a [Socket] is a
/// single-subscription stream, and a second `listen` after a `cancel` throws
/// `Bad state: Stream has already been listened to`. The SOCKS5 handshake has
/// to read from the socket, and it may over-read into the first application
/// bytes, so something must own the one and only subscription and hand the
/// caller a stream that starts with whatever was buffered.
///
/// That something is this class. Every connection in DarkFlow — inbound from
/// the onion service, outbound through Tor's SOCKS port — is a [PeerStream],
/// which is why the rest of the networking layer never touches a raw socket.
class PeerStream {
  PeerStream._({
    required this._socket,
    required this._incoming,
    required this._onClose,
  });

  final Socket _socket;
  final Stream<Uint8List> _incoming;
  final Future<void> Function() _onClose;

  bool _closed = false;

  /// Bytes arriving from the peer.
  Stream<Uint8List> get incoming => _incoming;

  /// True once this stream has been closed or destroyed.
  bool get isClosed => _closed;

  /// The peer's address as seen by the operating system.
  InternetAddress? get remoteAddress => _socket.remoteAddress;

  /// Queues [data] for the peer.
  void add(List<int> data) {
    if (_closed) return;
    _socket.add(data);
  }

  /// Queues a single byte. `Socket` has no `addByte`, only `IOSink.add`.
  void addByte(int byte) => add(<int>[byte & 0xff]);

  Future<void> flush() async {
    if (_closed) return;
    await _socket.flush();
  }

  /// Half-closes the stream: the peer sees end-of-file once everything queued
  /// has been written, but the socket stays open for its remaining traffic.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _onClose();
  }

  /// Tears the connection down immediately, without a graceful shutdown.
  void destroy() {
    if (_closed) return;
    _closed = true;
    _socket.destroy();
  }

  /// Sets the socket-level keep-alive, which matters for long-lived onion
  /// circuits that an idle NAT might otherwise drop.
  void enableKeepAlive() {
    try {
      _socket.setOption(SocketOption.tcpNoDelay, true);
    } on Object {
      // Not every platform honours the option; it is an optimisation, not a
      // correctness requirement.
    }
  }

  /// Wraps an inbound socket. Nothing has read from it yet, so the subscription
  /// starts here.
  static PeerStream attach(Socket socket) {
    final controller = StreamController<Uint8List>();
    final subscription = socket.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
      cancelOnError: false,
    );
    return PeerStream._(
      socket: socket,
      incoming: controller.stream,
      onClose: () async {
        await subscription.cancel();
        await controller.close();
        await socket.close();
      },
    );
  }

  /// Builds a stream that yields [leftover] first and then everything the
  /// already-running [subscription] delivers.
  ///
  /// Used by the SOCKS5 handshake, which has read the greeting and may hold the
  /// beginning of the application protocol in its buffer.
  static PeerStream adopt({
    required Socket socket,
    required StreamSubscription<Uint8List> subscription,
    required Uint8List leftover,
  }) {
    final controller = StreamController<Uint8List>();
    if (leftover.isNotEmpty) controller.add(leftover);
    subscription.onData(controller.add);
    subscription.onError(controller.addError);
    subscription.onDone(controller.close);
    return PeerStream._(
      socket: socket,
      incoming: controller.stream,
      onClose: () async {
        await subscription.cancel();
        if (!controller.isClosed) await controller.close();
        await socket.close();
      },
    );
  }
}
