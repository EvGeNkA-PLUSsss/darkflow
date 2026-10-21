import 'dart:io';

import 'package:darkflow/src/data/models/tor_settings.dart';
import 'package:darkflow/src/tor/tor_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// The exact path that was broken end to end: bridge lines typed into the box
/// must come out of `TorConfig` as a torrc that tells Tor to use them.
///
/// Every link in this chain was checked in isolation at some point while
/// chasing the bug, and each looked fine — which is why it survived. This test
/// asserts the whole chain at once, starting from the strings a user actually
/// pastes.
void main() {
  /// The bridge lines `@GetBridgesBot` hands out, verbatim — no `Bridge`
  /// keyword, which is exactly how people paste them.
  const pasted = 'webtunnel [2001:db8:39ff:b176:96c8:fe95:7795:6a84]:443 '
      '8A619BB4906C5BA1CE1C411B39C5191991741BBF '
      'url=https://benches.date/Zjx8DRPQrFZUpUTdpFNu7x3r ver=0.0.7\n'
      'webtunnel [2001:db8:b25f:7b5c:ea:7689:d15e:3389]:443 '
      '669F835F5358D33A79DDDD559A3A167B104FF3BC '
      'url=https://dsl.one.pl/X7yJZdFkZTGdQkMMclV4qdVz ver=0.0.5';

  String buildTorrc(TorSettings settings) => TorConfig.build(
        settings: settings,
        dataDirectory: Directory(r'C:\data'),
        hiddenServiceDirectory: Directory(r'C:\onion'),
        controlPort: 1,
        socksPort: 2,
        cookieAuthFile: r'C:\data\cookie',
        onionServiceTargetPort: 3,
        transportPaths: const <String, String>{
          'webtunnel': r'C:\pt\webtunnel-client.exe',
          'obfs4': r'C:\pt\obfs4proxy.exe',
        },
        geoIpFile: null,
        geoIpV6File: null,
      );

  test('lines pasted without choosing a transport still enable bridges', () {
    // The bug: `mode` stayed `automatic` because no preset was tapped, so the
    // app wrote `UseBridges 0` and silently connected directly.
    const settings = TorSettings(customBridges: pasted);

    final torrc = buildTorrc(settings);

    expect(torrc, contains('UseBridges 1'),
        reason: 'a box full of bridge lines must not be ignored');
    expect(torrc, isNot(contains('UseBridges 0')));
    // The transport the lines name must be registered, or Tor would have a
    // bridge it cannot speak to. Quoting is `_quote`'s business, so only the
    // substance is asserted here.
    expect(
      torrc,
      contains('ClientTransportPlugin webtunnel exec'),
      reason: 'the transport the lines name must be registered',
    );
    expect(torrc, contains('webtunnel-client.exe'));
    // Both lines are written, each carrying the keyword torrc requires.
    final bridgeLines = torrc
        .split('\n')
        .where((line) => line.startsWith('Bridge '))
        .toList();
    expect(bridgeLines, hasLength(2));
    expect(bridgeLines.first, startsWith('Bridge webtunnel [2001:db8:39ff'));
    expect(bridgeLines.last, contains('ver=0.0.5'));
  });

  test('a line that already carries the keyword is not doubled', () {
    final torrc = buildTorrc(
      const TorSettings(customBridges: 'Bridge obfs4 192.0.2.10:443 47B2E1F5C3D8A96B0E4F1C2D3A5B6C7D8E9F0A12 cert=abcdEFGH12345678'),
    );
    expect(torrc, contains('UseBridges 1'));
    expect(torrc, contains('Bridge obfs4 192.0.2.10:443 47B2E1F5C3D8A96B0E4F1C2D3A5B6C7D8E9F0A12 cert=abcdEFGH12345678'));
    expect(torrc, isNot(contains('Bridge Bridge')));
  });

  test('an empty box still leaves the direct path alone', () {
    // The other half of the rule: `UseBridges 1` with nothing to connect to
    // would start a bootstrap that can never move.
    final torrc = buildTorrc(const TorSettings(mode: BridgeMode.webTunnel));
    expect(torrc, contains('UseBridges 0'));
    expect(torrc, isNot(contains('Bridge ')));
  });
}
