import 'package:flutter/material.dart';
import '../models/conversation.dart';

class ConversationEncryptionStatus extends StatelessWidget {
  final Conversation conversation;
  final Color? color;

  const ConversationEncryptionStatus({
    super.key,
    required this.conversation,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final label = conversation.encryptionMode.shortLabel;
    final icon = switch (conversation.encryptionMode) {
      EncryptionMode.mls => Icons.enhanced_encryption_outlined,
      EncryptionMode.pgp => Icons.lock_outline,
      EncryptionMode.plaintext => Icons.lock_open_outlined,
    };
    final resolvedColor = color ?? Colors.grey[400];

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: resolvedColor),
        const SizedBox(width: 3),
        Text(label, style: TextStyle(fontSize: 11, color: resolvedColor)),
      ],
    );
  }
}
