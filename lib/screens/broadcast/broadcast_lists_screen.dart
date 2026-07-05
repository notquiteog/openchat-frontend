import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassPullDownButton, GlassMenuItem;
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
    return GlassScreenScaffold(
      title: const Text('Broadcast lists'),
      actions: [
        IconButton(
          tooltip: 'New list',
          icon: const Icon(Icons.add_rounded),
          onPressed: () => _editList(context, null),
        ),
      ],
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
                  _BroadcastListRow(
                    list: list,
                    onTap: () => _compose(context, list),
                    onEdit: () => _editList(context, list),
                    onDelete: () => context
                        .read<SettingsProvider>()
                        .removeBroadcastList(list.id),
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
                        GlassListTile(
                          title: Text(u.displayName),
                          subtitle: Text('@${u.username}'),
                          trailing: GlassSwitch(
                            value: selected.contains(u.id),
                            onChanged: (v) => setSheet(() {
                              if (v) {
                                selected.add(u.id);
                              } else {
                                selected.remove(u.id);
                              }
                            }),
                          ),
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
    final name = nameCtrl.text.trim();
    nameCtrl.dispose();
    if (saved != true || !context.mounted) return;
    if (name.isEmpty || selected.isEmpty) {
      showAppToast(
        context,
        'Name and at least one contact required',
        isError: true,
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
    textCtrl.dispose();
    if (text.isEmpty) return;
    final chat = context.read<ChatProvider>();
    var ok = 0;
    for (final userId in list.memberUserIds) {
      try {
        final dm = await chat.openDM(userId);
        if (await chat.sendMessage(convID: dm.id, plaintext: text)) ok++;
      } catch (_) {}
    }
    if (!context.mounted) return;
    showAppToast(context, 'Sent to $ok/${list.memberUserIds.length}');
  }
}

/// Opaque content row for a single broadcast list. Glass is reserved for
/// floating chrome, so the scrolling rows render as flat themed fills (mirroring
/// the conversations list) rather than a GlassCard per row.
class _BroadcastListRow extends StatelessWidget {
  const _BroadcastListRow({
    required this.list,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  final BroadcastList list;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fill = isDark
        ? scheme.surfaceContainerHigh
        : scheme.surfaceContainerLow;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            child: Row(
              children: [
                const CircleAvatar(child: Icon(Icons.campaign_rounded)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        list.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${list.memberUserIds.length} recipients',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                GlassPullDownButton(
                  items: [
                    GlassMenuItem(title: 'Edit', onTap: onEdit),
                    GlassMenuItem(
                      title: 'Delete',
                      isDestructive: true,
                      onTap: onDelete,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
