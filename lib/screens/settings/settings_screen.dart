import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_selector/file_selector.dart';
import 'package:image_picker/image_picker.dart';
import 'package:local_auth/local_auth.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import '../../config/api_config.dart';
import '../../crypto/pgp_service.dart';
import '../../providers/auth_provider.dart';
import '../../providers/key_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/api_service.dart';
import '../../services/app_lock_state.dart';
import '../../services/background_ws_service.dart';
import '../../services/encrypted_backup_service.dart';
import '../../services/local_private_state_service.dart';
import '../../services/notification_service.dart';
import '../../services/passphrase_strength.dart';
import '../../services/push_notification_service.dart';
import '../../services/secure_storage_service.dart';
import '../../utils/account_security_duration.dart';
import '../../utils/backup_staleness.dart';
import '../../utils/device_label.dart';
import '../../widgets/glass.dart';
import '../bots/bot_management_screen.dart';
import '../custom_emojis/custom_emoji_pack_screen.dart';
import '../mini_apps/mini_apps_screen.dart';
import '../stickers/sticker_pack_screen.dart';
import 'device_pairing_screen.dart';
import 'pgp_keys_screen.dart';
import 'premium_screen.dart';
import '../../services/mesh/nearby_mesh_service.dart';
import '../nearby/nearby_screen.dart';
import 'on_device_ai_screen.dart';
import 'proxy_settings_screen.dart';
import 'social_recovery_screen.dart';
import 'trust_center_screen.dart';
import 'wallet_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _auth = LocalAuthentication();
  bool _biometricAvailable = false;
  bool _biometricEnabled = false;
  bool _appLockEnabled = false;
  bool _appPinConfigured = false;
  bool _duressPinConfigured = false;
  String _duressAction = 'decoy';
  int _deadmanDays = 0;
  DateTime? _lastBackupAt;
  late final Future<PackageInfo> _packageInfoFuture;

  @override
  void initState() {
    super.initState();
    _packageInfoFuture = PackageInfo.fromPlatform();
    _loadSecurityPrefs();
    _loadBackupMeta();
  }

  Future<void> _loadBackupMeta() async {
    try {
      final at = await EncryptedBackupService(
        storage: context.read<SecureStorageService>(),
      ).latestBackupTimestamp(api: context.read<ApiService>());
      if (mounted) setState(() => _lastBackupAt = at);
    } catch (_) {
      // Best-effort: a metadata failure just leaves the generic subtitle.
    }
  }

  Future<void> _loadSecurityPrefs() async {
    final storage = context.read<SecureStorageService>();
    final available = await _biometricsAvailable();
    final biometricEnabled = await storage.getBiometricEnabled();
    final appLockEnabled = await storage.getAppLockEnabled();
    final appPinConfigured = await storage.hasAppLockPin();
    final duressPinConfigured = await storage.hasDuressPin();
    final duressAction = await storage.getDuressAction();
    final deadmanDays = await storage.getDeadmanDays();
    if (mounted) {
      setState(() {
        _biometricAvailable = available;
        _biometricEnabled = biometricEnabled;
        _appLockEnabled = appLockEnabled;
        _appPinConfigured = appPinConfigured;
        _duressPinConfigured = duressPinConfigured;
        _duressAction = duressAction;
        _deadmanDays = deadmanDays;
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

  Future<void> _setBiometric(bool value) async {
    final messenger = ScaffoldMessenger.of(context);
    if (value) {
      try {
        final ok = await _auth.authenticate(
          localizedReason: 'Authenticate to enable biometric key unlock',
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
    final storage = context.read<SecureStorageService>();
    await storage.setBiometricEnabled(value);
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
    final storage = context.read<SecureStorageService>();
    await storage.setAppLockEnabled(value);
    if (mounted) setState(() => _appLockEnabled = value);
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
      title: 'Dead-man switch',
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
    await context.read<SecureStorageService>().setDeadmanDays(choice!);
    if (mounted) setState(() => _deadmanDays = choice!);
  }

  Future<void> _setPushEnabled(bool value, SettingsProvider settings) async {
    final messenger = ScaffoldMessenger.of(context);
    final api = context.read<ApiService>();

    if (value) {
      // Show privacy warning before enabling.
      var confirmed = false;
      await GlassDialog.show<void>(
        context: context,
        title: 'Privacy notice',
        message:
            'Push notifications route metadata (sender, device ID) '
            'through Google Firebase servers. No message content is sent.\n\n'
            'For full metadata privacy, use Background WebSocket instead.',
        actions: [
          GlassDialogAction(
            label: 'Cancel',
            onPressed: () => Navigator.pop(context),
          ),
          GlassDialogAction(
            label: 'Enable',
            isPrimary: true,
            onPressed: () {
              confirmed = true;
              Navigator.pop(context);
            },
          ),
        ],
      );
      if (!confirmed || !mounted) return;

      // Disable WebSocket background before enabling push — only one
      // notification channel should be active at a time.
      if (settings.wsBackgroundEnabled) {
        await BackgroundWsService.stop();
        await settings.setWsBackgroundEnabled(false);
      }

      final result = await PushNotificationService.initDetailed(api: api);
      if (!mounted) return;
      if (!result.success) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              PushNotificationService.messageForInitFailure(
                result.failure ?? PushNotificationInitFailure.unsupported,
              ),
            ),
          ),
        );
        return;
      }
    } else {
      await PushNotificationService.disable(api: api);
    }

    await settings.setPushNotificationsEnabled(value);
  }

  Future<void> _setWsBackground(bool value, SettingsProvider settings) async {
    final messenger = ScaffoldMessenger.of(context);
    if (value) {
      // Show battery warning before enabling.
      var confirmed = false;
      await GlassDialog.show<void>(
        context: context,
        title: 'Battery notice',
        message:
            'Background WebSocket keeps a live connection even when the '
            'app is closed, providing real-time notifications without '
            'Firebase.',
        actions: [
          GlassDialogAction(
            label: 'Cancel',
            onPressed: () => Navigator.pop(context),
          ),
          GlassDialogAction(
            label: 'Enable',
            isPrimary: true,
            onPressed: () {
              confirmed = true;
              Navigator.pop(context);
            },
          ),
        ],
      );
      if (!confirmed || !mounted) return;

      // Disable Firebase push before enabling WebSocket — only one
      // notification channel should be active at a time.
      if (settings.pushNotificationsEnabled) {
        final api = context.read<ApiService>();
        await PushNotificationService.disable(api: api);
        await settings.setPushNotificationsEnabled(false);
      }

      // Request local-notification permission. On iOS this shows the system
      // prompt; on Android 13+ it requests POST_NOTIFICATIONS at runtime.
      // firebase_messaging is NOT involved here, so we must ask ourselves.
      if (!mounted) return;
      final permitted = await NotificationService.requestPermission();
      if (!mounted) return;
      if (!permitted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Notification permission is required for background notifications.',
            ),
          ),
        );
        return;
      }

      final storage = context.read<SecureStorageService>();
      final token = await storage.getAccessToken() ?? '';
      final started = await BackgroundWsService.start(
        accessToken: token,
        showSensitive: settings.notificationSensitiveContent,
        conversationNotificationPreferences:
            settings.conversationNotificationPreferences,
      );
      if (!mounted) return;
      if (!started) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Background WebSocket could not start. Try again.'),
          ),
        );
        return;
      }
    } else {
      await BackgroundWsService.stop();
    }

    await settings.setWsBackgroundEnabled(value);
  }

  void _editProfile() {
    final user = context.read<AuthProvider>().currentUser;
    if (user == null) return;
    final api = context.read<ApiService>();
    final auth = context.read<AuthProvider>();
    final messenger = ScaffoldMessenger.of(context);

    final displayNameCtrl = TextEditingController(
      text: user.profileDisplayName ?? '',
    );
    final usernameCtrl = TextEditingController(text: user.username);
    final bioCtrl = TextEditingController(text: user.bio ?? '');
    String? pendingAvatarUrl = user.avatarUrl;
    bool uploading = false;

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDialog) {
          Future<void> pickAndUpload() async {
            final picked = await ImagePicker().pickImage(
              source: ImageSource.gallery,
              imageQuality: 90,
            );
            if (picked == null) return;
            setStateDialog(() => uploading = true);
            try {
              final bytes = await picked.readAsBytes();
              final url = await api.uploadAvatar(
                fileBytes: bytes,
                filename: picked.name,
              );
              setStateDialog(() {
                pendingAvatarUrl = url;
                uploading = false;
              });
            } catch (e) {
              setStateDialog(() => uploading = false);
              messenger.showSnackBar(
                SnackBar(content: Text('Upload failed: $e')),
              );
            }
          }

          return GlassAlertDialog(
            title: const Text('Edit Profile'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  GestureDetector(
                    onTap: uploading ? null : pickAndUpload,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        CircleAvatar(
                          radius: 40,
                          backgroundImage: pendingAvatarUrl != null
                              ? CachedNetworkImageProvider(
                                  ApiConfig.resolveMedia(pendingAvatarUrl!),
                                )
                              : null,
                          child: pendingAvatarUrl == null
                              ? Text(
                                  user.avatarInitial,
                                  style: const TextStyle(fontSize: 28),
                                )
                              : null,
                        ),
                        if (uploading)
                          const GlassProgressIndicator.circular(size: 40),
                        if (!uploading)
                          Positioned(
                            bottom: 0,
                            right: 0,
                            child: CircleAvatar(
                              radius: 12,
                              backgroundColor: Theme.of(
                                ctx,
                              ).colorScheme.primary,
                              child: const Icon(
                                Icons.camera_alt,
                                size: 14,
                                color: Colors.white,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('Account ID', style: Theme.of(ctx).textTheme.labelLarge),
                  const SizedBox(height: 4),
                  SelectableText(
                    user.id,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: Theme.of(
                        ctx,
                      ).colorScheme.onSurface.withValues(alpha: 0.65),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: displayNameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Display name',
                      prefixIcon: Icon(Icons.badge_outlined),
                    ),
                    maxLength: 96,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: usernameCtrl,
                    decoration: const InputDecoration(
                      labelText: '@',
                      prefixText: '@',
                      prefixIcon: Icon(Icons.alternate_email_rounded),
                      helperText:
                          '3-32 lowercase letters, numbers, or underscores',
                    ),
                    autocorrect: false,
                    enableSuggestions: false,
                    textCapitalization: TextCapitalization.none,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: bioCtrl,
                    decoration: const InputDecoration(labelText: 'Bio'),
                    maxLines: 3,
                    maxLength: 200,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: uploading
                    ? null
                    : () async {
                        final username = usernameCtrl.text
                            .trim()
                            .toLowerCase()
                            .replaceFirst(RegExp(r'^@+'), '');
                        if (username.isEmpty) {
                          showAppToast(ctx, 'Username required', isError: true);
                          return;
                        }
                        if (!RegExp(r'^[a-z0-9_]{3,32}$').hasMatch(username)) {
                          showAppToast(
                            ctx,
                            'Username must be 3-32 lowercase letters, '
                            'numbers, or underscores',
                            isError: true,
                          );
                          return;
                        }
                        final displayName = displayNameCtrl.text.trim();
                        final bio = bioCtrl.text.trim();
                        Navigator.pop(ctx);
                        try {
                          await api.updateProfile(
                            username: username,
                            displayName: displayName,
                            bio: bio.isEmpty ? null : bio,
                            avatarUrl: pendingAvatarUrl,
                          );
                          await auth.refreshCurrentUser();
                        } catch (e) {
                          messenger.showSnackBar(
                            SnackBar(content: Text('Failed to update: $e')),
                          );
                        }
                      },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    ).whenComplete(() {
      displayNameCtrl.dispose();
      usernameCtrl.dispose();
      bioCtrl.dispose();
    });
  }

  static const List<Color> _accentPalette = [
    Color(SettingsProvider.defaultSeed), // OpenChat blue (default)
    Color(0xFF6750A4), Color(0xFF7E57C2), Color(0xFFAB47BC),
    Color(0xFFEC407A), Color(0xFFEF5350), Color(0xFFFF7043),
    Color(0xFFFFA726), Color(0xFFFFCA28), Color(0xFF66BB6A),
    Color(0xFF26A69A), Color(0xFF26C6DA), Color(0xFF42A5F5),
    Color(0xFF546E7A), Color(0xFF37474F),
  ];

  Future<void> _pickAccentColor(
    BuildContext context,
    SettingsProvider settings,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: const Text('Accent color'),
        content: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final c in _accentPalette)
              GestureDetector(
                onTap: () {
                  settings.setSeedColor(c);
                  Navigator.pop(ctx);
                },
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: c,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: settings.seedColorValue == c.toARGB32()
                          ? Theme.of(ctx).colorScheme.onSurface
                          : Colors.transparent,
                      width: 3,
                    ),
                    boxShadow: settings.seedColorValue == c.toARGB32()
                        ? [
                            BoxShadow(
                              color: c.withValues(alpha: 0.5),
                              blurRadius: 10,
                              spreadRadius: -2,
                            ),
                          ]
                        : null,
                  ),
                ),
              ),
            // Custom color button
            GestureDetector(
              onTap: () async {
                Navigator.pop(ctx);
                await _pickCustomAccentColor(context, settings);
              },
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const SweepGradient(
                    colors: [
                      Color(0xFFFF0000),
                      Color(0xFFFFFF00),
                      Color(0xFF00FF00),
                      Color(0xFF00FFFF),
                      Color(0xFF0000FF),
                      Color(0xFFFF00FF),
                      Color(0xFFFF0000),
                    ],
                  ),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.4),
                    width: 1.5,
                  ),
                ),
                child: const Icon(
                  Icons.colorize,
                  size: 18,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              settings.resetSeedColor();
              Navigator.pop(ctx);
            },
            child: const Text('Reset'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickCustomAccentColor(
    BuildContext context,
    SettingsProvider settings,
  ) async {
    final initial = settings.seedColor;
    final picked = await showDialog<Color>(
      context: context,
      builder: (_) => _CustomAccentColorDialog(initial: initial),
    );
    if (picked != null) {
      await settings.setSeedColor(picked);
    }
  }

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

  Future<void> _manageTwoFactorPassword() async {
    final api = context.read<ApiService>();
    final messenger = ScaffoldMessenger.of(context);
    final twoFactorCtrl = TextEditingController();
    final Map<String, dynamic> settings;
    try {
      settings = await api.getSecuritySettings();
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
      twoFactorCtrl.dispose();
      return;
    }
    if (!mounted) {
      twoFactorCtrl.dispose();
      return;
    }

    final twoFactorEnabled = settings['two_factor_enabled'] as bool? ?? false;
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
                            await api.updateSecuritySettings(
                              disableTwoFactor: true,
                            );
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
                  child: const Text('Disable 2FA'),
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
                          await api.updateSecuritySettings(
                            twoFactorPassword: password,
                          );
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
    final Map<String, dynamic> settings;
    try {
      settings = await api.getSecuritySettings();
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
      return;
    }
    if (!mounted) return;

    var selectedDays = normalizeInactiveDeletionDays(
      settings['account_self_destruct_days'] as int?,
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
                          await api.updateSecuritySettings(
                            accountSelfDestructDays: selectedDays,
                          );
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

  Future<void> _manageSessions() async {
    final api = context.read<ApiService>();
    final storage = context.read<SecureStorageService>();
    final messenger = ScaffoldMessenger.of(context);
    var sessions = await api.listSessions();
    final currentSessionId = await storage.getSessionId();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => GlassAlertDialog(
          title: const Text('Active sessions'),
          content: SizedBox(
            width: double.maxFinite,
            child: sessions.isEmpty
                ? const Text('No active sessions found')
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: sessions.length,
                    itemBuilder: (_, i) {
                      final session = sessions[i];
                      final sessionId = session['id'] as String? ?? '';
                      final isCurrent =
                          currentSessionId != null &&
                          sessionId == currentSessionId;
                      return GlassListTile(
                        leading: const Icon(
                          CupertinoIcons.device_phone_portrait,
                        ),
                        title: Text(
                          sessionDeviceDisplayLabel(session),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          session['last_seen_at'] as String? ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (!isCurrent) ...[
                              GestureDetector(
                                onTap: () async {
                                  final wiped = await _wipeDeviceSession(
                                    session,
                                  );
                                  if (!wiped) return;
                                  final refreshed = await api.listSessions();
                                  if (ctx.mounted) {
                                    setDlg(() => sessions = refreshed);
                                  }
                                },
                                child: const Icon(
                                  Icons.phonelink_erase,
                                  color: CupertinoColors.destructiveRed,
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: 14),
                            ],
                            GestureDetector(
                              onTap: () async {
                                await api.revokeSession(sessionId);
                                if (ctx.mounted) Navigator.pop(ctx);
                                messenger.showSnackBar(
                                  const SnackBar(
                                    content: Text('Session revoked'),
                                  ),
                                );
                              },
                              child: const Icon(
                                CupertinoIcons.power,
                                color: CupertinoColors.destructiveRed,
                                size: 20,
                              ),
                            ),
                          ],
                        ),
                        isLast: i == sessions.length - 1,
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  /// Confirms, signs, and sends a remote-wipe command for [session]. Returns
  /// true once the command was accepted by the server. The signature binds
  /// the session id and timestamp so the server can only relay — never forge.
  Future<bool> _wipeDeviceSession(Map<String, dynamic> session) async {
    final id = session['id'] as String? ?? '';
    if (id.isEmpty) return false;
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
    if (!confirmed || !mounted) return false;
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
        return false;
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
      messenger.showSnackBar(
        const SnackBar(content: Text('Wipe command sent')),
      );
      return true;
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Wipe failed: $e')));
      return false;
    }
  }

  Future<void> _manageBusinessProfile() async {
    final api = context.read<ApiService>();
    final messenger = ScaffoldMessenger.of(context);
    final profile = await api.getBusinessProfile();
    final displayCtrl = TextEditingController(
      text: profile['display_name'] as String? ?? '',
    );
    final greetingCtrl = TextEditingController(
      text: profile['greeting_message'] as String? ?? '',
    );
    final awayCtrl = TextEditingController(
      text: profile['away_message'] as String? ?? '',
    );
    final quickRepliesCtrl = TextEditingController(
      text: _businessQuickRepliesText(profile['quick_replies']),
    );
    final openingHours = _businessMap(profile['opening_hours']);
    final weekdayHoursCtrl = TextEditingController(
      text: openingHours['weekdays']?.toString() ?? '',
    );
    final saturdayHoursCtrl = TextEditingController(
      text: openingHours['saturday']?.toString() ?? '',
    );
    final sundayHoursCtrl = TextEditingController(
      text: openingHours['sunday']?.toString() ?? '',
    );
    var enabled = profile['enabled'] as bool? ?? false;
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => GlassAlertDialog(
          title: const Text('Business profile'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GlassListTile(
                  title: const Text('Enabled'),
                  trailing: GlassSwitch(
                    value: enabled,
                    onChanged: (v) => setDlg(() => enabled = v),
                    activeColor: Theme.of(ctx).colorScheme.primary,
                    enableHaptics: true,
                  ),
                  onTap: () => setDlg(() => enabled = !enabled),
                ),
                TextField(
                  controller: displayCtrl,
                  decoration: const InputDecoration(labelText: 'Display name'),
                ),
                TextField(
                  controller: greetingCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Greeting message',
                  ),
                ),
                TextField(
                  controller: awayCtrl,
                  decoration: const InputDecoration(labelText: 'Away message'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: quickRepliesCtrl,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: 'Quick replies',
                    hintText: '/hours | We are open 9-5 today',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: weekdayHoursCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Weekday hours',
                    hintText: 'Mon-Fri 09:00-17:00',
                  ),
                ),
                TextField(
                  controller: saturdayHoursCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Saturday hours',
                    hintText: 'Closed',
                  ),
                ),
                TextField(
                  controller: sundayHoursCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Sunday hours',
                    hintText: 'Closed',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                await api.updateBusinessProfile(
                  displayName: displayCtrl.text.trim().isEmpty
                      ? null
                      : displayCtrl.text.trim(),
                  greetingMessage: greetingCtrl.text.trim().isEmpty
                      ? null
                      : greetingCtrl.text.trim(),
                  awayMessage: awayCtrl.text.trim().isEmpty
                      ? null
                      : awayCtrl.text.trim(),
                  quickReplies: _parseBusinessQuickReplies(
                    quickRepliesCtrl.text,
                  ),
                  openingHours: {
                    if (weekdayHoursCtrl.text.trim().isNotEmpty)
                      'weekdays': weekdayHoursCtrl.text.trim(),
                    if (saturdayHoursCtrl.text.trim().isNotEmpty)
                      'saturday': saturdayHoursCtrl.text.trim(),
                    if (sundayHoursCtrl.text.trim().isNotEmpty)
                      'sunday': sundayHoursCtrl.text.trim(),
                  },
                  enabled: enabled,
                );
                if (ctx.mounted) Navigator.pop(ctx);
                messenger.showSnackBar(
                  const SnackBar(content: Text('Business profile saved')),
                );
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Map<String, dynamic> _businessMap(Object? raw) {
    final decoded = _decodeBusinessJson(raw);
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
    return const {};
  }

  List<Map<String, dynamic>> _businessList(Object? raw) {
    final decoded = _decodeBusinessJson(raw);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map>()
        .map(
          (item) => item.map((key, value) => MapEntry(key.toString(), value)),
        )
        .toList(growable: false);
  }

  Object? _decodeBusinessJson(Object? raw) {
    if (raw is Map || raw is List) return raw;
    if (raw is! String || raw.trim().isEmpty) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  String _businessQuickRepliesText(Object? raw) {
    final replies = _businessList(raw);
    return replies
        .map((reply) {
          final shortcut = reply['shortcut']?.toString().trim() ?? '';
          final text = reply['text']?.toString().trim() ?? '';
          if (shortcut.isEmpty) return text;
          if (text.isEmpty) return shortcut;
          return '$shortcut | $text';
        })
        .where((line) => line.trim().isNotEmpty)
        .join('\n');
  }

  List<Map<String, dynamic>> _parseBusinessQuickReplies(String text) {
    final replies = <Map<String, dynamic>>[];
    for (final line in const LineSplitter().convert(text)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final separator = trimmed.indexOf('|');
      if (separator == -1) {
        replies.add({'text': trimmed});
        continue;
      }
      final shortcut = trimmed.substring(0, separator).trim();
      final replyText = trimmed.substring(separator + 1).trim();
      if (shortcut.isEmpty && replyText.isEmpty) continue;
      replies.add({
        if (shortcut.isNotEmpty) 'shortcut': shortcut,
        if (replyText.isNotEmpty) 'text': replyText,
      });
    }
    return replies;
  }

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
      if (mounted) setState(() => _lastBackupAt = DateTime.now());
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
      if (mounted) setState(() => _lastBackupAt = null);
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

  Future<void> _clearAllData() async {
    final messenger = ScaffoldMessenger.of(context);
    var confirmed = false;
    await GlassDialog.show<void>(
      context: context,
      title: 'Clear all local data?',
      message:
          'This permanently removes your PGP private key, session '
          'tokens, and all app preferences. You will be signed out and '
          'need to re-import your PGP key.',
      actions: [
        GlassDialogAction(
          label: 'Cancel',
          onPressed: () => Navigator.pop(context),
        ),
        GlassDialogAction(
          label: 'Clear',
          isDestructive: true,
          onPressed: () {
            confirmed = true;
            Navigator.pop(context);
          },
        ),
      ],
    );
    if (!confirmed || !mounted) return;

    // Capture service references before any async gap that could unmount the widget.
    final storage = context.read<SecureStorageService>();
    final auth = context.read<AuthProvider>();

    try {
      // Logout first so the server can revoke the token while we still have it.
      await auth.logout();
    } catch (_) {
      // Best-effort; proceed to wipe local data regardless.
    }
    // Delete everything remaining in the platform secure store (PGP keys,
    // biometric flag, any leftovers from older app versions).
    await storage.clearAll();

    // logout() already navigates to the login screen and clears in-memory
    // state, so no further action is needed here.
    messenger.showSnackBar(
      const SnackBar(content: Text('All local data cleared')),
    );
  }

  Future<void> _deleteAccountEverywhere() async {
    final api = context.read<ApiService>();
    final auth = context.read<AuthProvider>();
    final storage = context.read<SecureStorageService>();
    final messenger = ScaffoldMessenger.of(context);
    final passwordCtrl = TextEditingController();
    final twoFactorCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    var submitting = false;
    var confirmed = false;

    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDlg) => GlassAlertDialog(
            icon: Icon(
              Icons.delete_forever_outlined,
              color: Colors.red.shade600,
            ),
            title: const Text('Delete account everywhere?'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'This deletes your account, frees your @ username, removes server-side account data, and purges messages linked to you. Locally held sealed-sender control tokens are sent once so those messages can be deleted too.',
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: passwordCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Account password',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: twoFactorCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: '2FA password, if enabled',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: confirmCtrl,
                  decoration: const InputDecoration(labelText: 'Type DELETE'),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: submitting ? null : () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                onPressed: submitting
                    ? null
                    : () async {
                        if (confirmCtrl.text.trim() != 'DELETE') {
                          showAppToast(ctx, 'Type DELETE', isError: true);
                          return;
                        }
                        if (passwordCtrl.text.isEmpty) {
                          showAppToast(ctx, 'Enter password', isError: true);
                          return;
                        }
                        setDlg(() => submitting = true);
                        try {
                          await api.deleteAccount(
                            currentPassword: passwordCtrl.text,
                            twoFactorPassword: twoFactorCtrl.text,
                          );
                          confirmed = true;
                          if (ctx.mounted) Navigator.pop(ctx);
                        } catch (e) {
                          if (ctx.mounted) setDlg(() => submitting = false);
                          messenger.showSnackBar(
                            SnackBar(content: Text('Delete failed: $e')),
                          );
                        }
                      },
                child: submitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Delete'),
              ),
            ],
          ),
        ),
      );
    } finally {
      passwordCtrl.dispose();
      twoFactorCtrl.dispose();
      confirmCtrl.dispose();
    }

    if (!confirmed || !mounted) return;
    await storage.clearAll();
    await auth.logout();
    messenger.showSnackBar(const SnackBar(content: Text('Account deleted')));
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final user = auth.currentUser;
    final keys = context.watch<KeyProvider>();
    final settings = context.watch<SettingsProvider>();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const GlassAppBar(title: Text('Settings')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          MediaQuery.paddingOf(context).top + kToolbarHeight + 12,
          16,
          MediaQuery.paddingOf(context).bottom + 32,
        ),
        children: [
          // ── Profile header ───────────────────────────────────────────────
          if (user != null) ...[
            GestureDetector(
              onTap: _editProfile,
              child: GlassCard(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    Stack(
                      children: [
                        Container(
                          width: 68,
                          height: 68,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: scheme.primary.withValues(alpha: 0.30),
                                blurRadius: 16,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: CircleAvatar(
                            radius: 34,
                            backgroundImage: user.avatarUrl != null
                                ? CachedNetworkImageProvider(
                                    ApiConfig.resolveMedia(user.avatarUrl!),
                                  )
                                : null,
                            child: user.avatarUrl == null
                                ? Text(
                                    user.avatarInitial,
                                    style: const TextStyle(
                                      fontSize: 26,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  )
                                : null,
                          ),
                        ),
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: scheme.primary,
                              border: Border.all(
                                color: Theme.of(
                                  context,
                                ).scaffoldBackgroundColor,
                                width: 2,
                              ),
                            ),
                            child: const Icon(
                              Icons.edit,
                              color: Colors.white,
                              size: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  user.displayName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 17,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (user.isSystemAdmin)
                                const Padding(
                                  padding: EdgeInsets.only(left: 6),
                                  child: Icon(
                                    Icons.verified,
                                    size: 16,
                                    color: Colors.blue,
                                  ),
                                ),
                              if (user.isPremium)
                                const Padding(
                                  padding: EdgeInsets.only(left: 4),
                                  child: Icon(
                                    Icons.workspace_premium,
                                    size: 16,
                                    color: Colors.amber,
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            user.handle,
                            style: TextStyle(
                              fontSize: 13,
                              color: scheme.onSurface.withValues(alpha: 0.55),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'Account ID ${user.id}',
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurface.withValues(alpha: 0.45),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 3),
                          Text(
                            user.bio?.isNotEmpty == true
                                ? user.bio!
                                : 'Tap to add a bio',
                            style: TextStyle(
                              fontSize: 13,
                              color: scheme.onSurface.withValues(alpha: 0.55),
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      CupertinoIcons.chevron_forward,
                      size: 14,
                      color: scheme.onSurface.withValues(alpha: 0.40),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],

          // ── Security & Keys ──────────────────────────────────────────────
          const _SectionHeader('Security & Keys'),
          GlassCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _GlassTile(
                  icon: Icons.shield_outlined,
                  title: 'Trust Center',
                  subtitle: 'Keys, encrypted chats, devices, and privacy',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const TrustCenterScreen(),
                    ),
                  ),
                ),
                if (!kIsWeb) ...[
                  _GlassDivider(),
                  _GlassTile(
                    icon: Icons.vpn_lock_outlined,
                    title: 'Proxy & Tor',
                    subtitle: 'Route traffic through HTTP, SOCKS5, or Tor',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const ProxySettingsScreen(),
                      ),
                    ),
                  ),
                  _GlassDivider(),
                  _GlassTile(
                    icon: Icons.psychology_outlined,
                    title: 'On-device intelligence',
                    subtitle:
                        'Transcription, translation, and sticker AI models',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const OnDeviceAiScreen(),
                      ),
                    ),
                  ),
                  if (NearbyMeshService.isSupported) ...[
                    _GlassDivider(),
                    _GlassTile(
                      icon: Icons.bluetooth_audio_rounded,
                      title: 'Nearby',
                      subtitle: 'Exchange queued messages over Bluetooth',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const NearbyScreen()),
                      ),
                    ),
                  ],
                ],
                _GlassDivider(),
                _GlassTile(
                  icon: keys.hasKey ? Icons.verified_user : Icons.warning_amber,
                  iconColor: keys.hasKey ? Colors.green : Colors.orange,
                  title: 'PGP Keys',
                  subtitle: keys.hasKey
                      ? 'Fingerprint: …${keys.fingerprint?.substring((keys.fingerprint?.length ?? 8) - 8)}'
                      : 'No key on device',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const PgpKeysScreen()),
                  ),
                ),
                if (!kIsWeb) ...[
                  _GlassDivider(),
                  _GlassTile(
                    icon: Icons.backup_outlined,
                    title: 'Export encrypted backup',
                    subtitle: 'Private key, trust pins, drafts, and folders',
                    onTap: _exportEncryptedBackup,
                  ),
                  _GlassDivider(),
                  _GlassTile(
                    icon: Icons.restore_outlined,
                    title: 'Import encrypted backup',
                    subtitle: 'Restore keys and encrypted local state',
                    onTap: _importEncryptedBackup,
                  ),
                ],
                _GlassDivider(),
                _GlassTile(
                  icon: Icons.cloud_upload_outlined,
                  title: 'Store encrypted backup on server',
                  subtitle: _lastBackupAt != null
                      ? backupStatusLabel(
                          evaluateBackupFreshness(
                            lastBackupAt: _lastBackupAt,
                            now: DateTime.now(),
                          ),
                        )
                      : 'Zero-knowledge: only the passphrase-encrypted blob '
                            'leaves this device',
                  onTap: _uploadBackupToServer,
                ),
                _GlassDivider(),
                _GlassTile(
                  icon: Icons.cloud_download_outlined,
                  title: 'Restore from server backup',
                  subtitle: 'Download and decrypt with your passphrase',
                  onTap: _restoreBackupFromServer,
                ),
                _GlassDivider(),
                _GlassTile(
                  icon: Icons.cloud_off_outlined,
                  title: 'Delete server backup',
                  subtitle: 'Remove the stored blob from the server',
                  onTap: _deleteServerBackup,
                ),
                _GlassDivider(),
                _GlassTile(
                  icon: Icons.diversity_3_outlined,
                  title: 'Recover with guardians',
                  subtitle: 'Rebuild your keys from shares your guardians hold',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const SocialRecoveryScreen(),
                    ),
                  ),
                ),
                if (!kIsWeb) ...[
                  _GlassDivider(),
                  _GlassTile(
                    icon: Icons.phonelink_lock_outlined,
                    title: 'Link this device',
                    subtitle: 'Create a one-time encrypted pairing QR',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const DevicePairingScreen(),
                      ),
                    ),
                  ),
                ],
                _GlassDivider(),
                _GlassTile(
                  icon: Icons.password_outlined,
                  title: 'Change Password',
                  subtitle: 'Update your account login password',
                  onTap: _changePassword,
                ),
                _GlassDivider(),
                _GlassTile(
                  icon: Icons.security_outlined,
                  title: '2FA Password',
                  subtitle: 'Add, update, or disable 2FA',
                  onTap: _manageTwoFactorPassword,
                ),
                _GlassDivider(),
                _GlassTile(
                  icon: Icons.timer_outlined,
                  title: 'Delete account when inactive for',
                  subtitle: 'Choose an exact inactivity period',
                  onTap: _manageAccountInactivityDeletion,
                ),
                // Sessions are vault-only: a decoy session must not reveal —
                // or be able to wipe/revoke — the account's other devices.
                ValueListenableBuilder<VaultMode>(
                  valueListenable: vaultModeListenable,
                  builder: (context, vaultMode, _) =>
                      vaultMode == VaultMode.real
                      ? Column(
                          children: [
                            _GlassDivider(),
                            _GlassTile(
                              icon: Icons.devices_outlined,
                              title: 'Active sessions',
                              subtitle:
                                  'Review, revoke, or wipe signed-in devices',
                              onTap: _manageSessions,
                            ),
                          ],
                        )
                      : const SizedBox.shrink(),
                ),
                _GlassDivider(),
                _GlassTile(
                  icon: Icons.business_center_outlined,
                  title: 'Business profile',
                  subtitle: 'Greeting, away message, and profile',
                  onTap: _manageBusinessProfile,
                  isLast: !_biometricAvailable,
                ),
                if (_biometricAvailable) ...[
                  _GlassDivider(),
                  _GlassSwitchTile(
                    icon: Icons.fingerprint,
                    title: 'Biometric Key Unlock',
                    subtitle:
                        'Require fingerprint / face before exporting your key',
                    value: _biometricEnabled,
                    onChanged: _setBiometric,
                  ),
                  _GlassDivider(),
                  _GlassSwitchTile(
                    icon: Icons.lock_outline,
                    title: 'App Lock',
                    subtitle: 'Require biometrics when returning to OpenChat',
                    value: _appLockEnabled,
                    onChanged: _setAppLock,
                    isLast: true,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          // ── PIN lock, duress PIN, dead-man switch ────────────────────────
          // Vault-only: a decoy (duress-PIN) session must show nothing of
          // this — its absence is what keeps the decoy indistinguishable
          // from an account that never configured a vault.
          ValueListenableBuilder<VaultMode>(
            valueListenable: vaultModeListenable,
            builder: (context, vaultMode, _) {
              if (vaultMode != VaultMode.real) return const SizedBox.shrink();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  GlassCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        _GlassTile(
                          icon: Icons.pin_outlined,
                          title: 'App lock PIN',
                          subtitle: _appPinConfigured
                              ? 'Set — change or remove the unlock PIN'
                              : 'Set a PIN to unlock OpenChat',
                          onTap: _manageAppLockPin,
                        ),
                        if (_appPinConfigured) ...[
                          _GlassDivider(),
                          _GlassTile(
                            icon: Icons.theater_comedy_outlined,
                            title: 'Duress PIN',
                            subtitle: _duressPinConfigured
                                ? 'Set — a second PIN for coerced unlocks'
                                : 'A second PIN for coerced unlocks',
                            onTap: _manageDuressPin,
                          ),
                          if (_duressPinConfigured) ...[
                            _GlassDivider(),
                            _GlassTile(
                              icon: Icons.fork_right_rounded,
                              title: 'Duress PIN action',
                              subtitle: _duressAction == 'wipe'
                                  ? 'Wipe this device'
                                  : 'Open decoy',
                              onTap: _pickDuressAction,
                            ),
                          ],
                        ],
                        _GlassDivider(),
                        _GlassTile(
                          icon: Icons.hourglass_bottom_outlined,
                          title: 'Dead-man switch',
                          subtitle:
                              'If the app sees no real unlock for this long, '
                              'local data is destroyed. Checked when the app '
                              'opens — iOS cannot enforce this in the '
                              'background.',
                          trailing: GlassPicker(
                            value: _deadmanDays == 0
                                ? 'Off'
                                : '$_deadmanDays days',
                            width: 100,
                            height: 38,
                            textStyle: TextStyle(
                              fontSize: 15,
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                            onTap: _pickDeadmanDays,
                          ),
                          onTap: _pickDeadmanDays,
                          isLast: true,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              );
            },
          ),
          GlassCard(
            padding: EdgeInsets.zero,
            child: _GlassSwitchTile(
              icon: Icons.group_add_outlined,
              title: 'Allow others to add me to groups',
              subtitle: 'Other users can add you to group chats',
              value: user?.allowGroupAdd ?? true,
              onChanged: (value) async {
                final api = context.read<ApiService>();
                final auth = context.read<AuthProvider>();
                final messenger = ScaffoldMessenger.of(context);
                try {
                  await api.updatePreferences(allowGroupAdd: value);
                  if (mounted) auth.refreshCurrentUser();
                } catch (e) {
                  if (mounted) {
                    messenger.showSnackBar(
                      SnackBar(content: Text('Failed: $e')),
                    );
                  }
                }
              },
              isLast: true,
            ),
          ),
          const SizedBox(height: 24),

          // ── Notifications ────────────────────────────────────────────────
          const _SectionHeader('Notifications'),
          GlassCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                if (!kIsWeb &&
                    (defaultTargetPlatform == TargetPlatform.android ||
                        defaultTargetPlatform == TargetPlatform.iOS)) ...[
                  _GlassSwitchTile(
                    icon: Icons.notifications_outlined,
                    title: 'Push Notifications',
                    subtitle: 'Via Firebase when the app is closed',
                    value: settings.pushNotificationsEnabled,
                    onChanged: (v) => _setPushEnabled(v, settings),
                  ),
                  _GlassDivider(),
                ],
                // Hidden on iOS: the OS kills persistent background sockets,
                // so BackgroundWsService.start() always refuses there and the
                // toggle could never turn on — push is the iOS channel.
                if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) ...[
                  _GlassSwitchTile(
                    icon: Icons.wifi_tethering,
                    title: 'Background WebSocket',
                    subtitle: 'Live connection for real-time notifications',
                    value: settings.wsBackgroundEnabled,
                    onChanged: (v) => _setWsBackground(v, settings),
                  ),
                  _GlassDivider(),
                ],
                _GlassSwitchTile(
                  icon: Icons.visibility_outlined,
                  title: 'Strict Privacy',
                  subtitle:
                      'Disable typing, read receipts, link previews, and link opens; when off, typing and read receipts use classic metadata',
                  value: settings.strictPrivacyMode,
                  onChanged: settings.setStrictPrivacyMode,
                ),
                _GlassDivider(),
                _GlassSwitchTile(
                  icon: Icons.visibility_outlined,
                  title: 'Show Sensitive Content',
                  subtitle: 'Show sender and preview in notifications',
                  value: settings.notificationSensitiveContent,
                  onChanged: settings.setNotificationSensitiveContent,
                ),
                _GlassDivider(),
                _GlassSwitchTile(
                  icon: Icons.link_rounded,
                  title: 'Link Previews',
                  subtitle: settings.strictPrivacyMode
                      ? 'Disabled while Strict Privacy is on'
                      : 'Fetch metadata through the OpenChat proxy',
                  value: settings.linkPreviewsEnabled,
                  onChanged: (value) {
                    if (settings.strictPrivacyMode && value) {
                      showAppToast(
                        context,
                        'Turn off Strict Privacy before enabling link previews',
                        isError: true,
                      );
                      return;
                    }
                    settings.setLinkPreviewsEnabled(value);
                  },
                  isLast: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // ── Wallet & Premium ─────────────────────────────────────────────
          const _SectionHeader('Wallet & Premium'),
          GlassCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _GlassTile(
                  icon: Icons.account_balance_wallet_outlined,
                  title: 'Wallet',
                  subtitle: 'BTC/XMR balances, withdrawals, and history',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const WalletScreen()),
                  ),
                ),
                _GlassDivider(),
                _GlassTile(
                  icon: user?.isPremium == true
                      ? Icons.workspace_premium
                      : Icons.workspace_premium_outlined,
                  iconColor: user?.isPremium == true ? Colors.amber : null,
                  title: 'OpenChat Premium',
                  subtitle: user?.isPremium == true
                      ? 'Active${user?.premiumUntil != null ? ' until ${user!.premiumUntil!.toLocal().toString().split(' ').first}' : ''}'
                      : '€10 / year — more stickers, emoji, bots, wallpapers',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const PremiumScreen()),
                  ),
                  isLast: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // ── Appearance ───────────────────────────────────────────────────
          const _SectionHeader('Appearance'),
          GlassCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _ThemeModeTile(settings: settings),
                _GlassDivider(),
                _GlassTile(
                  icon: Icons.palette_outlined,
                  title: 'Accent color',
                  subtitle: 'Theme color used across the app',
                  trailing: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: settings.seedColor,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: settings.seedColor.withValues(alpha: 0.45),
                          blurRadius: 8,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                  ),
                  onTap: () => _pickAccentColor(context, settings),
                ),
                _GlassDivider(),
                _MessageFontSizeTile(settings: settings),
                _GlassDivider(),
                _GlassSwitchTile(
                  icon: Icons.campaign_outlined,
                  title: 'Channels in their own tab',
                  subtitle: 'Off: channels appear in your Chats list',
                  value: settings.channelsOwnTab,
                  onChanged: settings.setChannelsOwnTab,
                ),
                _GlassDivider(),
                _GlassSwitchTile(
                  icon: Icons.smart_toy_outlined,
                  title: 'Bots in their own tab',
                  subtitle: 'Off: bot chats appear in your Chats list',
                  value: settings.botsOwnTab,
                  onChanged: settings.setBotsOwnTab,
                ),
                _GlassDivider(),
                _GlassSwitchTile(
                  icon: Icons.water_drop_outlined,
                  title: 'Reduce transparency',
                  subtitle: 'Use more opaque surfaces throughout the app',
                  value: settings.reduceTransparency,
                  onChanged: settings.setReduceTransparency,
                  isLast: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // ── Data & Storage (auto-download) ───────────────────────────────
          const _SectionHeader('Auto-download media'),
          GlassCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _GlassSwitchTile(
                  icon: Icons.wifi_rounded,
                  title: 'On Wi-Fi',
                  subtitle: 'Automatically download photos & videos on Wi-Fi',
                  value: settings.autoDownloadWifi,
                  onChanged: settings.setAutoDownloadWifi,
                ),
                _GlassDivider(),
                _GlassSwitchTile(
                  icon: Icons.signal_cellular_alt_rounded,
                  title: 'On mobile data',
                  subtitle: 'Roaming can\'t be detected separately',
                  value: settings.autoDownloadMobile,
                  onChanged: settings.setAutoDownloadMobile,
                ),
                _GlassDivider(),
                _GlassTile(
                  icon: Icons.straighten_rounded,
                  title: 'Size limit',
                  subtitle: settings.autoDownloadMaxMb == 0
                      ? 'No limit'
                      : 'Skip files over ${settings.autoDownloadMaxMb} MB',
                  trailing: GlassPicker(
                    value: settings.autoDownloadMaxMb == 0
                        ? 'No limit'
                        : '${settings.autoDownloadMaxMb} MB',
                    width: 112,
                    height: 38,
                    textStyle: TextStyle(
                      fontSize: 15,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    onTap: () => showGlassActionSheet<void>(
                      context: context,
                      title: 'Size limit',
                      actions: [
                        for (final mb in const [0, 1, 5, 10, 25, 50])
                          GlassActionSheetAction(
                            label: mb == 0 ? 'No limit' : '$mb MB',
                            onPressed: () => settings.setAutoDownloadMaxMb(mb),
                          ),
                      ],
                    ),
                  ),
                  isLast: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // ── Content & Bots ───────────────────────────────────────────────
          const _SectionHeader('Content & Bots'),
          GlassCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _GlassTile(
                  icon: Icons.emoji_emotions_outlined,
                  title: 'Sticker Packs',
                  subtitle: 'Create and manage your sticker packs',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const StickerPackScreen(),
                    ),
                  ),
                ),
                _GlassDivider(),
                _GlassTile(
                  icon: Icons.add_reaction_outlined,
                  title: 'Custom Emoji Packs',
                  subtitle: 'Create and manage your custom emoji packs',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const CustomEmojiPackScreen(),
                    ),
                  ),
                ),
                _GlassDivider(),
                _GlassTile(
                  icon: Icons.smart_toy_outlined,
                  title: 'My Bots',
                  subtitle: 'Create and manage bots',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const BotManagementScreen(),
                    ),
                  ),
                ),
                _GlassDivider(),
                _GlassTile(
                  icon: Icons.widgets_outlined,
                  title: 'Mini Apps',
                  subtitle: 'Open bot-owned apps in an isolated browser',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const MiniAppsScreen()),
                  ),
                  isLast: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // ── About ────────────────────────────────────────────────────────
          const _SectionHeader('About'),
          GlassCard(
            padding: EdgeInsets.zero,
            child: FutureBuilder<PackageInfo>(
              future: _packageInfoFuture,
              builder: (context, snapshot) {
                final version = snapshot.data == null
                    ? ''
                    : 'v${snapshot.data!.version}+${snapshot.data!.buildNumber}';
                return _GlassTile(
                  icon: Icons.info_outline,
                  title: 'OpenChat',
                  subtitle: version.isEmpty
                      ? 'Open Source • E2E Encrypted'
                      : '$version • Open Source • E2E Encrypted',
                  onTap: () => showDialog<void>(
                    context: context,
                    builder: (ctx) => GlassAlertDialog(
                      title: const Text('OpenChat'),
                      content: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Image.asset(
                            'assets/images/logo.png',
                            height: 56,
                            errorBuilder: (_, _, _) => const SizedBox.shrink(),
                          ),
                          if (version.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(
                              version,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                          const SizedBox(height: 12),
                          const Text(
                            'Open source, end-to-end encrypted messenger.\n'
                            'Uses OpenPGP (RFC 4880) for encryption.',
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('OK'),
                        ),
                      ],
                    ),
                  ),
                  isLast: true,
                );
              },
            ),
          ),
          const SizedBox(height: 24),

          // ── Sign out ─────────────────────────────────────────────────────
          GlassCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _GlassTile(
                  icon: Icons.logout_rounded,
                  iconColor: scheme.error,
                  title: 'Sign Out',
                  titleColor: scheme.error,
                  onTap: () async {
                    var doSignOut = false;
                    await GlassDialog.show<void>(
                      context: context,
                      title: 'Sign Out',
                      message: 'Your PGP keys will remain on this device.',
                      actions: [
                        GlassDialogAction(
                          label: 'Cancel',
                          onPressed: () => Navigator.pop(context),
                        ),
                        GlassDialogAction(
                          label: 'Sign Out',
                          isPrimary: true,
                          onPressed: () {
                            doSignOut = true;
                            Navigator.pop(context);
                          },
                        ),
                      ],
                    );
                    if (doSignOut && context.mounted) {
                      await context.read<AuthProvider>().logout();
                    }
                  },
                  isLast: false,
                ),
                _GlassDivider(),
                _GlassTile(
                  icon: Icons.delete_forever_outlined,
                  iconColor: scheme.error,
                  title: 'Delete Account Everywhere',
                  titleColor: scheme.error,
                  subtitle: 'Purge account, messages, keys, and username',
                  onTap: _deleteAccountEverywhere,
                  isLast:
                      !kIsWeb &&
                          (defaultTargetPlatform == TargetPlatform.windows ||
                              defaultTargetPlatform == TargetPlatform.linux ||
                              defaultTargetPlatform == TargetPlatform.macOS)
                      ? false
                      : true,
                ),
                if (!kIsWeb &&
                    (defaultTargetPlatform == TargetPlatform.windows ||
                        defaultTargetPlatform == TargetPlatform.linux ||
                        defaultTargetPlatform == TargetPlatform.macOS)) ...[
                  _GlassDivider(),
                  _GlassTile(
                    icon: Icons.delete_forever_outlined,
                    iconColor: scheme.error,
                    title: 'Clear All Local Data',
                    titleColor: scheme.error,
                    subtitle: 'Remove stored keys, tokens, and preferences',
                    onTap: _clearAllData,
                    isLast: true,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Message text-size control with a live preview bubble (Batch 5.1).
class _ThemeModeTile extends StatelessWidget {
  final SettingsProvider settings;
  const _ThemeModeTile({required this.settings});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Exhaustive switch (no default) so a future ThemeMode value is a compile
    // error rather than an out-of-range segment index.
    final selectedIndex = switch (settings.themeMode) {
      ThemeMode.light => 0,
      ThemeMode.dark => 1,
      ThemeMode.system => 2,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.brightness_6_outlined,
                color: scheme.primary,
                size: 22,
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Theme',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          GlassSegmentedControl(
            segments: const ['Light', 'Dark', 'System'],
            selectedIndex: selectedIndex,
            onSegmentSelected: (i) => settings.setThemeMode(
              const [ThemeMode.light, ThemeMode.dark, ThemeMode.system][i],
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageFontSizeTile extends StatelessWidget {
  final SettingsProvider settings;
  const _MessageFontSizeTile({required this.settings});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final scale = settings.messageFontScale;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.text_fields_rounded, color: scheme.primary, size: 22),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Message text size',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Text('${(scale * 100).round()}%'),
            ],
          ),
          const SizedBox(height: 6),
          // Live preview bubble.
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 6),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                'The quick brown fox',
                textScaler: TextScaler.linear(scale),
                style: const TextStyle(fontSize: 15),
              ),
            ),
          ),
          GlassSlider(
            value: scale,
            min: SettingsProvider.minMessageFontScale,
            max: SettingsProvider.maxMessageFontScale,
            divisions: 14,
            onChanged: settings.setMessageFontScale,
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
    child: Text(
      title.toUpperCase(),
      style: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.90),
        letterSpacing: 1.4,
      ),
    ),
  );
}

/// A row inside a glass card — backed by [GlassListTile] for native iOS 26
/// tap feedback and Cupertino-adaptive text colours.
class _GlassTile extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final Color? titleColor;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool isLast;

  const _GlassTile({
    required this.icon,
    this.iconColor,
    required this.title,
    this.titleColor,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final effectiveColor = iconColor ?? scheme.primary;
    return GlassListTile(
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: effectiveColor.withValues(alpha: 0.14),
        ),
        child: Icon(icon, size: 17, color: effectiveColor),
      ),
      title: Text(
        title,
        style: titleColor != null
            ? TextStyle(color: titleColor, fontWeight: FontWeight.w600)
            : const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: subtitle != null ? Text(subtitle!) : null,
      trailing:
          trailing ??
          Icon(
            CupertinoIcons.chevron_forward,
            size: 14,
            color: scheme.onSurface.withValues(alpha: 0.40),
          ),
      onTap: onTap,
      isLast: isLast,
      showDivider: false,
    );
  }
}

/// A switch row inside a glass card — backed by [GlassListTile] + [GlassSwitch].
class _GlassSwitchTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool isLast;

  const _GlassSwitchTile({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassListTile(
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: scheme.primary.withValues(alpha: 0.14),
        ),
        child: Icon(icon, size: 17, color: scheme.primary),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: subtitle != null ? Text(subtitle!) : null,
      trailing: GlassSwitch(
        value: value,
        onChanged: onChanged,
        activeColor: scheme.primary,
        enableHaptics: true,
      ),
      onTap: () => onChanged(!value),
      isLast: isLast,
      showDivider: false,
    );
  }
}

// ── Custom accent color HSV picker ───────────────────────────────────────────

class _CustomAccentColorDialog extends StatefulWidget {
  final Color initial;
  const _CustomAccentColorDialog({required this.initial});

  @override
  State<_CustomAccentColorDialog> createState() =>
      _CustomAccentColorDialogState();
}

class _CustomAccentColorDialogState extends State<_CustomAccentColorDialog> {
  late double _hue;
  late double _sat;
  late double _val;

  @override
  void initState() {
    super.initState();
    final hsv = HSVColor.fromColor(widget.initial);
    _hue = hsv.hue;
    _sat = hsv.saturation;
    _val = hsv.value;
  }

  Color get _current => HSVColor.fromAHSV(1, _hue, _sat, _val).toColor();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassAlertDialog(
      title: const Text('Custom accent color'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 80),
            width: double.infinity,
            height: 52,
            decoration: BoxDecoration(
              color: _current,
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: _current.withValues(alpha: 0.55),
                  blurRadius: 20,
                  spreadRadius: -2,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _label(context, 'Hue'),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 14,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              trackShape: _HueTrackShape(),
            ),
            child: Slider(
              value: _hue,
              min: 0,
              max: 360,
              onChanged: (v) => setState(() => _hue = v),
            ),
          ),
          _label(context, 'Saturation'),
          _gradientSlider(
            value: _sat,
            left: HSVColor.fromAHSV(1, _hue, 0, _val).toColor(),
            right: HSVColor.fromAHSV(1, _hue, 1, _val).toColor(),
            onChanged: (v) => setState(() => _sat = v),
          ),
          _label(context, 'Brightness'),
          _gradientSlider(
            value: _val,
            left: Colors.black,
            right: HSVColor.fromAHSV(1, _hue, _sat, 1).toColor(),
            onChanged: (v) => setState(() => _val = v),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(
                CupertinoIcons.number,
                size: 14,
                color: scheme.onSurface.withValues(alpha: 0.55),
              ),
              const SizedBox(width: 4),
              Text(
                _current
                    .toARGB32()
                    .toRadixString(16)
                    .toUpperCase()
                    .padLeft(8, '0')
                    .substring(2),
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.4,
                  color: scheme.onSurface.withValues(alpha: 0.75),
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _current),
          child: const Text('Apply'),
        ),
      ],
    );
  }

  Widget _label(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: Theme.of(
            context,
          ).colorScheme.onSurface.withValues(alpha: 0.55),
        ),
      ),
    ),
  );

  Widget _gradientSlider({
    required double value,
    required Color left,
    required Color right,
    required ValueChanged<double> onChanged,
  }) {
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 14,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
        trackShape: _GradientTrackShape(left: left, right: right),
      ),
      child: Slider(value: value, onChanged: onChanged),
    );
  }
}

class _HueTrackShape extends RoundedRectSliderTrackShape {
  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    final Rect trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(trackRect, const Radius.circular(7)),
      Paint()
        ..shader = const LinearGradient(
          colors: [
            Color(0xFFFF0000),
            Color(0xFFFFFF00),
            Color(0xFF00FF00),
            Color(0xFF00FFFF),
            Color(0xFF0000FF),
            Color(0xFFFF00FF),
            Color(0xFFFF0000),
          ],
        ).createShader(trackRect),
    );
  }
}

class _GradientTrackShape extends RoundedRectSliderTrackShape {
  final Color left;
  final Color right;
  const _GradientTrackShape({required this.left, required this.right});

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    final Rect trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(trackRect, const Radius.circular(7)),
      Paint()
        ..shader = LinearGradient(
          colors: [left, right],
        ).createShader(trackRect),
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

/// A 1dp hairline separator inside glass cards.
class _GlassDivider extends StatelessWidget {
  const _GlassDivider();

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      thickness: 0.5,
      indent: 66,
      endIndent: 0,
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.10),
    );
  }
}
