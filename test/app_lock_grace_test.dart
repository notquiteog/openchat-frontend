import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/utils/app_lock_grace.dart';

void main() {
  test('normalizes to supported grace options', () {
    expect(normalizeAppLockGraceSeconds(null), 0);
    expect(normalizeAppLockGraceSeconds(-1), 0);
    expect(normalizeAppLockGraceSeconds(20), 30);
    expect(normalizeAppLockGraceSeconds(45), 30);
    expect(normalizeAppLockGraceSeconds(80), 60);
    expect(normalizeAppLockGraceSeconds(700), 900);
  });

  test('labels grace options', () {
    expect(appLockGraceLabel(0), 'Immediately');
    expect(appLockGraceLabel(30), '30 seconds');
    expect(appLockGraceLabel(60), '1 minute');
    expect(appLockGraceLabel(300), '5 minutes');
    expect(appLockGraceLabel(900), '15 minutes');
    expect(appLockGraceSummaryLabel(0), 'Immediately');
    expect(appLockGraceSummaryLabel(60), 'After 1 minute');
  });

  test('detects elapsed grace window', () {
    final now = DateTime.utc(2026, 6, 15, 12);
    expect(
      appLockGraceElapsed(backgroundedAt: now, now: now, graceSeconds: 0),
      isTrue,
    );
    expect(
      appLockGraceElapsed(backgroundedAt: null, now: now, graceSeconds: 60),
      isTrue,
    );
    expect(
      appLockGraceElapsed(
        backgroundedAt: now.subtract(const Duration(seconds: 20)),
        now: now,
        graceSeconds: 60,
      ),
      isFalse,
    );
    expect(
      appLockGraceElapsed(
        backgroundedAt: now.subtract(const Duration(seconds: 60)),
        now: now,
        graceSeconds: 60,
      ),
      isTrue,
    );
  });
}
