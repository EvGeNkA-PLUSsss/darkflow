import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../design/design.dart';

/// The break drawn between two calendar days of a conversation.
///
/// The chat mockup puts the day label centred on a hairline rather than inside a
/// floating pill, so the label is flanked by two flexible 1 px rules. Keeping
/// the rules flexible means the separator still reads correctly when the chat
/// pane is wider than the 390 pt design canvas.
class DaySeparator extends StatelessWidget {
  const DaySeparator({required this.date, this.now, super.key});

  /// Any moment inside the day this separator introduces.
  final DateTime date;

  /// Injectable "today" so [labelFor] stays deterministic under test. When it
  /// is null the real clock is used, which is what the app wants.
  final DateTime? now;

  /// The label drawn between the two rules: "Today", "Yesterday", or a full
  /// date such as "3 February 2026".
  static String labelFor(DateTime date, {DateTime? now}) {
    final difference = _dayOf(now ?? DateTime.now()).difference(_dayOf(date)).inDays;
    // A message can carry a timestamp from the near future (a peer's clock can
    // run ahead of ours); treating that as "Today" is less confusing than
    // printing a date the user has not reached yet.
    if (difference <= 0) return 'Today';
    if (difference == 1) return 'Yesterday';
    return DateFormat('d MMMM yyyy').format(date);
  }

  /// Truncates to midnight so the comparison is per calendar day rather than
  /// per elapsed 24 hours.
  static DateTime _dayOf(DateTime value) => DateTime(value.year, value.month, value.day);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          const Expanded(child: AppDivider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(labelFor(date, now: now), style: AppTypography.caption),
          ),
          const Expanded(child: AppDivider()),
        ],
      ),
    );
  }
}
