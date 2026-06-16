import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../../config/api_config.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';
import '../../services/secure_storage_service.dart';
import '../../widgets/glass.dart';
import '../admin/admin_home_screen.dart';
import 'account_settings_screen.dart';
import 'appearance_settings_screen.dart';
import 'calls_settings_screen.dart';
import 'content_settings_screen.dart';
import 'data_storage_settings_screen.dart';
import 'notifications_settings_screen.dart';
import 'premium_screen.dart';
import 'settings_widgets.dart';
import 'trust_center_screen.dart';
import 'wallet_screen.dart';

/// The Settings hub: a slim iOS/Telegram-style entry point. The profile card
/// and a short list of category rows drill into focused sub-pages; every
/// individual control lives on exactly one of those sub-pages.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final Future<PackageInfo> _packageInfoFuture;

  @override
  void initState() {
    super.initState();
    _packageInfoFuture = PackageInfo.fromPlatform();
  }

  bool get _isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS);

  void _open(Widget screen) {
    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => screen));
  }

  Future<void> _showAbout() async {
    final info = await _packageInfoFuture;
    if (!mounted) return;
    final version = 'v${info.version}+${info.buildNumber}';
    await showDialog<void>(
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
            const SizedBox(height: 8),
            Text(version, style: Theme.of(ctx).textTheme.bodySmall),
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
    );
  }

  Future<void> _signOut() async {
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
    if (doSignOut && mounted) {
      await context.read<AuthProvider>().logout();
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
                    ? const GlassProgressIndicator.circular(
                        size: 16,
                        strokeWidth: 2,
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
    final user = context.watch<AuthProvider>().currentUser;
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
          // ── Profile header → Account page ────────────────────────────────
          if (user != null) ...[
            GestureDetector(
              onTap: () => _open(const AccountSettingsScreen()),
              child: GlassCard(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    Container(
                      width: 64,
                      height: 64,
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
                        radius: 32,
                        backgroundImage: user.avatarUrl != null
                            ? CachedNetworkImageProvider(
                                ApiConfig.resolveMedia(user.avatarUrl!),
                              )
                            : null,
                        child: user.avatarUrl == null
                            ? Text(
                                user.avatarInitial,
                                style: const TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w700,
                                ),
                              )
                            : null,
                      ),
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
                                    fontSize: 18,
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
                          if (user.bio?.isNotEmpty == true) ...[
                            const SizedBox(height: 3),
                            Text(
                              user.bio!,
                              style: TextStyle(
                                fontSize: 13,
                                color: scheme.onSurface.withValues(alpha: 0.55),
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
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

          // ── Categories ───────────────────────────────────────────────────
          SettingsGroup(
            children: [
              SettingsTile(
                icon: Icons.person_outline_rounded,
                title: 'Account',
                subtitle: 'Profile, username, and business profile',
                onTap: () => _open(const AccountSettingsScreen()),
              ),
              SettingsTile(
                icon: Icons.shield_outlined,
                title: 'Privacy & Security',
                subtitle: 'Keys, encrypted chats, devices, locks, and privacy',
                onTap: () => _open(const TrustCenterScreen()),
              ),
              SettingsTile(
                icon: Icons.notifications_outlined,
                title: 'Notifications',
                subtitle: 'Delivery, quiet hours, and previews',
                onTap: () => _open(const NotificationsSettingsScreen()),
              ),
              SettingsTile(
                icon: Icons.brightness_6_outlined,
                title: 'Appearance',
                subtitle: 'Theme, colour, text size, and accessibility',
                onTap: () => _open(const AppearanceSettingsScreen()),
              ),
              SettingsTile(
                icon: Icons.sd_storage_outlined,
                title: 'Data & Storage',
                subtitle: 'Auto-download, link previews, and tools',
                onTap: () => _open(const DataStorageSettingsScreen()),
              ),
              SettingsTile(
                icon: Icons.call_outlined,
                title: 'Calls',
                subtitle: 'Data saver and voice-only options',
                onTap: () => _open(const CallsSettingsScreen()),
              ),
              SettingsTile(
                icon: Icons.emoji_emotions_outlined,
                title: 'Stickers & Emoji',
                subtitle: 'Sticker packs, custom emoji, bots, and mini apps',
                onTap: () => _open(const ContentSettingsScreen()),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // ── Wallet & Premium ─────────────────────────────────────────────
          SettingsGroup(
            children: [
              SettingsTile(
                icon: Icons.account_balance_wallet_outlined,
                title: 'Wallet',
                subtitle: 'BTC/XMR balances, withdrawals, and history',
                onTap: () => _open(const WalletScreen()),
              ),
              SettingsTile(
                icon: user?.isPremium == true
                    ? Icons.workspace_premium
                    : Icons.workspace_premium_outlined,
                iconColor: user?.isPremium == true ? Colors.amber : null,
                title: 'OpenChat Premium',
                subtitle: user?.isPremium == true
                    ? 'Active${user?.premiumUntil != null ? ' until ${user!.premiumUntil!.toLocal().toString().split(' ').first}' : ''}'
                    : '€10 / year — more stickers, emoji, bots, wallpapers',
                onTap: () => _open(const PremiumScreen()),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // ── System Admin (admins only) ───────────────────────────────────
          if (user?.isSystemAdmin ?? false) ...[
            SettingsGroup(
              children: [
                SettingsTile(
                  icon: Icons.admin_panel_settings_outlined,
                  title: 'System Admin',
                  subtitle: 'Reports, audit, and server health',
                  onTap: () => _open(const AdminHomeScreen()),
                ),
              ],
            ),
            const SizedBox(height: 24),
          ],

          // ── About ────────────────────────────────────────────────────────
          SettingsGroup(
            children: [
              FutureBuilder<PackageInfo>(
                future: _packageInfoFuture,
                builder: (context, snapshot) {
                  final version = snapshot.data == null
                      ? ''
                      : 'v${snapshot.data!.version}+${snapshot.data!.buildNumber}';
                  return SettingsTile(
                    icon: Icons.info_outline,
                    title: 'About OpenChat',
                    subtitle: version.isEmpty
                        ? 'Open Source • E2E Encrypted'
                        : '$version • Open Source • E2E Encrypted',
                    onTap: _showAbout,
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 24),

          // ── Account actions ──────────────────────────────────────────────
          SettingsGroup(
            children: [
              SettingsTile(
                icon: Icons.logout_rounded,
                iconColor: scheme.error,
                title: 'Sign Out',
                titleColor: scheme.error,
                trailing: const SizedBox.shrink(),
                onTap: _signOut,
              ),
              SettingsTile(
                icon: Icons.delete_forever_outlined,
                iconColor: scheme.error,
                title: 'Delete Account Everywhere',
                titleColor: scheme.error,
                subtitle: 'Purge account, messages, keys, and username',
                trailing: const SizedBox.shrink(),
                onTap: _deleteAccountEverywhere,
              ),
              if (_isDesktop)
                SettingsTile(
                  icon: Icons.delete_forever_outlined,
                  iconColor: scheme.error,
                  title: 'Clear All Local Data',
                  titleColor: scheme.error,
                  subtitle: 'Remove stored keys, tokens, and preferences',
                  trailing: const SizedBox.shrink(),
                  onTap: _clearAllData,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
