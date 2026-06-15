const List<int> appLockGraceOptionsSeconds = [0, 30, 60, 300, 900];

String appLockGraceLabel(int seconds) =>
    switch (normalizeAppLockGraceSeconds(seconds)) {
      0 => 'Immediately',
      30 => '30 seconds',
      60 => '1 minute',
      300 => '5 minutes',
      900 => '15 minutes',
      _ => 'Immediately',
    };

String appLockGraceSummaryLabel(int seconds) {
  final normalized = normalizeAppLockGraceSeconds(seconds);
  if (normalized == 0) return 'Immediately';
  return 'After ${appLockGraceLabel(normalized).toLowerCase()}';
}

int normalizeAppLockGraceSeconds(int? seconds) {
  if (seconds == null) return 0;
  var best = appLockGraceOptionsSeconds.first;
  var bestDistance = (seconds - best).abs();
  for (final option in appLockGraceOptionsSeconds.skip(1)) {
    final distance = (seconds - option).abs();
    if (distance < bestDistance) {
      best = option;
      bestDistance = distance;
    }
  }
  return best;
}

bool appLockGraceElapsed({
  required DateTime? backgroundedAt,
  required DateTime now,
  required int graceSeconds,
}) {
  if (graceSeconds <= 0) return true;
  if (backgroundedAt == null) return true;
  return now.difference(backgroundedAt) >= Duration(seconds: graceSeconds);
}
