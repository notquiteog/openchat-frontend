import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

/// Whether two timestamps fall on the same local calendar day.
bool isSameCalendarDay(DateTime a, DateTime b) {
  final la = a.toLocal();
  final lb = b.toLocal();
  return la.year == lb.year && la.month == lb.month && la.day == lb.day;
}

/// "Today", "Yesterday", a weekday within the last week, then "May 28"
/// (with the year once it differs from the current one).
String daySeparatorLabel(DateTime when) {
  final local = when.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final delta = today.difference(day).inDays;
  if (delta <= 0) return 'Today';
  if (delta == 1) return 'Yesterday';
  if (delta < 7) return DateFormat.EEEE().format(local);
  if (local.year == now.year) return DateFormat.MMMMd().format(local);
  return DateFormat.yMMMMd().format(local);
}

/// Centered chip marking the first message of a calendar day in a message
/// stream (chats and channel feeds).
class DaySeparator extends StatelessWidget {
  final String label;

  const DaySeparator({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
          decoration: BoxDecoration(
            color: scheme.onSurface.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
              color: scheme.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ),
      ),
    );
  }
}
