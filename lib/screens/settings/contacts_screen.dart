import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/contact_bundle.dart';
import '../../providers/settings_provider.dart';
import '../../services/api_service.dart';
import '../../utils/identity_qr.dart';
import '../../widgets/glass.dart';
import '../chat/chat_screen.dart';

/// Lists the private contacts the user has saved (via QR scan, nearby mesh, or
/// contact links) with tap-to-message and swipe-to-remove, plus a "Share my
/// contact" action that mints a one-time contact link and renders it as a QR.
/// Previously these saved contacts were write-only — there was no screen to see
/// or use them, and the share-contact backend had no UI at all.
class ContactsScreen extends StatelessWidget {
  const ContactsScreen({super.key});

  Future<void> _openDm(BuildContext context, ContactBundle contact) async {
    final api = context.read<ApiService>();
    final navigator = Navigator.of(context);
    try {
      final conv = await api.openDM(contact.userId);
      await navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => ChatScreen(conversation: conv),
        ),
      );
    } catch (e) {
      if (context.mounted) {
        showAppToast(context, 'Could not open chat: $e', isError: true);
      }
    }
  }

  Future<void> _remove(BuildContext context, ContactBundle contact) async {
    await context.read<SettingsProvider>().removePrivateContact(contact.userId);
    if (context.mounted) {
      showAppToast(context, 'Removed ${contact.displayName}');
    }
  }

  Future<void> _shareMyContact(BuildContext context) async {
    final api = context.read<ApiService>();
    final messenger = ScaffoldMessenger.of(context);
    String? link;
    try {
      final result = await api.createContactLink();
      final token = result['token'] as String?;
      if (token == null || token.isEmpty) throw StateError('no token');
      link = contactLinkDeepLink(token: token);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not create a contact link: $e')),
      );
      return;
    }
    if (!context.mounted) return;
    final shareLink = link;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => GlassBottomSheetFrame(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const GlassSheetGrabber(),
            const GlassSheetHeader(
              icon: Icons.qr_code_2_rounded,
              title: 'Share my contact',
              subtitle: 'Scan or share this link to add you. Expires in 24h.',
            ),
            const SizedBox(height: 8),
            IdentityQrView(data: shareLink),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: GlassButtonWidget.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: shareLink));
                  showAppToast(context, 'Contact link copied');
                },
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: const Text('Copy link'),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final contacts = context.watch<SettingsProvider>().privateContacts.values
        .toList()
      ..sort(
        (a, b) => a.displayName.toLowerCase().compareTo(
          b.displayName.toLowerCase(),
        ),
      );
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: GlassAppBar(
        title: const Text('Contacts'),
        actions: [
          IconButton(
            tooltip: 'Share my contact',
            icon: const Icon(Icons.qr_code_2_rounded),
            onPressed: () => _shareMyContact(context),
          ),
        ],
      ),
      body: contacts.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.contacts_outlined,
                    size: 44,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 12),
                  const Text('No saved contacts yet.'),
                  const SizedBox(height: 6),
                  Text(
                    'Scan a contact QR or share yours to get started.',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
              itemCount: contacts.length,
              itemBuilder: (context, i) {
                final c = contacts[i];
                final initial = (c.displayName.isNotEmpty
                        ? c.displayName
                        : c.username.isNotEmpty
                        ? c.username
                        : '?')
                    .characters
                    .first
                    .toUpperCase();
                return Dismissible(
                  key: ValueKey('contact-${c.userId}'),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    color: scheme.error.withValues(alpha: 0.18),
                    child: Icon(Icons.delete_outline, color: scheme.error),
                  ),
                  confirmDismiss: (_) async {
                    await _remove(context, c);
                    return true;
                  },
                  child: GlassListTile(
                    leading: CircleAvatar(
                      backgroundColor: scheme.primaryContainer,
                      child: Text(initial),
                    ),
                    title: Text(
                      c.displayName.isNotEmpty ? c.displayName : c.username,
                    ),
                    subtitle: c.username.isNotEmpty ? Text('@${c.username}') : null,
                    trailing: const Icon(Icons.chat_bubble_outline_rounded),
                    onTap: () => _openDm(context, c),
                  ),
                );
              },
            ),
    );
  }
}
