import 'package:flutter/material.dart';

import '../models/message.dart';
import 'glass.dart';

class MessageActionSheetItem<T> {
  final T value;
  final IconData icon;
  final String label;
  final String? subtitle;
  final Color? color;
  final bool dividerBefore;

  const MessageActionSheetItem({
    required this.value,
    required this.icon,
    required this.label,
    this.subtitle,
    this.color,
    this.dividerBefore = false,
  });
}

Future<T?> showMessageActionSheet<T>({
  required BuildContext context,
  required Message message,
  required List<MessageActionSheetItem<T>> actions,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => GlassBottomSheetFrame(
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(
                  ctx,
                ).colorScheme.onSurface.withValues(alpha: 0.22),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            _MessageActionHeader(message: message),
            for (final action in actions) ...[
              if (action.dividerBefore)
                Divider(
                  height: 1,
                  indent: 70,
                  endIndent: 16,
                  color: Theme.of(
                    ctx,
                  ).colorScheme.outline.withValues(alpha: 0.14),
                ),
              _MessageActionTile<T>(action: action),
            ],
            const SizedBox(height: 10),
          ],
        ),
      ),
    ),
  );
}

class _MessageActionHeader extends StatelessWidget {
  final Message message;

  const _MessageActionHeader({required this.message});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sender = message.sender?.username;
    final title = sender == null || sender.isEmpty ? 'Message' : '@$sender';
    final preview = _previewFor(message);

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.primary.withValues(alpha: 0.12),
            ),
            child: Icon(_iconFor(message), color: scheme.primary, size: 21),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  preview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurface.withValues(alpha: 0.58),
                    fontSize: 13,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _previewFor(Message message) {
    final preview = message.listPreview.trim();
    if (preview.isNotEmpty) return preview;
    return switch (message.type) {
      MessageType.image => 'Image',
      MessageType.video => 'Video',
      MessageType.voice => 'Voice message',
      MessageType.audio => 'Audio',
      MessageType.file => 'File',
      MessageType.location => 'Location',
      MessageType.poll => 'Poll',
      MessageType.checklist => 'Checklist',
      MessageType.system => 'System message',
      _ => 'Message',
    };
  }

  static IconData _iconFor(Message message) {
    return switch (message.type) {
      MessageType.image || MessageType.livePhoto => Icons.photo_outlined,
      MessageType.video || MessageType.videoNote => Icons.videocam_outlined,
      MessageType.voice || MessageType.audio => Icons.graphic_eq_rounded,
      MessageType.file => Icons.insert_drive_file_outlined,
      MessageType.location || MessageType.venue => Icons.location_on_outlined,
      MessageType.poll => Icons.poll_outlined,
      MessageType.checklist => Icons.checklist_rounded,
      MessageType.system => Icons.info_outline_rounded,
      _ => Icons.chat_bubble_outline_rounded,
    };
  }
}

class _MessageActionTile<T> extends StatelessWidget {
  final MessageActionSheetItem<T> action;

  const _MessageActionTile({required this.action});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = action.color ?? scheme.primary;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => Navigator.pop(context, action.value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: tint.withValues(alpha: 0.12),
                ),
                child: Icon(action.icon, color: tint, size: 19),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      action.label,
                      style: TextStyle(
                        color: action.color,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    if (action.subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        action.subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: scheme.onSurface.withValues(alpha: 0.48),
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
