enum TrustCenterLevel { protected, review, attention }

class TrustCenterSummary {
  final TrustCenterLevel level;
  final String title;
  final String subtitle;
  final int attentionCount;
  final int reviewCount;

  const TrustCenterSummary({
    required this.level,
    required this.title,
    required this.subtitle,
    required this.attentionCount,
    required this.reviewCount,
  });
}

TrustCenterSummary evaluateTrustCenter({
  required bool hasLocalKey,
  required bool accountKeyExpired,
  required bool fingerprintMatchesAccount,
  required bool twoFactorEnabled,
  required bool appLockEnabled,
  required bool biometricAvailable,
  required bool biometricKeyExportEnabled,
  required bool allowGroupAdd,
  required bool notificationShowSender,
  required bool notificationShowPreview,
  required bool pushNotificationsEnabled,
  required int unencryptedConversations,
  required int keyTransparencyWarnings,
  bool hasServerBackup = true,
}) {
  var attention = 0;
  var review = 0;

  if (!hasLocalKey) attention++;
  if (accountKeyExpired) attention++;
  if (!fingerprintMatchesAccount) attention++;
  if (unencryptedConversations > 0) attention++;
  attention += keyTransparencyWarnings;

  if (!twoFactorEnabled) review++;
  if (!appLockEnabled) review++;
  if (biometricAvailable && !biometricKeyExportEnabled) review++;
  if (allowGroupAdd) review++;
  // Revealing identity OR a preview on a push (whose Notification block the OS
  // shows on the lock screen) is the lock-screen-exposure tradeoff. One review
  // point for either — don't double-count when both are on.
  if (pushNotificationsEnabled &&
      (notificationShowSender || notificationShowPreview)) {
    review++;
  }
  // A missing server backup is a hardening gap, not a cryptographic emergency —
  // keep it in the non-nagging 'review' tier, never 'attention'.
  if (!hasServerBackup) review++;

  if (attention > 0) {
    return TrustCenterSummary(
      level: TrustCenterLevel.attention,
      title: 'Needs attention',
      subtitle: '$attention high-priority item${attention == 1 ? '' : 's'}',
      attentionCount: attention,
      reviewCount: review,
    );
  }

  if (review > 0) {
    return TrustCenterSummary(
      level: TrustCenterLevel.review,
      title: 'Review recommended',
      subtitle: '$review optional hardening step${review == 1 ? '' : 's'}',
      attentionCount: attention,
      reviewCount: review,
    );
  }

  return const TrustCenterSummary(
    level: TrustCenterLevel.protected,
    title: 'Protected',
    subtitle: 'Core protections are active',
    attentionCount: 0,
    reviewCount: 0,
  );
}

String trustCenterLevelLabel(TrustCenterLevel level) {
  return switch (level) {
    TrustCenterLevel.protected => 'Protected',
    TrustCenterLevel.review => 'Review',
    TrustCenterLevel.attention => 'Attention',
  };
}
