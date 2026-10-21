import 'dart:io';

import 'package:darkflow/src/net/peer_server.dart';
import 'package:darkflow/src/net/peer_stream.dart';
import 'package:darkflow/src/tor/tor_manager.dart';
import 'package:darkflow/src/tor/tor_paths.dart';
import 'package:flutter_test/flutter_test.dart';

/// The real daemon, started the way the application starts it.
///
/// ## What this covers that nothing else does
///
/// Every other Tor test fakes the transport or checks a generated file. This one runs
/// `TorManager.start()` against the actual `tor.exe`, which is the only way to exercise the part
/// that was rewritten in this round:
///
///  * **Port reservation.** The previous implementation asked the operating system for a free
///    port, closed the socket, and wrote the number into `torrc` — leaving a window in which the
///    port belonged to nobody. The rewrite binds each port and *holds* the socket until Tor has
///    claimed it. Whether that works is a fact about the operating system, not about the code, so
///    it has to be observed rather than asserted from a description.
///  * **That Tor is actually listening on the port it reports.** The reported SOCKS port is what
///    the mesh dials. A mismatch is invisible in logs and fatal in practice: every dial fails
///    against a loopback port with nothing on it, which is exactly the
///    `Connection refused ... port = 52024` in the report that prompted this work.
///  * **That the daemon comes up on a bridge-less configuration** and publishes an onion address.
///
/// It is skipped when the runtime has not been staged, because a test that fails for a missing
/// file teaches nobody anything.
void main() {
  /// The staged runtime, which is where a release build keeps the daemon.
  Directory? stagedRuntime() {
    for (final path in <String>[
      r'build\windows\x64\runner\Release\tor',
      r'build\windows\x64\runner\Profile\tor',
      'build/windows/x64/runner/Release/tor',
    ]) {
      final directory = Directory(path);
      if (directory.existsSync() &&
          File('${directory.path}${Platform.pathSeparator}tor.exe').existsSync()) {
        return directory;
      }
    }
    return null;
  }

  test(
    'the daemon starts, and the port it reports is the port it listens on',
    () async {
      final staged = stagedRuntime();
      if (staged == null) {
        markTestSkipped('no staged Tor runtime; run tool/stage_tor_runtime.ps1 first');
        return;
      }

      final root = await Directory.systemTemp.createTemp('df-tor-real-');

      // The locator looks for `tor/` beside the executable directory it is given, so a
      // temporary directory holding a copy of the staged runtime is enough — no Flutter asset
      // bundle and no path_provider, which is what made the other integration test unrunnable
      // under `flutter test`.
      final besideExecutable = await Directory.systemTemp.createTemp('df-tor-beside-');
      final runtime = Directory(
        '${besideExecutable.path}${Platform.pathSeparator}tor',
      );
      await runtime.create(recursive: true);
      for (final entity in staged.listSync()) {
        if (entity is! File) continue;
        await entity.copy('${runtime.path}${Platform.pathSeparator}'
            '${entity.uri.pathSegments.last}');
      }

      // The port the onion service forwards to, held the way the application holds it.
      final peerServer = PeerServer(
        onConnection: (PeerStream stream) {
          stream.destroy();
          return Future<void>.value();
        },
      );
      final peerPort = await peerServer.start();
      expect(peerPort, greaterThan(0));

      final manager = TorManager(
        rootDirectory: root,
        serviceTargetPort: peerPort,
        locator: TorBinaryLocator(executableDirectory: besideExecutable),
      );

      addTearDown(() async {
        await manager.stop();
        manager.dispose();
        await peerServer.stop();
        for (final directory in <Directory>[root, besideExecutable]) {
          try {
            if (directory.existsSync()) {
              await directory.delete(recursive: true);
            }
          } on FileSystemException {
            // The daemon may still hold a file; not worth failing a passed test over.
          }
        }
      });

      await manager.start();

      final socksPort = manager.status.socksPort;
      final controlPort = manager.status.controlPort;
      expect(socksPort, isNotNull, reason: 'the mesh needs this port to dial at all');
      expect(controlPort, isNotNull);
      expect(socksPort, isNot(controlPort),
          reason: 'the two reservations must not collide — that was the bug');

      // The fact this test exists for. A port that is reported but not bound is precisely the
      // failure that produced "usually there is no connection".
      expect(
        await _acceptsConnections(socksPort!),
        isTrue,
        reason: 'Tor reported SOCKS on $socksPort and nothing is listening there',
      );
      expect(await _acceptsConnections(controlPort!), isTrue);

      // And the onion service is published, which is what a peer needs in order to reach us.
      final deadline = DateTime.now().add(const Duration(minutes: 2));
      while (DateTime.now().isBefore(deadline) &&
          (manager.status.onionAddress ?? '').isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      final address = manager.status.onionAddress;
      expect(
        address,
        isNotNull,
        reason: 'without an address the mesh is never configured and no dial is attempted. '
            'stage=${manager.status.stage.name} '
            'error=${manager.status.error ?? 'none'} '
            'hostname file exists='
            '${File('${root.path}${Platform.pathSeparator}tor'
                '${Platform.pathSeparator}onion'
                '${Platform.pathSeparator}hostname').existsSync()} '
            'log=${manager.log.skip(manager.log.length > 6 ? manager.log.length - 6 : 0).join(' | ')}',
      );
      expect(address, endsWith('.onion'));
      expect(address!.length, 62);

      // The two must agree, because they were passed to each other.
      final torrc = File('${root.path}${Platform.pathSeparator}tor'
          '${Platform.pathSeparator}torrc');
      expect(torrc.existsSync(), isTrue);
      final text = await torrc.readAsString();
      expect(text, contains('HiddenServicePort 80 127.0.0.1:$peerPort'),
          reason: 'the onion service must forward to the port the peer server holds');
      expect(text, contains('SocksPort 127.0.0.1:$socksPort'));
      expect(text, contains('ControlPort 127.0.0.1:$controlPort'));
    },
    tags: <String>['integration'],
    timeout: const Timeout(Duration(minutes: 6)),
  );
}

/// True when something accepts a connection on the loopback port.
Future<bool> _acceptsConnections(int port) async {
  try {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: const Duration(seconds: 2),
    );
    socket.destroy();
    return true;
  } on Object {
    return false;
  }
}
