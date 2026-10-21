import 'dart:convert';

import 'package:flutter/services.dart';

import 'models/tor_settings.dart';

/// Loads the bridge presets that ship with the app.
///
/// The presets are deliberately *transport* presets, not address lists. Bridge
/// lines are rotated by the Tor Project precisely because censors block them,
/// so a list baked into a release is stale within weeks and gives users a false
/// sense of having working access. What the app can honestly provide is the
/// transport wiring — which pluggable transport to launch and how to configure
/// torrc — plus a place to paste addresses obtained from BridgeDB.
class BridgePresetStore {
  // Assigned rather than taken as an initialising formal so callers write
  // `bundle:` rather than `_bundle:`.
  // ignore: prefer_initializing_formals
  const BridgePresetStore({AssetBundle? bundle}) : _bundle = bundle;

  final AssetBundle? _bundle;

  /// Where the preset definitions live.
  static const String assetPath = 'assets/bridges/bridges.json';

  /// Reads the presets, or returns an empty list when the asset is unavailable.
  ///
  /// A missing asset must not stop the app from starting: the bridge screen is
  /// still usable as a manual paste box, which is the path that works when the
  /// bundled list is stale anyway.
  Future<List<BridgePreset>> load() async {
    try {
      final raw = await (_bundle ?? rootBundle).loadString(assetPath);
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return const <BridgePreset>[];
      final presets = decoded['presets'];
      if (presets is! List) return const <BridgePreset>[];
      return presets
          .whereType<Map<dynamic, dynamic>>()
          .map((entry) => BridgePreset.fromJson(Map<String, dynamic>.from(entry)))
          .toList(growable: false);
    } on Object {
      return const <BridgePreset>[];
    }
  }
}
