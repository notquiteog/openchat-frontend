import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:timeago/timeago.dart' as timeago;

import '../config/api_config.dart';
import '../models/conversation.dart';
import '../models/user.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../screens/channels/channel_screen.dart';
import '../screens/chat/chat_screen.dart';
import '../screens/profile/user_profile_screen.dart';
import '../services/api_service.dart';
import '../services/message_search_service.dart';
import 'glass.dart';

/// What the user picked from global search. Shared by the legacy
/// showSearch-based flow and the bottom-bar search field.
sealed class ChatSearchSelection {
  const ChatSearchSelection();
}

class UserSearchSelection extends ChatSearchSelection {
  final String userID;
  const UserSearchSelection(this.userID);
}

class ChannelSearchSelection extends ChatSearchSelection {
  final Conversation channel;
  const ChannelSearchSelection(this.channel);
}

class MessageSearchSelection extends ChatSearchSelection {
  final MessageSearchResult result;
  const MessageSearchSelection(this.result);
}

/// Runs the navigation a search selection implies: open/start the DM, open
/// the channel feed, or jump to the matched message.
Future<void> handleChatSearchSelection(
  BuildContext context,
  ChatSearchSelection selection, {
  void Function(Conversation conversation, String? initialMessageId)?
      openConversation,
}) async {
  final chat = context.read<ChatProvider>();
  switch (selection) {
    case UserSearchSelection(:final userID):
      try {
        final conv = await chat.openDM(userID);
        if (!context.mounted) return;
        if (openConversation != null) {
          openConversation(conv, null);
        } else {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => ChatScreen(conversation: conv)),
          );
        }
      } catch (error) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(openDmErrorMessage(error))),
        );
      }
    case ChannelSearchSelection(:final channel):
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChannelFeedScreen(channel: channel),
        ),
      );
    case MessageSearchSelection(:final result):
      var conv = chat.conversations
          .where((conversation) => conversation.id == result.conversationId)
          .firstOrNull;
      if (conv == null) {
        await chat.loadConversations();
        conv = chat.conversations
            .where((conversation) => conversation.id == result.conversationId)
            .firstOrNull;
      }
      if (!context.mounted || conv == null) return;
      if (openConversation != null) {
        openConversation(conv, result.messageId);
      } else {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ChatScreen(
              conversation: conv!,
              initialMessageId: result.messageId,
            ),
          ),
        );
      }
  }
}

/// "Could not open DM" errors phrased for humans.
String openDmErrorMessage(Object error) {
  if (error is ApiException) {
    return 'Could not open DM (${error.statusCode} ${error.code}): ${error.message}';
  }
  return 'Could not open DM: $error';
}

/// Global search results — users, channels, and on-device messages — for a
/// live [query]. Pure content widget: hosts can mount it under a search bar
/// (bottom-bar search) or inside a SearchDelegate body.
class ChatSearchResultsView extends StatefulWidget {
  final String query;
  final ValueChanged<ChatSearchSelection> onSelect;

  const ChatSearchResultsView({
    super.key,
    required this.query,
    required this.onSelect,
  });

  @override
  State<ChatSearchResultsView> createState() => _ChatSearchResultsViewState();
}

class _ChatSearchResultsViewState extends State<ChatSearchResultsView> {
  MessageSearchCategory? _messageCategory;

  @override
  Widget build(BuildContext context) {
    final q = widget.query.trim();
    if (q.length < 2) {
      return const Center(
        child: Text('Search users, channels, and local messages'),
      );
    }
    final term = q.startsWith('@') ? q.substring(1) : q;
    final api = context.read<ApiService>();
    final chat = context.read<ChatProvider>();
    final currentUserId = context.read<AuthProvider>().currentUser?.id ?? '';

    return FutureBuilder<_SearchResults>(
      // Re-runs when the query or category changes (new future identity).
      key: ValueKey('$term/${_messageCategory?.name}'),
      future: _search(api, chat, term),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: GlassProgressIndicator.circular());
        }
        final results = snapshot.data;
        if (results == null ||
            (results.users.isEmpty &&
                results.channels.isEmpty &&
                results.messages.isEmpty)) {
          return const Center(child: Text('No results'));
        }
        return ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            // People lead the results; the on-device message section (with its
            // category filter chips) follows.
            if (results.users.isNotEmpty)
              const _SearchSectionHeader(label: 'People and bots'),
            for (final u in results.users)
              GlassListTile(
                leading: CircleAvatar(
                  backgroundImage: u.avatarUrl != null
                      ? CachedNetworkImageProvider(
                          ApiConfig.resolveMedia(u.avatarUrl!),
                        )
                      : null,
                  child: u.avatarUrl == null
                      ? Text(u.username[0].toUpperCase())
                      : null,
                ),
                title: Row(
                  children: [
                    Flexible(child: Text('@${u.username}')),
                    if (u.isBot)
                      const Padding(
                        padding: EdgeInsets.only(left: 6),
                        child: Icon(
                          Icons.smart_toy,
                          size: 14,
                          color: Colors.grey,
                        ),
                      ),
                  ],
                ),
                subtitle: Text(u.isBot ? 'Bot' : 'Key: ${u.shortFingerprint}'),
                trailing: IconButton(
                  icon: const Icon(Icons.person_outline),
                  tooltip: 'View profile',
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => UserProfileScreen(user: u),
                    ),
                  ),
                ),
                onTap: () => widget.onSelect(UserSearchSelection(u.id)),
              ),
            _MessageSearchFilters(
              selected: _messageCategory,
              onSelected: (category) =>
                  setState(() => _messageCategory = category),
            ),
            if (results.messages.isNotEmpty) ...[
              _SearchSectionHeader(
                label: _messageCategory == null
                    ? 'Messages on this device'
                    : '${_messageCategoryLabel(_messageCategory!)} on this device',
              ),
              for (final message in results.messages)
                GlassListTile(
                  leading: CircleAvatar(
                    child: Icon(_messageCategoryIcon(message.category)),
                  ),
                  title: Text(
                    message.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    _messageSubtitle(chat, currentUserId, message),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Text(
                    timeago.format(message.createdAt),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  onTap: () => widget.onSelect(MessageSearchSelection(message)),
                ),
            ],
            if (results.channels.isNotEmpty)
              const _SearchSectionHeader(label: 'Channels'),
            for (final ch in results.channels)
              GlassListTile(
                leading: CircleAvatar(
                  backgroundImage: ch.avatarUrl != null
                      ? CachedNetworkImageProvider(
                          ApiConfig.resolveMedia(ch.avatarUrl!),
                        )
                      : null,
                  child: ch.avatarUrl == null
                      ? const Icon(Icons.campaign)
                      : null,
                ),
                title: Text(ch.name ?? 'Channel'),
                subtitle: Text(
                  ch.handle != null
                      ? '@${ch.handle}'
                      : (ch.description ?? 'Public channel'),
                ),
                trailing: const Icon(Icons.campaign_outlined),
                onTap: () => widget.onSelect(ChannelSearchSelection(ch)),
              ),
          ],
        );
      },
    );
  }

  Future<_SearchResults> _search(
    ApiService api,
    ChatProvider chat,
    String term,
  ) async {
    final categories = _messageCategory == null
        ? null
        : <MessageSearchCategory>{_messageCategory!};
    final results = await Future.wait([
      api.searchUsers(term).catchError((_) => <User>[]),
      api.searchChannels(term).catchError((_) => <Conversation>[]),
      chat
          .searchMessages(term, categories: categories, limit: 30)
          .catchError((_) => <MessageSearchResult>[]),
    ]);
    return _SearchResults(
      users: results[0] as List<User>,
      channels: results[1] as List<Conversation>,
      messages: results[2] as List<MessageSearchResult>,
    );
  }

  String _messageSubtitle(
    ChatProvider chat,
    String currentUserId,
    MessageSearchResult message,
  ) {
    final conv = chat.conversations
        .where((conversation) => conversation.id == message.conversationId)
        .firstOrNull;
    final convName = conv?.displayName(currentUserId) ?? 'Conversation';
    if (message.snippet.isEmpty) return convName;
    return '$convName - ${message.snippet}';
  }
}

class _SearchResults {
  final List<User> users;
  final List<Conversation> channels;
  final List<MessageSearchResult> messages;
  _SearchResults({
    required this.users,
    required this.channels,
    required this.messages,
  });
}

class _SearchSectionHeader extends StatelessWidget {
  final String label;

  const _SearchSectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(
            context,
          ).colorScheme.onSurface.withValues(alpha: 0.58),
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _MessageSearchFilters extends StatelessWidget {
  final MessageSearchCategory? selected;
  final ValueChanged<MessageSearchCategory?> onSelected;

  const _MessageSearchFilters({
    required this.selected,
    required this.onSelected,
  });

  static const _options = <(String, MessageSearchCategory?)>[
    ('All', null),
    ('Chats', MessageSearchCategory.messages),
    ('Media', MessageSearchCategory.media),
    ('Files', MessageSearchCategory.files),
    ('Links', MessageSearchCategory.links),
    ('Voice', MessageSearchCategory.voice),
    ('Polls', MessageSearchCategory.polls),
    ('Payments', MessageSearchCategory.payments),
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        itemCount: _options.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final (label, category) = _options[i];
          return GlassChip(
            label: label,
            selected: selected == category,
            onTap: () => onSelected(category),
          );
        },
      ),
    );
  }
}

String _messageCategoryLabel(MessageSearchCategory category) =>
    switch (category) {
      MessageSearchCategory.media => 'Media',
      MessageSearchCategory.files => 'Files',
      MessageSearchCategory.links => 'Links',
      MessageSearchCategory.voice => 'Voice',
      MessageSearchCategory.polls => 'Polls',
      MessageSearchCategory.payments => 'Payments',
      MessageSearchCategory.checklists => 'Lists',
      MessageSearchCategory.messages => 'Messages',
    };

IconData _messageCategoryIcon(MessageSearchCategory category) =>
    switch (category) {
      MessageSearchCategory.media => Icons.photo_library_outlined,
      MessageSearchCategory.files => Icons.insert_drive_file_outlined,
      MessageSearchCategory.links => Icons.link_rounded,
      MessageSearchCategory.voice => Icons.graphic_eq_rounded,
      MessageSearchCategory.polls => Icons.poll_outlined,
      MessageSearchCategory.payments => Icons.payments_outlined,
      MessageSearchCategory.checklists => Icons.checklist_rounded,
      MessageSearchCategory.messages => Icons.chat_bubble_outline_rounded,
    };
