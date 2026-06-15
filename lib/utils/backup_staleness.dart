// Pure, dependency-free classification of how fresh the server-stored
// encrypted backup is. Kept free of Flutter/timeago imports (mirroring
// utils/trust_center_summary.dart) so it is trivially unit-testable.

enum BackupFreshness { none, fresh, aging, stale }

class BackupStatus {
  final BackupFreshness freshness;

  /// Whole days since the last backup, or null when there is no backup.
  final int? daysSinceBackup;

  const BackupStatus({required this.freshness, required this.daysSinceBackup});
}

/// Classifies backup freshness from the last-backup timestamp:
/// - null timestamp        → none
/// - ≤ [agingAfterDays]    → fresh
/// - ≤ [staleAfterDays]    → aging
/// - > [staleAfterDays]    → stale
///
/// A timestamp in the future (clock skew) is treated as "today" (0 days).
BackupStatus evaluateBackupFreshness({
  required DateTime? lastBackupAt,
  required DateTime now,
  int agingAfterDays = 14,
  int staleAfterDays = 60,
}) {
  if (lastBackupAt == null) {
    return const BackupStatus(
      freshness: BackupFreshness.none,
      daysSinceBackup: null,
    );
  }
  final rawDays = now.difference(lastBackupAt).inDays;
  final days = rawDays < 0 ? 0 : rawDays;
  final BackupFreshness freshness;
  if (days <= agingAfterDays) {
    freshness = BackupFreshness.fresh;
  } else if (days <= staleAfterDays) {
    freshness = BackupFreshness.aging;
  } else {
    freshness = BackupFreshness.stale;
  }
  return BackupStatus(freshness: freshness, daysSinceBackup: days);
}

/// A short human label for a [BackupStatus], e.g. 'No server backup yet',
/// 'Backed up today', 'Last backup 1 day ago', 'Last backup 12 days ago'.
String backupStatusLabel(BackupStatus status) {
  if (status.freshness == BackupFreshness.none) return 'No server backup yet';
  final days = status.daysSinceBackup ?? 0;
  if (days == 0) return 'Backed up today';
  if (days == 1) return 'Last backup 1 day ago';
  return 'Last backup $days days ago';
}
