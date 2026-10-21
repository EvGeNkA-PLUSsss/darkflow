// Determines whether a dart:io Socket can be listened to again after its first
// subscription is cancelled.
//
// This decides the shape of the Tor transport layer: if re-listening works, the
// SOCKS5 handshake can consume the greeting and then hand a plain Socket back
// to the caller. If it does not, the handshake must own the single subscription
// for the lifetime of the connection and expose a wrapped stream instead.
//
// Run:  dart run tool/probe_socket_relisten.dart

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

Future<void> main() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;

  server.listen((socket) {
    socket.add(<int>[1, 2, 3, 4]);
    socket.flush();
    Future<void>.delayed(const Duration(milliseconds: 120), () {
      socket.add(<int>[5, 6, 7, 8]);
      socket.flush();
    });
  });

  final client = await Socket.connect(InternetAddress.loopbackIPv4, port);
  final first = <int>[];
  late StreamSubscription<Uint8List> subscription;

  final gotFirst = Completer<void>();
  subscription = client.listen((data) {
    first.addAll(data);
    if (first.length >= 4 && !gotFirst.isCompleted) gotFirst.complete();
  });

  await gotFirst.future;
  print('first read: $first');
  await subscription.cancel();

  try {
    final second = <int>[];
    final gotSecond = Completer<void>();
    client.listen((data) {
      second.addAll(data);
      if (second.length >= 4 && !gotSecond.isCompleted) gotSecond.complete();
    });
    await gotSecond.future.timeout(const Duration(seconds: 2));
    print('RE-LISTEN WORKS, second read: $second');
  } on Object catch (error) {
    print('RE-LISTEN FAILS: $error');
  }

  await server.close();
  exit(0);
}
