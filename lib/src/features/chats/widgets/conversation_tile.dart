import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../design/design.dart';

/// One row of the conversation list: avatar, name, timestamp, preview, badge.
///
/// The tile takes plain values rather than a `ConversationSummary` so that it
/// can be used (and widget-tested) on its own, and so that `chats_screen.dart`
/// stays the only file that knows about the summary type.
///
/// Geometry is measured from `Chats.svg`: the avatar is inset 45 pt, the name
/// starts 18 pt after it (x = 111) and the row is 72 pt tall. The specification
/// also mentions 20 pt of vertical padding, which cannot be true next to a
/// 48 pt avatar inside a 72 pt row — 48 + 2 x 20 already exceeds it — so the row
/// is held at the measured 72 pt with 12 pt above and below the avatar.
class ConversationTile extends StatefulWidget {
  const ConversationTile({
    required this.displayName,
    required this.onTap,
    this.avatarPath,
    this.online = false,
    this.preview = '',
    this.lastMessageAt,
    this.unreadCount = 0,
    this.muted = false,
    this.pinned = false,
    this.now,
    this.onMenuRequested,
    super.key,
  });

  /// The contact's name, or the shortened onion address when unnamed.
  final String displayName;

  final VoidCallback onTap;
  final String? avatarPath;

  /// Draws the presence dot on the avatar.
  final bool online;

  /// The last message, one line, ellipsised. Empty means "nothing was ever
  /// sent here", which the tile says in words instead of leaving a gap.
  final String preview;

  final DateTime? lastMessageAt;
  final int unreadCount;

  /// Shows a crossed-out bell; muted threads still arrive, they just stay quiet.
  final bool muted;

  /// Shows a pin glyph so a pinned thread is identifiable at a glance.
  final bool pinned;

  /// Injectable "now" for the today/date decision; null uses the real clock.
  final DateTime? now;

  /// Reports a long press (phone) or a secondary click (desktop) along with where
  /// it happened, so the caller can put a menu under the finger. No menu is wired
  /// up when this is null, and the row then responds to a plain tap only.
  final void Function(Offset position)? onMenuRequested;

  /// The mockup's row height. A minimum rather than a fixed height so a large
  /// accessibility text scale grows the row instead of clipping it.
  static const double rowHeight = 72;

  @override
  State<ConversationTile> createState() => _ConversationTileState();
}

class _ConversationTileState extends State<ConversationTile> {
  bool _hovered = false;

  /// "HH:mm" for today, "3 Feb" otherwise — the pattern the mockups use.
  String get _timestamp {
    final at = widget.lastMessageAt;
    if (at == null) return '';
    final now = (widget.now ?? DateTime.now()).toLocal();
    final local = at.toLocal();
    final sameDay = local.year == now.year && local.month == now.month && local.day == now.day;
    return sameDay ? DateFormat('HH:mm').format(local) : DateFormat('d MMM').format(local);
  }

  @override
  Widget build(BuildContext context) {
    final timestamp = _timestamp;
    final preview = widget.preview.isEmpty ? 'No messages yet' : widget.preview;
    final menu = widget.onMenuRequested;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        // Both gestures, because they are the same action on two platforms: a
        // long press is how a phone asks for the menu of a row, a right click is
        // how a desktop does. Neither is bound when there is no menu, so a row
        // without one does not swallow the gesture and look unresponsive.
        onLongPressStart: menu == null
            ? null
            : (LongPressStartDetails details) => menu(details.globalPosition),
        onSecondaryTapUp: menu == null
            ? null
            : (TapUpDetails details) => menu(details.globalPosition),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          constraints: const BoxConstraints(minHeight: ConversationTile.rowHeight),
          padding: const EdgeInsets.only(
            left: AppMetrics.controlInset,
            right: AppMetrics.screenPadding,
            top: 12,
            bottom: 12,
          ),
          // The list sits directly on the canvas, so the resting row is
          // transparent and only a hovered row lifts to a surface.
          color: _hovered ? AppColors.surfacePressed : AppColors.transparent,
          child: Row(
            children: [
              AppAvatar(
                name: widget.displayName,
                size: AppMetrics.avatarList,
                imagePath: widget.avatarPath,
                online: widget.online,
                showOnlineBadge: true,
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (widget.pinned) ...[
                          const Icon(
                            Icons.push_pin_outlined,
                            size: 15,
                            color: AppColors.textSecondary,
                          ),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: Text(
                            widget.displayName,
                            style: AppTypography.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 12),
                        if (timestamp.isNotEmpty)
                          Text(timestamp, style: AppTypography.caption),
                        if (widget.muted) ...[
                          const SizedBox(width: 6),
                          const Icon(
                            Icons.notifications_off_outlined,
                            size: 15,
                            color: AppColors.textSecondary,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            preview,
                            style: AppTypography.secondary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (widget.unreadCount > 0) ...[
                          const SizedBox(width: 12),
                          _UnreadBadge(count: widget.unreadCount),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The accent pill that carries the unread count.
class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      // At least 20 pt so a single digit still reads as a circle.
      constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.accent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        // Three digits would stretch the pill across the row; 99+ is honest and
        // keeps the geometry stable.
        count > 99 ? '99+' : '$count',
        style: AppTypography.caption.copyWith(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: AppColors.textPrimary,
        ),
      ),
    );
  }
}
