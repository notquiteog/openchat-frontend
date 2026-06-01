import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../config/api_config.dart';
import '../models/conversation.dart';

class ConversationInfoPanel extends StatelessWidget {
  final Conversation conversation;
  final String currentUserId;

  const ConversationInfoPanel({
    super.key,
    required this.conversation,
    required this.currentUserId,
  });

  @override
  Widget build(BuildContext context) {
    final name = conversation.displayName(currentUserId);
    final avatar = conversation.displayAvatar(currentUserId);
    final description = conversation.description?.trim();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        CircleAvatar(
          key: const Key('conversation-info-avatar'),
          radius: 42,
          backgroundImage: avatar != null && avatar.isNotEmpty
              ? CachedNetworkImageProvider(ApiConfig.resolveMedia(avatar))
              : null,
          child: avatar == null || avatar.isEmpty
              ? Icon(
                  conversation.isChannel
                      ? Icons.campaign
                      : conversation.isGroup
                          ? Icons.group
                          : Icons.person,
                  size: 34,
                )
              : null,
        ),
        const SizedBox(height: 14),
        Text(
          name,
          style: Theme.of(context).textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        if (description != null && description.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            description,
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 12),
        Text(
          '${conversation.members.length} member${conversation.members.length == 1 ? '' : 's'}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
