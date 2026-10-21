import 'package:flutter/widgets.dart';

/// Layout constants measured from the mockups (a 390 x 844 logical canvas).
///
/// Values are taken verbatim from `tool/layout_report.json` so the built app
/// lines up with the design files instead of relying on guesswork.
abstract final class AppMetrics {
  /// The reference canvas the mockups were drawn on.
  static const Size designCanvas = Size(390, 844);

  // ---------------------------------------------------------------- spacing

  /// Horizontal padding for screen content that is not a primary control.
  static const double screenPadding = 24;

  /// Horizontal inset of primary controls (fields and buttons) on auth screens.
  /// The design uses 45 on both sides, giving a 300 pt control on a 390 canvas.
  static const double controlInset = 45;

  /// The vertical rhythm between stacked controls: measured 18-20 in the
  /// mockups, normalised to 20.
  static const double gap = 20;

  /// Gap between a form and its submit button.
  static const double formGap = 20;

  // -------------------------------------------------------------- controls

  static const double fieldHeight = 56;
  static const double fieldRadius = 12;
  static const double fieldTextPadding = 18;

  static const double buttonHeight = 56;
  static const double buttonRadius = 12;

  /// A pill-shaped search field on the Chats screen: 300 x 40, fully rounded.
  static const double searchHeight = 40;

  /// The chat composer: 50 tall, pill shaped.
  static const double composerHeight = 50;

  // --------------------------------------------------------------- avatars

  static const double avatarProfile = 96;
  static const double avatarList = 48;
  static const double avatarChat = 38;
  static const double avatarSmall = 32;

  // ----------------------------------------------------------------- lists

  static const double listTileHeight = 50;
  static const double listTileGap = 5;

  // ------------------------------------------------------------------ chat

  static const double chatAppBarHeight = 60;
  static const double bubbleRadius = 12;
  static const double bubbleMaxWidthFactor = 0.78;

  // ------------------------------------------------------------------- tor

  /// Height of the bootstrap progress bar (measured 7.2 pt, fully rounded).
  static const double progressBarHeight = 7;
  static const double progressStepSpacing = 30;
  static const double progressDotSize = 9;

  /// "Go to Tor bridge settings" + "Next" are stacked with this gap (10.4).
  static const double stackedButtonGap = 10;

  // ------------------------------------------------------------ bridge form

  static const double bridgePresetHeight = 60;
  static const double bridgePresetGap = 30;
  static const int bridgePresetColumns = 2;

  /// The manual-configuration text area is deliberately tall (464.5 pt).
  static const double bridgeTextAreaHeight = 464;

  // -------------------------------------------------------------- floating

  static const double fabSize = 48;
  static const double fabMargin = 16;

  // ------------------------------------------------------------ responsive

  /// On desktop the app is centred in a column no wider than this, so forms do
  /// not stretch across an entire monitor.
  static const double maxContentWidth = 440;

  /// Above this width the layout switches to desktop affordances (hover, a
  /// persistent navigation rail, keyboard shortcuts).
  static const double desktopBreakpoint = 900;

  /// The darkest point at which the two-pane (list + conversation) layout is
  /// used instead of pushing a new route.
  static const double twoPaneBreakpoint = 760;

  static const double masterPaneWidth = 340;
}
