import 'package:flutter/material.dart';

import '../../../data/models/message.dart';
import '../../../design/design.dart';

/// A single text bubble in the message list.
///
/// Bubbles are always left-aligned in DarkFlow's chat mockup — incoming and
/// outgoing alike — because the sender is identified by the avatar at the left
/// of the row, not by the bubble's side. The bubble therefore only owns its
/// fill, its text, its optional reply quote and its delivery glyph; the row
/// (avatar, position, spacing) lives in `chat_screen.dart`.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    required this.text,
    required this.outgoing,
    this.status,
    this.note,
    this.quotedText,
    this.onTap,
    this.onDoubleTap,
    this.onLongPress,
    this.onRetry,
    this.highlight = '',
    this.maxWidthFactor = AppMetrics.bubbleMaxWidthFactor,
    super.key,
  });

  final String text;

  /// True when the account wrote this message: accent fill, white text.
  final bool outgoing;

  /// Only outgoing messages carry a delivery state; incoming ones pass null.
  final MessageStatus? status;

  /// Why an outgoing message has not gone anywhere, rendered under the text.
  ///
  /// A clock glyph says "not delivered" and nothing more, which is how a message
  /// with no route at all came to look identical to one on its way. The mesh
  /// knows the difference and now reports it; this is where the user finds out.
  final String? note;

  /// The body of the message this one replies to, already resolved by the
  /// screen. Null means "not a reply" or "the quoted message is not loaded",
  /// and the quote block is then omitted rather than faked.
  final String? quotedText;

  /// A substring to mark inside [text], case-insensitively. Empty means no
  /// search is running.
  ///
  /// The conversation's own search filters the list down to the messages that
  /// contain the term, and marking the term is what makes the reason a match is
  /// visible — a filtered list whose entries look identical to their unfiltered
  /// selves is hard to trust. This widget is the only place that owns the body
  /// text, so it is the only place that can do it.
  final String highlight;

  final VoidCallback? onTap;

  /// Double-tap starts a reply.
  final VoidCallback? onDoubleTap;

  /// Long-press opens the message menu.
  final VoidCallback? onLongPress;

  /// Called instead of [onTap] when [status] is [MessageStatus.failed].
  final VoidCallback? onRetry;

  /// Share of the row's free width a bubble may take. The default is the
  /// measured 78%; a caller that already constrained the width passes 1.
  final double maxWidthFactor;

  /// Whether this bubble can be retried, which is the only tappable state.
  bool get _failed => status == MessageStatus.failed;

  /// The delivery glyph, or null when there is nothing to report.
  Widget? _statusGlyph() {
    final value = status;
    if (!outgoing || value == null) return null;
    switch (value) {
      case MessageStatus.queued:
        return _glyph(Icons.schedule, 0.75);
      case MessageStatus.sending:
        return _glyph(Icons.arrow_upward, 0.75);
      case MessageStatus.sent:
        return _glyph(Icons.check, 0.85);
      case MessageStatus.delivered:
        return _glyph(Icons.done_all, 0.95);
      case MessageStatus.read:
        // The mockup draws "read" with a lighter tick than "delivered", which is
        // the reverse of the usual convention; the mockup wins.
        return _glyph(Icons.done_all, 0.55);
      case MessageStatus.failed:
        // The one glyph that leaves the accent/white palette, because failure
        // has to be recognisable at a glance and invites a tap.
        return const Icon(Icons.error_outline, size: 14, color: AppColors.danger);
    }
  }

  Widget _glyph(IconData icon, double opacity) => Icon(
        icon,
        size: 14,
        color: AppColors.textOnAccent.withValues(alpha: opacity),
      );

  /// The body text, with every occurrence of [highlight] marked.
  ///
  /// The mark is a background wash rather than a colour change, because the
  /// bubble's foreground is either white on the accent fill or the primary text
  /// colour on a surface, and a colour that stayed legible on both would be a
  /// third tone fighting the two the design already has.
  List<TextSpan> _spans(String body, Color foreground) {
    final needle = highlight.trim();
    if (needle.isEmpty) return <TextSpan>[TextSpan(text: body)];

    final haystack = body.toLowerCase();
    final lowered = needle.toLowerCase();
    final spans = <TextSpan>[];
    var cursor = 0;
    while (true) {
      final at = haystack.indexOf(lowered, cursor);
      if (at < 0) break;
      if (at > cursor) spans.add(TextSpan(text: body.substring(cursor, at)));
      spans.add(
        TextSpan(
          text: body.substring(at, at + needle.length),
          style: TextStyle(
            backgroundColor: foreground.withValues(alpha: 0.28),
            fontWeight: FontWeight.w600,
          ),
        ),
      );
      cursor = at + needle.length;
    }
    if (cursor < body.length) spans.add(TextSpan(text: body.substring(cursor)));
    // An empty list would raise the "no text" assertion in a `TextSpan`.
    return spans.isEmpty ? <TextSpan>[TextSpan(text: body)] : spans;
  }

  @override
  Widget build(BuildContext context) {
    final glyph = _statusGlyph();
    final foreground = outgoing ? AppColors.textOnAccent : AppColors.textPrimary;
    final quote = quotedText;
    // On an accent bubble an accent reply bar would be invisible, so outgoing
    // replies use the bubble's own foreground colour as the bar.
    final quoteBar = outgoing ? AppColors.textOnAccent : AppColors.accent;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final available = constraints.maxWidth;
        final maxWidth = available.isFinite ? available * maxWidthFactor : available;

        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _failed ? onRetry : onTap,
            onDoubleTap: onDoubleTap,
            onLongPress: onLongPress,
            child: Container(
              decoration: BoxDecoration(
                color: outgoing ? AppColors.accent : AppColors.surface,
                borderRadius: BorderRadius.circular(AppMetrics.bubbleRadius),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (quote != null)
                    Container(
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(color: quoteBar, width: 2),
                        ),
                      ),
                      padding: const EdgeInsets.only(left: 8, bottom: 6),
                      child: Text(
                        quote,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.caption.copyWith(
                          fontSize: 13,
                          color: foreground.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                  if (text.isNotEmpty)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Flexible(
                          child: Text.rich(
                            TextSpan(children: _spans(text, foreground)),
                            style: AppTypography.body.copyWith(color: foreground),
                          ),
                        ),
                        if (glyph != null) ...[const SizedBox(width: 8), glyph],
                      ],
                    )
                  else if (glyph != null)
                    // A bubble with no text (an attachment whose caption is
                    // empty) still has to show where the message stands.
                    Align(alignment: Alignment.centerRight, child: glyph),
                  if (note != null) ...<Widget>[
                    const SizedBox(height: 6),
                    Text(
                      note!,
                      style: AppTypography.caption.copyWith(
                        fontSize: 12,
                        color: foreground.withValues(alpha: 0.8),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
