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
      notificationSensitiveContent: false,
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
      notificationSensitiveContent: false,
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
      notificationSensitiveContent: true,
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
      notificationSensitiveContent: false,
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
        notificationSensitiveContent: false,
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
      notificationSensitiveContent: false,
      pushNotificationsEnabled: false,
      unencryptedConversations: 0,
      keyTransparencyWarnings: 2,
    );

    expect(summary.level, TrustCenterLevel.attention);
    expect(summary.attentionCount, 2);
  });
}
