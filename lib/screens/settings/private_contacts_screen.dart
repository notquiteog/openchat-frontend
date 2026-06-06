import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/contact_bundle.dart';
import '../../providers/auth_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/api_service.dart';
import '../../utils/identity_qr.dart';
import '../../widgets/glass.dart';
import 'identity_qr_scanner_screen.dart';

class PrivateContactsScreen extends StatefulWidget {
  const PrivateContactsScreen({super.key});

  @override
  State<PrivateContactsScreen> createState() => _PrivateContactsScreenState();
}

class _PrivateContactsScreenState extends State<PrivateContactsScreen> {
  final _usernameCtrl = TextEditingController();
  final _displayNameCtrl = TextEditingController();
  bool _publicDiscovery = true;
  bool _syncedProfile = false;
  bool _savingDiscovery = false;
  bool _creatingLink = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final user = context.watch<AuthProvider>().currentUser;
    if (!_syncedProfile && user != null) {
      _usernameCtrl.text = user.username;
      _displayNameCtrl.text = user.profileDisplayName ?? '';
      _publicDiscovery = user.publicDiscovery;
      _syncedProfile = true;
    }
  }

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _displayNameCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveDiscovery() async {
    final username = _usernameCtrl.text.trim().toLowerCase();
    if (username.isEmpty) {
      _snack('Username required');
      return;
    }
    if (username.isNotEmpty &&
        !RegExp(r'^[a-z0-9_]{3,32}$').hasMatch(username)) {
      _snack(
        'Username must be 3-32 lowercase letters, numbers, or underscores',
      );
      return;
    }
    setState(() => _savingDiscovery = true);
    final api = context.read<ApiService>();
    final auth = context.read<AuthProvider>();
    try {
      await api.updateProfile(
        username: username,
        displayName: _displayNameCtrl.text.trim(),
        publicDiscovery: _publicDiscovery,
      );
      await auth.refreshCurrentUser();
      _snack('Discovery settings saved');
    } catch (e) {
      _snack('Failed: $e');
    } finally {
      if (mounted) setState(() => _savingDiscovery = false);
    }
  }

  Future<void> _createOneTimeLink() async {
    setState(() => _creatingLink = true);
    try {
      final data = await context.read<ApiService>().createContactLink();
      final token = data['token']?.toString() ?? '';
      if (token.isEmpty) throw Exception('missing token');
      final link = contactLinkDeepLink(token: token);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => GlassAlertDialog(
          title: const Text('One-time contact link'),
          content: SelectableText(link),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    } catch (e) {
      _snack('Failed: $e');
    } finally {
      if (mounted) setState(() => _creatingLink = false);
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().currentUser;
    final settings = context.watch<SettingsProvider>();
    final contacts = settings.privateContacts.values.toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    final bundle = user == null ? null : ContactBundle.fromUser(user);

    return Scaffold(
      appBar: const GlassAppBar(title: Text('Private Contacts')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          if (user != null) ...[
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Account ID',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    user.id,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _displayNameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Display name',
                      prefixIcon: Icon(Icons.badge_outlined),
                    ),
                    maxLength: 96,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _usernameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Username',
                      prefixIcon: Icon(Icons.alternate_email_rounded),
                    ),
                    autocorrect: false,
                  ),
                  const SizedBox(height: 8),
                  GlassListTile(
                    title: const Text('Public discovery',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: const Text('Allow username search'),
                    trailing: GlassSwitch(
                      value: _publicDiscovery,
                      onChanged: (value) =>
                          setState(() => _publicDiscovery = value),
                      activeColor: Theme.of(context).colorScheme.primary,
                      enableHaptics: true,
                    ),
                    onTap: () =>
                        setState(() => _publicDiscovery = !_publicDiscovery),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _savingDiscovery ? null : _saveDiscovery,
                    icon: _savingDiscovery
                        ? const GlassProgressIndicator.circular(size: 16, strokeWidth: 2)
                        : const Icon(Icons.save_outlined),
                    label: const Text('Save'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (bundle != null)
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    'My Contact QR',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 16),
                  IdentityQrView(data: contactBundleQrPayload(bundle)),
                  const SizedBox(height: 16),
                  Text(
                    formatIdentityFingerprint(bundle.keyFingerprint),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const IdentityQrScannerScreen(),
                            ),
                          ),
                          icon: const Icon(Icons.qr_code_scanner_rounded),
                          label: const Text('Scan'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _creatingLink ? null : _createOneTimeLink,
                          icon: _creatingLink
                              ? const GlassProgressIndicator.circular(size: 16, strokeWidth: 2)
                              : const Icon(Icons.link_rounded),
                          label: const Text('Link'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          GlassCard(
            padding: EdgeInsets.zero,
            child: contacts.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('No private contacts saved'),
                  )
                : Column(
                    children: [
                      for (var i = 0; i < contacts.length; i++) ...[
                        _ContactTile(contact: contacts[i]),
                        if (i != contacts.length - 1)
                          Divider(
                            height: 1,
                            color: Theme.of(context).colorScheme.outlineVariant
                                .withValues(alpha: 0.25),
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

class _ContactTile extends StatelessWidget {
  final ContactBundle contact;

  const _ContactTile({required this.contact});

  @override
  Widget build(BuildContext context) {
    final settings = context.read<SettingsProvider>();
    return GlassListTile(
      leading: const CircleAvatar(child: Icon(Icons.person_outline)),
      title: Text(contact.title),
      subtitle: Text(
        contact.username.isNotEmpty
            ? contact.safetyNumber
            : 'Account ${contact.userId}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        tooltip: 'Remove',
        icon: const Icon(Icons.delete_outline),
        onPressed: () => settings.removePrivateContact(contact.userId),
      ),
    );
  }
}
