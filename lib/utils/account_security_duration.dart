const int accountInactivityDeletionMaxDays = 3650;

int normalizeInactiveDeletionDays(int? days) {
  if (days == null || days < 0) return 0;
  if (days > accountInactivityDeletionMaxDays) {
    return accountInactivityDeletionMaxDays;
  }
  return days;
}

String inactiveDeletionDurationLabel(int days) {
  final normalized = normalizeInactiveDeletionDays(days);
  if (normalized == 0) return 'Off';
  return normalized == 1 ? '1 day' : '$normalized days';
}

String inactiveDeletionSummaryLabel(int days) {
  final normalized = normalizeInactiveDeletionDays(days);
  if (normalized == 0) return 'Off';
  return 'After ${inactiveDeletionDurationLabel(normalized)}';
}
