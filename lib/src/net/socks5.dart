import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../app/log_book.dart';
import 'peer_stream.dart';

/// Thrown when the SOCKS5 handshake fails, carrying the relay's own reason code.
class Socks5Exception implements Exception {
  const Socks5Exception(this.message, {this.replyCode});

  final String message;

  /// The SOCKS5 `REP` byte, when the failure came from the proxy.
  final int? replyCode;

  /// A human explanation of a `REP` code, so the UI can say something useful
  /// instead of "connection failed".
  String? get replyExplanation => switch (replyCode) {
        0x01 => 'general SOCKS server failure',
        0x02 => 'connection not allowed by ruleset',
        0x03 => 'network unreachable',
        0x04 => 'host unreachable — the .onion address is probably offline',
        0x05 => 'connection refused — the peer is not accepting connections',
        0x06 => 'TTL expired',
        0x07 => 'command not supported',
        0x08 => 'address type not supported',
        _ => null,
      };

  /// True when the failure means "the peer is not there right now", which the
  /// mesh treats as a reason to hand the message to a relay rather than to give
  /// up.
  bool get isPeerUnreachable => replyCode == 0x04 || replyCode == 0x05 || replyCode == 0x03;

  @override
  String toString() => replyExplanation == null ? message : '$message (${replyExplanation!})';
}

/// A SOCKS5 client — the only way outbound traffic leaves DarkFlow, through
/// Tor's `SocksPort`.
///
/// It is written by hand rather than taken from a package for one decisive
/// reason: the target host must reach the proxy as a **domain name**
/// (`ATYP = 0x03`) so that Tor, and not the local resolver, resolves it. A
/// `.onion` address has no DNS record anywhere, so any implementation that
/// resolves locally — or that calls `InternetAddress.lookup` on the target —
/// simply cannot reach an onion service. Nothing here ever resolves the target.
abstract final class Socks5Client {
  /// `VER`, `NMETHODS` and the no-authentication method.
  static const List<int> _greeting = <int>[0x05, 0x01, 0x00];

  /// `VER CMD RSV ATYP` for a CONNECT to a domain name.
  static const List<int> _connectDomainPreamble = <int>[0x05, 0x01, 0x00, 0x03];

  /// Opens a stream to `targetHost:targetPort` through the proxy.
  ///
  /// The returned [PeerStream] owns the socket's single subscription, so the
  /// caller can start reading immediately without losing anything the handshake
  /// buffered.
  static Future<PeerStream> connect({
    required String targetHost,
    required int targetPort,
    String proxyHost = '127.0.0.1',
    int proxyPort = 9050,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    if (targetHost.isEmpty) {
      throw ArgumentError.value(targetHost, 'targetHost', 'must not be empty');
    }
    if (targetPort <= 0 || targetPort > 65535) {
      throw ArgumentError.value(targetPort, 'targetPort', 'must be a valid port');
    }

    final socket = await Socket.connect(proxyHost, proxyPort, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    final reader = _HandshakeReader(socket);

    // Recorded before the first byte goes out. A failure to reach the proxy at all is the one
    // case where nothing else in the application can say what happened, because there is no
    // reply to carry a reason: the exception is a bare "connection refused" against a loopback
    // port, and the useful part — which port, and whether Tor was supposed to be on it — is only
    // known here.
    logNetwork(
      'dialling $targetHost:$targetPort through $proxyHost:$proxyPort',
      detail: 'timeout ${timeout.inSeconds}s',
    );

    try {
      // 1. Greeting and method negotiation.
      socket.add(_greeting);
      await socket.flush();
      final greetingReply = await reader.read(2).timeout(timeout);
      if (greetingReply[0] != 0x05) {
        throw const Socks5Exception('the proxy is not speaking SOCKS5');
      }
      if (greetingReply[1] != 0x00) {
        throw Socks5Exception(
          'the proxy demands authentication it did not offer (method ${greetingReply[1]})',
        );
      }

      // 2. CONNECT with a domain-name target, so the proxy resolves it.
      final hostBytes = Uint8List.fromList(targetHost.codeUnits);
      if (hostBytes.length > 255) {
        throw const Socks5Exception('the target hostname is longer than 255 bytes');
      }
      socket.add(<int>[
        ..._connectDomainPreamble,
        hostBytes.length,
        ...hostBytes,
        (targetPort >> 8) & 0xff,
        targetPort & 0xff,
      ]);
      await socket.flush();

      // 3. Read the reply. Its bound address has a variable length that must be
      //    consumed exactly, or the first application bytes would be eaten.
      final head = await reader.read(4).timeout(timeout);
      if (head[1] != 0x00) {
        socket.destroy();
        // Logged here rather than left to the caller, because the `REP` byte is the only thing
        // that distinguishes "the peer's onion service is not running" from "this machine
        // refused to open the circuit at all", and by the time an exception has travelled up
        // through the mesh that distinction is gone.
        logNetwork(
          'SOCKS refused $targetHost:$targetPort',
          detail: 'proxy 127.0.0.1:$proxyPort · REP=0x${head[1].toRadixString(16)} '
              '(${_explain(head[1])})',
        );
        throw Socks5Exception(
          'the proxy refused the connection to $targetHost',
          replyCode: head[1],
        );
      }
      switch (head[3]) {
        case 0x01:
          await reader.read(4); // IPv4
        case 0x04:
          await reader.read(16); // IPv6
        case 0x03:
          final length = (await reader.read(1))[0];
          if (length > 0) await reader.read(length);
        default:
          socket.destroy();
          logNetwork(
            'SOCKS replied with an address type this client cannot read',
            detail: 'ATYP=0x${head[3].toRadixString(16)} for $targetHost:$targetPort',
          );
          throw Socks5Exception('the proxy replied with address type ${head[3]}');
      }
      await reader.read(2); // BND.PORT

      logNetwork('SOCKS opened $targetHost:$targetPort via 127.0.0.1:$proxyPort');

      return reader.release(socket);
    } on Socks5Exception {
      // A rejection this code raises itself has to destroy the socket too.
      //
      // The three earlier branches did, and this arm did not, so the paths that
      // throw from the negotiation — a proxy that is not SOCKS5 at all, one that
      // demands authentication, an over-long hostname, a socket that closed
      // mid-handshake — left the socket, its file descriptor and its live
      // subscription open for the lifetime of the process. The mesh retries every
      // twenty seconds, so a misconfigured port accumulated them until the process
      // ran out of descriptors and *all* networking failed, including the parts
      // that had nothing to do with the bad port.
      socket.destroy();
      rethrow;
    } on Object catch (error) {
      socket.destroy();
      // The case with no reply to explain it: nothing is listening on the proxy port, the
      // proxy dropped the connection, or the negotiation timed out. The port is the whole
      // story here, so it is recorded with the message.
      logNetwork(
        'could not open a circuit to $targetHost:$targetPort',
        detail: 'proxy 127.0.0.1:$proxyPort · $error',
      );
      throw Socks5Exception('the SOCKS5 handshake with $targetHost failed: $error');
    }
  }

  /// A short explanation of a SOCKS5 `REP` code, for the log.
  static String _explain(int reply) => switch (reply) {
        0x01 => 'general SOCKS server failure',
        0x02 => 'connection not allowed by ruleset',
        0x03 => 'network unreachable',
        0x04 => 'host unreachable — the .onion address is probably offline',
        0x05 => 'connection refused — the peer is not accepting connections',
        0x06 => 'TTL expired',
        0x07 => 'command not supported',
        0x08 => 'address type not supported',
        _ => 'unknown reply code',
      };

  /// Checks that the proxy port is open and speaking SOCKS5.
  ///
  /// The connection screen uses this to distinguish "Tor is not running" from
  /// "Tor is running but has not built a circuit yet" — two very different
  /// problems for the user.
  static Future<bool> probe({
    String proxyHost = '127.0.0.1',
    int proxyPort = 9050,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    Socket? socket;
    try {
      socket = await Socket.connect(proxyHost, proxyPort, timeout: timeout);
      socket.add(_greeting);
      await socket.flush();
      final reply = await _firstBytes(socket, 2).timeout(timeout);
      return reply != null && reply[0] == 0x05 && reply[1] == 0x00;
    } on Object {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  /// True when [host] is a syntactically valid Tor v3 onion address.
  static bool isOnionHost(String host) {
    final value = host.toLowerCase();
    if (!value.endsWith('.onion')) return false;
    final body = value.substring(0, value.length - '.onion'.length);
    return body.length == 56 && RegExp(r'^[a-z2-7]+$').hasMatch(body);
  }

  static Future<Uint8List?> _firstBytes(Socket socket, int count) async {
    final completer = Completer<Uint8List?>();
    final buffer = BytesBuilder(copy: false);
    late StreamSubscription<Uint8List> subscription;
    subscription = socket.listen(
      (data) {
        buffer.add(data);
        if (buffer.length >= count && !completer.isCompleted) {
          completer.complete(Uint8List.fromList(buffer.takeBytes()));
        }
      },
      onError: (Object error) {
        if (!completer.isCompleted) completer.complete(null);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete(null);
      },
      cancelOnError: false,
    );
    final result = await completer.future;
    await subscription.cancel();
    return result;
  }
}

/// Reads an exact number of bytes from a socket while it owns the single
/// subscription, then hands ownership to a [PeerStream].
///
/// `Socket` delivers arbitrary chunk boundaries, so a reply can arrive split
/// across events, and an event can contain the tail of the handshake together
/// with the first bytes of application data. Both cases are handled by
/// buffering and by returning the remainder in [release].
class _HandshakeReader {
  _HandshakeReader(Socket socket) {
    _subscription = socket.listen(
      _onData,
      onError: (Object error) {
        _error = error;
        _wake();
      },
      onDone: () {
        _done = true;
        _wake();
      },
      cancelOnError: false,
    );
  }

  late final StreamSubscription<Uint8List> _subscription;
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  Completer<void>? _waiter;
  Object? _error;
  bool _done = false;

  void _onData(Uint8List data) {
    _buffer.add(data);
    _wake();
  }

  void _wake() {
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  /// Waits until at least [count] bytes are available, then returns exactly
  /// that many, keeping the remainder buffered.
  Future<Uint8List> read(int count) async {
    while (_buffer.length < count) {
      if (_error != null) {
        throw Socks5Exception('the socket failed during the SOCKS5 handshake: $_error');
      }
      if (_done) {
        throw const Socks5Exception('the proxy closed the connection mid-handshake');
      }
      _waiter = Completer<void>();
      await _waiter!.future;
      _waiter = null;
    }
    final all = _buffer.takeBytes();
    final head = Uint8List.sublistView(all, 0, count);
    if (all.length > count) {
      _buffer.add(Uint8List.sublistView(all, count));
    }
    return Uint8List.fromList(head);
  }

  /// Hands the still-open subscription to a [PeerStream] together with whatever
  /// the handshake over-read.
  PeerStream release(Socket socket) {
    final leftover = Uint8List.fromList(_buffer.takeBytes());
    return PeerStream.adopt(
      socket: socket,
      subscription: _subscription,
      leftover: leftover,
    );
  }
}
