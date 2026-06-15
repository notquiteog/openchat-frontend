import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/utils/backup_staleness.dart';

/// #18 — pure classification of server-backup freshness. Boundaries:
/// fresh ≤ 14 days, aging ≤ 60 days, stale > 60 days; null → none.
void main() {
  final now = DateTime.utc(2026, 6, 15, 12);

  test('null timestamp is none with no day count', () {
    final s = evaluateBackupFreshness(lastBackupAt: null, now: now);
    expect(s.freshness, BackupFreshness.none);
    expect(s.daysSinceBackup, isNull);
  });

  test('now is fresh, 0 days', () {
    final s = evaluateBackupFreshness(lastBackupAt: now, now: now);
    expect(s.freshness, BackupFreshness.fresh);
    expect(s.daysSinceBackup, 0);
  });

  test('exactly 14 days is still fresh; 15 days tips to aging', () {
    final at14 = evaluateBackupFreshness(
      lastBackupAt: now.subtract(const Duration(days: 14)),
      now: now,
    );
    expect(at14.freshness, BackupFreshness.fresh);
    expect(at14.daysSinceBackup, 14);

    final at15 = evaluateBackupFreshness(
      lastBackupAt: now.subtract(const Duration(days: 15)),
      now: now,
    );
    expect(at15.freshness, BackupFreshness.aging);
    expect(at15.daysSinceBackup, 15);
  });

  test('exactly 60 days is aging; 61 days tips to stale', () {
    final at60 = evaluateBackupFreshness(
      lastBackupAt: now.subtract(const Duration(days: 60)),
      now: now,
    );
    expect(at60.freshness, BackupFreshness.aging);

    final at61 = evaluateBackupFreshness(
      lastBackupAt: now.subtract(const Duration(days: 61)),
      now: now,
    );
    expect(at61.freshness, BackupFreshness.stale);
    expect(at61.daysSinceBackup, 61);
  });

  test('a future timestamp (clock skew) clamps to 0 days / fresh', () {
    final s = evaluateBackupFreshness(
      lastBackupAt: now.add(const Duration(days: 3)),
      now: now,
    );
    expect(s.freshness, BackupFreshness.fresh);
    expect(s.daysSinceBackup, 0);
  });

  group('labels', () {
    test('none', () {
      expect(
        backupStatusLabel(
          evaluateBackupFreshness(lastBackupAt: null, now: now),
        ),
        'No server backup yet',
      );
    });

    test('today', () {
      expect(
        backupStatusLabel(evaluateBackupFreshness(lastBackupAt: now, now: now)),
        'Backed up today',
      );
    });

    test('singular day', () {
      expect(
        backupStatusLabel(
          evaluateBackupFreshness(
            lastBackupAt: now.subtract(const Duration(days: 1)),
            now: now,
          ),
        ),
        'Last backup 1 day ago',
      );
    });

    test('plural days', () {
      expect(
        backupStatusLabel(
          evaluateBackupFreshness(
            lastBackupAt: now.subtract(const Duration(days: 12)),
            now: now,
          ),
        ),
        'Last backup 12 days ago',
      );
    });
  });
}
