import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../app_metrics.dart';
import '../app_typography.dart';

/// A full-bleed row on the Profile and Settings screens: 50 pt tall,
/// `#2C2C2C`, label inset 14 pt, no corner radius, 5 pt gaps between rows.
class AppListRow extends StatefulWidget {
  const AppListRow({
    required this.label,
    this.onTap,
    this.leading,
    this.trailing,
    this.labelColor,
    this.subtitle,
    this.selected = false,
    super.key,
  });

  final String label;
  final VoidCallback? onTap;
  final Widget? leading;
  final Widget? trailing;
  final Color? labelColor;
  final String? subtitle;
  final bool selected;

  @override
  State<AppListRow> createState() => _AppListRowState();
}

class _AppListRowState extends State<AppListRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final interactive = widget.onTap != null;
    final background = widget.selected
        ? AppColors.accentWash
        : _hovered && interactive
            ? AppColors.surfacePressed
            : AppColors.surface;

    return MouseRegion(
      cursor: interactive ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          color: background,
          constraints: const BoxConstraints(minHeight: AppMetrics.listTileHeight),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Row(
            children: [
              if (widget.leading != null) ...[
                widget.leading!,
                const SizedBox(width: 14),
              ],
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      widget.label,
                      style: AppTypography.body.copyWith(color: widget.labelColor),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (widget.subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        widget.subtitle!,
                        style: AppTypography.caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              if (widget.trailing != null) ...[
                const SizedBox(width: 12),
                widget.trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A vertical run of [AppListRow]s with the 5 pt rhythm from the mockups.
class AppListSection extends StatelessWidget {
  const AppListSection({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) rows.add(const SizedBox(height: AppMetrics.listTileGap));
      rows.add(children[i]);
    }
    return Column(mainAxisSize: MainAxisSize.min, children: rows);
  }
}

/// A toggle row. Material's switch is restyled to the accent colour so it sits
/// in the design language; the mockups do not show a switch, so the geometry
/// follows that of a normal list row.
class AppSwitchRow extends StatelessWidget {
  const AppSwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
    super.key,
  });

  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return AppListRow(
      label: label,
      subtitle: subtitle,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      trailing: Switch(
        value: value,
        onChanged: onChanged,
        activeThumbColor: AppColors.textOnAccent,
        activeTrackColor: AppColors.accent,
        inactiveThumbColor: AppColors.textSecondary,
        inactiveTrackColor: AppColors.surfaceHigh,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}
