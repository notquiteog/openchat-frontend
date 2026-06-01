enum AppAccessGateDecision {
  showApp,
  showAppLock;

  static AppAccessGateDecision resolve({
    required bool authenticated,
    required bool appLockEnabled,
    required bool appLocked,
    required bool biometricKeyExportEnabled,
  }) {
    if (authenticated && appLockEnabled && appLocked) {
      return AppAccessGateDecision.showAppLock;
    }
    return AppAccessGateDecision.showApp;
  }
}
