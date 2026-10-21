import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../app_metrics.dart';
import '../app_typography.dart';

/// The solid accent button used for the primary action on every screen
/// ("Next", "Create account", "Go to Tor bridge settings" is its secondary
/// sibling).
///
/// Measured from the mockups: 56 pt tall, 12 pt radius, full control width.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.expand = true,
    this.icon,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;

  /// Shows a spinner in place of the label and blocks taps.
  final bool busy;

  /// When false the button hugs its content instead of filling the row.
  final bool expand;

  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    return _ButtonSurface(
      expand: expand,
      background: enabled ? AppColors.accent : AppColors.accent.withValues(alpha: 0.35),
      pressedBackground: AppColors.accentPressed,
      enabled: enabled,
      onPressed: enabled ? onPressed : null,
      child: busy
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                valueColor: AlwaysStoppedAnimation(AppColors.textOnAccent),
              ),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 20, color: AppColors.textOnAccent),
                  const SizedBox(width: 10),
                ],
                Flexible(
                  child: Text(
                    label,
                    style: AppTypography.bodyStrong.copyWith(
                      color: AppColors.textOnAccent.withValues(alpha: enabled ? 1 : 0.7),
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
    );
  }
}

/// A neutral, surface-coloured button. Used for secondary actions such as
/// "Go to Tor bridge settings" and for bridge presets.
class SecondaryButton extends StatelessWidget {
  const SecondaryButton({
    required this.label,
    required this.onPressed,
    this.expand = true,
    this.height = AppMetrics.buttonHeight,
    this.selected = false,
    this.icon,
    this.child,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool expand;
  final double height;

  /// Renders the accent wash used for the active bridge preset.
  final bool selected;

  final IconData? icon;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return _ButtonSurface(
      expand: expand,
      height: height,
      background: selected ? AppColors.accentWash : AppColors.surface,
      pressedBackground: AppColors.surfacePressed,
      border: selected ? AppColors.accent : null,
      enabled: enabled,
      onPressed: enabled ? onPressed : null,
      child: child ??
          Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 20, color: AppColors.textPrimary),
                const SizedBox(width: 10),
              ],
              Flexible(
                child: Text(
                  label,
                  style: AppTypography.bodyStrong,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
    );
  }
}

class _ButtonSurface extends StatefulWidget {
  const _ButtonSurface({
    required this.child,
    required this.background,
    required this.pressedBackground,
    required this.enabled,
    required this.onPressed,
    required this.expand,
    this.height = AppMetrics.buttonHeight,
    this.border,
  });

  final Widget child;
  final Color background;
  final Color pressedBackground;
  final bool enabled;
  final VoidCallback? onPressed;
  final bool expand;
  final double height;
  final Color? border;

  @override
  State<_ButtonSurface> createState() => _ButtonSurfaceState();
}

class _ButtonSurfaceState extends State<_ButtonSurface> {
  bool _hovered = false;
  bool _held = false;

  @override
  Widget build(BuildContext context) {
    final background = _held
        ? widget.pressedBackground
        : _hovered && widget.enabled
            ? Color.alphaBlend(AppColors.surfacePressed.withValues(alpha: 0.35), widget.background)
            : widget.background;

    final button = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      height: widget.height,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppMetrics.buttonRadius),
        border: widget.border == null ? null : Border.all(color: widget.border!, width: 1.5),
      ),
      child: widget.child,
    );

    return MouseRegion(
      cursor: widget.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _held = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: widget.enabled ? (_) => setState(() => _held = true) : null,
        onTapUp: widget.enabled ? (_) => setState(() => _held = false) : null,
        onTapCancel: widget.enabled ? () => setState(() => _held = false) : null,
        onTap: widget.onPressed,
        child: widget.expand ? SizedBox(width: double.infinity, child: button) : button,
      ),
    );
  }
}
