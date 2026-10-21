import 'dart:io';

import 'package:darkflow/src/data/models/tor_settings.dart';
import 'package:darkflow/src/tor/tor_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// What survives a Tor restart, and what must.
///
/// The reported symptom was a PC where a contact appeared only after restarting DarkFlow, and a
/// phone that said it had a peer while the PC had none. Both point at the seam between "the
/// daemon is running" and "the rest of the application believes it is": the ports, the address,
/// and the torrc that ties them together.
///
/// Starting the daemon for real is `test/integration/tor_manager_test.dart`. This file covers the
/// part that has to hold on every pass, including restarts, with no network: that the file the
/// daemon is given names the ports and the target it was told about, and that a second build for
/// the same directories produces the same answers.
void main() {
  late Directory root;
  late Directory data;
  late Directory hidden;

  setUp(() {
    root = Directory.systemTemp.createTempSync('df-restart-');
    data = Directory('${root.path}${Platform.pathSeparator}data')..createSync();
    hidden = Directory('${root.path}${Platform.pathSeparator}hs')..createSync();
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  String build({
    required int socksPort,
    required int controlPort,
    required int onionServiceTargetPort,
    TorSettings settings = const TorSettings(),
    // The transports are separate programs found on disk. Supplied here so the
    // `ClientTransportPlugin` lines are produced; without a path the builder correctly omits
    // them, which is why a bridge test that forgets this sees no registration at all.
    Map<String, String> transportPaths = const <String, String>{
      'webtunnel': r'C:\runtime\webtunnel-client.exe',
      'obfs4': r'C:\runtime\lyrebird.exe',
    },
  }) =>
      TorConfig.build(
        settings: settings,
        dataDirectory: data,
        hiddenServiceDirectory: hidden,
        socksPort: socksPort,
        controlPort: controlPort,
        cookieAuthFile: '${root.path}${Platform.pathSeparator}cookie',
        onionServiceTargetPort: onionServiceTargetPort,
        transportPaths: transportPaths,
        owningProcessId: 4242,
      );

  group('the peer port the onion service forwards to', () {
    test('is written into HiddenServicePort, not lost', () {
      // The link between the two halves of the application. Tor publishes
      // `HiddenServicePort 80 127.0.0.1:<port>`, and `<port>` has to be the one the peer server
      // holds. A mismatch produces an address that resolves, accepts, and delivers nothing —
      // every inbound handshake disappears with no error on either side.
      final torrc = build(socksPort: 9050, controlPort: 9051, onionServiceTargetPort: 41234);
      expect(torrc, contains('HiddenServicePort 80 127.0.0.1:41234'));
    });

    test('follows the virtual port the user set', () {
      // Peers dial this port through the onion service, so both sides have to agree. The mesh
      // sends to `_settings.torSettings.virtualPort`, which is why the same value is used here.
      final torrc = build(
        socksPort: 9050,
        controlPort: 9051,
        onionServiceTargetPort: 41234,
        settings: const TorSettings(virtualPort: 443),
      );
      expect(torrc, contains('HiddenServicePort 443 127.0.0.1:41234'));
    });

    test('is absent when the onion service is off', () {
      final torrc = build(
        socksPort: 9050,
        controlPort: 9051,
        onionServiceTargetPort: 41234,
        settings: const TorSettings(enableOnionService: false),
      );
      expect(torrc, isNot(contains('HiddenServicePort')));
      expect(torrc, isNot(contains('HiddenServiceDir')));
    });
  });

  group('what a restart has to preserve', () {
    test('the same settings produce the same document', () {
      // A restart rewrites this file from the settings. If two builds of the same configuration
      // differed, the daemon would be given a different listener than the one the application
      // expects — and the difference would be invisible.
      final first = build(socksPort: 9050, controlPort: 9051, onionServiceTargetPort: 41234);
      final second = build(socksPort: 9050, controlPort: 9051, onionServiceTargetPort: 41234);
      expect(second, first);
    });

    test('a new SOCKS port is written, and nothing else moves with it', () {
      // What a restart looks like when the ports were ephemeral: the number changes. The rest of
      // the file must not, or the mesh ends up dialling one port while Tor listens on another.
      final before = build(socksPort: 9050, controlPort: 9051, onionServiceTargetPort: 41234);
      final after = build(socksPort: 39883, controlPort: 9051, onionServiceTargetPort: 41234);

      expect(after, contains('SocksPort 127.0.0.1:39883'));
      expect(before, contains('SocksPort 127.0.0.1:9050'));
      expect(after, contains('HiddenServicePort 80 127.0.0.1:41234'),
          reason: 'the onion service target is the peer server and must not follow the SOCKS '
              'port around');
      expect(after, contains('ControlPort 127.0.0.1:9051'));
    });

    test('the daemon is tied to the application that started it', () {
      // `__OwningControllerProcess` is what stops a crashed application leaving a daemon holding
      // the data directory, which makes every later start fail with "another Tor process is
      // running with the same data directory". A restart is exactly when a stale daemon would be
      // inherited.
      final torrc = build(socksPort: 9050, controlPort: 9051, onionServiceTargetPort: 41234);
      expect(torrc, contains('__OwningControllerProcess 4242'));
    });

    test('the hidden service keys are kept where Tor wrote them', () {
      // The address is a function of these files. Writing the directory somewhere else — or
      // recreating it — changes the account's address, which is what a user would experience as
      // "my contacts can no longer reach me after a restart".
      final torrc = build(socksPort: 9050, controlPort: 9051, onionServiceTargetPort: 41234);
      expect(torrc, contains('HiddenServiceDir ${hidden.path}'));
    });
  });

  group('a bridge configuration survives a restart', () {
    test('the lines are still written and the transports still registered', () {
      // Bridge lines are the setting most likely to be edited between two runs, and the failure
      // they cause is a stall rather than an error: `UseBridges 1` with no `Bridge`, or a
      // transport with no `ClientTransportPlugin`.
      final torrc = build(
        socksPort: 9050,
        controlPort: 9051,
        onionServiceTargetPort: 41234,
        settings: const TorSettings(
          customBridges: 'webtunnel [2001:db8::1]:443 '
              '8A619BB4906C5BA1CE1C411B39C5191991741BBF '
              'url=https://example.com/abc ver=0.0.7',
          mode: BridgeMode.webTunnel,
        ),
      );

      expect(torrc, contains('UseBridges 1'));
      expect(torrc, contains('Bridge webtunnel'));
      // The transport has to be registered, or Tor has a bridge it cannot speak to and the
      // bootstrap stalls with the screen insisting a bridge is configured.
      expect(torrc, contains('ClientTransportPlugin webtunnel exec'));
    });
  });
}
