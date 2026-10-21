import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../app_metrics.dart';
import '../app_typography.dart';

/// The base scaffold: `#1A1A1A` canvas, no Material elevation or tint.
class AppScaffold extends StatelessWidget {
  const AppScaffold({
    required this.child,
    this.appBar,
    this.bottomBar,
    this.resizeToAvoidBottomInset = true,
    super.key,
  });

  final Widget child;
  final PreferredSizeWidget? appBar;
  final Widget? bottomBar;
  final bool resizeToAvoidBottomInset;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      resizeToAvoidBottomInset: resizeToAvoidBottomInset,
      appBar: appBar,
      bottomNavigationBar: bottomBar,
      body: child,
    );
  }
}

/// Keeps forms readable on a wide desktop window by centring them in a column
/// of at most [AppMetrics.maxContentWidth].
class CenteredContent extends StatelessWidget {
  const CenteredContent({
    required this.child,
    this.maxWidth = AppMetrics.maxContentWidth,
    this.padding = const EdgeInsets.symmetric(horizontal: AppMetrics.controlInset),
    super.key,
  });

  final Widget child;
  final double maxWidth;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// The large centred screen title used on the auth, Chats, Profile and
/// Settings screens ("Create Account", "Chats", "Profile", "Settings").
class ScreenTitle extends StatelessWidget {
  const ScreenTitle(this.text, {this.alignment = TextAlign.center, this.style, super.key});

  final String text;
  final TextAlign alignment;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Text(
        text,
        textAlign: alignment,
        style: style ?? AppTypography.h1,
      ),
    );
  }
}

/// A left-aligned section label such as "Presets" or "Manual Configuration".
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.text, {this.padding = EdgeInsets.zero, super.key});

  final String text;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Text(text, style: AppTypography.sectionLabel),
    );
  }
}

/// The 60 pt `#2C2C2C` bar at the top of a conversation.
///
/// [header] replaces the avatar/title/status trio when the caller has to wrap them
/// in something — a tap target that opens the peer's profile, say. It is a whole
/// widget rather than a callback because only the caller knows whether the header
/// leads anywhere: half-tappable bars are worse than either option.
class ChatAppBar extends StatelessWidget implements PreferredSizeWidget {
  const ChatAppBar({
    required this.title,
    this.avatar,
    this.actions = const [],
    this.onBack,
    this.status,
    this.header,
    super.key,
  });

  final String title;
  final Widget? avatar;
  final List<Widget> actions;
  final VoidCallback? onBack;
  final Widget? status;

  /// Fills the space between the back affordance and [actions]. When null, the
  /// [avatar], [title] and [status] are laid out as usual.
  final Widget? header;

  @override
  Size get preferredSize => const Size.fromHeight(AppMetrics.chatAppBarHeight);

  @override
  Widget build(BuildContext context) {
    final header = this.header;
    return Material(
      color: AppColors.surface,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: AppMetrics.chatAppBarHeight,
          child: Row(
            children: [
              if (onBack != null)
                IconButton(
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back_ios_new, size: 18),
                  color: AppColors.textPrimary,
                  splashRadius: 22,
                )
              else
                const SizedBox(width: 14),
              if (header != null)
                Expanded(child: header)
              else ...<Widget>[
                if (avatar != null) ...[
                  avatar!,
                  const SizedBox(width: 18),
                ],
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: AppTypography.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      ?status,
                    ],
                  ),
                ),
              ],
              ...actions,
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}

/// A thin `#3A3A3A` bar with an accent fill, used by the Tor bootstrap screen.
class AppProgressBar extends StatelessWidget {
  const AppProgressBar({required this.value, this.height = AppMetrics.progressBarHeight, super.key});

  /// 0..1. Values outside the range are clamped.
  final double value;
  final double height;

  @override
  Widget build(BuildContext context) {
    final clamped = value.clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: Stack(
        children: [
          Container(height: height, color: AppColors.surfaceHigh),
          FractionallySizedBox(
            widthFactor: clamped,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
              height: height,
              decoration: BoxDecoration(
                color: AppColors.accent,
                borderRadius: BorderRadius.circular(height / 2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The small filled circle that marks a bootstrap step.
class StatusDot extends StatelessWidget {
  const StatusDot({this.active = false, this.size = AppMetrics.progressDotSize, super.key});

  final bool active;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: active ? AppColors.accent : AppColors.textSecondary,
        shape: BoxShape.circle,
      ),
    );
  }
}

/// A 1 px hairline used between rows where the mockups show a subtle break.
class AppDivider extends StatelessWidget {
  const AppDivider({this.indent = 0, super.key});

  final double indent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: indent),
      child: const Divider(height: 1, thickness: 1, color: AppColors.divider),
    );
  }
}
