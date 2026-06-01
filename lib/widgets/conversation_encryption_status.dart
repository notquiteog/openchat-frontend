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
    final label =
        conversation.encryptionEnabled ? 'Encrypted' : 'Encryption off';
    final icon = conversation.encryptionEnabled
        ? Icons.lock_outline
        : Icons.lock_open_outlined;
    final resolvedColor = color ?? Colors.grey[400];

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: resolvedColor),
        const SizedBox(width: 3),
        Text(
          label,
          style: TextStyle(fontSize: 11, color: resolvedColor),
        ),
      ],
    );
  }
}
