const int maxDisappearingMessageDays = 3650;
const int maxDisappearingMessageSeconds =
    maxDisappearingMessageDays * Duration.secondsPerDay;

class DisappearingMessageDurationParts {
  final int days;
  final int hours;
  final int minutes;
  final int seconds;

  const DisappearingMessageDurationParts({
    required this.days,
    required this.hours,
    required this.minutes,
    required this.seconds,
  });
}

int normalizeDisappearingMessageSeconds(int? seconds) {
  if (seconds == null || seconds < 0) return 0;
  if (seconds > maxDisappearingMessageSeconds) {
    return maxDisappearingMessageSeconds;
  }
  return seconds;
}

DisappearingMessageDurationParts disappearingMessageDurationParts(
  int? seconds,
) {
  var remaining = normalizeDisappearingMessageSeconds(seconds);
  final days = remaining ~/ Duration.secondsPerDay;
  remaining %= Duration.secondsPerDay;
  final hours = remaining ~/ Duration.secondsPerHour;
  remaining %= Duration.secondsPerHour;
  final minutes = remaining ~/ Duration.secondsPerMinute;
  remaining %= Duration.secondsPerMinute;

  return DisappearingMessageDurationParts(
    days: days,
    hours: hours,
    minutes: minutes,
    seconds: remaining,
  );
}

int disappearingMessageSecondsFromParts({
  required int days,
  required int hours,
  required int minutes,
  required int seconds,
}) {
  final total =
      (days * Duration.secondsPerDay) +
      (hours * Duration.secondsPerHour) +
      (minutes * Duration.secondsPerMinute) +
      seconds;
  return normalizeDisappearingMessageSeconds(total);
}

String disappearingMessageDurationLabel(int seconds) {
  final normalized = normalizeDisappearingMessageSeconds(seconds);
  if (normalized == 0) return 'Off';

  final parts = disappearingMessageDurationParts(normalized);
  final labels = <String>[
    if (parts.days > 0) _unitLabel(parts.days, 'day'),
    if (parts.hours > 0) _unitLabel(parts.hours, 'hour'),
    if (parts.minutes > 0) _unitLabel(parts.minutes, 'minute'),
    if (parts.seconds > 0) _unitLabel(parts.seconds, 'second'),
  ];

  return labels.join(' ');
}

String disappearingMessageSummaryLabel(int seconds) {
  final normalized = normalizeDisappearingMessageSeconds(seconds);
  if (normalized == 0) return 'Off';
  return 'After ${disappearingMessageDurationLabel(normalized)}';
}

String _unitLabel(int value, String unit) {
  return value == 1 ? '1 $unit' : '$value ${unit}s';
}
