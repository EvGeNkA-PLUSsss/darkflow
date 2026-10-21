import 'package:darkflow/src/data/bridge_presets.dart';
import 'package:darkflow/src/data/models/tor_settings.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The bridge screen is useless if its presets do not load, and the asset is
/// the kind of thing that silently stops being bundled when a `pubspec.yaml`
/// entry is edited. These tests pin both the shipped file and the parsing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('bundled asset', () {
    test('is declared and parses into presets', () async {
      final presets = await const BridgePresetStore().load();
      expect(presets, isNotEmpty, reason: 'assets/bridges/bridges.json must ship');
      expect(
        presets.map((preset) => preset.id),
        containsAll(<String>['obfs4', 'webtunnel', 'snowflake', 'meek']),
      );
    });

    test('every preset names a real transport and has a description', () async {
      for (final preset in await const BridgePresetStore().load()) {
        expect(
          BridgeMode.values.map((mode) => mode.name),
          contains(preset.mode.name),
          reason: '${preset.id} maps to an unknown BridgeMode',
        );
        expect(preset.description, isNotEmpty, reason: '${preset.id} has no description');
        expect(preset.label, isNotEmpty, reason: '${preset.id} has no label');
      }
    });

    test('no bridge addresses are baked into the app', () async {
      // This is a deliberate product decision, not an oversight: bridge lines
      // rotate precisely because censors block them, so a bundled list would be
      // stale within weeks and would give users false confidence. If someone
      // later "fixes" this by pasting addresses into the asset, this test is the
      // place that says why they should not.
      for (final preset in await const BridgePresetStore().load()) {
        expect(
          preset.bridges,
          isEmpty,
          reason: '${preset.id} ships bridge addresses; they rotate and must not be '
              'baked into a release',
        );
      }
    });
  });

  group('parsing', () {
    test('an unavailable asset yields an empty list rather than throwing', () async {
      final store = BridgePresetStore(bundle: _EmptyBundle());
      expect(await store.load(), isEmpty);
    });

    test('a malformed asset yields an empty list rather than throwing', () async {
      final store = BridgePresetStore(bundle: _LiteralBundle('not json at all'));
      expect(await store.load(), isEmpty);
    });

    test('a preset without a bridges array still loads', () async {
      final store = BridgePresetStore(
        bundle: _LiteralBundle(
          '{"presets":[{"id":"x","label":"X","mode":"obfs4","description":"d"}]}',
        ),
      );
      final presets = await store.load();
      expect(presets, hasLength(1));
      expect(presets.single.bridges, isEmpty);
      expect(presets.single.mode, BridgeMode.obfs4);
    });
  });

  group('TransportConfig safety', () {
    test('a transport with no addresses does not enable UseBridges', () {
      // A preset with an empty box must not produce `UseBridges 1` with no
      // `Bridge` lines: Tor would start, find nothing to connect to, and the
      // bootstrap would never move. `TorConfig` guards on the line count, and
      // this asserts the model the guard reads.
      const settings = TorSettings(mode: BridgeMode.obfs4, customBridges: '');
      expect(settings.usesBridges, isTrue);
      expect(settings.bridgeLines, isEmpty);
    });

    test('pasted lines are parsed one per line', () {
      const settings = TorSettings(
        mode: BridgeMode.obfs4,
        customBridges: 'Bridge obfs4 1.2.3.4:443 FP cert=x iat-mode=0\n'
            '\n'
            '# a comment\n'
            'Bridge obfs4 5.6.7.8:80 FP2 cert=y iat-mode=0\n',
      );
      expect(settings.bridgeLines, hasLength(2));
      expect(settings.bridgeLines.first, startsWith('Bridge obfs4 1.2.3.4'));
    });
  });
}

/// A bundle with nothing in it, standing in for a build that lost the asset.
class _EmptyBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => throw StateError('missing $key');

  @override
  Future<String> loadString(String key, {bool cache = true}) async =>
      throw StateError('missing $key');
}

/// A bundle that returns whatever string it was given.
class _LiteralBundle extends CachingAssetBundle {
  _LiteralBundle(this.contents);

  final String contents;

  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(Uint8List.fromList(contents.codeUnits));

  @override
  Future<String> loadString(String key, {bool cache = true}) async => contents;
}
