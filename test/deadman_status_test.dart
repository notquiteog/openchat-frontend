import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/utils/deadman_status.dart';

void main() {
  test('disabled switch has no wipe or warning time', () {
    final now = DateTime.utc(2026, 6, 15, 12);
    final status = computeDeadmanStatus(
      days: 0,
      lastRealUnlockAt: now.subtract(const Duration(days: 3)),
      now: now,
    );

    expect(status.enabled, isFalse);
    expect(status.wipeAt, isNull);
    expect(status.daysRemaining, 0);
    expect(status.expired, isFalse);
    expect(deadmanCountdownLabel(status), 'Off');
    expect(deadmanWarningFireAt(status, now: now), isNull);
  });

  test('missing last unlock starts a fresh full window from now', () {
    final now = DateTime.utc(2026, 6, 15, 12);
    final status = computeDeadmanStatus(
      days: 7,
      lastRealUnlockAt: null,
      now: now,
    );

    expect(status.enabled, isTrue);
    expect(status.wipeAt, DateTime.utc(2026, 6, 22, 12));
    expect(status.daysRemaining, 7);
    expect(status.expired, isFalse);
    expect(deadmanCountdownLabel(status), 'In 7 days');
  });

  test('counts down from the last real unlock in UTC', () {
    final now = DateTime.utc(2026, 6, 15, 12);
    final status = computeDeadmanStatus(
      days: 7,
      lastRealUnlockAt: DateTime.utc(2026, 6, 12, 12),
      now: now,
    );

    expect(status.wipeAt, DateTime.utc(2026, 6, 19, 12));
    expect(status.daysRemaining, 4);
    expect(deadmanCountdownLabel(status), 'In 4 days');
    expect(
      deadmanWarningFireAt(status, now: now),
      DateTime.utc(2026, 6, 18, 12),
    );
  });

  test('expired windows clamp to today and schedule no warning', () {
    final now = DateTime.utc(2026, 6, 15, 12);
    final status = computeDeadmanStatus(
      days: 7,
      lastRealUnlockAt: DateTime.utc(2026, 6, 1, 12),
      now: now,
    );

    expect(status.expired, isTrue);
    expect(status.daysRemaining, 0);
    expect(deadmanCountdownLabel(status), 'Today');
    expect(deadmanWarningFireAt(status, now: now), isNull);
  });

  test('labels one-day and same-day windows', () {
    final oneDay = computeDeadmanStatus(
      days: 7,
      lastRealUnlockAt: DateTime.utc(2026, 6, 9, 12),
      now: DateTime.utc(2026, 6, 15, 12),
    );
    final sameDay = computeDeadmanStatus(
      days: 7,
      lastRealUnlockAt: DateTime.utc(2026, 6, 8, 14),
      now: DateTime.utc(2026, 6, 15, 12),
    );

    expect(deadmanCountdownLabel(oneDay), 'In 1 day');
    expect(deadmanCountdownLabel(sameDay), 'Today');
  });
}
