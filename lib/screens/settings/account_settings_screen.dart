import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassFormField, GlassTextArea;
import 'package:provider/provider.dart';

import '../../config/api_config.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';
import '../../widgets/glass.dart';
import 'settings_widgets.dart';

/// Account & profile: who you are publicly. Edit your display name, username,
/// photo, and bio; manage your business profile. Login credentials, 2FA, and
/// device security live in Privacy & Security, not here.
class AccountSettingsScreen extends StatefulWidget {
  const AccountSettingsScreen({super.key});

  @override
  State<AccountSettingsScreen> createState() => _AccountSettingsScreenState();
}

class _AccountSettingsScreenState extends State<AccountSettingsScreen> {
  void _editProfile() {
    final user = context.read<AuthProvider>().currentUser;
    if (user == null) return;
    final api = context.read<ApiService>();
    final auth = context.read<AuthProvider>();

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
              if (ctx.mounted) {
                showAppToast(ctx, 'Upload failed: $e', isError: true);
              }
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
                  GlassFormField(
                    label: 'Display name',
                    child: GlassTextField(
                      controller: displayNameCtrl,
                      prefixIcon: const Icon(Icons.badge_outlined),
                      maxLength: 96,
                    ),
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
                  GlassFormField(
                    label: 'Bio',
                    child: GlassTextField(
                      controller: bioCtrl,
                      minLines: 1,
                      maxLines: 3,
                      maxLength: 200,
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
                        // Keep the dialog open until the save succeeds — if it
                        // fails (e.g. username taken) the user keeps their edits
                        // and can fix them instead of losing everything.
                        try {
                          await api.updateProfile(
                            username: username,
                            displayName: displayName,
                            // Send the empty string (not null) so an emptied bio
                            // actually clears server-side; null omits the field
                            // and the old bio would persist.
                            bio: bio,
                            avatarUrl: pendingAvatarUrl,
                          );
                          await auth.refreshCurrentUser();
                          if (ctx.mounted) Navigator.pop(ctx);
                        } catch (e) {
                          if (ctx.mounted) {
                            showAppToast(
                              ctx,
                              'Failed to update: $e',
                              isError: true,
                            );
                          }
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

  /// Seller side of paid DMs: set (or clear) the price a non-contact must pay
  /// from their wallet before they can send a first message.
  Future<void> _managePaidInbox() async {
    final api = context.read<ApiService>();
    var provider = 'btc';
    final amountCtrl = TextEditingController();
    try {
      final current = await api.getInboxPrice();
      if (current.provider.isNotEmpty) provider = current.provider;
      if ((double.tryParse(current.amount) ?? 0) > 0) {
        amountCtrl.text = current.amount;
      }
    } catch (_) {}
    if (!mounted) return;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => GlassAlertDialog(
          title: const Text('Paid inbox'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Non-contacts pay this once from their wallet before they can '
                'send you a first message. Leave empty (or 0) to turn it off.',
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  for (final p in const ['btc', 'xmr'])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(p.toUpperCase()),
                        selected: provider == p,
                        onSelected: (_) => setDlg(() => provider = p),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              GlassFormField(
                label: 'Amount (${provider.toUpperCase()})',
                child: GlassTextField(
                  controller: amountCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  placeholder: '0 to disable',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    final amountText = amountCtrl.text.trim();
    amountCtrl.dispose();
    if (saved != true || !mounted) return;
    final amount = (double.tryParse(amountText) ?? 0) <= 0 ? '0' : amountText;
    try {
      await api.setInboxPrice(provider: provider, amount: amount);
      if (mounted) {
        showAppToast(
          context,
          amount == '0' ? 'Paid inbox turned off' : 'Paid inbox updated',
        );
      }
    } catch (_) {
      if (mounted) showAppToast(context, 'Could not update', isError: true);
    }
  }

  Future<void> _manageBusinessProfile() async {
    final api = context.read<ApiService>();
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
                GlassFormField(
                  label: 'Display name',
                  child: GlassTextField(controller: displayCtrl),
                ),
                const SizedBox(height: 10),
                GlassFormField(
                  label: 'Greeting message',
                  child: GlassTextField(controller: greetingCtrl),
                ),
                const SizedBox(height: 10),
                GlassFormField(
                  label: 'Away message',
                  child: GlassTextField(controller: awayCtrl),
                ),
                const SizedBox(height: 10),
                GlassFormField(
                  label: 'Quick replies',
                  child: GlassTextArea(
                    controller: quickRepliesCtrl,
                    minLines: 2,
                    maxLines: 5,
                    placeholder: '/hours | We are open 9-5 today',
                  ),
                ),
                const SizedBox(height: 10),
                GlassFormField(
                  label: 'Weekday hours',
                  child: GlassTextField(
                    controller: weekdayHoursCtrl,
                    placeholder: 'Mon-Fri 09:00-17:00',
                  ),
                ),
                const SizedBox(height: 10),
                GlassFormField(
                  label: 'Saturday hours',
                  child: GlassTextField(
                    controller: saturdayHoursCtrl,
                    placeholder: 'Closed',
                  ),
                ),
                const SizedBox(height: 10),
                GlassFormField(
                  label: 'Sunday hours',
                  child: GlassTextField(
                    controller: sundayHoursCtrl,
                    placeholder: 'Closed',
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
                if (mounted) showAppToast(context, 'Business profile saved');
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

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().currentUser;
    final scheme = Theme.of(context).colorScheme;

    return SettingsScaffold(
      title: 'Account',
      children: [
        if (user != null) ...[
          GestureDetector(
            onTap: _editProfile,
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
                        Text(
                          user.displayName,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 18,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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
                          const SizedBox(height: 4),
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
                    Icons.edit_outlined,
                    size: 18,
                    color: scheme.onSurface.withValues(alpha: 0.40),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
        ],

        const SettingsSectionHeader('Profile'),
        SettingsGroup(
          children: [
            SettingsTile(
              icon: Icons.edit_outlined,
              title: 'Edit profile',
              subtitle: 'Name, username, photo, and bio',
              onTap: _editProfile,
            ),
            if (user != null)
              SettingsTile(
                icon: Icons.badge_outlined,
                title: 'Account ID',
                subtitle: user.id,
                trailing: IconButton(
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  tooltip: 'Copy account ID',
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: user.id));
                    if (context.mounted) {
                      showAppToast(context, 'Account ID copied');
                    }
                  },
                ),
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: user.id));
                  if (context.mounted) {
                    showAppToast(context, 'Account ID copied');
                  }
                },
              ),
          ],
        ),
        const SizedBox(height: 20),

        const SettingsSectionHeader('Business'),
        SettingsGroup(
          children: [
            SettingsTile(
              icon: Icons.business_center_outlined,
              title: 'Business profile',
              subtitle: 'Greeting, away message, hours, and quick replies',
              onTap: _manageBusinessProfile,
            ),
            SettingsTile(
              icon: Icons.mark_email_unread_outlined,
              title: 'Paid inbox',
              subtitle: 'Charge non-contacts for a first message',
              onTap: _managePaidInbox,
            ),
          ],
        ),
      ],
    );
  }
}
