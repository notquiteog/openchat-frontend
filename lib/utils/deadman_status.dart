const deadmanWarningLeadTime = Duration(hours: 24);

class DeadmanStatus {
  final bool enabled;
  final DateTime? wipeAt;
  final int daysRemaining;
  final bool expired;

  const DeadmanStatus({
    required this.enabled,
    required this.wipeAt,
    required this.daysRemaining,
    required this.expired,
  });
}

DeadmanStatus computeDeadmanStatus({
  required int days,
  required DateTime? lastRealUnlockAt,
  required DateTime now,
}) {
  if (days <= 0) {
    return const DeadmanStatus(
      enabled: false,
      wipeAt: null,
      daysRemaining: 0,
      expired: false,
    );
  }
  final utcNow = now.toUtc();
  final anchor = lastRealUnlockAt?.toUtc() ?? utcNow;
  final wipeAt = anchor.add(Duration(days: days));
  final remaining = wipeAt.difference(utcNow);
  return DeadmanStatus(
    enabled: true,
    wipeAt: wipeAt,
    daysRemaining: remaining.isNegative ? 0 : remaining.inDays,
    expired: !utcNow.isBefore(wipeAt),
  );
}

String deadmanCountdownLabel(DeadmanStatus status) {
  if (!status.enabled) return 'Off';
  if (status.daysRemaining <= 0) return 'Today';
  if (status.daysRemaining == 1) return 'In 1 day';
  return 'In ${status.daysRemaining} days';
}

DateTime? deadmanWarningFireAt(DeadmanStatus status, {DateTime? now}) {
  final wipeAt = status.wipeAt;
  if (!status.enabled || status.expired || wipeAt == null) return null;
  final fireAt = wipeAt.subtract(deadmanWarningLeadTime);
  return fireAt.isAfter((now ?? DateTime.now()).toUtc()) ? fireAt : null;
}
