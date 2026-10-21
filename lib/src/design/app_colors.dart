import 'package:flutter/widgets.dart';

/// Colour tokens extracted pixel-by-pixel from the DarkFlow mockups.
///
/// Every value here comes from the SVG sources (see `tool/extract_layout.py`),
/// so the running app and the design files agree exactly.
abstract final class AppColors {
  /// `#1A1A1A` — the canvas behind everything.
  static const Color background = Color(0xFF1A1A1A);

  /// `#2C2C2C` — text fields, cards, incoming bubbles, list rows, top bars.
  static const Color surface = Color(0xFF2C2C2C);

  /// `#3A3A3A` — the unfilled part of a progress bar.
  static const Color surfaceHigh = Color(0xFF3A3A3A);

  /// A slightly lifted surface used for hover/pressed states on desktop.
  static const Color surfacePressed = Color(0xFF383838);

  /// `#6C63FF` — the single accent colour: primary buttons, outgoing bubbles,
  /// active indicators, links, the composer send glyph.
  static const Color accent = Color(0xFF6C63FF);

  /// `#463CE5` — the accent's pressed/held state.
  static const Color accentPressed = Color(0xFF463CE5);

  /// A very low-opacity accent wash for selected rows and focus glows.
  static const Color accentWash = Color(0x1F6C63FF);

  /// `#FFFFFF` — primary text.
  static const Color textPrimary = Color(0xFFFFFFFF);

  /// `#B0B0B0` — placeholders, subtitles, timestamps, inactive steps.
  static const Color textSecondary = Color(0xFFB0B0B0);

  /// Text drawn on top of [accent].
  static const Color textOnAccent = Color(0xFFFFFFFF);

  /// Hairline separators. Kept nearly invisible, matching the mockups.
  static const Color divider = Color(0xFF262626);

  /// The colour of a text field's outline once focused.
  static const Color fieldBorderFocused = Color(0xFF6C63FF);

  /// The default (unfocused) field outline — intentionally invisible.
  static const Color fieldBorder = Color(0x00000000);

  /// Destructive actions such as "Block". Not present in the mockups, so it is
  /// tuned to sit comfortably beside the accent without shouting.
  static const Color danger = Color(0xFFFF5C6C);

  /// Positive state used for "Online" and successful Tor bootstrap.
  static const Color online = Color(0xFF6C63FF);

  /// Amber used for warnings (e.g. Tor is bootstrapping over a slow bridge).
  static const Color warning = Color(0xFFFFB74D);

  /// Fully transparent, used for hit-target padding.
  static const Color transparent = Color(0x00000000);
}
