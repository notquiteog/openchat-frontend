import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:image_picker/image_picker.dart';
import 'package:local_auth/local_auth.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import '../../config/api_config.dart';
import '../../providers/auth_provider.dart';
import '../../providers/key_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/api_service.dart';
import '../../services/background_ws_service.dart';
import '../../services/notification_service.dart';
import '../../services/push_notification_service.dart';
import '../../services/secure_storage_service.dart';
import '../../utils/account_security_duration.dart';
import '../../utils/device_label.dart';
import '../../widgets/glass.dart';
import '../bots/bot_management_screen.dart';
import '../custom_emojis/custom_emoji_pack_screen.dart';
import '../stickers/sticker_pack_screen.dart';
import 'pgp_keys_screen.dart';
import 'premium_screen.dart';
import 'private_contacts_screen.dart';
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
  late final Future<PackageInfo> _packageInfoFuture;

  @override
  void initState() {
    super.initState();
    _packageInfoFuture = PackageInfo.fromPlatform();
    _loadSecurityPrefs();
  }

  Future<void> _loadSecurityPrefs() async {
    final storage = context.read<SecureStorageService>();
    final available =
        await _auth.canCheckBiometrics || await _auth.isDeviceSupported();
    final biometricEnabled = await storage.getBiometricEnabled();
    final appLockEnabled = await storage.getAppLockEnabled();
    if (mounted) {
      setState(() {
        _biometricAvailable = available;
        _biometricEnabled = biometricEnabled;
        _appLockEnabled = appLockEnabled;
      });
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
            'app is closed, providing real-time notifications without Firebase. '
            'On iOS the OS may still suspend it.',
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
            content: Column(
              mainAxisSize: MainAxisSize.min,
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
                      if (uploading) const GlassProgressIndicator.circular(size: 40),
                      if (!uploading)
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: CircleAvatar(
                            radius: 12,
                            backgroundColor: Theme.of(ctx).colorScheme.primary,
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
                TextField(
                  controller: displayNameCtrl,
                  decoration: const InputDecoration(labelText: 'Display name'),
                  maxLength: 96,
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
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: uploading
                    ? null
                    : () async {
                        final bio = bioCtrl.text.trim();
                        Navigator.pop(ctx);
                        try {
                          await api.updateProfile(
                            displayName: displayNameCtrl.text.trim(),
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
    );
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
                  ? const GlassProgressIndicator.circular(size: 16, strokeWidth: 2)
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
                    ? const GlassProgressIndicator.circular(size: 16, strokeWidth: 2)
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
                    ? const GlassProgressIndicator.circular(size: 16, strokeWidth: 2)
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
    final messenger = ScaffoldMessenger.of(context);
    final sessions = await api.listSessions();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
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
                      trailing: GestureDetector(
                        onTap: () async {
                          await api.revokeSession(session['id'] as String);
                          if (ctx.mounted) Navigator.pop(ctx);
                          messenger.showSnackBar(
                            const SnackBar(content: Text('Session revoked')),
                          );
                        },
                        child: const Icon(
                          CupertinoIcons.power,
                          color: CupertinoColors.destructiveRed,
                          size: 20,
                        ),
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
    );
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
    var enabled = profile['enabled'] as bool? ?? false;
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => GlassAlertDialog(
          title: const Text('Business profile'),
          content: Column(
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
            ],
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

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final user = auth.currentUser;
    final keys = context.watch<KeyProvider>();
    final settings = context.watch<SettingsProvider>();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: const GlassAppBar(title: Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
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
                              Text(
                                user.displayName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 17,
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
                          if (user.profileDisplayName?.trim().isNotEmpty ==
                              true) ...[
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
                          ],
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
                      Icons.arrow_forward_ios_rounded,
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
                _GlassDivider(),
                _GlassTile(
                  icon: Icons.contacts_outlined,
                  title: 'Private Contacts',
                  subtitle:
                      'Username discovery, QR bundles, and one-time links',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const PrivateContactsScreen(),
                    ),
                  ),
                ),
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
                _GlassDivider(),
                _GlassTile(
                  icon: Icons.devices_outlined,
                  title: 'Active sessions',
                  subtitle: 'Review and revoke signed-in devices',
                  onTap: _manageSessions,
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
                _GlassSwitchTile(
                  icon: Icons.wifi_tethering,
                  title: 'Background WebSocket',
                  subtitle: 'Live connection for real-time notifications',
                  value: settings.wsBackgroundEnabled,
                  onChanged: (v) => _setWsBackground(v, settings),
                ),
                _GlassDivider(),
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
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Turn off Strict Privacy before enabling link previews',
                          ),
                        ),
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
        color: Theme.of(
          context,
        ).colorScheme.primary.withValues(alpha: 0.90),
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
      trailing: trailing ?? GlassListTile.chevron,
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
