const int notificationPauseIndefiniteUntilMs = 8640000000000000;

bool notificationPauseIsIndefiniteMs(int? milliseconds) =>
    milliseconds == notificationPauseIndefiniteUntilMs;

bool notificationPauseIsIndefiniteDate(DateTime? date) =>
    date?.toUtc().millisecondsSinceEpoch == notificationPauseIndefiniteUntilMs;

DateTime? notificationPauseDateFromMs(int? milliseconds) {
  if (milliseconds == null) return null;
  if (notificationPauseIsIndefiniteMs(milliseconds)) {
    return DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
  }
  return DateTime.fromMillisecondsSinceEpoch(
    milliseconds,
    isUtc: true,
  ).toLocal();
}

int? notificationPauseMsFromDate(DateTime? date) =>
    date?.toUtc().millisecondsSinceEpoch;

bool notificationPauseUntilIsActiveAt(DateTime now, int? pausedUntilMs) {
  if (pausedUntilMs == null) return false;
  if (notificationPauseIsIndefiniteMs(pausedUntilMs)) return true;
  final pausedUntil = DateTime.fromMillisecondsSinceEpoch(
    pausedUntilMs,
    isUtc: true,
  ).toLocal();
  return pausedUntil.isAfter(now);
}

bool globalQuietHoursAreActiveAt(
  DateTime now, {
  int? quietStartMinute,
  int? quietEndMinute,
}) {
  if (quietStartMinute == null || quietEndMinute == null) return false;
  final start = quietStartMinute.clamp(0, 1439).toInt();
  final end = quietEndMinute.clamp(0, 1439).toInt();
  if (start == end) return false;
  final minute = now.hour * 60 + now.minute;
  if (start < end) return minute >= start && minute < end;
  return minute >= start || minute < end;
}

bool isGloballyPausedAt(
  DateTime now, {
  int? pausedUntilMs,
  int? quietStartMinute,
  int? quietEndMinute,
}) {
  return notificationPauseUntilIsActiveAt(now, pausedUntilMs) ||
      globalQuietHoursAreActiveAt(
        now,
        quietStartMinute: quietStartMinute,
        quietEndMinute: quietEndMinute,
      );
}
