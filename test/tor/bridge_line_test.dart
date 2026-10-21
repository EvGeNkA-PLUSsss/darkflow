import 'dart:io';

import 'package:darkflow/src/tor/bridge_line.dart';
import 'package:darkflow/src/tor/tor_config.dart';
import 'package:darkflow/src/data/models/tor_settings.dart';
import 'package:flutter_test/flutter_test.dart';

/// A malformed bridge line stops Tor from starting, and this is what catches it.
///
/// ## The failure being tested against
///
/// Reproduced against the real daemon (`tor.exe 0.4.9.13`) with a line whose fingerprint
/// was four characters instead of forty:
///
/// ```
/// [warn] Key digest for Bridge is wrong length.
/// [warn] Failed to parse/validate config: Bridge line did not parse. See logs for details.
/// [err]  Reading config failed--see warnings above.
/// ```
///
/// `tor.exe` then exits with code 1. There is no partial start and no fallback: one bad
/// line means no Tor, which means no messaging at all, and the screen said only
/// "Reading config failed--see warnings above".
void main() {
  group('a line that cannot work is rejected', () {
    test('a fingerprint that is too short', () {
      // The exact failure that produced the reported error. The line is otherwise
      // well-formed — a real https URL for WebTunnel — so the fingerprint is the only thing
      // wrong, which is what makes it a test of that check.
      final problem = bridgeLineProblem('webtunnel https://example.com/abc AAAA');
      expect(problem, isNotNull);
      expect(problem, contains('40'));
      expect(problem, contains('4'),
          reason: 'saying how long it actually is tells the user what was truncated');
    });

    test('a short fingerprint on an obfs4 line', () {
      final problem =
          bridgeLineProblem('obfs4 192.0.2.1:443 AAAA cert=abc');
      expect(problem, isNotNull);
      expect(problem, contains('40'));
    });

    test('a fingerprint with non-hexadecimal characters', () {
      expect(
        bridgeLineProblem('obfs4 192.0.2.1:443 ZZ47B2E1F5C3D8A96B0E4F1C2D3A5B6C7D8E9F0A '
            'cert=abc'),
        isNotNull,
      );
    });

    test('a valid-looking line that lost its certificate', () {
      final problem = bridgeLineProblem(
        'obfs4 192.0.2.1:443 47B2E1F5C3D8A96B0E4F1C2D3A5B6C7D8E9F0A12',
      );
      expect(problem, isNotNull);
      expect(problem, contains('cert='));
    });

    test('an address without a port', () {
      expect(
        bridgeLineProblem('webtunnel 192.0.2.1 '
            '47B2E1F5C3D8A96B0E4F1C2D3A5B6C7D8E9F0A12'),
        isNotNull,
      );
    });

    test('a port that is not a port', () {
      final problem = bridgeLineProblem(
        'obfs4 192.0.2.1:99999 47B2E1F5C3D8A96B0E4F1C2D3A5B6C7D8E9F0A12 cert=abc',
      );
      expect(problem, isNotNull);
      expect(problem, contains('65535'));
    });

    test('a WebTunnel URL that is not https', () {
      // Tor refuses these, and a plain-http WebTunnel would defeat the transport.
      final problem = bridgeLineProblem(
        'webtunnel http://example.com/path 47B2E1F5C3D8A96B0E4F1C2D3A5B6C7D8E9F0A12',
      );
      expect(problem, isNotNull);
      expect(problem, contains('https'));
    });

    test('a transport DarkFlow cannot register', () {
      // No `ClientTransportPlugin` line would be written for an unknown keyword, so Tor
      // would hold a bridge it cannot speak to and stall — the failure mode that made a
      // configured bridge look ignored.
      final problem = bridgeLineProblem(
        'madeup 192.0.2.1:443 47B2E1F5C3D8A96B0E4F1C2D3A5B6C7D8E9F0A12',
      );
      expect(problem, isNotNull);
      expect(problem, contains('madeup'));
      expect(problem, contains('obfs4'), reason: 'the message names what does work');
    });

    test('an empty line', () {
      expect(bridgeLineProblem('   '), isNotNull);
    });

    test('the word Bridge and nothing else', () {
      expect(bridgeLineProblem('Bridge'), isNotNull);
    });

    test('a snowflake line with no broker URL', () {
      expect(bridgeLineProblem('snowflake 47B2E1F5C3D8A96B0E4F1C2D3A5B6C7D8E9F0A12'),
          isNotNull);
    });
  });

  group('a line that can work is accepted', () {
    // The real shapes, with documentation-range addresses. These must pass: a validator
    // that rejects correct input is worse than none, because it makes the app unusable for
    // the people who need bridges most.
    test('obfs4 with iat-mode', () {
      expect(
        bridgeLineProblem('obfs4 192.0.2.10:443 '
            '47B2E1F5C3D8A96B0E4F1C2D3A5B6C7D8E9F0A12 '
            'cert=abcdEFGH12345678 iat-mode=0'),
        isNull,
      );
    });

    test('obfs4 with a leading Bridge keyword', () {
      expect(
        bridgeLineProblem('Bridge obfs4 192.0.2.10:443 '
            '47B2E1F5C3D8A96B0E4F1C2D3A5B6C7D8E9F0A12 cert=abc'),
        isNull,
      );
    });

    test('lower-case "bridge" and lower-case transport', () {
      // torrc keywords are case-insensitive, and the parser used to be case-sensitive
      // here — which is how a configured bridge came to be silently ignored.
      expect(
        bridgeLineProblem('bridge obfs4 192.0.2.10:443 '
            '47b2e1f5c3d8a96b0e4f1c2d3a5b6c7d8e9f0a12 cert=abc'),
        isNull,
      );
    });

    test('webtunnel in the format the Tor Project actually hands out', () {
      // Copied from a real bridge line: address, fingerprint, url=, ver=. The endpoint is an
      // address even though the transport reaches a URL, which is the detail an earlier
      // version of this check got wrong and would have rejected working bridges over.
      expect(
        bridgeLineProblem('webtunnel [2001:db8:39ff:b176:96c8:fe95:7795:6a84]:443 '
            '8A619BB4906C5BA1CE1C411B39C5191991741BBF '
            'url=https://benches.date/Zjx8DRPQrFZUpUTdpFNu7x3r ver=0.0.7'),
        isNull,
      );
    });

    test('webtunnel with a bare https URL in the first position', () {
      // Hand-written lines are pasted both ways, so both are accepted.
      expect(
        bridgeLineProblem('webtunnel https://example.com/abc '
            '47B2E1F5C3D8A96B0E4F1C2D3A5B6C7D8E9F0A12 url=https://example.com/abc'),
        isNull,
      );
    });

    test('webtunnel with neither an address nor a URL', () {
      final problem = bridgeLineProblem('webtunnel example.com '
          '47B2E1F5C3D8A96B0E4F1C2D3A5B6C7D8E9F0A12 url=https://x/');
      expect(problem, isNotNull);
      expect(problem, contains('https://'),
          reason: 'the message has to say both shapes, or it misleads');
    });

    test('snowflake with a broker URL', () {
      expect(
        bridgeLineProblem('snowflake 47B2E1F5C3D8A96B0E4F1C2D3A5B6C7D8E9F0A12 '
            'url=https://snowflake-broker.example/ ice=stun:stun.example:3478'),
        isNull,
      );
    });

    test('meek_lite with url and front', () {
      expect(
        bridgeLineProblem('meek_lite 192.0.2.10:443 '
            '47B2E1F5C3D8A96B0E4F1C2D3A5B6C7D8E9F0A12 '
            'url=https://example.com/ front=www.example.com'),
        isNull,
      );
    });

    test('an IPv6 address in brackets', () {
      expect(
        bridgeLineProblem('obfs4 [2001:db8::1]:443 '
            '47B2E1F5C3D8A96B0E4F1C2D3A5B6C7D8E9F0A12 cert=abc'),
        isNull,
      );
    });

    test('a plain bridge line keeps only the "needs a fingerprint" complaint', () {
      // A bare address is not the obfs4 shape, and saying so specifically is more useful
      // than a generic rejection.
      final problem = bridgeLineProblem('192.0.2.10:443');
      expect(problem, isNotNull);
      expect(problem, contains('fingerprint'));
    });

    test('a plain bridge line with a fingerprint is accepted', () {
      expect(
        bridgeLineProblem(
          '192.0.2.10:443 47B2E1F5C3D8A96B0E4F1C2D3A5B6C7D8E9F0A12',
        ),
        isNull,
      );
    });
  });

  group('the generated torrc', () {
    // Real `Directory` objects rather than stand-ins: `Directory` is not an interface that
    // can be implemented, and `TorConfig.build` only reads `.path` from them. They are
    // created per test and removed by `tearDown`, because `addTearDown` is not available
    // while a group is being declared.
    late Directory data;
    late Directory hidden;

    setUp(() {
      data = Directory.systemTemp.createTempSync('df-torrc-data-');
      hidden = Directory.systemTemp.createTempSync('df-torrc-hs-');
    });

    tearDown(() {
      if (data.existsSync()) data.deleteSync(recursive: true);
      if (hidden.existsSync()) hidden.deleteSync(recursive: true);
    });

    TorSettings settingsWith(String bridges) => TorSettings(
          customBridges: bridges,
          mode: BridgeMode.webTunnel,
        );

    String build(TorSettings settings) => TorConfig.build(
          settings: settings,
          dataDirectory: data,
          hiddenServiceDirectory: hidden,
          socksPort: 9050,
          controlPort: 9051,
          cookieAuthFile: 'cookie',
          onionServiceTargetPort: 8080,
        );

    test('names no option Tor 0.4.9 calls deprecated', () {
      // Both of these were written into every bridged configuration, and Tor 0.4.9 logs a
      // warning for each — so every bridged start carried two lines of red text that had
      // nothing to do with whether the connection worked. Their values were Tor's own
      // defaults.
      final torrc = build(settingsWith('webtunnel https://example.com/a '
          '47B2E1F5C3D8A96B0E4F1C2D3A5B6C7D8E9F0A12'));

      expect(torrc, isNot(contains('ClientBootstrapConsensusAuthorityDownloadSchedule')));
      expect(torrc, isNot(contains('ClientBootstrapConsensusFallbackDownloadSchedule')));
      expect(torrc, isNot(contains('ClientBootstrapConsensus')));
    });

    test('writes the bridge line verbatim, with the keyword added once', () {
      final torrc = build(settingsWith(
        'webtunnel https://example.com/a 47B2E1F5C3D8A96B0E4F1C2D3A5B6C7D8E9F0A12 '
        'url=https://example.com/a',
      ));
      expect(torrc, contains('UseBridges 1'));
      expect(torrc, contains('Bridge webtunnel https://example.com/a '
          '47B2E1F5C3D8A96B0E4F1C2D3A5B6C7D8E9F0A12 url=https://example.com/a'));
      expect(torrc, isNot(contains('Bridge Bridge')));
    });

    test('writes UseBridges 0 when there are no lines', () {
      final torrc = build(settingsWith(''));
      expect(torrc, contains('UseBridges 0'));
      expect(torrc, isNot(contains('UseBridges 1')));
    });

    test('forwards the onion service to the port the server holds', () {
      // This pairing is what a mismatched port silently breaks: the address is published
      // and every inbound connection is delivered into nothing.
      final torrc = build(settingsWith(''));
      expect(torrc, contains('HiddenServicePort 80 127.0.0.1:8080'));
    });

    test('drops a malformed line instead of stopping the daemon', () {
      // The recovery path. A line saved before this validation existed — or pasted by a user
      // who has forgotten it — must not be able to keep Tor from starting, because that is
      // a total loss of the network with no way out from inside the app.
      final torrc = build(settingsWith(
        'webtunnel https://example.com/abc AAAA\n'
        'obfs4 192.0.2.10:443 47B2E1F5C3D8A96B0E4F1C2D3A5B6C7D8E9F0A12 cert=abc',
      ));

      // The good line is written.
      expect(torrc, contains('Bridge obfs4 192.0.2.10:443 '
          '47B2E1F5C3D8A96B0E4F1C2D3A5B6C7D8E9F0A12 cert=abc'));
      // The bad one is not, and its absence is explained where it was.
      expect(torrc, isNot(contains('Bridge webtunnel https://example.com/abc AAAA')));
      expect(torrc, contains('Ignored, because Tor will not start while it is present'));
      expect(torrc, contains('40 characters'));
    });

    test('a configuration whose every line is bad falls back to no bridges at all', () {
      // Tor still starts, and — more importantly — the rest of the file is still written.
      // An early return here would have dropped the onion service, leaving the account with
      // no address, which is a worse failure than the one being fixed.
      final torrc = build(settingsWith('webtunnel https://example.com/abc AAAA'));
      expect(torrc, isNot(contains('Bridge webtunnel')));
      expect(torrc, contains('Ignored'));
      expect(torrc, contains('UseBridges 0'));
      expect(torrc, isNot(contains('UseBridges 1')));
      expect(torrc, contains('HiddenServiceDir'),
          reason: 'the account must still publish an address');
      expect(torrc, contains('HiddenServicePort 80 127.0.0.1:8080'));
      expect(torrc, contains('SocksPort 127.0.0.1:9050'),
          reason: 'the mesh still needs a SOCKS port to dial through');
    });
  });
}
