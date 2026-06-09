import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../crypto/pgp_service.dart';
import '../models/conversation.dart';
import '../models/message.dart';
import '../models/scheduled_message.dart';
import '../services/api_service.dart';
import '../services/mls_service.dart';
import '../services/secure_storage_service.dart';
import 'glass.dart';

Future<void> showScheduledMessagesSheet(
  BuildContext context, {
  required Conversation conversation,
  required bool channel,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) =>
        ScheduledMessagesSheet(conversation: conversation, channel: channel),
  );
}

class ScheduledMessagesSheet extends StatefulWidget {
  final Conversation conversation;
  final bool channel;

  const ScheduledMessagesSheet({
    super.key,
    required this.conversation,
    required this.channel,
  });

  @override
  State<ScheduledMessagesSheet> createState() => _ScheduledMessagesSheetState();
}

class _ScheduledMessagesSheetState extends State<ScheduledMessagesSheet> {
  var _messages = <ScheduledMessage>[];
  final _sendingIds = <String>{};
  final _cancelingIds = <String>{};
  final _reschedulingIds = <String>{};
  bool _loading = true;
  String? _error;

  String get _title =>
      widget.channel ? 'Scheduled posts' : 'Scheduled messages';
  String get _emptyText =>
      widget.channel ? 'No scheduled posts' : 'No scheduled messages';
  String get _canceledText =>
      widget.channel ? 'Scheduled post canceled' : 'Scheduled message canceled';
  String get _rescheduledText =>
      widget.channel ? 'Scheduled post updated' : 'Scheduled message updated';
  String get _sentText =>
      widget.channel ? 'Scheduled post sent' : 'Scheduled message sent';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final api = context.read<ApiService>();
      final storage = context.read<SecureStorageService>();
      final items = await api.listScheduledMessages(
        widget.conversation.id,
        channel: widget.channel,
      );
      final privateKey = await storage.getPrivateKeyIfUnlocked() ?? '';
      final hydrated = await Future.wait(
        items.map((item) => _hydratePreview(item, privateKey, storage)),
      );
      if (!mounted) return;
      setState(() {
        _messages = hydrated;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Scheduled queue failed: $e';
        _loading = false;
      });
    }
  }

  Future<ScheduledMessage> _hydratePreview(
    ScheduledMessage item,
    String privateKey,
    SecureStorageService storage,
  ) async {
    final mls = context.read<MlsService>();
    final api = context.read<ApiService>();
    // Author-local plaintext saved at schedule time — the only reliable preview
    // for encrypted conversations, where the stored payload is ciphertext the
    // author can't decrypt back (forward-secret MLS especially).
    final local = await storage.getScheduledPlaintext(
      item.conversationId,
      item.id,
    );
    if (local != null && local.isNotEmpty) {
      return item.copyWith(decryptedContent: local, decryptionFailed: false);
    }
    if (!widget.conversation.isEncrypted) {
      return item.copyWith(decryptedContent: item.encryptedPayload);
    }
    if (widget.conversation.usesMls) {
      final raw = await mls.decryptPayload(
        api: api,
        conversation: widget.conversation,
        encryptedPayload: item.encryptedPayload,
      );
      if (raw == null || raw.isEmpty) {
        return item.copyWith(decryptionFailed: true);
      }
      return item.copyWith(decryptedContent: raw, decryptionFailed: false);
    }
    if (privateKey.isEmpty || item.encryptedPayload.isEmpty) return item;

    try {
      final raw = await PgpService.decrypt(
        encryptedArmor: item.encryptedPayload,
        privateKeyArmored: privateKey,
      );
      return item.copyWith(decryptedContent: raw, decryptionFailed: false);
    } catch (_) {
      return item.copyWith(decryptionFailed: true);
    }
  }

  Future<void> _cancel(ScheduledMessage item) async {
    final label = widget.channel ? 'post' : 'message';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: Text('Cancel scheduled $label?'),
        content: const Text('This removes it from the delivery queue.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _cancelingIds.add(item.id));
    final storage = context.read<SecureStorageService>();
    try {
      await context.read<ApiService>().cancelScheduledMessage(
        widget.conversation.id,
        item.id,
        channel: widget.channel,
      );
      await storage.deleteScheduledPlaintext(widget.conversation.id, item.id);
      if (!mounted) return;
      setState(() {
        _messages = _messages.where((msg) => msg.id != item.id).toList();
        _cancelingIds.remove(item.id);
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_canceledText)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _cancelingIds.remove(item.id));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Cancel failed: $e')));
    }
  }

  Future<DateTime?> _pickRescheduleTime(ScheduledMessage item) {
    final minimumSchedule = DateTime.now().add(const Duration(minutes: 1));
    var draftSchedule = item.scheduledFor.toLocal().isAfter(minimumSchedule)
        ? item.scheduledFor.toLocal()
        : minimumSchedule;

    return showModalBottomSheet<DateTime>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => GlassBottomSheetFrame(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.30),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Row(
                  children: [
                    const Icon(Icons.event_repeat_outlined),
                    const SizedBox(width: 12),
                    Text(
                      'Reschedule delivery',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: 216,
                child: CupertinoDatePicker(
                  mode: CupertinoDatePickerMode.dateAndTime,
                  minimumDate: minimumSchedule,
                  initialDateTime: draftSchedule,
                  minuteInterval: 1,
                  onDateTimeChanged: (value) =>
                      setSheetState(() => draftSchedule = value),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Row(
                  children: [
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      icon: const Icon(Icons.schedule_send_outlined),
                      label: const Text('Update'),
                      onPressed: () => Navigator.pop(ctx, draftSchedule),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _reschedule(ScheduledMessage item) async {
    final scheduledFor = await _pickRescheduleTime(item);
    if (scheduledFor == null || !mounted) return;

    setState(() => _reschedulingIds.add(item.id));
    try {
      await context.read<ApiService>().rescheduleScheduledMessage(
        widget.conversation.id,
        item.id,
        scheduledFor: scheduledFor,
        channel: widget.channel,
      );
      if (!mounted) return;
      setState(() {
        _messages = [
          for (final msg in _messages)
            if (msg.id == item.id)
              msg.copyWith(scheduledFor: scheduledFor)
            else
              msg,
        ]..sort((a, b) => a.scheduledFor.compareTo(b.scheduledFor));
        _reschedulingIds.remove(item.id);
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_rescheduledText)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _reschedulingIds.remove(item.id));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Reschedule failed: $e')));
    }
  }

  Future<void> _sendNow(ScheduledMessage item) async {
    setState(() => _sendingIds.add(item.id));
    final storage = context.read<SecureStorageService>();
    try {
      await context.read<ApiService>().sendScheduledMessageNow(
        widget.conversation.id,
        item.id,
        channel: widget.channel,
      );
      await storage.deleteScheduledPlaintext(widget.conversation.id, item.id);
      if (!mounted) return;
      setState(() {
        _messages = _messages.where((msg) => msg.id != item.id).toList();
        _sendingIds.remove(item.id);
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_sentText)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _sendingIds.remove(item.id));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Send now failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxListHeight = math.min(
      460.0,
      MediaQuery.sizeOf(context).height * 0.56,
    );

    return GlassBottomSheetFrame(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      includeKeyboardInset: false,
      scrollable: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.primary.withValues(alpha: 0.14),
                ),
                child: Icon(
                  Icons.schedule_send_outlined,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _title,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      widget.conversation.name ?? _title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh_rounded),
                onPressed: _loading ? null : _load,
              ),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 18),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 34),
              child: Center(child: GlassProgressIndicator.circular()),
            )
          else if (_error != null)
            _ScheduledStateMessage(
              icon: Icons.error_outline_rounded,
              title: 'Could not load queue',
              subtitle: _error!,
              action: TextButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Try again'),
              ),
            )
          else if (_messages.isEmpty)
            _ScheduledStateMessage(
              icon: Icons.schedule_outlined,
              title: _emptyText,
              subtitle: widget.channel
                  ? 'Posts you schedule from the composer appear here.'
                  : 'Messages you schedule from the composer appear here.',
            )
          else
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxListHeight),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _messages.length,
                separatorBuilder: (_, _) => Divider(
                  height: 1,
                  thickness: 0.5,
                  color: scheme.outlineVariant.withValues(alpha: 0.35),
                ),
                itemBuilder: (ctx, index) {
                  final item = _messages[index];
                  return _ScheduledMessageTile(
                    item: item,
                    sending: _sendingIds.contains(item.id),
                    canceling: _cancelingIds.contains(item.id),
                    rescheduling: _reschedulingIds.contains(item.id),
                    onSendNow: () => unawaited(_sendNow(item)),
                    onReschedule: () => unawaited(_reschedule(item)),
                    onCancel: () => unawaited(_cancel(item)),
                  );
                },
              ),
            ),
          if (!_loading && _error == null && _messages.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              '${_messages.length} pending',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ScheduledMessageTile extends StatelessWidget {
  final ScheduledMessage item;
  final bool sending;
  final bool canceling;
  final bool rescheduling;
  final VoidCallback onSendNow;
  final VoidCallback onReschedule;
  final VoidCallback onCancel;

  const _ScheduledMessageTile({
    required this.item,
    required this.sending,
    required this.canceling,
    required this.rescheduling,
    required this.onSendNow,
    required this.onReschedule,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final meta = [
      _formatScheduledFor(item.scheduledFor),
      if (item.silent) 'Silent',
      if (item.decryptionFailed) 'Preview locked',
    ].join(' | ');

    return GlassListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: scheme.secondaryContainer.withValues(alpha: 0.38),
        ),
        child: Icon(
          _iconForType(item.type),
          color: scheme.onSecondaryContainer,
        ),
      ),
      title: Text(
        item.previewText,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(
          context,
        ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(
        meta,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      ),
      trailing: SizedBox(
        width: 126,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            SizedBox.square(
              dimension: 42,
              child: sending
                  ? const Padding(
                      padding: EdgeInsets.all(10),
                      child: GlassProgressIndicator.circular(strokeWidth: 2),
                    )
                  : IconButton(
                      tooltip: 'Send now',
                      icon: const Icon(Icons.send_rounded),
                      onPressed: canceling || rescheduling ? null : onSendNow,
                    ),
            ),
            SizedBox.square(
              dimension: 42,
              child: rescheduling
                  ? const Padding(
                      padding: EdgeInsets.all(10),
                      child: GlassProgressIndicator.circular(strokeWidth: 2),
                    )
                  : IconButton(
                      tooltip: 'Reschedule',
                      icon: const Icon(Icons.event_repeat_outlined),
                      onPressed: sending || canceling ? null : onReschedule,
                    ),
            ),
            SizedBox.square(
              dimension: 42,
              child: canceling
                  ? const Padding(
                      padding: EdgeInsets.all(10),
                      child: GlassProgressIndicator.circular(strokeWidth: 2),
                    )
                  : IconButton(
                      tooltip: 'Cancel scheduled item',
                      icon: const Icon(Icons.delete_outline_rounded),
                      color: Colors.red,
                      onPressed: sending || rescheduling ? null : onCancel,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScheduledStateMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? action;

  const _ScheduledStateMessage({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 34, color: scheme.primary),
          const SizedBox(height: 10),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (action != null) ...[const SizedBox(height: 12), action!],
        ],
      ),
    );
  }
}

String _formatScheduledFor(DateTime when) {
  final local = when.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  final year = local.year == DateTime.now().year ? '' : '/${local.year}';
  return '${local.month}/${local.day}$year at $hour:$minute';
}

IconData _iconForType(MessageType type) {
  return switch (type) {
    MessageType.text => Icons.chat_bubble_outline_rounded,
    MessageType.sticker => Icons.emoji_emotions_outlined,
    MessageType.file => Icons.insert_drive_file_outlined,
    MessageType.image => Icons.image_outlined,
    MessageType.video => Icons.videocam_outlined,
    MessageType.voice => Icons.mic_none_rounded,
    MessageType.audio => Icons.music_note_outlined,
    MessageType.animation => Icons.gif_box_outlined,
    MessageType.videoNote => Icons.video_camera_front_outlined,
    MessageType.livePhoto => Icons.photo_library_outlined,
    MessageType.poll => Icons.poll_outlined,
    MessageType.location => Icons.location_on_outlined,
    MessageType.venue => Icons.storefront_outlined,
    MessageType.contact => Icons.person_pin_outlined,
    MessageType.dice => Icons.casino_outlined,
    MessageType.game => Icons.casino_outlined,
    MessageType.checklist => Icons.checklist_rounded,
    MessageType.invoice => Icons.receipt_long_outlined,
    MessageType.paymentRequest => Icons.request_quote_outlined,
    MessageType.paymentTransfer => Icons.account_balance_wallet_outlined,
    MessageType.system => Icons.info_outline_rounded,
  };
}
