import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/utils/trust_center_summary.dart';

void main() {
  test('reports protected when core and privacy protections are enabled', () {
    final summary = evaluateTrustCenter(
      hasLocalKey: true,
      accountKeyExpired: false,
      fingerprintMatchesAccount: true,
      twoFactorEnabled: true,
      appLockEnabled: true,
      biometricAvailable: true,
      biometricKeyExportEnabled: true,
      allowGroupAdd: false,
      notificationShowSender: false,
      notificationShowPreview: false,
      pushNotificationsEnabled: true,
      unencryptedConversations: 0,
      keyTransparencyWarnings: 0,
    );

    expect(summary.level, TrustCenterLevel.protected);
    expect(summary.attentionCount, 0);
    expect(summary.reviewCount, 0);
  });

  test('prioritizes local key and encryption problems as attention items', () {
    final summary = evaluateTrustCenter(
      hasLocalKey: false,
      accountKeyExpired: true,
      fingerprintMatchesAccount: false,
      twoFactorEnabled: true,
      appLockEnabled: true,
      biometricAvailable: false,
      biometricKeyExportEnabled: false,
      allowGroupAdd: false,
      notificationShowSender: false,
      notificationShowPreview: false,
      pushNotificationsEnabled: false,
      unencryptedConversations: 2,
      keyTransparencyWarnings: 0,
    );

    expect(summary.level, TrustCenterLevel.attention);
    expect(summary.attentionCount, 4);
  });

  test('classifies optional hardening gaps as review recommendations', () {
    final summary = evaluateTrustCenter(
      hasLocalKey: true,
      accountKeyExpired: false,
      fingerprintMatchesAccount: true,
      twoFactorEnabled: false,
      appLockEnabled: false,
      biometricAvailable: true,
      biometricKeyExportEnabled: false,
      allowGroupAdd: true,
      notificationShowSender: true,
      notificationShowPreview: true,
      pushNotificationsEnabled: true,
      unencryptedConversations: 0,
      keyTransparencyWarnings: 0,
    );

    expect(summary.level, TrustCenterLevel.review);
    expect(summary.attentionCount, 0);
    expect(summary.reviewCount, 5);
  });

  test('a missing server backup is a review item, never attention', () {
    final summary = evaluateTrustCenter(
      hasLocalKey: true,
      accountKeyExpired: false,
      fingerprintMatchesAccount: true,
      twoFactorEnabled: true,
      appLockEnabled: true,
      biometricAvailable: true,
      biometricKeyExportEnabled: true,
      allowGroupAdd: false,
      notificationShowSender: false,
      notificationShowPreview: false,
      pushNotificationsEnabled: true,
      unencryptedConversations: 0,
      keyTransparencyWarnings: 0,
      hasServerBackup: false,
    );

    // Otherwise fully protected, so the missing backup is the sole review item.
    expect(summary.level, TrustCenterLevel.review);
    expect(summary.attentionCount, 0);
    expect(summary.reviewCount, 1);
  });

  test(
    'hasServerBackup defaults true so existing protected config is green',
    () {
      final summary = evaluateTrustCenter(
        hasLocalKey: true,
        accountKeyExpired: false,
        fingerprintMatchesAccount: true,
        twoFactorEnabled: true,
        appLockEnabled: true,
        biometricAvailable: true,
        biometricKeyExportEnabled: true,
        allowGroupAdd: false,
        notificationShowSender: false,
        notificationShowPreview: false,
        pushNotificationsEnabled: true,
        unencryptedConversations: 0,
        keyTransparencyWarnings: 0,
      );
      expect(summary.level, TrustCenterLevel.protected);
      expect(summary.reviewCount, 0);
    },
  );

  test('treats key transparency warnings as attention items', () {
    final summary = evaluateTrustCenter(
      hasLocalKey: true,
      accountKeyExpired: false,
      fingerprintMatchesAccount: true,
      twoFactorEnabled: true,
      appLockEnabled: true,
      biometricAvailable: false,
      biometricKeyExportEnabled: false,
      allowGroupAdd: false,
      notificationShowSender: false,
      notificationShowPreview: false,
      pushNotificationsEnabled: false,
      unencryptedConversations: 0,
      keyTransparencyWarnings: 2,
    );

    expect(summary.level, TrustCenterLevel.attention);
    expect(summary.attentionCount, 2);
  });

  test('preview-only on push counts as one review item (OR, not double)', () {
    TrustCenterSummary summarize({
      required bool showSender,
      required bool showPreview,
      required bool push,
    }) => evaluateTrustCenter(
      hasLocalKey: true,
      accountKeyExpired: false,
      fingerprintMatchesAccount: true,
      twoFactorEnabled: true,
      appLockEnabled: true,
      biometricAvailable: true,
      biometricKeyExportEnabled: true,
      allowGroupAdd: false,
      notificationShowSender: showSender,
      notificationShowPreview: showPreview,
      pushNotificationsEnabled: push,
      unencryptedConversations: 0,
      keyTransparencyWarnings: 0,
    );

    // Either reveal, with push on, is the single lock-screen-exposure review.
    expect(
      summarize(showSender: false, showPreview: true, push: true).reviewCount,
      1,
    );
    expect(
      summarize(showSender: true, showPreview: false, push: true).reviewCount,
      1,
    );
    // Both on is still one point (no double-count).
    expect(
      summarize(showSender: true, showPreview: true, push: true).reviewCount,
      1,
    );
    // No push → nothing on the lock screen → no review item.
    expect(
      summarize(showSender: true, showPreview: true, push: false).reviewCount,
      0,
    );
  });
}
