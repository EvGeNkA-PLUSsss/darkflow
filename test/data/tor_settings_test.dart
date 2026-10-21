import 'package:darkflow/src/data/models/tor_settings.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the two settings that shape the first-run experience.
///
/// Both were changed in response to how the app actually behaved: a user on a
/// censored network watched a bootstrap stall at 10% before they had any chance
/// to configure a bridge, and a preset with no addresses silently produced a
/// `UseBridges 1` configuration with nothing to connect to.
void main() {
  group('starting the daemon', () {
    test('there is no stored flag that could start Tor by itself', () {
      // Tor has exactly one entry point — the Connect button — so the model
      // must not carry a setting that could quietly start it. An earlier
      // version persisted `autoStart`, and a vault written by it would have
      // overridden the new default.
      final json = const TorSettings().toJson();
      expect(json.containsKey('autoStart'), isFalse);
      expect(json.containsKey('autostart'), isFalse);
    });

    test('a legacy vault carrying autoStart still loads', () {
      // Old vaults have the key; reading one must not throw, and the value must
      // be ignored rather than acted on.
      final decoded = TorSettings.fromJson(<String, dynamic>{
        'mode': 'obfs4',
        'customBridges': 'Bridge obfs4 1.2.3.4:443 FP cert=x',
        'autoStart': true,
      });
      expect(decoded.mode, BridgeMode.obfs4);
      expect(decoded.bridgeLines, hasLength(1));
    });
  });

  group('bridge lines', () {
    test('an empty box yields no lines', () {
      expect(const TorSettings(mode: BridgeMode.obfs4).bridgeLines, isEmpty);
    });

    test('comments and blank lines are dropped', () {
      const settings = TorSettings(
        mode: BridgeMode.custom,
        customBridges: '# a note\n'
            '\n'
            '   \n'
            'Bridge obfs4 1.2.3.4:443 FP cert=x\n',
      );
      expect(settings.bridgeLines, hasLength(1));
    });

    test('the first token of a line is preserved', () {
      // `TorConfig` writes the lines verbatim when they already start with
      // `Bridge`, and prefixes the keyword when they do not — so the model must
      // not strip it here.
      const settings = TorSettings(
        customBridges: 'Bridge obfs4 1.2.3.4:443 FP cert=x',
      );
      expect(settings.bridgeLines.single, startsWith('Bridge obfs4'));
    });
  });

  group('bridges inferred from the lines', () {
    // The bug this pins: the user pasted `webtunnel …` lines and pressed Next
    // without tapping a preset, so `mode` stayed `automatic`, `usesBridges`
    // stayed false, and torrc was written with `UseBridges 0` — the bridges
    // were silently discarded and Tor connected directly.
    test('pasted webtunnel lines turn bridges on by themselves', () {
      const settings = TorSettings(
        customBridges:
            'webtunnel [2001:db8::1]:443 8A61 url=https://x ver=0.0.7',
      );
      expect(settings.usesBridges, isTrue);
      expect(settings.effectiveMode, BridgeMode.webTunnel);
      expect(settings.requiredTransports, contains('webtunnel'));
    });

    test('the keyword is recognised with and without the Bridge prefix', () {
      for (final line in <String>[
        'webtunnel [2001:db8::1]:443 8A61 url=https://x ver=0.0.7',
        'Bridge webtunnel [2001:db8::1]:443 8A61 url=https://x ver=0.0.7',
      ]) {
        expect(
          const TorSettings(customBridges: '').copyWith(customBridges: line).effectiveMode,
          BridgeMode.webTunnel,
          reason: 'failed on: $line',
        );
      }
    });

    test('obfs4 and snowflake lines are recognised too', () {
      expect(
        const TorSettings(customBridges: 'obfs4 1.2.3.4:443 FP cert=x')
            .effectiveMode,
        BridgeMode.obfs4,
      );
      expect(
        const TorSettings(customBridges: 'snowflake 192.0.2.1:1 FP').effectiveMode,
        BridgeMode.snowflake,
      );
    });

    test('an explicit preset still wins over the lines', () {
      // Choosing a transport deliberately must not be overridden by whatever
      // happens to be in the box.
      const settings = TorSettings(
        mode: BridgeMode.obfs4,
        customBridges: 'webtunnel [2001:db8::1]:443 8A61 url=https://x',
      );
      expect(settings.effectiveMode, BridgeMode.obfs4);
    });

    test('no lines and no preset means a direct connection', () {
      const settings = TorSettings();
      expect(settings.usesBridges, isFalse);
      expect(settings.effectiveMode, BridgeMode.automatic);
      expect(settings.requiredTransports, isEmpty);
    });
  });

  group('transport metadata', () {
    test('automatic is not a bridge mode', () {
      expect(BridgeMode.automatic.isBridgeMode, isFalse);
      expect(BridgeMode.obfs4.isBridgeMode, isTrue);
    });

    test('each bridge mode reports the transports torrc needs', () {
      expect(const TorSettings(mode: BridgeMode.automatic).requiredTransports, isEmpty);
      expect(
        const TorSettings(mode: BridgeMode.obfs4).requiredTransports,
        contains('obfs4'),
      );
      expect(
        const TorSettings(mode: BridgeMode.webTunnel).requiredTransports,
        contains('webtunnel'),
      );
      expect(
        const TorSettings(mode: BridgeMode.snowflake).requiredTransports,
        contains('snowflake'),
      );
      expect(
        const TorSettings(mode: BridgeMode.meek).requiredTransports,
        contains('meek'),
      );
    });

    test('every mode has a label for the settings row', () {
      for (final mode in BridgeMode.values) {
        expect(mode.label, isNotEmpty, reason: '${mode.name} has no label');
      }
    });
  });
}
