import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:image_picker/image_picker.dart';
import 'package:local_auth/local_auth.dart';
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
import '../bots/bot_management_screen.dart';
import '../stickers/sticker_pack_screen.dart';
import 'pgp_keys_screen.dart';
import 'premium_screen.dart';

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

  @override
  void initState() {
    super.initState();
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
            SnackBar(content: Text('Biometric unlock unavailable: $e')));
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
        messenger
            .showSnackBar(SnackBar(content: Text('App lock unavailable: $e')));
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
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Privacy notice'),
          content: const Text(
            'Push notifications route metadata (sender, device ID) through '
            'Google Firebase servers. No message content is sent — only '
            'a notification trigger.\n\n'
            'If you value full metadata privacy, use Background WebSocket '
            'notifications instead.',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Enable')),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;

      // Disable WebSocket background before enabling push — only one
      // notification channel should be active at a time.
      if (settings.wsBackgroundEnabled) {
        await BackgroundWsService.stop();
        await settings.setWsBackgroundEnabled(false);
      }

      final ok = await PushNotificationService.init(api: api);
      if (!mounted) return;
      if (!ok) {
        messenger.showSnackBar(const SnackBar(
          content: Text(
            'Firebase is not configured on this server. '
            'Ask your server operator to set up Firebase.',
          ),
        ));
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
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Battery notice'),
          content: const Text(
            'Background WebSocket keeps a persistent connection to the server '
            'even when the app is closed. This provides real-time notifications '
            'without relying on Google Firebase, but will increase battery usage.\n\n'
            'On iOS the OS may still suspend the connection; push notifications '
            'are more reliable there.',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Enable')),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;

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
        messenger.showSnackBar(const SnackBar(
          content: Text(
            'Notification permission is required for background notifications.',
          ),
        ));
        return;
      }

      final storage = context.read<SecureStorageService>();
      final token = await storage.getAccessToken() ?? '';
      final started = await BackgroundWsService.start(
        accessToken: token,
        showSensitive: settings.notificationSensitiveContent,
      );
      if (!mounted) return;
      if (!started) {
        messenger.showSnackBar(const SnackBar(
          content: Text(
            'Background WebSocket could not start. Try again.',
          ),
        ));
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

    final bioCtrl = TextEditingController(text: user.bio ?? '');
    String? pendingAvatarUrl = user.avatarUrl;
    bool uploading = false;

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDialog) {
          Future<void> pickAndUpload() async {
            final picked = await ImagePicker()
                .pickImage(source: ImageSource.gallery, imageQuality: 90);
            if (picked == null) return;
            setStateDialog(() => uploading = true);
            try {
              final bytes = await picked.readAsBytes();
              final url = await api.uploadAvatar(
                  fileBytes: bytes, filename: picked.name);
              setStateDialog(() {
                pendingAvatarUrl = url;
                uploading = false;
              });
            } catch (e) {
              setStateDialog(() => uploading = false);
              messenger
                  .showSnackBar(SnackBar(content: Text('Upload failed: $e')));
            }
          }

          return AlertDialog(
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
                                ApiConfig.resolveMedia(pendingAvatarUrl!))
                            : null,
                        child: pendingAvatarUrl == null
                            ? Text(user.username[0].toUpperCase(),
                                style: const TextStyle(fontSize: 28))
                            : null,
                      ),
                      if (uploading) const CircularProgressIndicator(),
                      if (!uploading)
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: CircleAvatar(
                            radius: 12,
                            backgroundColor: Theme.of(ctx).colorScheme.primary,
                            child: const Icon(Icons.camera_alt,
                                size: 14, color: Colors.white),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
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
                  child: const Text('Cancel')),
              FilledButton(
                onPressed: uploading
                    ? null
                    : () async {
                        final bio = bioCtrl.text.trim();
                        Navigator.pop(ctx);
                        try {
                          await api.updateProfile(
                            bio: bio.isEmpty ? null : bio,
                            avatarUrl: pendingAvatarUrl,
                          );
                          await auth.refreshCurrentUser();
                        } catch (e) {
                          messenger.showSnackBar(
                              SnackBar(content: Text('Failed to update: $e')));
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
    Color(0xFFFFA726), Color(0xFF66BB6A), Color(0xFF26A69A),
    Color(0xFF26C6DA), Color(0xFF42A5F5),
  ];

  Future<void> _pickAccentColor(
      BuildContext context, SettingsProvider settings) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Accent colour'),
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
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('Change Password'),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: currentCtrl,
                  obscureText: true,
                  decoration:
                      const InputDecoration(labelText: 'Current password'),
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
                  decoration:
                      const InputDecoration(labelText: 'Confirm new password'),
                  validator: (v) =>
                      v != newCtrl.text ? 'Passwords do not match' : null,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: submitting ? null : () => Navigator.pop(ctx),
                child: const Text('Cancel')),
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
                            const SnackBar(content: Text('Password changed')));
                      } catch (e) {
                        setDlg(() => submitting = false);
                        messenger.showSnackBar(
                            SnackBar(content: Text('Failed: $e')));
                      }
                    },
              child: submitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Change'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _clearAllData() async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear all local data?'),
        content: const Text(
          'This permanently removes everything stored on this device: '
          'your PGP private key, session tokens, and all app preferences.\n\n'
          'Use this to fix problems caused by stale data from a previous '
          'install — the secure storage on desktop persists across reinstalls.\n\n'
          'You will be signed out and will need to sign in again and '
          're-import your PGP key.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

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

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          // ── Profile header ──────────────────────────────────────────────────
          if (user != null)
            ListTile(
              leading: CircleAvatar(
                backgroundImage: user.avatarUrl != null
                    ? CachedNetworkImageProvider(
                        ApiConfig.resolveMedia(user.avatarUrl!))
                    : null,
                child: user.avatarUrl == null
                    ? Text(user.username[0].toUpperCase())
                    : null,
              ),
              title: Row(
                children: [
                  Text('@${user.username}',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  if (user.isSystemAdmin)
                    const Padding(
                      padding: EdgeInsets.only(left: 6),
                      child: Icon(Icons.verified, size: 16, color: Colors.blue),
                    ),
                  if (user.isPremium)
                    const Padding(
                      padding: EdgeInsets.only(left: 6),
                      child: Icon(Icons.workspace_premium,
                          size: 16, color: Colors.amber),
                    ),
                ],
              ),
              subtitle: Text(user.bio ?? 'No bio set'),
              trailing: const Icon(Icons.edit_outlined),
              onTap: _editProfile,
            ),

          const Divider(),

          // ── Security section ────────────────────────────────────────────────
          const _SectionHeader('Security & Keys'),

          ListTile(
            leading: Icon(
              keys.hasKey ? Icons.verified_user : Icons.warning_amber,
              color: keys.hasKey ? Colors.green : Colors.orange,
            ),
            title: const Text('PGP Keys'),
            subtitle: keys.hasKey
                ? Text(
                    'Fingerprint: …${keys.fingerprint?.substring((keys.fingerprint?.length ?? 8) - 8)}')
                : const Text('No key on device',
                    style: TextStyle(color: Colors.orange)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PgpKeysScreen()),
            ),
          ),

          ListTile(
            leading: const Icon(Icons.password_outlined),
            title: const Text('Change Password'),
            subtitle: const Text('Update your account login password'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _changePassword,
          ),

          if (_biometricAvailable) ...[
            SwitchListTile(
              secondary: const Icon(Icons.fingerprint),
              title: const Text('Biometric Key Unlock'),
              subtitle: const Text(
                  'Require fingerprint / face to decrypt messages and use your PGP key'),
              value: _biometricEnabled,
              onChanged: _setBiometric,
            ),
            SwitchListTile(
              secondary: const Icon(Icons.lock_outline),
              title: const Text('App Lock'),
              subtitle: const Text(
                  'Require biometrics to open OpenChat after it leaves the background'),
              value: _appLockEnabled,
              onChanged: _setAppLock,
            ),
          ],

          SwitchListTile(
            secondary: const Icon(Icons.group_add_outlined),
            title: const Text('Allow others to add me to groups'),
            subtitle: const Text('Other users can add you to group chats'),
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
                      SnackBar(content: Text('Failed to update: $e')));
                }
              }
            },
          ),

          const Divider(),

          // ── Notifications ────────────────────────────────────────────────────
          const _SectionHeader('Notifications'),

          // Push notifications are only available on Android and iOS.
          // Linux is not supported by firebase_messaging; desktop users rely
          // on the Background WebSocket option below instead.
          if (!kIsWeb &&
              (defaultTargetPlatform == TargetPlatform.android ||
                  defaultTargetPlatform == TargetPlatform.iOS))
            SwitchListTile(
              secondary: const Icon(Icons.notifications_outlined),
              title: const Text('Push Notifications'),
              subtitle: const Text(
                  'Receive notifications via Firebase when the app is closed'),
              value: settings.pushNotificationsEnabled,
              onChanged: (v) => _setPushEnabled(v, settings),
            ),

          SwitchListTile(
            secondary: const Icon(Icons.wifi_tethering),
            title: const Text('Background WebSocket'),
            subtitle: const Text(
                'Keep a live connection open for real-time notifications '
                '(uses more battery)'),
            value: settings.wsBackgroundEnabled,
            onChanged: (v) => _setWsBackground(v, settings),
          ),

          SwitchListTile(
            secondary: const Icon(Icons.visibility_outlined),
            title: const Text('Show Sensitive Content'),
            subtitle: const Text(
                'Display sender name and message preview in notifications. '
                'Off shows only "New message"'),
            value: settings.notificationSensitiveContent,
            onChanged: settings.setNotificationSensitiveContent,
          ),

          const Divider(),

          // ── Premium ─────────────────────────────────────────────────────────
          ListTile(
            leading: Icon(
              user?.isPremium == true
                  ? Icons.workspace_premium
                  : Icons.workspace_premium_outlined,
              color: user?.isPremium == true ? Colors.amber : null,
            ),
            title: const Text('OpenChat Premium'),
            subtitle: Text(
              user?.isPremium == true
                  ? 'Active${user?.premiumUntil != null ? ' until ${user!.premiumUntil!.toLocal().toString().split(' ').first}' : ''}'
                  : '€10 / year or €2 / month — more stickers, more bots, custom channel wallpapers',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PremiumScreen()),
            ),
          ),

          const Divider(),

          // ── Appearance ──────────────────────────────────────────────────────
          const _SectionHeader('Appearance'),

          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('Accent colour'),
            subtitle: const Text('Theme colour used across the app'),
            trailing: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: settings.seedColor,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.grey.withValues(alpha: 0.5)),
              ),
            ),
            onTap: () => _pickAccentColor(context, settings),
          ),

          SwitchListTile(
            secondary: const Icon(Icons.campaign_outlined),
            title: const Text('Channels in their own tab'),
            subtitle:
                const Text('Off: channels appear in your Chats list (default)'),
            value: settings.channelsOwnTab,
            onChanged: settings.setChannelsOwnTab,
          ),

          SwitchListTile(
            secondary: const Icon(Icons.smart_toy_outlined),
            title: const Text('Bots in their own tab'),
            subtitle: const Text(
                'Off: bot chats appear in your Chats list (default)'),
            value: settings.botsOwnTab,
            onChanged: settings.setBotsOwnTab,
          ),

          const Divider(),

          // ── Content & Bots ──────────────────────────────────────────────────
          const _SectionHeader('Content & Bots'),

          ListTile(
            leading: const Icon(Icons.emoji_emotions_outlined),
            title: const Text('Sticker Packs'),
            subtitle: const Text('Create and manage your sticker packs'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const StickerPackScreen()),
            ),
          ),

          ListTile(
            leading: const Icon(Icons.smart_toy_outlined),
            title: const Text('My Bots'),
            subtitle: const Text('Create and manage bots'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const BotManagementScreen()),
            ),
          ),

          const Divider(),

          // ── About ───────────────────────────────────────────────────────────
          const _SectionHeader('About'),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('OpenChat'),
            subtitle: const Text('v0.2.1 • Open Source • E2E Encrypted'),
            onTap: () => showAboutDialog(
              context: context,
              applicationName: 'OpenChat',
              applicationVersion: '0.2.1',
              applicationIcon: Image.asset('assets/images/logo.png',
                  height: 48,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink()),
              applicationLegalese:
                  'Open source, end-to-end encrypted messenger.\n'
                  'Uses OpenPGP (RFC 4880) for encryption.',
            ),
          ),

          const Divider(),

          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: const Text('Sign Out', style: TextStyle(color: Colors.red)),
            onTap: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Sign Out'),
                  content:
                      const Text('Your PGP keys will remain on this device.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Sign Out')),
                  ],
                ),
              );
              if (confirmed == true && context.mounted) {
                await context.read<AuthProvider>().logout();
              }
            },
          ),

          // Desktop secure stores (Windows Credential Manager, macOS Keychain,
          // Linux libsecret) persist across app reinstalls. Provide an explicit
          // wipe for users who need a clean slate after an upgrade.
          if (!kIsWeb &&
              (defaultTargetPlatform == TargetPlatform.windows ||
                  defaultTargetPlatform == TargetPlatform.linux ||
                  defaultTargetPlatform == TargetPlatform.macOS)) ...[
            const Divider(),
            ListTile(
              leading:
                  const Icon(Icons.delete_forever_outlined, color: Colors.red),
              title: const Text('Clear All Local Data',
                  style: TextStyle(color: Colors.red)),
              subtitle: const Text(
                  'Remove stored keys, tokens, and preferences from this device'),
              onTap: _clearAllData,
            ),
          ],
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
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.primary,
            letterSpacing: 0.8,
          ),
        ),
      );
}
