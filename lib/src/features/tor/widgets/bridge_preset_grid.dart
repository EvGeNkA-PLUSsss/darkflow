import 'package:flutter/material.dart';

import '../../../data/models/tor_settings.dart';
import '../../../design/design.dart';

/// The tap-to-select grid of bridge presets.
///
/// The mockup draws two 160 x 60 pt tiles separated by a 30 pt gutter on a
/// 390 pt canvas. Rather than freezing that geometry, the grid derives the
/// column count from the width it is given, so a wide desktop window shows four
/// tiles per row instead of two very wide ones — while the 60 pt height, the
/// 12 pt radius and the selected-state treatment stay exactly as designed.
class BridgePresetGrid extends StatelessWidget {
  const BridgePresetGrid({
    required this.presets,
    required this.selectedMode,
    this.onSelected,
    this.enabled = true,
    super.key,
  });

  /// The presets to offer, in display order.
  final List<BridgePreset> presets;

  /// The mode currently configured. A tile is highlighted when its own mode
  /// matches, which is what the screen's `selectedMode` means: several presets
  /// may ship lines for the same transport.
  final BridgeMode selectedMode;

  /// Called with the tapped preset. When null — or when [enabled] is false —
  /// the tiles are drawn in their disabled state and swallow no taps.
  final ValueChanged<BridgePreset>? onSelected;

  /// False while a fresh preset list is being fetched, so the user cannot pick
  /// from a list that is about to be replaced.
  final bool enabled;

  /// The narrowest tile worth drawing; below this the grid drops to one column.
  static const double _minTileWidth = 160;

  /// Vertical rhythm between wrapped rows. The mockup only ever shows one row,
  /// so this is the smallest gap that still reads as a grid.
  static const double _runSpacing = 12;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // A horizontally unbounded parent would make the arithmetic below
        // meaningless; fall back to the designed two columns.
        final width = constraints.hasBoundedWidth ? constraints.maxWidth : 350.0;
        final columns = _columnsFor(width);
        const gutter = AppMetrics.bridgePresetGap;
        final tileWidth = (width - gutter * (columns - 1)) / columns;

        return Wrap(
          spacing: gutter,
          runSpacing: _runSpacing,
          children: <Widget>[
            for (final preset in presets)
              SizedBox(
                width: tileWidth,
                height: AppMetrics.bridgePresetHeight,
                child: SecondaryButton(
                  label: preset.label,
                  height: AppMetrics.bridgePresetHeight,
                  selected: preset.mode == selectedMode,
                  onPressed: enabled && onSelected != null ? () => onSelected!(preset) : null,
                ),
              ),
          ],
        );
      },
    );
  }

  /// How many 160 pt tiles (plus gutters) fit in [width], clamped to the range
  /// the design tolerates. The tiny epsilon keeps a width that lands exactly on
  /// the boundary — 350 pt gives two tiles — from falling to the column below
  /// through floating-point rounding.
  int _columnsFor(double width) {
    const gutter = AppMetrics.bridgePresetGap;
    final fit = ((width + gutter) / (_minTileWidth + gutter) + 1e-6).floor();
    return fit < 1
        ? 1
        : fit > 4
            ? 4
            : fit;
  }
}
