import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/utils/disappearing_message_duration.dart';

void main() {
  test('splits disappearing message seconds into precise wheel parts', () {
    final parts = disappearingMessageDurationParts(90061);

    expect(parts.days, 1);
    expect(parts.hours, 1);
    expect(parts.minutes, 1);
    expect(parts.seconds, 1);
  });

  test('combines precise wheel parts into seconds', () {
    expect(
      disappearingMessageSecondsFromParts(
        days: 1,
        hours: 2,
        minutes: 3,
        seconds: 4,
      ),
      93784,
    );
  });

  test('formats disappearing message durations without preset names', () {
    expect(disappearingMessageDurationLabel(0), 'Off');
    expect(disappearingMessageDurationLabel(1), '1 second');
    expect(disappearingMessageDurationLabel(3661), '1 hour 1 minute 1 second');
    expect(
      disappearingMessageSummaryLabel(90061),
      'After 1 day 1 hour 1 minute 1 second',
    );
  });

  test('normalizes disappearing message seconds to the picker range', () {
    expect(normalizeDisappearingMessageSeconds(null), 0);
    expect(normalizeDisappearingMessageSeconds(-1), 0);
    expect(
      normalizeDisappearingMessageSeconds(maxDisappearingMessageSeconds + 1),
      maxDisappearingMessageSeconds,
    );
  });
}
