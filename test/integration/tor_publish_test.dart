import 'dart:io';

import 'package:darkflow/src/app/app_controller.dart';
import 'package:darkflow/src/data/vault_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// The one step nothing else covers: the real Tor daemon, started for real.
///
/// ## What this is for
///
/// Every test above this one fakes the transport. The handshake tests replace Tor with a
/// SOCKS proxy, and the mesh tests do the same. That leaves a whole layer verified by
/// nothing: whether the daemon starts, whether it writes a `hostname` file, and whether
/// `AppController` adopts that address and configures the mesh with it.
///
/// And that layer is where "the handshake does not complete" actually lives. While the
/// address is null, `_publishAddressAndConfigureMesh` returns early, the mesh is never
/// configured, and *no handshake is ever attempted* — the contact sits at "waiting for the
/// first handshake" for ever with nothing anywhere saying the network had not come up.
///
/// ## Why it is not part of the default run
///
/// It starts a real Tor process and waits for a real onion service, which takes tens of
/// seconds and depends on a daemon that a censored network may not bootstrap. The tests
/// above run in ten seconds in total; this one alone would multiply that. It is tagged
/// `integration` and run explicitly:
///
/// ```
/// flutter test --tags integration test/integration/tor_publish_test.dart
/// ```
/// ## How to run it, and why it cannot run here
///
/// It needs the platform plugins, not just the Dart side: `path_provider` hands the daemon
/// its working directory over a method channel, and a headless `flutter test` has no
/// implementation for that channel. Running it under `flutter test` fails with
/// `MissingPluginException(No implementation found for method getApplicationSupportDirectory)`
/// — which is a fact about the harness, not about DarkFlow. (The application itself is fine:
/// `main` calls `WidgetsFlutterBinding.ensureInitialized()` precisely so these channels
/// exist before the vault is touched.)
///
/// It is therefore skipped by default and has to be asked for:
///
/// ```
/// flutter test --tags integration --run-skipped test/integration/tor_publish_test.dart
/// ```
///
/// and it is worth running on a machine with an uncensored network, because what it checks
/// is the step every other test fakes.
void main() {
  // The daemon interacts with platform channels — the native library directory, the
  // process environment — so the binding has to exist before the first call. The
  // application does the same thing in `main`, and for the same reason.
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a fresh account publishes an onion address through the real daemon',
    skip: 'needs a device or desktop runner: path_provider has no test-harness '
        'implementation, so the daemon cannot be given its working directory',
    () async {
      final sandbox = await Directory.systemTemp.createTemp('df-tor-publish-');
      addTearDown(() async {
        try {
          if (sandbox.existsSync()) await sandbox.delete(recursive: true);
        } on FileSystemException {
          // Tor may still hold a file open; not worth failing the test over.
        }
      });

      final paths = VaultPaths(sandbox);
      await paths.ensureCreated();
      final controller = AppController(paths: paths);
      addTearDown(() async {
        await controller.lock();
        controller.dispose();
      });

      await controller.bootstrap();
      expect(controller.stage, AppStage.needsAccount,
          reason: 'a fresh directory has no account');

      await controller.createAccount(
        displayName: 'Integration',
        about: '',
        password: 'an integration passphrase',
      );
      expect(controller.isUnlocked, isTrue);

      // The daemon and the local server it forwards to. `startTor` brings the peer server
      // up first and hands its port to Tor, which is the pairing that has never been
      // exercised for real.
      await controller.startTor();

      final tor = controller.tor;
      expect(tor, isNotNull, reason: 'startTor creates the manager');

      // Wait for the address rather than for a circuit: the address is what the mesh needs,
      // and Tor writes it once the service keys exist — it does not have to reach the
      // network for that. This is the same distinction the fix in `_publishOwnAddress` is
      // about.
      final deadline = DateTime.now().add(const Duration(minutes: 3));
      while (DateTime.now().isBefore(deadline)) {
        final address = controller.tor?.status.onionAddress;
        if (address != null && address.isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }

      final address = controller.tor?.status.onionAddress;
      expect(
        address,
        isNotNull,
        reason: 'Without an address the mesh is never configured and no handshake is ever '
            'attempted. Tor said: ${controller.tor?.status.error ?? 'nothing'} '
            '(stage ${controller.tor?.status.stage.name})',
      );
      expect(address, endsWith('.onion'));
      expect(address!.length, 62, reason: '56 characters plus ".onion"');

      // The port Tor was told to forward to must be the one the local server is on. These
      // two disagreeing is a silent way for every inbound connection to go nowhere.
      final serverPort = controller.localPeerPort;
      expect(serverPort, greaterThan(0));
      final torrc = File('${sandbox.path}${Platform.pathSeparator}tor'
          '${Platform.pathSeparator}torrc');
      expect(torrc.existsSync(), isTrue, reason: 'the daemon reads this file');
      expect(
        await torrc.readAsString(),
        contains('HiddenServicePort 80 127.0.0.1:$serverPort'),
        reason: 'the onion service must forward to the port the server actually holds',
      );

      // And the account adopted it, which is what the address on screen comes from.
      expect(controller.account?.onionAddress, address,
          reason: 'the published address is the account address');
    },
    tags: <String>['integration'],
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
