import 'package:flutter/material.dart';

import '../../design/design.dart';

/// The base for every screen in the account flow (login, sign-up, password
/// creation).
///
/// It exists so that those screens share one *frame* rather than one layout:
/// the `#1A1A1A` canvas, desktop-safe chrome and scrollers written once here,
/// while each screen keeps control of where its own block sits vertically.
/// The screens themselves stay presentational — they are handed callbacks by
/// the app layer and never reach for a service.
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({
    required this.child,
    this.bottomBar,
    super.key,
  });

  /// The screen's form content. It is wrapped in [CenteredContent], so it is
  /// capped at [AppMetrics.maxContentWidth] and inset by
  /// [AppMetrics.controlInset] on both sides.
  final Widget child;

  /// Pinned below the content and outside the scroll view, so a screen-wide
  /// action stays reachable on a short viewport.
  final Widget? bottomBar;

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      bottomBar: bottomBar,
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            // A short viewport (a phone with the keyboard up) scrolls; a tall
            // one still centres the block, because the scroll view is told never
            // to shrink below the height it was given.
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: CenteredContent(child: child),
            ),
          ),
        ),
      ),
    );
  }
}

/// Positions an auth screen's block inside the [AuthScaffold] viewport.
///
/// The design mockups are not all centred the same way: "Create Account" is
/// centred, while the sign-in block sits noticeably above the middle. Expressing
/// that as an [Alignment] on the free space — instead of as a magic top margin —
/// keeps the offset proportional on every window size.
class AuthFormLayout extends StatelessWidget {
  const AuthFormLayout({
    required this.child,
    this.alignment = Alignment.center,
    super.key,
  });

  /// Where the block sits in the space it does not fill. `Alignment(0, -0.18)`
  /// reproduces the sign-in mockup, whose block centre is roughly 76 pt above
  /// the screen centre on the 390 x 844 canvas.
  final Alignment alignment;

  /// The screen's form. It is laid out at its natural height and stretched to
  /// the content column's width, so fields and buttons fill the 300 pt control
  /// width without every screen repeating `double.infinity`.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Align(
        alignment: alignment,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [child],
        ),
      ),
    );
  }
}

/// The "DarkFlow" wordmark above the sign-in form.
class AuthWordmark extends StatelessWidget {
  const AuthWordmark({this.text = 'DarkFlow', super.key});

  /// The wordmark copy. A parameter so the logo is never retyped as a literal
  /// in a second place.
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: AppTypography.logo,
      textAlign: TextAlign.center,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// A tappable line of accent text — "Create account", "I already have an
/// account".
///
/// It is deliberately not a [PrimaryButton]: the mockups draw these as plain
/// accent text with no fill, so it only needs a mouse cursor and a tap target.
/// The callback is optional so the same widget can render a read-only hint.
class AuthTextLink extends StatelessWidget {
  const AuthTextLink({
    required this.label,
    this.onTap,
    this.alignment = TextAlign.center,
    super.key,
  });

  final String label;

  /// Null renders the line as static text: no cursor change, no tap target.
  final VoidCallback? onTap;

  /// Alignment of the label inside the link's full width, for callers that want
  /// it flush left next to a form rather than centred under it.
  final TextAlign alignment;

  @override
  Widget build(BuildContext context) {
    final tappable = onTap != null;
    return MouseRegion(
      cursor: tappable ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          // Pads the tap target out to the 44 pt accessibility minimum without
          // changing where the glyphs sit.
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(
            label,
            textAlign: alignment,
            style: AppTypography.input.copyWith(
              fontSize: 15,
              color: AppColors.accent,
            ),
          ),
        ),
      ),
    );
  }
}

/// The back affordance for an auth screen that shows a header instead of an
/// [AuthScaffold]-style centred block.
///
/// It is a plain [IconButton] so it inherits [AppTheme]'s white icon colour and
/// Material's focus/hover behaviour on desktop, where it is the only way back.
class AuthBackButton extends StatelessWidget {
  const AuthBackButton({required this.onPressed, this.tooltip = 'Back', super.key});

  /// Null disables the affordance, for the rare case where leaving is not
  /// allowed while an operation is in flight.
  final VoidCallback? onPressed;

  /// Hover text. Announced by screen readers in place of the icon, which has no
  /// label of its own.
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      icon: const Icon(Icons.arrow_back_ios_new, size: 18),
      color: AppColors.textPrimary,
      splashRadius: 22,
    );
  }
}

/// A short strip of centred content pinned below an auth screen's block.
///
/// [AppScaffold] takes a [PreferredSizeWidget] as its bottom bar, and a bar that
/// hugs its content still has to answer for its height before layout runs. The
/// height is therefore a fixed row ([AppMetrics.fieldHeight]) rather than the
/// child's intrinsic size.
class AuthBottomSlot extends StatelessWidget implements PreferredSizeWidget {
  const AuthBottomSlot({required this.child, super.key});

  /// Centred inside the fixed row.
  final Widget child;

  @override
  Size get preferredSize => const Size.fromHeight(AppMetrics.fieldHeight);

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: SizedBox(
        height: AppMetrics.fieldHeight,
        child: Center(child: child),
      ),
    );
  }
}
