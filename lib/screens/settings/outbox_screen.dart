import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../services/offline_outbox_service.dart';
import '../../widgets/glass.dart';

class OutboxScreen extends StatefulWidget {
  const OutboxScreen({super.key});

  @override
  State<OutboxScreen> createState() => _OutboxScreenState();
}

class _OutboxScreenState extends State<OutboxScreen> {
  Future<void> _showItemActions(OfflineOutboxItem item) async {
    String? choice;
    await showGlassActionSheet<void>(
      context: context,
      title: _outboxActionLabel(item.action),
      actions: [
        GlassActionSheetAction(
          label: 'Retry now',
          onPressed: () => choice = 'retry',
        ),
        GlassActionSheetAction(
          label: 'Discard',
          style: GlassActionSheetStyle.destructive,
          onPressed: () => choice = 'discard',
        ),
      ],
    );
    if (!mounted || choice == null) return;
    final chat = context.read<ChatProvider>();
    if (choice == 'retry') {
      await chat.retryOutboxItem(item.id);
      if (mounted) showAppToast(context, 'Retry queued');
      return;
    }
    var confirmed = false;
    await GlassDialog.show<void>(
      context: context,
      title: 'Discard item?',
      message: 'This removes the queued send from this device.',
      actions: [
        GlassDialogAction(
          label: 'Cancel',
          onPressed: () => Navigator.pop(context),
        ),
        GlassDialogAction(
          label: 'Discard',
          isDestructive: true,
          onPressed: () {
            confirmed = true;
            Navigator.pop(context);
          },
        ),
      ],
    );
    if (!mounted || !confirmed) return;
    await chat.discardOutboxItem(item.id);
    if (mounted) showAppToast(context, 'Outbox item discarded');
  }

  Future<void> _clearAll() async {
    var confirmed = false;
    await GlassDialog.show<void>(
      context: context,
      title: 'Clear outbox?',
      message: 'This removes every queued send from this device.',
      actions: [
        GlassDialogAction(
          label: 'Cancel',
          onPressed: () => Navigator.pop(context),
        ),
        GlassDialogAction(
          label: 'Clear all',
          isDestructive: true,
          onPressed: () {
            confirmed = true;
            Navigator.pop(context);
          },
        ),
      ],
    );
    if (!mounted || !confirmed) return;
    await context.read<ChatProvider>().clearOutbox();
    if (mounted) showAppToast(context, 'Outbox cleared');
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatProvider>();
    final items = chat.outboxItems;
    final currentUserId = context.read<AuthProvider>().currentUser?.id ?? '';
    final grouped = <String, List<OfflineOutboxItem>>{};
    for (final item in items) {
      grouped.putIfAbsent(item.conversationId, () => []).add(item);
    }

    return GlassScreenScaffold.list(
      title: const Text('Outbox'),
      actions: [
        if (items.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'Clear all',
            onPressed: _clearAll,
          ),
      ],
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        if (items.isEmpty)
          _OutboxEmptyState()
        else
          for (final entry in grouped.entries) ...[
            _OutboxSectionHeader(
              title:
                  chat
                      .conversationById(entry.key)
                      ?.displayName(currentUserId) ??
                  'Unknown conversation',
            ),
            GlassCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (var i = 0; i < entry.value.length; i++)
                    _OutboxItemTile(
                      item: entry.value[i],
                      isLast: i == entry.value.length - 1,
                      onTap: () => _showItemActions(entry.value[i]),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
      ],
    );
  }
}

class _OutboxEmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 96),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.outbox_outlined,
              size: 44,
              color: scheme.onSurface.withValues(alpha: 0.36),
            ),
            const SizedBox(height: 14),
            Text(
              'Outbox is clear',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              'Nothing waiting to send',
              style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.55)),
            ),
          ],
        ),
      ),
    );
  }
}

class _OutboxSectionHeader extends StatelessWidget {
  final String title;

  const _OutboxSectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w800,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class _OutboxItemTile extends StatelessWidget {
  final OfflineOutboxItem item;
  final VoidCallback onTap;
  final bool isLast;

  const _OutboxItemTile({
    required this.item,
    required this.onTap,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = _outboxStatusColor(context, item.status);
    final icon = _outboxStatusIcon(item.status);
    final subtitle = _outboxSubtitle(item);
    return GlassListTile(
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: 0.13),
        ),
        child: item.status == OfflineOutboxStatus.sending
            ? Padding(
                padding: const EdgeInsets.all(9),
                child: GlassProgressIndicator.circular(
                  size: 16,
                  strokeWidth: 2,
                ),
              )
            : Icon(icon, size: 18, color: color),
      ),
      title: Text(
        _outboxActionLabel(item.action),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(
        subtitle,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          height: 1.28,
          color: scheme.onSurface.withValues(alpha: 0.58),
        ),
      ),
      trailing: Icon(
        CupertinoIcons.ellipsis_circle,
        size: 20,
        color: scheme.onSurface.withValues(alpha: 0.45),
      ),
      onTap: onTap,
      isLast: isLast,
    );
  }
}

String _outboxActionLabel(OfflineOutboxAction action) => switch (action) {
  OfflineOutboxAction.sendMessage => 'Message',
  OfflineOutboxAction.editMessage => 'Edit',
  OfflineOutboxAction.reaction => 'Reaction',
  OfflineOutboxAction.attachmentUpload => 'Attachment',
  OfflineOutboxAction.channelPost => 'Channel post',
  OfflineOutboxAction.channelAttachmentUpload => 'Channel attachment',
  OfflineOutboxAction.channelReaction => 'Channel reaction',
};

String _outboxSubtitle(OfflineOutboxItem item) {
  final status = switch (item.status) {
    OfflineOutboxStatus.queued => 'Queued',
    OfflineOutboxStatus.sending => 'Sending',
    OfflineOutboxStatus.failed => 'Failed',
  };
  final attempts =
      '${item.attempts} ${item.attempts == 1 ? 'attempt' : 'attempts'}';
  final error = item.lastError?.trim();
  if (error == null || error.isEmpty) return '$status - $attempts';
  return '$status - $attempts\n$error';
}

IconData _outboxStatusIcon(OfflineOutboxStatus status) => switch (status) {
  OfflineOutboxStatus.queued => Icons.schedule_send_outlined,
  OfflineOutboxStatus.sending => Icons.sync_rounded,
  OfflineOutboxStatus.failed => Icons.error_outline_rounded,
};

Color _outboxStatusColor(BuildContext context, OfflineOutboxStatus status) {
  final scheme = Theme.of(context).colorScheme;
  return switch (status) {
    OfflineOutboxStatus.queued => scheme.onSurface.withValues(alpha: 0.62),
    OfflineOutboxStatus.sending => scheme.primary,
    OfflineOutboxStatus.failed => scheme.error,
  };
}
