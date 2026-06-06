import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:provider/provider.dart';
import 'package:timeago/timeago.dart' as timeago;

import '../../models/conversation.dart';
import '../../models/key_transparency_event.dart';
import '../../models/key_trust_pin.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/key_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/api_service.dart';
import '../../services/mls_service.dart';
import '../../services/secure_storage_service.dart';
import '../../utils/account_security_duration.dart';
import '../../utils/device_label.dart';
import '../../utils/identity_qr.dart';
import '../../utils/trust_center_summary.dart';
import '../../widgets/glass.dart';
import 'identity_qr_scanner_screen.dart';
import 'pgp_keys_screen.dart';

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
  bool _loading = true;
  Map<String, dynamic> _security = const {};
  List<Map<String, dynamic>> _sessions = const [];
  Map<String, KeyTrustPin> _keyPins = const {};
  List<KeyTransparencyEvent> _keyEvents = const [];
  MlsSignerStorage? _mlsSigner;
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
      var keyEvents = <KeyTransparencyEvent>[];
      MlsSignerStorage? mlsSigner;
      if (user != null) {
        try {
          keyEvents = await api.getKeyTransparencyEvents(user.id);
        } catch (_) {
          keyEvents = const [];
        }
        mlsSigner = await storage.getMlsSigner(user.id);
      }
      if (!mounted) return;
      setState(() {
        _biometricAvailable = biometricAvailable;
        _biometricEnabled = results[0] as bool;
        _appLockEnabled = results[1] as bool;
        _security = results[2] as Map<String, dynamic>;
        _sessions = results[3] as List<Map<String, dynamic>>;
        _keyPins = keyPins;
        _keyEvents = keyEvents;
        _mlsSigner = mlsSigner;
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
      await context.read<MlsService>().ensureIdentityForCurrentUser();
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
    final mlsSignerSigned =
        (_mlsSigner?.publicKey.trim().isNotEmpty ?? false) &&
        (_mlsSigner?.signature.trim().isNotEmpty ?? false);
    final summary = evaluateTrustCenter(
      hasLocalKey: keys.hasKey,
      accountKeyExpired: user?.isKeyExpired ?? false,
      fingerprintMatchesAccount: fingerprintMatches,
      twoFactorEnabled: twoFactorEnabled,
      appLockEnabled: _appLockEnabled,
      biometricAvailable: _biometricAvailable,
      biometricKeyExportEnabled: _biometricEnabled,
      allowGroupAdd: user?.allowGroupAdd ?? true,
      notificationSensitiveContent: settings.notificationSensitiveContent,
      pushNotificationsEnabled: settings.pushNotificationsEnabled,
      unencryptedConversations: unencrypted.length,
      keyTransparencyWarnings: keyWarnings.length,
    );
    final timelineItems = _trustTimelineItems(
      keyEvents: _keyEvents,
      keyPins: _keyPins,
      sessions: _sessions,
    );

    return Scaffold(
      appBar: GlassAppBar(
        title: const Text('Trust Center'),
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
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            _TrustHero(summary: summary, loading: _loading, error: _error),
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
                    iconColor: latestKeyEvent == null
                        ? Colors.orange
                        : Colors.green,
                    title: 'Key transparency log',
                    subtitle: latestKeyEvent == null
                        ? 'No account key event seen yet'
                        : '${_keyEvents.length} event${_keyEvents.length == 1 ? '' : 's'}; latest ${_shortHash(latestKeyEvent.eventHash)}',
                    trailing: _StatusPill(
                      label: latestKeyEvent == null ? 'No log' : 'Logged',
                      color: latestKeyEvent == null
                          ? Colors.orange
                          : Colors.green,
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
                ],
              ),
            ),
            const SizedBox(height: 20),
            const _TrustSectionHeader('Devices'),
            GlassCard(
              padding: EdgeInsets.zero,
              child: _sessions.isEmpty
                  ? _TrustRow(
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
                      isLast: true,
                    )
                  : Column(
                      children: [
                        for (var index = 0; index < _sessions.length; index++)
                          _TrustRow(
                            icon: Icons.devices_outlined,
                            title: sessionDeviceDisplayLabel(_sessions[index]),
                            subtitle: _sessionSubtitle(_sessions[index]),
                            trailing: IconButton(
                              icon: const Icon(Icons.logout_outlined),
                              tooltip: 'Revoke session',
                              onPressed: () => _revokeSession(_sessions[index]),
                            ),
                            isLast: index == _sessions.length - 1,
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
                        'Disable typing, read receipts, link previews, and link opens; when off, typing and read receipts use classic metadata',
                    value: settings.strictPrivacyMode,
                    onChanged: settings.setStrictPrivacyMode,
                  ),
                  const _TrustDivider(),
                  _TrustSwitchRow(
                    icon: Icons.visibility_outlined,
                    title: 'Sensitive notification content',
                    subtitle: 'Show sender and previews in notifications',
                    value: settings.notificationSensitiveContent,
                    onChanged: settings.setNotificationSensitiveContent,
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
    return ClipRRect(
      borderRadius: BorderRadius.vertical(
        bottom: isLast ? const Radius.circular(22) : Radius.zero,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color.withValues(alpha: 0.12),
                  ),
                  child: Icon(icon, size: 18, color: color),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurface.withValues(alpha: 0.55),
                            height: 1.3,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                trailing ??
                    Icon(
                      CupertinoIcons.chevron_forward,
                      size: 14,
                      color: scheme.onSurface.withValues(alpha: 0.35),
                    ),
              ],
            ),
          ),
        ),
      ),
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
