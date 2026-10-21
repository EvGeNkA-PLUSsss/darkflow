import 'package:flutter/widgets.dart';

import 'app_colors.dart';

/// The type scale, derived from glyph-height measurements of the mockups.
///
/// Text in the SVG sources is outlined, so sizes were recovered by measuring
/// rendered cap-heights (`tool/measure_text.py`) and converting them with the
/// Inter cap-height ratio of 0.727 em.
///
/// Every style sets `decoration: TextDecoration.none` explicitly, and that is
/// load-bearing rather than decorative. `MaterialApp` installs a deliberately
/// alarming fallback text style — red, monospace, 48 pt, with a *double yellow
/// underline* — for any `Text` that is not inside a `Material`, and its
/// `debugLabel` literally reads "put your text in a Material". A style that
/// sets family, size and colour but not `decoration` inherits that underline,
/// which is exactly how the desktop empty state ended up with yellow stripes
/// under its words.
abstract final class AppTypography {
  /// Bundled with the app so Windows, Android, iOS, Linux and macOS all render
  /// the design identically.
  static const String fontFamily = 'Inter';

  /// The wordmark on the sign-in screen.
  static const TextStyle logo = TextStyle(
    fontFamily: fontFamily,
    decoration: TextDecoration.none,
    fontSize: 36,
    fontWeight: FontWeight.w700,
    height: 1.1,
    letterSpacing: -0.8,
    color: AppColors.textPrimary,
  );

  /// Auth/screen titles: "Create Account", "Chats", "Profile", "Settings".
  static const TextStyle h1 = TextStyle(
    fontFamily: fontFamily,
    decoration: TextDecoration.none,
    fontSize: 28,
    fontWeight: FontWeight.w700,
    height: 1.2,
    letterSpacing: -0.4,
    color: AppColors.textPrimary,
  );

  /// The Tor screens use a slightly smaller title.
  static const TextStyle h2 = TextStyle(
    fontFamily: fontFamily,
    decoration: TextDecoration.none,
    fontSize: 24,
    fontWeight: FontWeight.w700,
    height: 1.25,
    letterSpacing: -0.3,
    color: AppColors.textPrimary,
  );

  /// Section labels inside a screen: "Presets", "Manual Configuration".
  static const TextStyle sectionLabel = TextStyle(
    fontFamily: fontFamily,
    decoration: TextDecoration.none,
    fontSize: 16,
    fontWeight: FontWeight.w700,
    height: 1.3,
    color: AppColors.textPrimary,
  );

  /// A contact or conversation name.
  static const TextStyle title = TextStyle(
    fontFamily: fontFamily,
    decoration: TextDecoration.none,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    height: 1.3,
    color: AppColors.textPrimary,
  );

  /// Default reading size.
  static const TextStyle body = TextStyle(
    fontFamily: fontFamily,
    decoration: TextDecoration.none,
    fontSize: 16,
    fontWeight: FontWeight.w400,
    height: 1.35,
    color: AppColors.textPrimary,
  );

  /// Body copy with emphasis, e.g. a button label.
  static const TextStyle bodyStrong = TextStyle(
    fontFamily: fontFamily,
    decoration: TextDecoration.none,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    height: 1.3,
    color: AppColors.textPrimary,
  );

  /// Input text and input placeholders.
  static const TextStyle input = TextStyle(
    fontFamily: fontFamily,
    decoration: TextDecoration.none,
    fontSize: 16,
    fontWeight: FontWeight.w400,
    height: 1.3,
    color: AppColors.textPrimary,
  );

  /// Input placeholders — a touch smaller than the entered text, as designed.
  static const TextStyle placeholder = TextStyle(
    fontFamily: fontFamily,
    decoration: TextDecoration.none,
    fontSize: 15,
    fontWeight: FontWeight.w400,
    height: 1.3,
    color: AppColors.textSecondary,
  );

  /// Secondary copy: subtitles, descriptions, list supporting text.
  static const TextStyle secondary = TextStyle(
    fontFamily: fontFamily,
    decoration: TextDecoration.none,
    fontSize: 15,
    fontWeight: FontWeight.w400,
    height: 1.35,
    color: AppColors.textSecondary,
  );

  /// Timestamps and other micro-copy.
  static const TextStyle caption = TextStyle(
    fontFamily: fontFamily,
    decoration: TextDecoration.none,
    fontSize: 13,
    fontWeight: FontWeight.w400,
    height: 1.2,
    color: AppColors.textSecondary,
  );

  /// The monospaced face used for onion addresses, fingerprints and seeds.
  static const TextStyle mono = TextStyle(
    fontFamily: 'monospace',
    decoration: TextDecoration.none,
    fontSize: 13,
    fontWeight: FontWeight.w400,
    height: 1.4,
    color: AppColors.textPrimary,
  );

  /// The single-letter initial inside an avatar.
  static const TextStyle avatarInitial = TextStyle(
    fontFamily: fontFamily,
    decoration: TextDecoration.none,
    fontWeight: FontWeight.w700,
    height: 1.0,
    color: AppColors.textOnAccent,
  );
}
