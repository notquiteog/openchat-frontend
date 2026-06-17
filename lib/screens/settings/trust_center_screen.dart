import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:timeago/timeago.dart' as timeago;

import '../../crypto/pgp_service.dart';
import '../../models/conversation.dart';
import '../../models/key_transparency_event.dart';
import '../../models/key_trust_pin.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/key_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/api_service.dart';
import '../../services/app_lock_state.dart';
import '../../services/encrypted_backup_service.dart';
import '../../services/kt_audit_service.dart';
import '../../services/local_private_state_service.dart';
import '../../services/mesh/nearby_mesh_service.dart';
import '../../services/mls_service.dart';
import '../../services/notification_service.dart';
import '../../services/passphrase_strength.dart';
import '../../services/secure_storage_service.dart';
import '../../services/security_service.dart';
import '../../services/social_recovery_service.dart';
import '../../utils/account_security_duration.dart';
import '../../utils/app_lock_grace.dart';
import '../../utils/backup_staleness.dart';
import '../../utils/deadman_status.dart';
import '../../utils/device_label.dart';
import '../../utils/identity_qr.dart';
import '../../utils/trust_center_summary.dart';
import '../../widgets/glass.dart';
import '../nearby/nearby_screen.dart';
import 'device_pairing_screen.dart';
import 'blocked_users_screen.dart';
import 'identity_qr_scanner_screen.dart';
import 'smp_verify_screen.dart';
import 'pgp_keys_screen.dart';
import 'proxy_settings_screen.dart';
import 'social_recovery_screen.dart';

String formatKtAlarmEvidenceForExport(Map<String, dynamic> alarm) {
  Object? evidence = alarm['evidence'];
  if (evidence is String) {
    try {
      evidence = jsonDecode(evidence);
    } catch (_) {
      // Keep the raw string if older evidence was not JSON.
    }
  }
  return const JsonEncoder.withIndent('  ').convert({
    'openchat_kt_alarm': 1,
    'reason': alarm['reason'],
    'at': alarm['at'],
    'evidence': evidence,
  });
}

class TrustCenterScreen extends StatefulWidget {
  const TrustCenterScreen({super.key});

  @override
  State<TrustCenterScreen> createState() => _TrustCenterScreenState();
}

class _TrustCenterScreenState extends State<TrustCenterScreen> {
  final _auth = LocalAuthentication();
  bool _biometricAvailable = false;
  bool _biometricEnabled = false;
  bool _appLockEnabled = false;
  bool _forceTurn = false;
  bool _screenSecurity = false;
  bool _loading = true;
  Map<String, dynamic> _security = const {};
  List<Map<String, dynamic>> _sessions = const [];
  String? _currentSessionId;
  Map<String, KeyTrustPin> _keyPins = const {};
  List<KeyTransparencyEvent> _keyEvents = const [];
  // True only when the stored MLS signer signature actually verifies against the
  // CURRENT PGP public key. Non-emptiness is not enough: after a key rotation a
  // signature made by the old key is non-empty but stale, and the server
  // rejects it — so the row must reflect real verification, not mere presence.
  bool _mlsSignerVerified = false;
  Map<String, dynamic>? _ktLogAlarm;
  KtInclusionStatus _ktInclusion = KtInclusionStatus.unknown;
  // Server-backup freshness, fetched best-effort during _load. _backupLoaded is
  // true only once we have a definitive answer (incl. "none"); a fetch failure
  // leaves it false so a transient error never nags the trust summary.
  DateTime? _lastBackupAt;
  bool _backupLoaded = false;
  bool _appPinConfigured = false;
  bool _duressPinConfigured = false;
  String _duressAction = 'decoy';
  int _appLockGraceSeconds = 0;
  int _deadmanDays = 0;
  DateTime? _lastRealUnlockAt;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(context.read<ChatProvider>().loadConversations());
      unawaited(_load());
    });
  }

  Future<void> _load() async {
    final storage = context.read<SecureStorageService>();
    final api = context.read<ApiService>();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final user = context.read<AuthProvider>().currentUser;
      final biometricAvailable = await _biometricsAvailable();
      final results = await Future.wait<Object>([
        storage.getBiometricEnabled(),
        storage.getAppLockEnabled(),
        api.getSecuritySettings(),
        api.listSessions(),
      ]);
      final keyPins = await storage.getKeyTrustPins();
      final forceTurn = await storage.getForceTurn();
      final screenSecurity = await storage.getScreenSecurity();
      final currentSessionId = await storage.getSessionId();
      final appPinConfigured = await storage.hasAppLockPin();
      final duressPinConfigured = await storage.hasDuressPin();
      final duressAction = await storage.getDuressAction();
      final appLockGraceSeconds = await storage.getAppLockGraceSeconds();
      final deadmanDays = await storage.getDeadmanDays();
      final lastRealUnlockAt = await storage.getLastRealUnlockAt();
      var ktLogAlarm = await storage.getKtLogAlarm();
      // Best-effort (mirrors the keyEvents block below): a backup-metadata
      // failure must never break the whole Trust Center load.
      DateTime? lastBackupAt;
      var backupLoaded = false;
      try {
        lastBackupAt = await EncryptedBackupService().latestBackupTimestamp(
          api: api,
        );
        backupLoaded = true;
      } catch (_) {
        backupLoaded = false;
      }
      var keyEvents = <KeyTransparencyEvent>[];
      var ktInclusion = KtInclusionStatus.unknown;
      MlsSignerStorage? mlsSigner;
      var mlsSignerVerified = false;
      if (user != null) {
        try {
          keyEvents = await api.getKeyTransparencyEvents(user.id);
        } catch (_) {
          keyEvents = const [];
        }
        try {
          ktInclusion = await KtAuditService(
            storage: storage,
          ).auditOwnInclusion(api, keyEvents);
          ktLogAlarm = await storage.getKtLogAlarm();
        } catch (_) {
          ktInclusion = KtInclusionStatus.unknown;
        }
        mlsSigner = await storage.getMlsSigner(user.id);
        // Verify the stored signer signature against the current PGP key so a
        // signature left over from a previous key (which the server rejects)
        // shows as 'Prepare', not a false-green 'Signed'.
        final currentPublicKey = await storage.getPublicKey();
        if (mlsSigner != null &&
            mlsSigner.signature.trim().isNotEmpty &&
            mlsSigner.publicKey.trim().isNotEmpty &&
            currentPublicKey != null &&
            currentPublicKey.isNotEmpty) {
          mlsSignerVerified = await PgpService.verify(
            data: PgpService.deviceKeySignatureData(
              userId: user.id,
              deviceKey: mlsSigner.publicKey,
            ),
            signatureArmor: mlsSigner.signature,
            signerPublicKeyArmored: currentPublicKey,
          );
        }
      }
      if (!mounted) return;
      setState(() {
        _biometricAvailable = biometricAvailable;
        _biometricEnabled = results[0] as bool;
        _appLockEnabled = results[1] as bool;
        _forceTurn = forceTurn;
        _screenSecurity = screenSecurity;
        _security = results[2] as Map<String, dynamic>;
        _sessions = results[3] as List<Map<String, dynamic>>;
        _currentSessionId = currentSessionId;
        _keyPins = keyPins;
        _keyEvents = keyEvents;
        _ktInclusion = ktInclusion;
        _mlsSignerVerified = mlsSignerVerified;
        _lastBackupAt = lastBackupAt;
        _backupLoaded = backupLoaded;
        _appPinConfigured = appPinConfigured;
        _duressPinConfigured = duressPinConfigured;
        _duressAction = duressAction;
        _appLockGraceSeconds = appLockGraceSeconds;
        _deadmanDays = deadmanDays;
        _lastRealUnlockAt = lastRealUnlockAt;
        _ktLogAlarm = ktLogAlarm;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<bool> _biometricsAvailable() async {
    try {
      return await _auth.canCheckBiometrics || await _auth.isDeviceSupported();
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> _showKeyWarnings(List<KeyTrustPin> warnings) async {
    if (warnings.isEmpty) return;
    await GlassDialog.show<void>(
      context: context,
      title: 'Key replacement warnings',
      message: warnings
          .map((pin) => pin.warning ?? 'Unexplained key replacement')
          .join('\n\n'),
      actions: [
        GlassDialogAction(
          label: 'Close',
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
  }

  Future<void> _exportKtAlarmEvidence() async {
    final alarm = _ktLogAlarm;
    if (alarm == null) return;
    final evidence = formatKtAlarmEvidenceForExport(alarm);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => GlassBottomSheetFrame(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const GlassSheetGrabber(),
            GlassSheetHeader(
              icon: Icons.gpp_bad_rounded,
              title: 'Export evidence',
              subtitle: 'Copy or share the preserved log-integrity proof.',
              onClose: () => Navigator.pop(sheetCtx),
            ),
            const SizedBox(height: 4),
            GlassMenuSection(
              entries: [
                GlassMenuEntry(
                  icon: Icons.copy_rounded,
                  label: 'Copy evidence',
                  onTap: () async {
                    Navigator.pop(sheetCtx);
                    await Clipboard.setData(ClipboardData(text: evidence));
                    if (mounted) showAppToast(context, 'Evidence copied');
                  },
                ),
                GlassMenuEntry(
                  icon: Icons.ios_share_rounded,
                  label: 'Share evidence',
                  onTap: () async {
                    Navigator.pop(sheetCtx);
                    await SharePlus.instance.share(
                      ShareParams(
                        text: evidence,
                        subject: 'OpenChat key-transparency violation evidence',
                      ),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Future<void> _setBiometric(bool value) async {
    final messenger = ScaffoldMessenger.of(context);
    if (value) {
      try {
        final ok = await _auth.authenticate(
          localizedReason: 'Authenticate to enable biometric key export guard',
        );
        if (!ok) return;
      } catch (e) {
        messenger.showSnackBar(
          SnackBar(content: Text('Biometric unlock unavailable: $e')),
        );
        return;
      }
    }
    if (!mounted) return;
    await context.read<SecureStorageService>().setBiometricEnabled(value);
    if (mounted) setState(() => _biometricEnabled = value);
  }

  Future<void> _setForceTurn(bool value) async {
    await context.read<SecureStorageService>().setForceTurn(value);
    if (mounted) setState(() => _forceTurn = value);
  }

  Future<void> _setScreenSecurity(bool value) async {
    await context.read<SecureStorageService>().setScreenSecurity(value);
    await SecurityService.instance.setGlobalSecure(value);
    if (mounted) setState(() => _screenSecurity = value);
  }

  Future<void> _setAppLock(bool value) async {
    final messenger = ScaffoldMessenger.of(context);
    if (value) {
      try {
        final ok = await _auth.authenticate(
          localizedReason: 'Authenticate to enable app lock',
        );
        if (!ok) return;
      } catch (e) {
        messenger.showSnackBar(
          SnackBar(content: Text('App lock unavailable: $e')),
        );
        return;
      }
    }
    if (!mounted) return;
    await context.read<SecureStorageService>().setAppLockEnabled(value);
    if (mounted) setState(() => _appLockEnabled = value);
  }

  Future<void> _setAllowGroupAdd(bool value) async {
    final api = context.read<ApiService>();
    final auth = context.read<AuthProvider>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await api.updatePreferences(allowGroupAdd: value);
      await auth.refreshCurrentUser();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<void> _setPublicDiscovery(bool value) async {
    final api = context.read<ApiService>();
    final auth = context.read<AuthProvider>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await api.updateProfile(publicDiscovery: value);
      await auth.refreshCurrentUser();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<void> _prepareMlsIdentity() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final mls = context.read<MlsService>();
      // ensureIdentityForCurrentUser only signs a MISSING/empty signature; a
      // stale non-empty one (left by a prior key) also needs re-signing, which
      // is exactly what the explicit resign covers.
      await mls.ensureIdentityForCurrentUser();
      await mls.resignDeviceKeyForCurrentUser();
      await _load();
      messenger.showSnackBar(
        const SnackBar(content: Text('MLS device key prepared')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('MLS key preparation failed: $e')),
      );
    }
  }

  Future<void> _revokeSession(Map<String, dynamic> session) async {
    final id = session['id'] as String?;
    if (id == null || id.isEmpty) return;
    final api = context.read<ApiService>();
    final messenger = ScaffoldMessenger.of(context);
    var confirmed = false;
    await GlassDialog.show<void>(
      context: context,
      title: 'Revoke session?',
      message: 'This signs out ${sessionDeviceDisplayLabel(session)}.',
      actions: [
        GlassDialogAction(
          label: 'Cancel',
          onPressed: () => Navigator.pop(context),
        ),
        GlassDialogAction(
          label: 'Revoke',
          isDestructive: true,
          onPressed: () {
            confirmed = true;
            Navigator.pop(context);
          },
        ),
      ],
    );
    if (!confirmed || !mounted) return;
    try {
      await api.revokeSession(id);
      await _load();
      messenger.showSnackBar(const SnackBar(content: Text('Session revoked')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  /// Confirms, signs, and sends a remote-wipe command for [session]. The
  /// signature binds the session id and timestamp so the server can only
  /// relay the command — never forge one.
  Future<void> _wipeDeviceSession(Map<String, dynamic> session) async {
    final id = session['id'] as String?;
    if (id == null || id.isEmpty) return;
    final api = context.read<ApiService>();
    final storage = context.read<SecureStorageService>();
    final messenger = ScaffoldMessenger.of(context);
    var confirmed = false;
    await GlassDialog.show<void>(
      context: context,
      title: 'Wipe device?',
      message:
          'This sends a signed self-destruct command to '
          '"${sessionDeviceDisplayLabel(session)}". All OpenChat data on that '
          'device — keys, messages, and settings — is destroyed as soon as it '
          'receives the command. This cannot be undone.',
      actions: [
        GlassDialogAction(
          label: 'Cancel',
          onPressed: () => Navigator.pop(context),
        ),
        GlassDialogAction(
          label: 'Wipe device',
          isDestructive: true,
          onPressed: () {
            confirmed = true;
            Navigator.pop(context);
          },
        ),
      ],
    );
    if (!confirmed || !mounted) return;
    try {
      final privateKey = await storage.getPrivateKey();
      if (privateKey == null || privateKey.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'No PGP private key on this device to sign the wipe command',
            ),
          ),
        );
        return;
      }
      final issuedAt = DateTime.now().toUtc().toIso8601String();
      final signature = await PgpService.sign(
        data: PgpService.deviceWipeSignedData(
          sessionId: id,
          issuedAt: issuedAt,
        ),
        privateKeyArmored: privateKey,
      );
      final command = jsonEncode({
        'openchat_device_wipe': 1,
        'session_id': id,
        'issued_at': issuedAt,
        'signature': signature,
      });
      await api.wipeSession(id, command: command);
      await _load();
      messenger.showSnackBar(
        const SnackBar(content: Text('Wipe command sent')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Wipe failed: $e')));
    }
  }

  Future<void> _manageTwoFactorPassword() async {
    final api = context.read<ApiService>();
    final messenger = ScaffoldMessenger.of(context);
    final twoFactorCtrl = TextEditingController();
    final twoFactorEnabled = _security['two_factor_enabled'] as bool? ?? false;
    var submitting = false;

    try {
      await showDialog<void>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDlg) => GlassAlertDialog(
            title: const Text('2FA password'),
            content: TextField(
              controller: twoFactorCtrl,
              obscureText: true,
              decoration: InputDecoration(
                labelText: twoFactorEnabled
                    ? 'New 2FA password'
                    : 'Enable 2FA password',
              ),
            ),
            actions: [
              if (twoFactorEnabled)
                TextButton(
                  onPressed: submitting
                      ? null
                      : () async {
                          setDlg(() => submitting = true);
                          try {
                            final next = await api.updateSecuritySettings(
                              disableTwoFactor: true,
                            );
                            if (mounted) setState(() => _security = next);
                            if (ctx.mounted) Navigator.pop(ctx);
                            messenger.showSnackBar(
                              const SnackBar(content: Text('2FA disabled')),
                            );
                          } catch (e) {
                            if (ctx.mounted) setDlg(() => submitting = false);
                            messenger.showSnackBar(
                              SnackBar(content: Text('Failed: $e')),
                            );
                          }
                        },
                  child: const Text('Disable'),
                ),
              TextButton(
                onPressed: submitting ? null : () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: submitting
                    ? null
                    : () async {
                        final password = twoFactorCtrl.text.trim();
                        if (password.isEmpty) {
                          messenger.showSnackBar(
                            const SnackBar(
                              content: Text('Enter a 2FA password'),
                            ),
                          );
                          return;
                        }
                        setDlg(() => submitting = true);
                        try {
                          final next = await api.updateSecuritySettings(
                            twoFactorPassword: password,
                          );
                          if (mounted) setState(() => _security = next);
                          if (ctx.mounted) Navigator.pop(ctx);
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text(
                                twoFactorEnabled
                                    ? '2FA password updated'
                                    : '2FA enabled',
                              ),
                            ),
                          );
                        } catch (e) {
                          if (ctx.mounted) setDlg(() => submitting = false);
                          messenger.showSnackBar(
                            SnackBar(content: Text('Failed: $e')),
                          );
                        }
                      },
                child: submitting
                    ? const GlassProgressIndicator.circular(
                        size: 16,
                        strokeWidth: 2,
                      )
                    : const Text('Save'),
              ),
            ],
          ),
        ),
      );
    } finally {
      twoFactorCtrl.dispose();
    }
  }

  Future<void> _manageAccountInactivityDeletion() async {
    final api = context.read<ApiService>();
    final messenger = ScaffoldMessenger.of(context);
    var selectedDays = normalizeInactiveDeletionDays(
      _security['account_self_destruct_days'] as int?,
    );
    var submitting = false;
    final wheelController = FixedExtentScrollController(
      initialItem: selectedDays,
    );

    try {
      await showDialog<void>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDlg) => GlassAlertDialog(
            title: const Text('Delete account when inactive for'),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    inactiveDeletionSummaryLabel(selectedDays),
                    style: Theme.of(ctx).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 216,
                    child: CupertinoPicker.builder(
                      scrollController: wheelController,
                      itemExtent: 44,
                      useMagnifier: true,
                      magnification: 1.06,
                      backgroundColor: Colors.transparent,
                      childCount: accountInactivityDeletionMaxDays + 1,
                      onSelectedItemChanged: (index) {
                        setDlg(() => selectedDays = index);
                      },
                      itemBuilder: (ctx, index) {
                        return Center(
                          child: Text(
                            inactiveDeletionDurationLabel(index),
                            style: Theme.of(ctx).textTheme.titleMedium,
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: submitting ? null : () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: submitting
                    ? null
                    : () async {
                        setDlg(() => submitting = true);
                        try {
                          final next = await api.updateSecuritySettings(
                            accountSelfDestructDays: selectedDays,
                          );
                          if (mounted) setState(() => _security = next);
                          if (ctx.mounted) Navigator.pop(ctx);
                          messenger.showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Inactive account deletion updated',
                              ),
                            ),
                          );
                        } catch (e) {
                          if (ctx.mounted) setDlg(() => submitting = false);
                          messenger.showSnackBar(
                            SnackBar(content: Text('Failed: $e')),
                          );
                        }
                      },
                child: submitting
                    ? const GlassProgressIndicator.circular(
                        size: 16,
                        strokeWidth: 2,
                      )
                    : const Text('Save'),
              ),
            ],
          ),
        ),
      );
    } finally {
      wheelController.dispose();
    }
  }

  Future<void> _manageAppLockGrace() async {
    final storage = context.read<SecureStorageService>();
    var selectedSeconds = normalizeAppLockGraceSeconds(_appLockGraceSeconds);
    var submitting = false;
    final initialIndex = appLockGraceOptionsSeconds.indexOf(selectedSeconds);
    final wheelController = FixedExtentScrollController(
      initialItem: initialIndex < 0 ? 0 : initialIndex,
    );

    try {
      await showDialog<void>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDlg) => GlassAlertDialog(
            title: const Text('Auto-lock after'),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    appLockGraceSummaryLabel(selectedSeconds),
                    style: Theme.of(ctx).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 216,
                    child: CupertinoPicker.builder(
                      scrollController: wheelController,
                      itemExtent: 44,
                      useMagnifier: true,
                      magnification: 1.06,
                      backgroundColor: Colors.transparent,
                      childCount: appLockGraceOptionsSeconds.length,
                      onSelectedItemChanged: (index) {
                        setDlg(() {
                          selectedSeconds = appLockGraceOptionsSeconds[index];
                        });
                      },
                      itemBuilder: (ctx, index) {
                        return Center(
                          child: Text(
                            appLockGraceLabel(
                              appLockGraceOptionsSeconds[index],
                            ),
                            style: Theme.of(ctx).textTheme.titleMedium,
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: submitting ? null : () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: submitting
                    ? null
                    : () async {
                        setDlg(() => submitting = true);
                        await storage.setAppLockGraceSeconds(selectedSeconds);
                        if (mounted) {
                          setState(
                            () => _appLockGraceSeconds = selectedSeconds,
                          );
                        }
                        if (ctx.mounted) Navigator.pop(ctx);
                        if (mounted) {
                          showAppToast(context, 'Auto-lock updated');
                        }
                      },
                child: submitting
                    ? const GlassProgressIndicator.circular(
                        size: 16,
                        strokeWidth: 2,
                      )
                    : const Text('Save'),
              ),
            ],
          ),
        ),
      );
    } finally {
      wheelController.dispose();
    }
  }

  // ── Login & key recovery (folded in from the old Settings screen) ──────────

  Future<void> _changePassword() async {
    final currentCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    final api = context.read<ApiService>();
    final messenger = ScaffoldMessenger.of(context);
    final formKey = GlobalKey<FormState>();
    bool submitting = false;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => GlassAlertDialog(
          title: const Text('Change Password'),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: currentCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Current password',
                  ),
                  validator: (v) =>
                      (v == null || v.isEmpty) ? 'Required' : null,
                ),
                TextFormField(
                  controller: newCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'New password'),
                  validator: (v) => (v == null || v.length < 8)
                      ? 'At least 8 characters'
                      : null,
                ),
                TextFormField(
                  controller: confirmCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Confirm new password',
                  ),
                  validator: (v) =>
                      v != newCtrl.text ? 'Passwords do not match' : null,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: submitting ? null : () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: submitting
                  ? null
                  : () async {
                      if (!formKey.currentState!.validate()) return;
                      setDlg(() => submitting = true);
                      try {
                        await api.changePassword(
                          currentPassword: currentCtrl.text,
                          newPassword: newCtrl.text,
                        );
                        if (ctx.mounted) Navigator.pop(ctx);
                        messenger.showSnackBar(
                          const SnackBar(content: Text('Password changed')),
                        );
                      } catch (e) {
                        setDlg(() => submitting = false);
                        messenger.showSnackBar(
                          SnackBar(content: Text('Failed: $e')),
                        );
                      }
                    },
              child: submitting
                  ? const GlassProgressIndicator.circular(
                      size: 16,
                      strokeWidth: 2,
                    )
                  : const Text('Change'),
            ),
          ],
        ),
      ),
    );
  }

  // ── App lock PIN + duress PIN + dead-man switch ───────────────────────────

  /// Glass dialog with PIN + confirm fields (digits only, min 4). Returns the
  /// PIN or null. [validate] runs after the local checks and returns an error
  /// string to reject (e.g. a duress PIN colliding with the real PIN).
  Future<String?> _promptNewPin({
    required String title,
    String? message,
    Future<String?> Function(String pin)? validate,
  }) async {
    final pinCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    String? errorText;
    try {
      return await showDialog<String>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDlg) => GlassAlertDialog(
            icon: const Icon(Icons.pin_outlined),
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (message != null) ...[
                  Text(message),
                  const SizedBox(height: 12),
                ],
                TextField(
                  controller: pinCtrl,
                  obscureText: true,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    labelText: 'PIN (at least 4 digits)',
                    errorText: errorText,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: confirmCtrl,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: 'Confirm PIN'),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () async {
                  final pin = pinCtrl.text.trim();
                  if (pin.length < 4) {
                    setDlg(() => errorText = 'Use at least 4 digits');
                    return;
                  }
                  if (pin != confirmCtrl.text.trim()) {
                    setDlg(() => errorText = 'PINs do not match');
                    return;
                  }
                  final validationError = await validate?.call(pin);
                  if (!ctx.mounted) return;
                  if (validationError != null) {
                    setDlg(() => errorText = validationError);
                    return;
                  }
                  Navigator.pop(ctx, pin);
                },
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      );
    } finally {
      pinCtrl.dispose();
      confirmCtrl.dispose();
    }
  }

  Future<void> _setAppLockPinFlow({required String title}) async {
    final storage = context.read<SecureStorageService>();
    final pin = await _promptNewPin(title: title);
    if (pin == null || !mounted) return;
    await storage.setAppLockPin(pin);
    appPinConfiguredListenable.value = true;
    if (mounted) setState(() => _appPinConfigured = true);
  }

  Future<void> _manageAppLockPin() async {
    if (!_appPinConfigured) {
      await _setAppLockPinFlow(title: 'Set app lock PIN');
      return;
    }
    String? choice;
    await showGlassActionSheet<void>(
      context: context,
      title: 'App lock PIN',
      actions: [
        GlassActionSheetAction(
          label: 'Change PIN',
          onPressed: () => choice = 'change',
        ),
        GlassActionSheetAction(
          label: 'Remove PIN',
          style: GlassActionSheetStyle.destructive,
          onPressed: () => choice = 'remove',
        ),
      ],
    );
    if (!mounted || choice == null) return;
    if (choice == 'change') {
      await _setAppLockPinFlow(title: 'Change app lock PIN');
      return;
    }
    final storage = context.read<SecureStorageService>();
    await storage.clearAppLockPin();
    // A duress PIN without a real PIN to hide behind is meaningless (and the
    // lock screen would treat any leftover code as the only unlock) — clear it.
    await storage.clearDuressPin();
    appPinConfiguredListenable.value = false;
    if (mounted) {
      setState(() {
        _appPinConfigured = false;
        _duressPinConfigured = false;
      });
    }
  }

  Future<void> _setDuressPinFlow() async {
    final storage = context.read<SecureStorageService>();
    final pin = await _promptNewPin(
      title: _duressPinConfigured ? 'Change duress PIN' : 'Set duress PIN',
      message:
          'A second unlock code for coerced unlocks. It must differ from '
          'your real PIN.',
      validate: (pin) async =>
          await storage.classifyAppLockPin(pin) == AppLockPinKind.real
          ? 'This is your real PIN — choose a different one'
          : null,
    );
    if (pin == null || !mounted) return;
    await storage.setDuressPin(pin);
    if (mounted) setState(() => _duressPinConfigured = true);
  }

  Future<void> _manageDuressPin() async {
    if (!_duressPinConfigured) {
      await _setDuressPinFlow();
      return;
    }
    String? choice;
    await showGlassActionSheet<void>(
      context: context,
      title: 'Duress PIN',
      actions: [
        GlassActionSheetAction(
          label: 'Change duress PIN',
          onPressed: () => choice = 'change',
        ),
        GlassActionSheetAction(
          label: 'Remove duress PIN',
          style: GlassActionSheetStyle.destructive,
          onPressed: () => choice = 'remove',
        ),
      ],
    );
    if (!mounted || choice == null) return;
    if (choice == 'change') {
      await _setDuressPinFlow();
      return;
    }
    await context.read<SecureStorageService>().clearDuressPin();
    if (mounted) setState(() => _duressPinConfigured = false);
  }

  Future<void> _pickDuressAction() async {
    String? choice;
    await showGlassActionSheet<void>(
      context: context,
      title: 'Duress PIN action',
      message: 'What happens when the duress PIN is entered.',
      actions: [
        GlassActionSheetAction(
          icon: _duressAction == 'decoy'
              ? const Icon(Icons.check_rounded)
              : null,
          label: 'Open decoy',
          onPressed: () => choice = 'decoy',
        ),
        GlassActionSheetAction(
          icon: _duressAction == 'wipe'
              ? const Icon(Icons.check_rounded)
              : null,
          label: 'Wipe this device',
          style: GlassActionSheetStyle.destructive,
          onPressed: () => choice = 'wipe',
        ),
      ],
    );
    if (!mounted || choice == null || choice == _duressAction) return;
    if (choice == 'wipe') {
      var confirmed = false;
      await GlassDialog.show<void>(
        context: context,
        title: 'Wipe on duress PIN?',
        message:
            'Entering this PIN under coercion silently destroys all local '
            'data. Unrecoverable without your backup.',
        actions: [
          GlassDialogAction(
            label: 'Cancel',
            onPressed: () => Navigator.pop(context),
          ),
          GlassDialogAction(
            label: 'Wipe device',
            isDestructive: true,
            onPressed: () {
              confirmed = true;
              Navigator.pop(context);
            },
          ),
        ],
      );
      if (!confirmed || !mounted) return;
    }
    await context.read<SecureStorageService>().setDuressAction(choice!);
    if (mounted) setState(() => _duressAction = choice!);
  }

  Future<void> _pickDeadmanDays() async {
    int? choice;
    await showGlassActionSheet<void>(
      context: context,
      title: 'Auto-wipe',
      message:
          'If the app sees no real unlock for this long, local data is '
          'destroyed.',
      actions: [
        for (final days in const [0, 7, 14, 30, 90])
          GlassActionSheetAction(
            icon: _deadmanDays == days ? const Icon(Icons.check_rounded) : null,
            label: days == 0 ? 'Off' : '$days days',
            onPressed: () => choice = days,
          ),
      ],
    );
    if (!mounted || choice == null || choice == _deadmanDays) return;
    final storage = context.read<SecureStorageService>();
    await storage.setDeadmanDays(choice!);
    await _refreshDeadmanWarning(choice!, storage);
    if (mounted) setState(() => _deadmanDays = choice!);
  }

  Future<void> _refreshDeadmanWarning(
    int days,
    SecureStorageService storage,
  ) async {
    final status = computeDeadmanStatus(
      days: days,
      lastRealUnlockAt: await storage.getLastRealUnlockAt(),
      now: DateTime.now().toUtc(),
    );
    final fireAt = deadmanWarningFireAt(status);
    if (fireAt == null) {
      await NotificationService.cancelDeadmanWarning();
    } else {
      await NotificationService.scheduleDeadmanWarning(fireAt: fireAt);
    }
  }

  // ── Encrypted backups (folded in from the old Settings screen) ─────────────

  Future<void> _exportEncryptedBackup() async {
    if (kIsWeb) return;
    final passphrase = await _promptBackupPassphrase(confirm: true);
    if (passphrase == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final service = EncryptedBackupService(
        storage: context.read<SecureStorageService>(),
        privateState: LocalPrivateStateService(
          storage: context.read<SecureStorageService>(),
        ),
      );
      final encoded = await service.exportBackup(passphrase: passphrase);
      final now = DateTime.now().toUtc();
      final name =
          'openchat-recovery-${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}.ocbackup.json';
      final location = await getSaveLocation(suggestedName: name);
      if (location == null) return;
      await File(location.path).writeAsString(encoded);
      messenger.showSnackBar(
        const SnackBar(content: Text('Encrypted backup exported')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  /// Stores the encrypted recovery bundle on the server as an opaque blob —
  /// zero-knowledge: only ciphertext leaves the device.
  Future<void> _uploadBackupToServer() async {
    final passphrase = await _promptBackupPassphrase(
      confirm: true,
      requireStrong: true,
    );
    if (passphrase == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final service = EncryptedBackupService(
        storage: context.read<SecureStorageService>(),
        privateState: LocalPrivateStateService(
          storage: context.read<SecureStorageService>(),
        ),
      );
      await service.uploadToServer(
        api: context.read<ApiService>(),
        passphrase: passphrase,
      );
      // Optimistic: reflect the just-now upload without a metadata round-trip.
      if (mounted) {
        setState(() {
          _lastBackupAt = DateTime.now();
          _backupLoaded = true;
        });
      }
      messenger.showSnackBar(
        const SnackBar(content: Text('Encrypted backup stored on server')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Backup failed: $e')));
    }
  }

  Future<void> _restoreBackupFromServer() async {
    final passphrase = await _promptBackupPassphrase(confirm: false);
    if (passphrase == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final service = EncryptedBackupService(
        storage: context.read<SecureStorageService>(),
        privateState: LocalPrivateStateService(
          storage: context.read<SecureStorageService>(),
        ),
      );
      final keyProvider = context.read<KeyProvider>();
      final settingsProvider = context.read<SettingsProvider>();
      await service.restoreFromServer(
        api: context.read<ApiService>(),
        passphrase: passphrase,
      );
      await keyProvider.load();
      await settingsProvider.reload();
      messenger.showSnackBar(
        const SnackBar(content: Text('Backup restored from server')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Restore failed: $e')));
    }
  }

  Future<void> _deleteServerBackup() async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        icon: const Icon(Icons.delete_outline),
        title: const Text('Delete server backup?'),
        content: const Text(
          'The encrypted backup blob is removed from the server. Local data '
          'is not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await context.read<ApiService>().deleteServerBackup();
      if (mounted) {
        setState(() {
          _lastBackupAt = null;
          _backupLoaded = true;
        });
      }
      messenger.showSnackBar(
        const SnackBar(content: Text('Server backup deleted')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Delete failed: $e')));
    }
  }

  Future<void> _importEncryptedBackup() async {
    if (kIsWeb) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'OpenChat backup',
            extensions: ['json', 'ocbackup'],
          ),
        ],
      );
      if (file == null || !mounted) return;
      final passphrase = await _promptBackupPassphrase(confirm: false);
      if (passphrase == null || !mounted) return;
      final service = EncryptedBackupService(
        storage: context.read<SecureStorageService>(),
        privateState: LocalPrivateStateService(
          storage: context.read<SecureStorageService>(),
        ),
      );
      final keyProvider = context.read<KeyProvider>();
      final settingsProvider = context.read<SettingsProvider>();
      await service.importBackup(
        encodedBackup: await file.readAsString(),
        passphrase: passphrase,
      );
      await keyProvider.load();
      await settingsProvider.reload();
      messenger.showSnackBar(
        const SnackBar(content: Text('Encrypted backup imported')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Import failed: $e')));
    }
  }

  Future<String?> _promptBackupPassphrase({
    required bool confirm,
    bool requireStrong = false,
  }) async {
    final passCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    String? errorText;
    var obscureText = true;
    try {
      return await showDialog<String>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDlg) => GlassAlertDialog(
            icon: const Icon(Icons.enhanced_encryption_outlined),
            title: Text(confirm ? 'Encrypt recovery backup' : 'Decrypt backup'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: passCtrl,
                  obscureText: obscureText,
                  onChanged: (_) => setDlg(() => errorText = null),
                  decoration: InputDecoration(
                    labelText: 'Backup passphrase',
                    errorText: errorText,
                    suffixIcon: IconButton(
                      tooltip: obscureText
                          ? 'Show passphrase'
                          : 'Hide passphrase',
                      icon: Icon(
                        obscureText
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () => setDlg(() => obscureText = !obscureText),
                    ),
                  ),
                ),
                if (confirm) ...[
                  const SizedBox(height: 10),
                  TextField(
                    controller: confirmCtrl,
                    obscureText: obscureText,
                    onChanged: (_) => setDlg(() => errorText = null),
                    decoration: const InputDecoration(
                      labelText: 'Confirm passphrase',
                    ),
                  ),
                  const SizedBox(height: 12),
                  _PassphraseStrengthMeter(passphrase: passCtrl.text),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: const Icon(Icons.auto_awesome_rounded),
                      label: const Text('Generate strong passphrase'),
                      onPressed: () {
                        final generated = PassphraseStrength.generate();
                        setDlg(() {
                          passCtrl.text = generated;
                          confirmCtrl.text = generated;
                          obscureText = false;
                          errorText = null;
                        });
                      },
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final passphrase = passCtrl.text.trim();
                  if (passphrase.length < 12) {
                    setDlg(() {
                      errorText = 'Use at least 12 characters';
                    });
                    return;
                  }
                  if (confirm && passphrase != confirmCtrl.text.trim()) {
                    setDlg(() {
                      errorText = 'Passphrases do not match';
                    });
                    return;
                  }
                  if (requireStrong &&
                      !PassphraseStrength.isStrongEnoughForServer(passphrase)) {
                    setDlg(() {
                      errorText = 'Choose a stronger passphrase';
                    });
                    return;
                  }
                  Navigator.pop(ctx, passphrase);
                },
                child: Text(confirm ? 'Export' : 'Import'),
              ),
            ],
          ),
        ),
      );
    } finally {
      passCtrl.dispose();
      confirmCtrl.dispose();
    }
  }

  void _showFingerprintQr(String fingerprint) {
    showDialog<void>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: const Text('Your identity QR'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IdentityQrView(data: identityFingerprintQrPayload(fingerprint)),
            const SizedBox(height: 12),
            Text(
              formatIdentityFingerprint(fingerprint),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final user = auth.currentUser;
    final keys = context.watch<KeyProvider>();
    final settings = context.watch<SettingsProvider>();
    final conversations = context.watch<ChatProvider>().conversations;
    final scheme = Theme.of(context).colorScheme;
    final deadmanStatus = computeDeadmanStatus(
      days: _deadmanDays,
      lastRealUnlockAt: _lastRealUnlockAt,
      now: DateTime.now().toUtc(),
    );
    final deadmanColor = !deadmanStatus.enabled
        ? Colors.grey
        : deadmanStatus.daysRemaining <= 1
        ? Colors.orange
        : Colors.green;

    final localFp = normalizeIdentityFingerprint(keys.fingerprint ?? '');
    final accountFp = normalizeIdentityFingerprint(user?.keyFingerprint ?? '');
    final fingerprintMatches =
        localFp.isNotEmpty && (accountFp.isEmpty || localFp == accountFp);
    final unencrypted = conversations
        .where((conversation) => !conversation.isEncrypted)
        .toList();
    final twoFactorEnabled = _security['two_factor_enabled'] as bool? ?? false;
    final keyWarnings = _keyPins.values
        .where((pin) => pin.warning != null && pin.warning!.trim().isNotEmpty)
        .toList();
    final latestKeyEvent = _keyEvents.isEmpty ? null : _keyEvents.last;
    final ktInclusion = _ktLogAlarm != null
        ? KtInclusionStatus.alarm
        : _ktInclusion;
    final (
      String ktPillLabel,
      Color ktPillColor,
      Color ktIconColor,
    ) = latestKeyEvent == null
        ? ('No log', Colors.orange, Colors.orange)
        : switch (ktInclusion) {
            KtInclusionStatus.verified => (
              'Verified',
              Colors.green,
              Colors.green,
            ),
            KtInclusionStatus.pending || KtInclusionStatus.unknown => (
              'Pending',
              Colors.orange,
              Colors.orange,
            ),
            KtInclusionStatus.alarm => ('Tampered', scheme.error, scheme.error),
          };
    final ktSubtitle = latestKeyEvent == null
        ? 'No account key event seen yet'
        : switch (ktInclusion) {
            KtInclusionStatus.verified =>
              '${_keyEvents.length} event${_keyEvents.length == 1 ? '' : 's'}; latest ${_shortHash(latestKeyEvent.eventHash)} proven in signed log',
            KtInclusionStatus.pending || KtInclusionStatus.unknown =>
              '${_keyEvents.length} event${_keyEvents.length == 1 ? '' : 's'}; awaiting next signed head',
            KtInclusionStatus.alarm =>
              'An account key event is missing from the signed log',
          };
    // Green only when the stored signature truly verifies against the current
    // PGP key (computed in _load); a stale post-rotation signature is non-empty
    // but fails verification, so it correctly shows 'Prepare'.
    final mlsSignerSigned = _mlsSignerVerified;
    final backupStatus = evaluateBackupFreshness(
      lastBackupAt: _lastBackupAt,
      now: DateTime.now(),
    );
    // Only nag about a missing backup once we definitively know there is none;
    // a not-yet-loaded or failed fetch counts as "has backup" so it stays quiet.
    final hasServerBackup =
        !_backupLoaded || backupStatus.freshness != BackupFreshness.none;
    final (
      Color backupColor,
      String backupPillLabel,
      IconData backupIcon,
    ) = switch (backupStatus.freshness) {
      BackupFreshness.fresh => (
        Colors.green,
        'Fresh',
        Icons.cloud_done_outlined,
      ),
      BackupFreshness.aging => (
        Colors.orange,
        'Aging',
        Icons.cloud_done_outlined,
      ),
      BackupFreshness.stale => (
        scheme.error,
        'Stale',
        Icons.cloud_off_outlined,
      ),
      BackupFreshness.none => (Colors.orange, 'None', Icons.cloud_off_outlined),
    };
    final summary = evaluateTrustCenter(
      hasLocalKey: keys.hasKey,
      accountKeyExpired: user?.isKeyExpired ?? false,
      fingerprintMatchesAccount: fingerprintMatches,
      twoFactorEnabled: twoFactorEnabled,
      appLockEnabled: _appLockEnabled,
      biometricAvailable: _biometricAvailable,
      biometricKeyExportEnabled: _biometricEnabled,
      allowGroupAdd: user?.allowGroupAdd ?? true,
      notificationShowSender: settings.notificationShowSender,
      notificationShowPreview: settings.notificationShowPreview,
      pushNotificationsEnabled: settings.pushNotificationsEnabled,
      unencryptedConversations: unencrypted.length,
      keyTransparencyWarnings: keyWarnings.length,
      hasServerBackup: hasServerBackup,
    );
    final timelineItems = _trustTimelineItems(
      keyEvents: _keyEvents,
      keyPins: _keyPins,
      sessions: _sessions,
    );

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassAppBar(
        title: const Text('Privacy & Security'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            16,
            MediaQuery.paddingOf(context).top + kToolbarHeight + 12,
            16,
            MediaQuery.paddingOf(context).bottom + 32,
          ),
          children: [
            _TrustHero(summary: summary, loading: _loading, error: _error),
            // A key-transparency log violation outranks everything on this
            // screen: it is cryptographic evidence the server (or its log
            // key holder) showed different key histories to different people.
            if (_ktLogAlarm != null) ...[
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: GlassListTile(
                  leading: Icon(
                    Icons.gpp_bad_rounded,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  title: const Text(
                    'Key-transparency violation detected',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(
                    '${_ktLogAlarm!['reason']} — the server may have tampered '
                    'with key history. Evidence is preserved on this device. '
                    'Re-verify your contacts before trusting new keys.',
                  ),
                  trailing: TextButton.icon(
                    icon: const Icon(Icons.ios_share_rounded),
                    label: const Text('Export evidence'),
                    onPressed: _exportKtAlarmEvidence,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 20),
            const _TrustSectionHeader('Identity'),
            GlassCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _TrustRow(
                    icon: keys.hasKey
                        ? Icons.verified_user_outlined
                        : Icons.warning_amber_rounded,
                    iconColor: keys.hasKey ? Colors.green : Colors.orange,
                    title: keys.hasKey ? 'Local PGP key' : 'No local key',
                    subtitle: keys.hasKey
                        ? fingerprintMatches
                              ? 'Fingerprint matches your account key'
                              : 'Fingerprint does not match your account key'
                        : 'Import or generate a key before relying on E2E chat',
                    trailing: _StatusPill(
                      label: keys.hasKey && fingerprintMatches
                          ? 'Verified'
                          : 'Check',
                      color: keys.hasKey && fingerprintMatches
                          ? Colors.green
                          : Colors.orange,
                    ),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const PgpKeysScreen(),
                      ),
                    ),
                  ),
                  if (keys.fingerprint != null &&
                      keys.fingerprint!.isNotEmpty) ...[
                    const _TrustDivider(),
                    _FingerprintPanel(
                      fingerprint: keys.fingerprint!,
                      onCopy: () {
                        Clipboard.setData(
                          ClipboardData(text: keys.fingerprint!),
                        );
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Fingerprint copied')),
                        );
                      },
                      onQr: () => _showFingerprintQr(keys.fingerprint!),
                    ),
                  ],
                  const _TrustDivider(),
                  _TrustRow(
                    icon: Icons.account_tree_outlined,
                    iconColor: ktIconColor,
                    title: 'Key transparency log',
                    subtitle: ktSubtitle,
                    trailing: _StatusPill(
                      label: ktPillLabel,
                      color: ktPillColor,
                    ),
                  ),
                  if (keyWarnings.isNotEmpty) ...[
                    const _TrustDivider(),
                    _TrustRow(
                      icon: Icons.report_gmailerrorred_outlined,
                      iconColor: scheme.error,
                      title: 'Unexplained key replacement',
                      subtitle: keyWarnings.length == 1
                          ? keyWarnings.first.warning
                          : '${keyWarnings.length} pinned keys changed without a signed log event',
                      trailing: _StatusPill(
                        label: '${keyWarnings.length}',
                        color: scheme.error,
                      ),
                      onTap: () => _showKeyWarnings(keyWarnings),
                    ),
                  ],
                  const _TrustDivider(),
                  _TrustRow(
                    icon: Icons.hub_outlined,
                    iconColor: mlsSignerSigned ? Colors.green : Colors.orange,
                    title: 'MLS device key',
                    subtitle: mlsSignerSigned
                        ? 'Signed by your PGP identity key'
                        : 'Prepare it now without sending an MLS message',
                    trailing: _StatusPill(
                      label: mlsSignerSigned ? 'Signed' : 'Prepare',
                      color: mlsSignerSigned ? Colors.green : Colors.orange,
                    ),
                    onTap: mlsSignerSigned ? null : _prepareMlsIdentity,
                  ),
                  const _TrustDivider(),
                  _TrustRow(
                    icon: Icons.qr_code_scanner_rounded,
                    title: 'Scan identity QR',
                    subtitle: 'Verify another person out-of-band',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const IdentityQrScannerScreen(),
                      ),
                    ),
                  ),
                  const _TrustDivider(),
                  _TrustRow(
                    icon: Icons.vpn_key_outlined,
                    title: 'Verify a contact (shared secret)',
                    subtitle:
                        'Socialist Millionaire Protocol — in-band, no key swap',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const SmpVerifyScreen(),
                      ),
                    ),
                  ),
                  const _TrustDivider(),
                  _TrustRow(
                    icon: Icons.block_rounded,
                    title: 'Blocked users',
                    subtitle: 'People you have blocked',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const BlockedUsersScreen(),
                      ),
                    ),
                    isLast: true,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            if (timelineItems.isNotEmpty) ...[
              const _TrustSectionHeader('Trust Timeline'),
              GlassCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (var index = 0; index < timelineItems.length; index++)
                      _TrustRow(
                        icon: timelineItems[index].icon,
                        iconColor: timelineItems[index].color,
                        title: timelineItems[index].title,
                        subtitle: timelineItems[index].subtitle,
                        trailing: Text(
                          timeago.format(timelineItems[index].createdAt),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface.withValues(alpha: 0.46),
                          ),
                        ),
                        isLast: index == timelineItems.length - 1,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],
            const _TrustSectionHeader('Encryption Health'),
            GlassCard(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _MetricTile(
                          label: 'Protected',
                          value: '${conversations.length - unencrypted.length}',
                          color: Colors.green,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _MetricTile(
                          label: 'Encryption off',
                          value: '${unencrypted.length}',
                          color: unencrypted.isEmpty
                              ? Colors.green
                              : scheme.error,
                        ),
                      ),
                    ],
                  ),
                  if (unencrypted.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Text(
                      'Review these chats',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    for (final conversation in unencrypted.take(5))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          children: [
                            Icon(
                              _conversationIcon(conversation),
                              size: 16,
                              color: scheme.error,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                conversation.displayName(user?.id ?? ''),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                  const SizedBox(height: 14),
                  const GlassDivider(),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: backupColor.withValues(alpha: 0.12),
                        ),
                        child: Icon(backupIcon, size: 18, color: backupColor),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Server backup',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _backupLoaded
                                  ? backupStatusLabel(backupStatus)
                                  : 'Checking backup status',
                              style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurface.withValues(alpha: 0.6),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      _StatusPill(label: backupPillLabel, color: backupColor),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            const _TrustSectionHeader('Backups'),
            GlassCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  if (!kIsWeb) ...[
                    _TrustRow(
                      icon: Icons.backup_outlined,
                      title: 'Export encrypted backup',
                      subtitle: 'Private key, trust pins, drafts, and folders',
                      onTap: _exportEncryptedBackup,
                    ),
                    _TrustRow(
                      icon: Icons.restore_outlined,
                      title: 'Import encrypted backup',
                      subtitle: 'Restore keys and encrypted local state',
                      onTap: _importEncryptedBackup,
                    ),
                  ],
                  _TrustRow(
                    icon: Icons.cloud_upload_outlined,
                    title: 'Store encrypted backup on server',
                    subtitle: _lastBackupAt != null
                        ? backupStatusLabel(backupStatus)
                        : 'Zero-knowledge: only the passphrase-encrypted blob '
                              'leaves this device',
                    onTap: _uploadBackupToServer,
                  ),
                  _TrustRow(
                    icon: Icons.cloud_download_outlined,
                    title: 'Restore from server backup',
                    subtitle: 'Download and decrypt with your passphrase',
                    onTap: _restoreBackupFromServer,
                  ),
                  _TrustRow(
                    icon: Icons.cloud_off_outlined,
                    title: 'Delete server backup',
                    subtitle: 'Remove the stored blob from the server',
                    onTap: _deleteServerBackup,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            const _TrustSectionHeader('Devices'),
            GlassCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  if (_sessions.isEmpty)
                    _TrustRow(
                      icon: Icons.devices_outlined,
                      title: 'Active sessions',
                      subtitle: _loading
                          ? 'Loading signed-in devices'
                          : 'No active sessions found',
                      trailing: _loading
                          ? const GlassProgressIndicator.circular(
                              size: 18,
                              strokeWidth: 2,
                            )
                          : null,
                    )
                  else
                    ValueListenableBuilder<VaultMode>(
                      // Wipe is vault-only: a coerced decoy session must not
                      // be able to send signed wipe commands to the account's
                      // other devices.
                      valueListenable: vaultModeListenable,
                      builder: (context, vaultMode, _) => Column(
                        children: [
                          for (var index = 0; index < _sessions.length; index++)
                            _TrustRow(
                              icon: Icons.devices_outlined,
                              title: sessionDeviceDisplayLabel(
                                _sessions[index],
                              ),
                              subtitle: _sessionSubtitle(_sessions[index]),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (vaultMode == VaultMode.real &&
                                      !(_currentSessionId != null &&
                                          _sessions[index]['id'] ==
                                              _currentSessionId))
                                    IconButton(
                                      icon: Icon(
                                        Icons.phonelink_erase,
                                        color: scheme.error,
                                      ),
                                      tooltip: 'Wipe device',
                                      onPressed: () =>
                                          _wipeDeviceSession(_sessions[index]),
                                    ),
                                  IconButton(
                                    icon: const Icon(Icons.logout_outlined),
                                    tooltip: 'Revoke session',
                                    onPressed: () =>
                                        _revokeSession(_sessions[index]),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  if (!kIsWeb)
                    _TrustRow(
                      icon: Icons.phonelink_lock_outlined,
                      title: 'Link this device',
                      subtitle: 'Create a one-time encrypted pairing QR',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => const DevicePairingScreen(),
                        ),
                      ),
                    ),
                  if (NearbyMeshService.isSupported)
                    _TrustRow(
                      icon: Icons.bluetooth_audio_rounded,
                      title: 'Nearby',
                      subtitle: 'Exchange queued messages over Bluetooth',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => const NearbyScreen(),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            const _TrustSectionHeader('Account Protection'),
            GlassCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _TrustRow(
                    icon: Icons.password_outlined,
                    title: 'Change password',
                    subtitle: 'Update your account login password',
                    onTap: _changePassword,
                  ),
                  const _TrustDivider(),
                  _TrustRow(
                    icon: Icons.security_outlined,
                    title: '2FA password',
                    subtitle: twoFactorEnabled
                        ? 'Enabled for sign-in'
                        : 'Add a second password for sign-in',
                    trailing: _StatusPill(
                      label: twoFactorEnabled ? 'On' : 'Off',
                      color: twoFactorEnabled ? Colors.green : Colors.orange,
                    ),
                    onTap: _manageTwoFactorPassword,
                  ),
                  const _TrustDivider(),
                  _TrustSwitchRow(
                    icon: Icons.lock_outline,
                    title: 'App lock',
                    subtitle: 'Require biometrics when returning to OpenChat',
                    value: _appLockEnabled,
                    onChanged: _setAppLock,
                  ),
                  if (_appLockEnabled) ...[
                    const _TrustDivider(),
                    _TrustRow(
                      icon: Icons.timer_outlined,
                      title: 'Auto-lock after',
                      subtitle: appLockGraceSummaryLabel(_appLockGraceSeconds),
                      onTap: _manageAppLockGrace,
                    ),
                  ],
                  ValueListenableBuilder<VaultMode>(
                    valueListenable: vaultModeListenable,
                    builder: (context, vaultMode, _) {
                      if (vaultMode != VaultMode.real) {
                        return const SizedBox.shrink();
                      }
                      return Column(
                        children: [
                          const _TrustDivider(),
                          _TrustRow(
                            icon: Icons.hourglass_bottom_outlined,
                            iconColor: deadmanColor,
                            title: 'Auto-wipe',
                            subtitle:
                                'Local data wipes after the silence window. '
                                'Checked when the app opens; iOS cannot '
                                'enforce this in the background.',
                            trailing: _StatusPill(
                              label: deadmanCountdownLabel(deadmanStatus),
                              color: deadmanColor,
                            ),
                            onTap: _pickDeadmanDays,
                          ),
                          const _TrustDivider(),
                          _TrustRow(
                            icon: Icons.pin_outlined,
                            iconColor: _appPinConfigured
                                ? Colors.green
                                : Colors.orange,
                            title: 'App lock PIN',
                            subtitle: _appPinConfigured
                                ? 'Set for manual unlocks'
                                : 'Not set',
                            trailing: _StatusPill(
                              label: _appPinConfigured ? 'Set' : 'Not set',
                              color: _appPinConfigured
                                  ? Colors.green
                                  : Colors.orange,
                            ),
                            onTap: _manageAppLockPin,
                          ),
                          if (_appPinConfigured) ...[
                            const _TrustDivider(),
                            _TrustRow(
                              icon: Icons.theater_comedy_outlined,
                              iconColor: _duressPinConfigured
                                  ? Colors.green
                                  : Colors.orange,
                              title: 'Duress PIN',
                              subtitle: _duressPinConfigured
                                  ? _duressAction == 'wipe'
                                        ? 'Set - wipes this device'
                                        : 'Set - opens decoy'
                                  : 'Not set',
                              trailing: _StatusPill(
                                label: _duressPinConfigured ? 'Set' : 'Not set',
                                color: _duressPinConfigured
                                    ? Colors.green
                                    : Colors.orange,
                              ),
                              onTap: _manageDuressPin,
                            ),
                            if (_duressPinConfigured) ...[
                              const _TrustDivider(),
                              _TrustRow(
                                icon: Icons.fork_right_rounded,
                                title: 'Duress PIN action',
                                subtitle: _duressAction == 'wipe'
                                    ? 'Wipe this device'
                                    : 'Open decoy',
                                onTap: _pickDuressAction,
                              ),
                            ],
                          ],
                        ],
                      );
                    },
                  ),
                  const _TrustDivider(),
                  _TrustSwitchRow(
                    icon: Icons.shield_moon_outlined,
                    title: 'Always relay calls',
                    subtitle: 'Hide your IP — route call media through TURN',
                    value: _forceTurn,
                    onChanged: _setForceTurn,
                  ),
                  const _TrustDivider(),
                  _TrustSwitchRow(
                    icon: Icons.screenshot_monitor_outlined,
                    title: 'Block screenshots',
                    subtitle:
                        'Prevent screenshots & screen recording across the app',
                    value: _screenSecurity,
                    onChanged: _setScreenSecurity,
                  ),
                  if (_biometricAvailable) ...[
                    const _TrustDivider(),
                    _TrustSwitchRow(
                      icon: Icons.fingerprint_rounded,
                      title: 'Biometric key export guard',
                      subtitle: 'Authenticate before private-key export',
                      value: _biometricEnabled,
                      onChanged: _setBiometric,
                    ),
                  ],
                  const _TrustDivider(),
                  _TrustRow(
                    icon: Icons.timer_outlined,
                    title: 'Inactive account deletion',
                    subtitle: inactiveDeletionSummaryLabel(
                      normalizeInactiveDeletionDays(
                        _security['account_self_destruct_days'] as int?,
                      ),
                    ),
                    onTap: _manageAccountInactivityDeletion,
                    isLast: true,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            // Hides itself entirely (headers included) in VaultMode.decoy and
            // carries its own trailing spacing so the layout collapses cleanly.
            SocialRecoverySection(localKeyMissing: !keys.hasKey),
            if (!kIsWeb) ...[
              const _TrustSectionHeader('Network'),
              GlassCard(
                padding: EdgeInsets.zero,
                child: _TrustRow(
                  icon: Icons.vpn_lock_outlined,
                  title: 'Proxy & Tor',
                  subtitle: 'Route traffic through HTTP, SOCKS5, or Tor',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const ProxySettingsScreen(),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],
            const _TrustSectionHeader('Privacy Controls'),
            GlassCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _TrustSwitchRow(
                    icon: Icons.manage_search_outlined,
                    title: 'Public discovery',
                    subtitle: 'Allow people to find you by username search',
                    value: user?.publicDiscovery ?? true,
                    onChanged: _setPublicDiscovery,
                  ),
                  const _TrustDivider(),
                  _TrustSwitchRow(
                    icon: Icons.group_add_outlined,
                    title: 'Allow group adds',
                    subtitle: 'Other users can add you to group chats',
                    value: user?.allowGroupAdd ?? true,
                    onChanged: _setAllowGroupAdd,
                  ),
                  const _TrustDivider(),
                  _TrustSwitchRow(
                    icon: Icons.visibility_outlined,
                    title: 'Strict privacy',
                    subtitle:
                        'Default for typing, read receipts, link previews, and link opens; chats can override typing and receipts',
                    value: settings.strictPrivacyMode,
                    onChanged: settings.setStrictPrivacyMode,
                  ),
                  const _TrustDivider(),
                  _TrustRow(
                    icon: settings.wsBackgroundEnabled
                        ? Icons.wifi_tethering
                        : Icons.notifications_outlined,
                    title: 'Notification route',
                    subtitle: settings.wsBackgroundEnabled
                        ? 'Background WebSocket avoids Firebase metadata'
                        : settings.pushNotificationsEnabled
                        ? 'Firebase push is enabled'
                        : 'Foreground-only notifications',
                    trailing: _StatusPill(
                      label: settings.wsBackgroundEnabled
                          ? 'Private'
                          : settings.pushNotificationsEnabled
                          ? 'Push'
                          : 'Local',
                      color: settings.wsBackgroundEnabled
                          ? Colors.green
                          : Colors.orange,
                    ),
                    isLast: true,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TrustHero extends StatelessWidget {
  final TrustCenterSummary summary;
  final bool loading;
  final String? error;

  const _TrustHero({
    required this.summary,
    required this.loading,
    required this.error,
  });

  @override
  Widget build(BuildContext context) {
    final color = _levelColor(context, summary.level);
    final icon = switch (summary.level) {
      TrustCenterLevel.protected => Icons.shield_rounded,
      TrustCenterLevel.review => Icons.shield_outlined,
      TrustCenterLevel.attention => Icons.gpp_maybe_outlined,
    };

    return GlassCard(
      tint: color.withValues(alpha: 0.08),
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.14),
            ),
            child: Icon(icon, color: color, size: 28),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  loading ? 'Checking trust status' : summary.title,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                Text(
                  error ?? summary.subtitle,
                  style: TextStyle(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.62),
                  ),
                ),
              ],
            ),
          ),
          if (loading)
            const GlassProgressIndicator.circular(size: 22, strokeWidth: 2),
        ],
      ),
    );
  }
}

class _FingerprintPanel extends StatelessWidget {
  final String fingerprint;
  final VoidCallback onCopy;
  final VoidCallback onQr;

  const _FingerprintPanel({
    required this.fingerprint,
    required this.onCopy,
    required this.onQr,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
      child: Row(
        children: [
          Expanded(
            child: Text(
              formatIdentityFingerprint(fingerprint),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy_rounded),
            tooltip: 'Copy fingerprint',
            onPressed: onCopy,
          ),
          IconButton(
            icon: const Icon(Icons.qr_code_rounded),
            tooltip: 'Show identity QR',
            onPressed: onQr,
          ),
        ],
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _MetricTile({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          Text(label, style: Theme.of(context).textTheme.labelMedium),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusPill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: 11,
        ),
      ),
    );
  }
}

class _TrustRow extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool isLast;

  const _TrustRow({
    required this.icon,
    this.iconColor,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = iconColor ?? scheme.primary;
    return GlassListTile(
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: 0.12),
        ),
        child: Icon(icon, size: 18, color: color),
      ),
      title: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle!,
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurface.withValues(alpha: 0.55),
                height: 1.3,
              ),
            )
          : null,
      trailing:
          trailing ??
          Icon(
            CupertinoIcons.chevron_forward,
            size: 14,
            color: scheme.onSurface.withValues(alpha: 0.35),
          ),
      onTap: onTap,
    );
  }
}

class _TrustSwitchRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _TrustSwitchRow({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _TrustRow(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: GlassSwitch(
        value: value,
        onChanged: onChanged,
        activeColor: Theme.of(context).colorScheme.primary,
        enableHaptics: true,
      ),
      onTap: () => onChanged(!value),
    );
  }
}

class _TrustSectionHeader extends StatelessWidget {
  final String title;

  const _TrustSectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: Theme.of(context).colorScheme.primary,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _TrustDivider extends StatelessWidget {
  const _TrustDivider();

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      indent: 66,
      color: Theme.of(context).dividerColor.withValues(alpha: 0.22),
    );
  }
}

class _PassphraseStrengthMeter extends StatelessWidget {
  final String passphrase;

  const _PassphraseStrengthMeter({required this.passphrase});

  @override
  Widget build(BuildContext context) {
    final level = PassphraseStrength.level(passphrase);
    final fraction = PassphraseStrength.fraction(passphrase);
    final color = _strengthColor(context, level);
    final scheme = Theme.of(context).colorScheme;
    return GlassContainer(
      padding: const EdgeInsets.all(10),
      shape: const LiquidRoundedSuperellipse(borderRadius: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(_strengthIcon(level), size: 16, color: color),
              const SizedBox(width: 6),
              Text(
                PassphraseStrength.label(passphrase),
                style: TextStyle(fontWeight: FontWeight.w700, color: color),
              ),
              const Spacer(),
              Text(
                '${PassphraseStrength.estimateBits(passphrase).round()} bits',
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurface.withValues(alpha: 0.58),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) => Stack(
              children: [
                Container(
                  height: 7,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(99),
                    color: scheme.onSurface.withValues(alpha: 0.10),
                  ),
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  width: constraints.maxWidth * fraction,
                  height: 7,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(99),
                    gradient: LinearGradient(
                      colors: [color.withValues(alpha: 0.72), color],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Color _strengthColor(BuildContext context, PassphraseStrengthLevel level) {
    final scheme = Theme.of(context).colorScheme;
    return switch (level) {
      PassphraseStrengthLevel.tooShort => scheme.outline,
      PassphraseStrengthLevel.weak => scheme.error,
      PassphraseStrengthLevel.fair => Colors.orange,
      PassphraseStrengthLevel.good => Colors.teal,
      PassphraseStrengthLevel.strong => Colors.green,
    };
  }

  IconData _strengthIcon(PassphraseStrengthLevel level) => switch (level) {
    PassphraseStrengthLevel.tooShort => Icons.horizontal_rule_rounded,
    PassphraseStrengthLevel.weak => Icons.warning_amber_rounded,
    PassphraseStrengthLevel.fair => Icons.shield_outlined,
    PassphraseStrengthLevel.good => Icons.verified_user_outlined,
    PassphraseStrengthLevel.strong => Icons.verified_user_rounded,
  };
}

Color _levelColor(BuildContext context, TrustCenterLevel level) {
  return switch (level) {
    TrustCenterLevel.protected => Colors.green,
    TrustCenterLevel.review => Colors.orange,
    TrustCenterLevel.attention => Theme.of(context).colorScheme.error,
  };
}

IconData _conversationIcon(Conversation conversation) {
  if (conversation.isChannel) return Icons.campaign_outlined;
  if (conversation.isGroup) return Icons.group_outlined;
  return Icons.person_outline_rounded;
}

class _TrustTimelineItem {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final DateTime createdAt;

  const _TrustTimelineItem({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.createdAt,
  });
}

List<_TrustTimelineItem> _trustTimelineItems({
  required List<KeyTransparencyEvent> keyEvents,
  required Map<String, KeyTrustPin> keyPins,
  required List<Map<String, dynamic>> sessions,
}) {
  final items = <_TrustTimelineItem>[];
  for (final event in keyEvents) {
    final rotated = event.eventType == 'rotate';
    items.add(
      _TrustTimelineItem(
        icon: rotated
            ? Icons.change_circle_outlined
            : Icons.add_moderator_outlined,
        color: rotated ? Colors.orange : Colors.green,
        title: rotated ? 'Account key rotated' : 'Account key registered',
        subtitle: 'Sequence ${event.sequence} - ${_shortHash(event.eventHash)}',
        createdAt: event.createdAt,
      ),
    );
  }
  for (final pin in keyPins.values) {
    final hasWarning = pin.warning?.trim().isNotEmpty == true;
    items.add(
      _TrustTimelineItem(
        icon: hasWarning
            ? Icons.report_gmailerrorred_outlined
            : Icons.verified_outlined,
        color: hasWarning ? Colors.orange : Colors.green,
        title: hasWarning ? 'Contact key warning' : 'Contact key verified',
        subtitle: hasWarning
            ? pin.warning!.trim()
            : '${_shortHash(pin.userId)} - ${_shortHash(pin.fingerprint)}',
        createdAt: pin.pinnedAt,
      ),
    );
  }
  for (final session in sessions) {
    final seenAt =
        _dateFromJson(session['last_seen_at']) ??
        _dateFromJson(session['created_at']);
    if (seenAt == null) continue;
    items.add(
      _TrustTimelineItem(
        icon: Icons.devices_outlined,
        color: Colors.blue,
        title: 'Session active',
        subtitle: sessionDeviceDisplayLabel(session),
        createdAt: seenAt,
      ),
    );
  }
  items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return items.take(12).toList(growable: false);
}

String _sessionSubtitle(Map<String, dynamic> session) {
  final lastSeen = _relativeTime(session['last_seen_at']);
  final created = _relativeTime(session['created_at']);
  final ip = session['ip_address'] as String?;
  final parts = <String>[
    if (lastSeen != null) 'Last seen $lastSeen',
    if (created != null) 'Created $created',
    if (ip != null && ip.isNotEmpty) ip,
  ];
  return parts.isEmpty ? 'OpenChat session' : parts.join(' - ');
}

String? _relativeTime(Object? value) {
  final parsed = _dateFromJson(value);
  if (parsed == null) return value is String ? value : null;
  return timeago.format(parsed.toLocal());
}

DateTime? _dateFromJson(Object? value) {
  if (value is DateTime) return value.toLocal();
  if (value is! String || value.trim().isEmpty) return null;
  return DateTime.tryParse(value)?.toLocal();
}

String _shortHash(String hash) {
  final normalized = hash.trim();
  if (normalized.length <= 12) return normalized;
  return normalized.substring(0, 12);
}

// ── Social recovery ──────────────────────────────────────────────────────────

class _GuardianCandidate {
  final String userId;
  final String displayName;
  final String username;

  const _GuardianCandidate({
    required this.userId,
    required this.displayName,
    required this.username,
  });
}

String _recoveryUserLabel(Object? user, String fallbackId) {
  if (user is Map) {
    final username = user['username']?.toString() ?? '';
    if (username.isNotEmpty) return '@$username';
  }
  final id = fallbackId.trim();
  if (id.isEmpty) return 'Unknown user';
  return 'User ${id.length > 8 ? id.substring(0, 8) : id}';
}

/// Trust Center "Social Recovery" section: the user's own k-of-n guardian
/// configuration plus the accounts this device guards (and their pending
/// recovery ceremonies). Public so widget tests can pump it in isolation;
/// [TrustCenterScreen] embeds it.
///
/// HIDDEN ENTIRELY in [VaultMode.decoy]: a coerced (duress) session must not
/// reveal that recovery exists, who the guardians are, or whom the user
/// guards.
class SocialRecoverySection extends StatefulWidget {
  const SocialRecoverySection({
    super.key,
    this.localKeyMissing = false,
    this.service,
  });

  /// True when no local PGP key exists — the only state where starting a
  /// recovery ceremony from this device makes sense, so the "Recover with
  /// guardians" entry shows.
  final bool localKeyMissing;

  /// Test seam — defaults to a real service over the ambient storage.
  final SocialRecoveryService? service;

  @override
  State<SocialRecoverySection> createState() => _SocialRecoverySectionState();
}

class _SocialRecoverySectionState extends State<SocialRecoverySection> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _config; // null = unconfigured
  List<Map<String, dynamic>> _guarded = const [];
  Map<String, String> _heldShares = const {};
  List<Map<String, dynamic>> _pending = const [];
  StreamSubscription<Map<String, dynamic>>? _eventsSub;
  SocialRecoveryService? _serviceInstance;

  SocialRecoveryService get _service => _serviceInstance ??=
      widget.service ??
      SocialRecoveryService(storage: context.read<SecureStorageService>());

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // A contact we guard opened a ceremony — refresh the pending list live
      // while the screen is open.
      _eventsSub = context.read<ChatProvider>().recoveryEvents.listen((event) {
        if (event['kind'] == 'request') unawaited(_load());
      });
      unawaited(_load());
    });
  }

  @override
  void dispose() {
    _eventsSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    // Invisible in duress sessions — don't even fetch.
    if (vaultModeListenable.value == VaultMode.decoy) return;
    final api = context.read<ApiService>();
    final storage = context.read<SecureStorageService>();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait<Object?>([
        api.getRecoveryConfig(),
        api.listGuardedUsers(),
        api.listGuardianRecoveryRequests(),
        storage.listHeldRecoveryShares(),
      ]);
      if (!mounted) return;
      setState(() {
        _config = results[0] as Map<String, dynamic>?;
        _guarded = results[1] as List<Map<String, dynamic>>;
        _pending = results[2] as List<Map<String, dynamic>>;
        _heldShares = results[3] as Map<String, String>;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  // ── Setup / reconfigure flow ───────────────────────────────────────────────

  List<_GuardianCandidate> _guardianCandidates() {
    final chat = context.read<ChatProvider>();
    final selfId = chat.selfId ?? '';
    final seen = <String>{};
    final out = <_GuardianCandidate>[];
    for (final conv in chat.conversations) {
      if (!conv.isDM) continue;
      final other = conv.otherUser(selfId);
      if (other == null || other.id.isEmpty || other.id == selfId) continue;
      if (other.isBot) continue; // a bot cannot verify you over a call
      if (!seen.add(other.id)) continue;
      out.add(
        _GuardianCandidate(
          userId: other.id,
          displayName: other.displayName,
          username: other.username,
        ),
      );
    }
    return out;
  }

  Future<void> _startSetup({required bool reconfigure}) async {
    if (reconfigure) {
      var proceed = false;
      await GlassDialog.show<void>(
        context: context,
        title: 'Reconfigure social recovery?',
        message:
            'A new recovery secret is created and fresh shares go to the '
            'guardians you pick. Old shares stop working and any in-flight '
            'recovery ceremony is invalidated.',
        actions: [
          GlassDialogAction(
            label: 'Cancel',
            onPressed: () => Navigator.pop(context),
          ),
          GlassDialogAction(
            label: 'Continue',
            isPrimary: true,
            onPressed: () {
              proceed = true;
              Navigator.pop(context);
            },
          ),
        ],
      );
      if (!proceed || !mounted) return;
    }
    final candidates = _guardianCandidates();
    if (candidates.length < 2) {
      showAppToast(
        context,
        'You need direct chats with at least 2 contacts before setting up '
        'social recovery.',
        isError: true,
      );
      return;
    }
    final guardians = await _pickGuardians(candidates);
    if (guardians == null || guardians.length < 2 || !mounted) return;
    final threshold = await _pickThreshold(guardians.length);
    if (threshold == null || !mounted) return;

    var confirmed = false;
    await GlassDialog.show<void>(
      context: context,
      title: 'Set up social recovery?',
      message:
          'Your keys are encrypted into a recovery bundle stored on the '
          'server. The decryption secret is split into ${guardians.length} '
          'shares — one is sent to each guardian as an encrypted message. '
          'Any $threshold of them together can restore your account; fewer '
          'than $threshold learn nothing. The server never sees your keys '
          'or a usable share.',
      actions: [
        GlassDialogAction(
          label: 'Cancel',
          onPressed: () => Navigator.pop(context),
        ),
        GlassDialogAction(
          label: 'Encrypt & send',
          isPrimary: true,
          onPressed: () {
            confirmed = true;
            Navigator.pop(context);
          },
        ),
      ],
    );
    if (!confirmed || !mounted) return;
    await _configureAndDeliver(guardians: guardians, threshold: threshold);
  }

  Future<List<_GuardianCandidate>?> _pickGuardians(
    List<_GuardianCandidate> candidates,
  ) {
    final selected = <String>{};
    return showModalBottomSheet<List<_GuardianCandidate>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheet) {
          final scheme = Theme.of(sheetCtx).colorScheme;
          return GlassBottomSheetFrame(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const GlassSheetGrabber(),
                GlassSheetHeader(
                  icon: Icons.diversity_3_outlined,
                  title: 'Choose guardians',
                  subtitle:
                      'Pick 2–10 contacts you trust to verify you over a call',
                  onClose: () => Navigator.pop(sheetCtx),
                ),
                for (final candidate in candidates)
                  GlassListTile(
                    leading: CircleAvatar(
                      child: Text(
                        candidate.displayName.isNotEmpty
                            ? candidate.displayName
                                  .replaceFirst('@', '')
                                  .substring(0, 1)
                                  .toUpperCase()
                            : '?',
                      ),
                    ),
                    title: Text(candidate.displayName),
                    subtitle: Text('@${candidate.username}'),
                    trailing: Icon(
                      selected.contains(candidate.userId)
                          ? Icons.check_circle_rounded
                          : Icons.circle_outlined,
                      color: selected.contains(candidate.userId)
                          ? scheme.primary
                          : scheme.onSurface.withValues(alpha: 0.35),
                    ),
                    onTap: () => setSheet(() {
                      if (selected.contains(candidate.userId)) {
                        selected.remove(candidate.userId);
                      } else if (selected.length < 10) {
                        selected.add(candidate.userId);
                      } else {
                        showAppToast(
                          sheetCtx,
                          'A maximum of 10 guardians is supported',
                          isError: true,
                        );
                      }
                    }),
                  ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: GlassButtonWidget(
                    onPressed: selected.length >= 2
                        ? () => Navigator.pop(sheetCtx, [
                            for (final candidate in candidates)
                              if (selected.contains(candidate.userId))
                                candidate,
                          ])
                        : null,
                    child: Text(
                      selected.length < 2
                          ? 'Select at least 2 guardians'
                          : 'Continue with ${selected.length} guardians',
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<int?> _pickThreshold(int guardianCount) {
    final majority = (guardianCount ~/ 2) + 1;
    var threshold = majority;
    return showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheet) {
          final scheme = Theme.of(sheetCtx).colorScheme;
          return GlassBottomSheetFrame(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const GlassSheetGrabber(),
                GlassSheetHeader(
                  icon: Icons.pin_outlined,
                  title: 'How many approvals?',
                  subtitle:
                      'Guardians who must approve together to recover your '
                      'account',
                  onClose: () => Navigator.pop(sheetCtx),
                ),
                for (var k = 2; k <= guardianCount; k++)
                  GlassListTile(
                    title: Text('$k of $guardianCount guardians'),
                    subtitle: k == majority
                        ? const Text('Recommended — a majority')
                        : null,
                    trailing: Icon(
                      threshold == k
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_off_rounded,
                      color: threshold == k
                          ? scheme.primary
                          : scheme.onSurface.withValues(alpha: 0.35),
                    ),
                    onTap: () => setSheet(() => threshold = k),
                  ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: GlassButtonWidget(
                    onPressed: () => Navigator.pop(sheetCtx, threshold),
                    child: const Text('Continue'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _configureAndDeliver({
    required List<_GuardianCandidate> guardians,
    required int threshold,
  }) async {
    final api = context.read<ApiService>();
    final chat = context.read<ChatProvider>();
    final storage = context.read<SecureStorageService>();
    final selfId = chat.selfId ?? await storage.getUserID() ?? '';
    if (selfId.isEmpty) {
      if (mounted) {
        showAppToast(
          context,
          'Could not determine your user id',
          isError: true,
        );
      }
      return;
    }
    if (!mounted) return;
    Map<String, String> deliveries;
    try {
      deliveries = await _service.configure(
        api: api,
        selfUserId: selfId,
        guardianUserIds: [for (final g in guardians) g.userId],
        threshold: threshold,
      );
    } catch (e) {
      if (mounted) {
        showAppToast(context, 'Recovery setup failed: $e', isError: true);
      }
      return;
    }
    if (!mounted) return;
    // Configuration now exists server-side; every guardian MUST receive their
    // share or they cannot help. The sheet sends one by one, surfaces
    // per-guardian failures, and offers retries.
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      builder: (_) => _ShareDeliverySheet(
        guardians: guardians,
        deliveries: deliveries,
        chat: chat,
      ),
    );
    await _load();
  }

  Future<void> _disable() async {
    final api = context.read<ApiService>();
    var confirmed = false;
    await GlassDialog.show<void>(
      context: context,
      title: 'Disable social recovery?',
      message:
          'The encrypted recovery bundle is deleted from the server and your '
          'guardians\' shares become useless. After this, losing your keys '
          'is unrecoverable without another backup.',
      actions: [
        GlassDialogAction(
          label: 'Cancel',
          onPressed: () => Navigator.pop(context),
        ),
        GlassDialogAction(
          label: 'Disable',
          isDestructive: true,
          onPressed: () {
            confirmed = true;
            Navigator.pop(context);
          },
        ),
      ],
    );
    if (!confirmed || !mounted) return;
    try {
      await api.deleteRecovery();
      if (mounted) showAppToast(context, 'Social recovery disabled');
    } catch (e) {
      if (mounted) showAppToast(context, 'Failed: $e', isError: true);
    }
    await _load();
  }

  // ── Guardian side ──────────────────────────────────────────────────────────

  Future<void> _openApproveSheet(Map<String, dynamic> request) async {
    final api = context.read<ApiService>();
    final requestId = request['id']?.toString() ?? '';
    final ownerUserId = request['user_id']?.toString() ?? '';
    final ephemeralPubkey = request['ephemeral_pubkey']?.toString() ?? '';
    final approved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => GuardianApproveSheet(
        requesterName: _recoveryUserLabel(request['user'], ownerUserId),
        ephemeralPubkeyArmored: ephemeralPubkey,
        recentRequestCount:
            (request['recent_request_count'] as num?)?.toInt() ?? 1,
        onApprove: () => _service.approveRequest(
          api: api,
          requestId: requestId,
          ownerUserId: ownerUserId,
          ephemeralPubkeyArmored: ephemeralPubkey,
        ),
      ),
    );
    if (approved == true && mounted) {
      showAppToast(context, 'Recovery share submitted');
      await _load();
    }
  }

  // ── UI ─────────────────────────────────────────────────────────────────────

  List<Widget> _ownConfigRows(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = <Widget>[];
    if (_error != null) {
      rows.add(
        _TrustRow(
          icon: Icons.error_outline_rounded,
          iconColor: scheme.error,
          title: 'Could not load recovery status',
          subtitle: 'Tap to retry — $_error',
          onTap: _load,
        ),
      );
    } else if (_loading && _config == null) {
      rows.add(
        const _TrustRow(
          icon: Icons.diversity_3_outlined,
          title: 'Social recovery',
          subtitle: 'Checking your configuration',
          trailing: GlassProgressIndicator.circular(size: 18, strokeWidth: 2),
        ),
      );
    } else if (_config == null) {
      rows.add(
        const _TrustRow(
          icon: Icons.diversity_3_outlined,
          iconColor: Colors.orange,
          title: 'Social recovery off',
          subtitle:
              'Key loss is unrecoverable without a backup. Let a few trusted '
              'contacts guard encrypted shares of your keys — enough of them '
              'together can restore your account, fewer learn nothing.',
          trailing: _StatusPill(label: 'Off', color: Colors.orange),
        ),
      );
      rows.add(const _TrustDivider());
      rows.add(
        _TrustRow(
          icon: Icons.group_add_outlined,
          title: 'Set up social recovery',
          subtitle: 'Pick 2–10 guardians and an approval threshold',
          onTap: () => _startSetup(reconfigure: false),
        ),
      );
    } else {
      final config = _config!;
      final guardianCount =
          ((config['guardian_ids'] as List?) ?? const []).length;
      final threshold = (config['threshold'] as num?)?.toInt() ?? 0;
      final updatedAt = _dateFromJson(config['updated_at']);
      rows.add(
        _TrustRow(
          icon: Icons.diversity_3_outlined,
          iconColor: Colors.green,
          title: 'Social recovery on',
          subtitle:
              '$threshold of $guardianCount guardians needed'
              '${updatedAt != null ? ' - updated ${timeago.format(updatedAt)}' : ''}',
          trailing: const _StatusPill(label: 'On', color: Colors.green),
        ),
      );
      rows.add(const _TrustDivider());
      rows.add(
        _TrustRow(
          icon: Icons.published_with_changes_rounded,
          title: 'Reconfigure',
          subtitle: 'Pick guardians again and re-send fresh shares',
          onTap: () => _startSetup(reconfigure: true),
        ),
      );
      rows.add(const _TrustDivider());
      rows.add(
        _TrustRow(
          icon: Icons.gpp_bad_outlined,
          iconColor: scheme.error,
          title: 'Disable social recovery',
          subtitle: 'Delete the recovery bundle and guardian set',
          onTap: _disable,
        ),
      );
    }
    if (widget.localKeyMissing) {
      rows.add(const _TrustDivider());
      rows.add(
        _TrustRow(
          icon: Icons.key_off_outlined,
          iconColor: Colors.orange,
          title: 'Recover with guardians',
          subtitle: 'No local key — start a recovery ceremony',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => const SocialRecoveryScreen(),
            ),
          ),
        ),
      );
    }
    return rows;
  }

  List<Widget> _guardianRows(BuildContext context) {
    final rows = <Widget>[];
    final guardedIds = <String>{};
    for (final guarded in _guarded) {
      final ownerId = guarded['user_id']?.toString() ?? '';
      if (ownerId.isEmpty) continue;
      guardedIds.add(ownerId);
      final held = _heldShares.containsKey(ownerId);
      rows.add(
        _TrustRow(
          icon: Icons.person_outline_rounded,
          iconColor: held ? Colors.green : Colors.orange,
          title: _recoveryUserLabel(guarded['user'], ownerId),
          subtitle: held
              ? 'Share held on this device'
              : 'Share missing on this device — ask them to reconfigure',
          trailing: _StatusPill(
            label: held ? 'Held' : 'Missing',
            color: held ? Colors.green : Colors.orange,
          ),
        ),
      );
    }
    // Shares held for accounts the server no longer lists (e.g. the owner
    // disabled recovery) — still show them, the data lives on this device.
    for (final ownerId in _heldShares.keys) {
      if (guardedIds.contains(ownerId)) continue;
      rows.add(
        _TrustRow(
          icon: Icons.person_outline_rounded,
          iconColor: Colors.green,
          title: _recoveryUserLabel(null, ownerId),
          subtitle: 'Share held on this device',
          trailing: const _StatusPill(label: 'Held', color: Colors.green),
        ),
      );
    }
    if (rows.isEmpty) {
      rows.add(
        const _TrustRow(
          icon: Icons.volunteer_activism_outlined,
          title: 'You guard no one yet',
          subtitle:
              'When a contact picks you as a guardian, their encrypted share '
              'appears here.',
          trailing: SizedBox.shrink(),
        ),
      );
    }
    for (final request in _pending) {
      final ownerId = request['user_id']?.toString() ?? '';
      rows.add(const _TrustDivider());
      rows.add(
        _TrustRow(
          icon: Icons.notification_important_outlined,
          iconColor: Colors.orange,
          title:
              '${_recoveryUserLabel(request['user'], ownerId)} is recovering',
          subtitle: 'Verify the words or code with them, then approve',
          trailing: const _StatusPill(label: 'Review', color: Colors.orange),
          onTap: () => _openApproveSheet(request),
        ),
      );
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VaultMode>(
      // The whole section — own config, guarded accounts, pending ceremonies
      // — must be invisible in a duress (decoy) session.
      valueListenable: vaultModeListenable,
      builder: (context, vaultMode, _) {
        if (vaultMode == VaultMode.decoy) return const SizedBox.shrink();
        final ownRows = _ownConfigRows(context);
        final guardianRows = _guardianRows(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _TrustSectionHeader('Social Recovery'),
            GlassCard(
              padding: EdgeInsets.zero,
              child: Column(children: ownRows),
            ),
            const SizedBox(height: 20),
            const _TrustSectionHeader('You Guard'),
            GlassCard(
              padding: EdgeInsets.zero,
              child: Column(children: guardianRows),
            ),
            const SizedBox(height: 20),
          ],
        );
      },
    );
  }
}

enum _DeliveryStatus { pending, sending, sent, failed }

/// Sends one Shamir share per guardian as a hidden E2EE message, with
/// per-guardian sent/failed state and retries. A guardian who never receives
/// their share cannot help recover, so this sheet stays up (non-dismissible)
/// until the user explicitly closes it.
class _ShareDeliverySheet extends StatefulWidget {
  const _ShareDeliverySheet({
    required this.guardians,
    required this.deliveries,
    required this.chat,
  });

  final List<_GuardianCandidate> guardians;
  final Map<String, String> deliveries;
  final ChatProvider chat;

  @override
  State<_ShareDeliverySheet> createState() => _ShareDeliverySheetState();
}

class _ShareDeliverySheetState extends State<_ShareDeliverySheet> {
  late final Map<String, _DeliveryStatus> _status = {
    for (final g in widget.guardians) g.userId: _DeliveryStatus.pending,
  };
  final Map<String, String> _errors = {};
  bool _running = false;

  bool get _allSent =>
      _status.values.every((status) => status == _DeliveryStatus.sent);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_sendPending());
    });
  }

  Future<void> _sendPending() async {
    if (_running) return;
    _running = true;
    try {
      for (final guardian in widget.guardians) {
        final status = _status[guardian.userId];
        if (status == _DeliveryStatus.sent ||
            status == _DeliveryStatus.sending) {
          continue;
        }
        await _sendOne(guardian.userId);
      }
    } finally {
      _running = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _sendOne(String guardianUserId) async {
    final shareJson = widget.deliveries[guardianUserId];
    if (shareJson == null) return;
    if (mounted) {
      setState(() {
        _status[guardianUserId] = _DeliveryStatus.sending;
        _errors.remove(guardianUserId);
      });
    }
    try {
      await widget.chat.sendRecoveryShare(guardianUserId, shareJson);
      if (mounted) {
        setState(() => _status[guardianUserId] = _DeliveryStatus.sent);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _status[guardianUserId] = _DeliveryStatus.failed;
          _errors[guardianUserId] = e.toString();
        });
      }
    }
  }

  Widget _trailingFor(String guardianUserId) {
    final scheme = Theme.of(context).colorScheme;
    return switch (_status[guardianUserId]!) {
      _DeliveryStatus.pending => Icon(
        Icons.schedule_rounded,
        size: 18,
        color: scheme.onSurface.withValues(alpha: 0.4),
      ),
      _DeliveryStatus.sending => const GlassProgressIndicator.circular(
        size: 18,
        strokeWidth: 2,
      ),
      _DeliveryStatus.sent => const Icon(
        Icons.check_circle_rounded,
        size: 20,
        color: Colors.green,
      ),
      _DeliveryStatus.failed => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline_rounded, size: 20, color: scheme.error),
          IconButton(
            icon: const Icon(Icons.refresh_rounded, size: 20),
            tooltip: 'Retry',
            onPressed: () => _sendOne(guardianUserId),
          ),
        ],
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final anyFailed = _status.values.contains(_DeliveryStatus.failed);
    return GlassBottomSheetFrame(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const GlassSheetGrabber(),
          const GlassSheetHeader(
            icon: Icons.send_outlined,
            title: 'Delivering shares',
            subtitle:
                'Each guardian receives their encrypted share as a hidden '
                'message',
          ),
          for (final guardian in widget.guardians)
            GlassListTile(
              leading: CircleAvatar(
                child: Text(
                  guardian.displayName.isNotEmpty
                      ? guardian.displayName
                            .replaceFirst('@', '')
                            .substring(0, 1)
                            .toUpperCase()
                      : '?',
                ),
              ),
              title: Text(guardian.displayName),
              subtitle: Text(
                _errors[guardian.userId] ?? '@${guardian.username}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: _trailingFor(guardian.userId),
            ),
          if (anyFailed)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
              child: Text(
                'A guardian who never receives their share cannot help you '
                'recover. Retry the failed deliveries before closing.',
                style: TextStyle(fontSize: 12, color: scheme.error),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: GlassButtonWidget(
              onPressed: _running ? null : () => Navigator.pop(context),
              child: Text(
                _allSent
                    ? 'Done'
                    : anyFailed
                    ? 'Close anyway'
                    : 'Close',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom sheet a guardian reviews before submitting their share to a
/// recovery ceremony. Public so widget tests can pump it directly.
///
/// The verification code derives from the ceremony's EPHEMERAL key — the
/// guardian must hear it from the recovering person over a call or in person
/// before approving, otherwise anyone holding the account password (or a
/// malicious server swapping the key) could collect shares.
class GuardianApproveSheet extends StatefulWidget {
  const GuardianApproveSheet({
    super.key,
    required this.requesterName,
    required this.ephemeralPubkeyArmored,
    required this.onApprove,
    this.recentRequestCount = 1,
    this.codeLoader = SocialRecoveryService.verificationCode,
    this.wordsLoader = SocialRecoveryService.verificationWords,
  });

  final String requesterName;
  final String ephemeralPubkeyArmored;
  final int recentRequestCount;

  /// Performs the actual share submission ([SocialRecoveryService
  /// .approveRequest]). Injected so tests can verify the wiring without the
  /// PGP bridge. A thrown [StateError]'s message is shown verbatim.
  final Future<void> Function() onApprove;

  /// Computes the verification code from the ephemeral pubkey. Defaults to
  /// [SocialRecoveryService.verificationCode]; injectable because PgpService
  /// is unavailable in widget tests.
  final Future<String> Function(String armored) codeLoader;

  /// Computes the read-aloud verification words from the ephemeral pubkey.
  /// Defaults to [SocialRecoveryService.verificationWords]; injectable because
  /// PgpService is unavailable in widget tests.
  final Future<List<String>> Function(String armored) wordsLoader;

  @override
  State<GuardianApproveSheet> createState() => _GuardianApproveSheetState();
}

class _GuardianApproveSheetState extends State<GuardianApproveSheet> {
  late final Future<String> _codeFuture;
  late final Future<List<String>> _wordsFuture;
  bool _submitting = false;
  bool _verified = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _codeFuture = widget.codeLoader(widget.ephemeralPubkeyArmored);
    _wordsFuture = widget.wordsLoader(widget.ephemeralPubkeyArmored);
  }

  Future<void> _approve() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.onApprove();
      if (mounted) Navigator.pop(context, true);
    } on StateError catch (e) {
      // User-readable by contract, e.g. "You hold no recovery share for this
      // account on this device."
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = 'Approval failed: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassBottomSheetFrame(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const GlassSheetGrabber(),
          GlassSheetHeader(
            icon: Icons.health_and_safety_outlined,
            title: 'Approve recovery',
            subtitle: '${widget.requesterName} is recovering their account',
            onClose: () => Navigator.pop(context, false),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'VERIFICATION WORDS',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(height: 10),
                FutureBuilder<List<String>>(
                  future: _wordsFuture,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return Text(
                        'Could not compute the words: ${snapshot.error}',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.error, fontSize: 13),
                      );
                    }
                    if (!snapshot.hasData) {
                      return const Center(
                        child: GlassProgressIndicator.circular(
                          size: 22,
                          strokeWidth: 2,
                        ),
                      );
                    }
                    return Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final word in snapshot.data!)
                          GlassChip(label: word),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),
                Text(
                  'VERIFICATION CODE',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(height: 10),
                FutureBuilder<String>(
                  future: _codeFuture,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return Text(
                        'Could not compute the code: ${snapshot.error}',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.error, fontSize: 13),
                      );
                    }
                    if (!snapshot.hasData) {
                      return const Center(
                        child: GlassProgressIndicator.circular(
                          size: 22,
                          strokeWidth: 2,
                        ),
                      );
                    }
                    return Text(
                      snapshot.data!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2,
                      ),
                    );
                  },
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.orange.withValues(alpha: 0.30),
                    ),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        color: Colors.orange,
                        size: 20,
                      ),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Only approve if you have verified these words or '
                          'this code with them over a call or in person. '
                          'Anyone with their password could be impersonating them.',
                          style: TextStyle(fontSize: 13, height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
                if (widget.recentRequestCount > 1) ...[
                  const SizedBox(height: 12),
                  Container(
                    key: const Key('guardian-recent-requests-warning'),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: scheme.primary.withValues(alpha: 0.20),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.info_outline_rounded,
                          color: scheme.primary,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'This account has requested recovery '
                            '${widget.recentRequestCount} times in the last '
                            '24 hours — be extra sure before approving.',
                            style: const TextStyle(fontSize: 13, height: 1.4),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                IgnorePointer(
                  ignoring: _submitting,
                  child: Opacity(
                    opacity: _submitting ? 0.55 : 1,
                    child: GlassListTile(
                      leading: Icon(
                        Icons.verified_user_outlined,
                        color: scheme.primary,
                      ),
                      title: Text(
                        'I verified these words or this code with '
                        '${widget.requesterName} over a call or in person',
                      ),
                      trailing: GlassSwitch(
                        key: const Key('guardian-verified-switch'),
                        value: _verified,
                        onChanged: (value) {
                          if (_submitting) return;
                          setState(() => _verified = value);
                        },
                        activeColor: scheme.primary,
                        enableHaptics: true,
                      ),
                      onTap: _submitting
                          ? null
                          : () => setState(() => _verified = !_verified),
                      showDivider: false,
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.error, fontSize: 13),
                  ),
                ],
                const SizedBox(height: 16),
                GlassButtonWidget(
                  onPressed: (_submitting || !_verified) ? null : _approve,
                  child: _submitting
                      ? const GlassProgressIndicator.circular(
                          size: 18,
                          strokeWidth: 2,
                        )
                      : const Text('Approve and send share'),
                ),
                TextButton(
                  onPressed: _submitting
                      ? null
                      : () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
