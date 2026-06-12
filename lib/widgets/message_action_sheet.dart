import 'package:flutter/material.dart';

import '../models/message.dart';
import 'desktop.dart';
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
  // Set on right-click: renders a cursor-anchored desktop context menu
  // instead of the touch bottom sheet.
  Offset? anchor,
}) {
  if (anchor != null) {
    return showGlassContextMenu<T>(
      context: context,
      anchor: anchor,
      items: [
        for (final action in actions)
          GlassContextMenuItem(
            value: action.value,
            icon: action.icon,
            label: action.label,
            color: action.color,
            dividerBefore: action.dividerBefore,
          ),
      ],
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => GlassBottomSheetFrame(
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const GlassSheetGrabber(),
            _MessageActionHeader(message: message),
            for (final action in actions) ...[
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
    final sender = message.sender?.username;
    final title = sender == null || sender.isEmpty ? 'Message' : '@$sender';
    final preview = _previewFor(message);

    return GlassSheetHeader(
      icon: _iconFor(message),
      title: title,
      subtitle: preview,
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
    return GlassActionTile(
      icon: action.icon,
      label: action.label,
      subtitle: action.subtitle,
      color: action.color,
      dividerBefore: action.dividerBefore,
      onTap: () => Navigator.pop(context, action.value),
    );
  }
}
