import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../models/broadcast_list.dart';
import '../../models/user.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/glass.dart';

/// Broadcast lists: message many contacts at once. Each send fans out to a
/// separate sealed-sender DM, so recipients never learn they're on a list.
class BroadcastListsScreen extends StatelessWidget {
  const BroadcastListsScreen({super.key});

  List<User> _contacts(BuildContext context) {
    final me = context.read<AuthProvider>().currentUser?.id ?? '';
    final chat = context.read<ChatProvider>();
    final out = <User>[];
    final seen = <String>{};
    for (final c in chat.conversations.where((c) => c.isDM)) {
      final u = c.otherUser(me);
      if (u != null && seen.add(u.id)) out.add(u);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final lists = settings.broadcastLists;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassAppBar(
        title: const Text('Broadcast lists'),
        actions: [
          IconButton(
            tooltip: 'New list',
            icon: const Icon(Icons.add_rounded),
            onPressed: () => _editList(context, null),
          ),
        ],
      ),
      body: lists.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.campaign_outlined,
                      size: 48,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.35),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'No broadcast lists yet.\nCreate one to message several '
                      'contacts at once — each gets a private DM.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            )
          : ListView(
              padding: EdgeInsets.fromLTRB(
                12,
                MediaQuery.paddingOf(context).top + kToolbarHeight + 12,
                12,
                24,
              ),
              children: [
                for (final list in lists)
                  GlassCard(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: GlassListTile(
                      leading: const CircleAvatar(
                        child: Icon(Icons.campaign_rounded),
                      ),
                      title: Text(list.name),
                      subtitle: Text('${list.memberUserIds.length} recipients'),
                      onTap: () => _compose(context, list),
                      trailing: PopupMenuButton<String>(
                        onSelected: (v) {
                          if (v == 'edit') _editList(context, list);
                          if (v == 'delete') {
                            context.read<SettingsProvider>().removeBroadcastList(
                              list.id,
                            );
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'edit', child: Text('Edit')),
                          PopupMenuItem(value: 'delete', child: Text('Delete')),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  Future<void> _editList(BuildContext context, BroadcastList? existing) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final selected = <String>{...?existing?.memberUserIds};
    final contacts = _contacts(context);
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheet) => GlassBottomSheetFrame(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const GlassSheetGrabber(),
              Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: 'List name'),
                ),
              ),
              if (contacts.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Start a DM with someone first to add them.'),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final u in contacts)
                        CheckboxListTile(
                          value: selected.contains(u.id),
                          onChanged: (v) => setSheet(() {
                            if (v == true) {
                              selected.add(u.id);
                            } else {
                              selected.remove(u.id);
                            }
                          }),
                          title: Text(u.displayName),
                          subtitle: Text('@${u.username}'),
                        ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: GlassButtonWidget(
                  onPressed: () => Navigator.pop(sheetCtx, true),
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (saved != true || !context.mounted) return;
    final name = nameCtrl.text.trim();
    if (name.isEmpty || selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name and at least one contact required')),
      );
      return;
    }
    await context.read<SettingsProvider>().saveBroadcastList(
      BroadcastList(
        id: existing?.id ?? const Uuid().v4(),
        name: name,
        memberUserIds: selected.toList(),
      ),
    );
  }

  Future<void> _compose(BuildContext context, BroadcastList list) async {
    final textCtrl = TextEditingController();
    final send = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => GlassAlertDialog(
        title: Text('Broadcast to ${list.name}'),
        content: TextField(
          controller: textCtrl,
          autofocus: true,
          maxLines: 4,
          decoration: const InputDecoration(hintText: 'Message'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (send != true || !context.mounted) return;
    final text = textCtrl.text.trim();
    if (text.isEmpty) return;
    final chat = context.read<ChatProvider>();
    final messenger = ScaffoldMessenger.of(context);
    var ok = 0;
    for (final userId in list.memberUserIds) {
      try {
        final dm = await chat.openDM(userId);
        if (await chat.sendMessage(convID: dm.id, plaintext: text)) ok++;
      } catch (_) {}
    }
    if (!context.mounted) return;
    messenger.showSnackBar(
      SnackBar(content: Text('Sent to $ok/${list.memberUserIds.length}')),
    );
  }
}
