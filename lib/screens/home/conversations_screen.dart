import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import 'package:timeago/timeago.dart' as timeago;
import '../../models/conversation.dart';
import '../../models/user.dart';
import '../../providers/auth_provider.dart';
import '../../providers/call_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/api_service.dart';
import '../../config/api_config.dart';
import '../../widgets/glass.dart';
import '../../widgets/stories_strip.dart';
import '../channels/channel_screen.dart';
import '../chat/chat_screen.dart';
import '../profile/user_profile_screen.dart';
import '../settings/settings_screen.dart';

class ConversationsScreen extends StatefulWidget {
  const ConversationsScreen({super.key});
  @override
  State<ConversationsScreen> createState() => _ConversationsScreenState();
}

class _ConversationsScreenState extends State<ConversationsScreen> {
  int _storiesRefreshKey = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ChatProvider>().loadConversations();
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final chat = context.watch<ChatProvider>();
    final settings = context.watch<SettingsProvider>();
    final currentUserID = auth.currentUser?.id ?? '';
    final callTopInset = context.select<CallProvider, double>(
      (cp) => cp.minimizedContentTopInset,
    );

    // Channels and bot DMs are hidden here only when the user has given them
    // their own dedicated tab; otherwise everything lives in one Chats list.
    final conversations = chat.conversations.where((c) {
      if (c.isChannel) return !settings.channelsOwnTab;
      if (c.isBotDM(currentUserID)) return !settings.botsOwnTab;
      return true;
    }).toList();

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassAppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/images/logo.png',
              height: 28,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
            const SizedBox(width: 8),
            const Text('OpenChat'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => _showSearch(context),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: chat.isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () async {
                await chat.loadConversations();
                if (mounted) setState(() => _storiesRefreshKey += 1);
              },
              // The list scrolls behind the translucent app bar
              // (extendBodyBehindAppBar), so drop the spinner below it
              // instead of letting it appear hidden under the bar.
              displacement:
                  MediaQuery.paddingOf(context).top +
                  kToolbarHeight +
                  callTopInset,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.only(
                  top:
                      MediaQuery.paddingOf(context).top +
                      kToolbarHeight +
                      callTopInset,
                  bottom: MediaQuery.paddingOf(context).bottom + 8,
                ),
                children: [
                  StoriesStrip(key: ValueKey(_storiesRefreshKey)),
                  const SizedBox(height: 6),
                  // No hard dividers between rows — the canvas reads as one
                  // continuous content surface under the floating chrome, with
                  // the tile's own ink/rounding marking selection on tap.
                  if (conversations.isEmpty)
                    SizedBox(height: 360, child: _buildEmpty(context))
                  else
                    for (
                      var index = 0;
                      index < conversations.length;
                      index++
                    )
                      _ConversationTile(
                        conversation: conversations[index],
                        currentUserID: currentUserID,
                        onTap: () =>
                            _openConversation(context, conversations[index]),
                        onLongPress: () =>
                            _confirmDelete(context, conversations[index]),
                      ),
                ],
              ),
            ),
      // Lift above the translucent glass nav bar. extendBody propagates the bar
      // height through MediaQuery.padding, but the FAB slot positions off
      // viewPadding (unaffected), so pad it up by the same inset.
      floatingActionButton: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
        child: FloatingActionButton(
          onPressed: () => _showNewConversation(context),
          child: const Icon(Icons.edit_outlined),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, Conversation conv) async {
    final messenger = ScaffoldMessenger.of(context);
    final chat = context.read<ChatProvider>();
    final currentUserId = context.read<AuthProvider>().currentUser?.id;
    final isOwner = conv.createdBy == currentUserId;
    final label = conv.isChannel ? 'channel' : 'group';

    final leaveOnly = !conv.isDM && !isOwner;

    final String title;
    final String body;
    final String action;
    if (conv.isDM) {
      title = 'Delete conversation?';
      body = 'This permanently deletes all messages for both participants.';
      action = 'Delete';
    } else if (leaveOnly) {
      title = 'Leave $label?';
      body =
          'You will leave this $label and your own messages will be deleted. '
          'Other members and their messages stay.';
      action = 'Leave';
    } else {
      title = 'Delete $label?';
      body =
          'This permanently deletes the $label and its messages for everyone.';
      action = 'Delete';
    }

    if (leaveOnly) {
      final action = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Leave $label?'),
          content: Text('Leave this $label or also delete your sent messages.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'leave'),
              child: const Text('Leave'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, 'leave_delete'),
              child: const Text('Leave + delete sent'),
            ),
          ],
        ),
      );
      if (action == null) return;
      try {
        await chat.leaveConversation(
          conv.id,
          deleteOwnMessages: action == 'leave_delete',
        );
      } catch (_) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Could not complete — you may not have permission.'),
          ),
        );
      }
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await chat.deleteConversation(conv.id);
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Could not complete — you may not have permission.'),
        ),
      );
    }
  }

  void _openConversation(BuildContext context, Conversation conv) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => conv.isChannel
            ? ChannelFeedScreen(channel: conv)
            : ChatScreen(conversation: conv),
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.chat_bubble_outline, size: 80, color: Colors.grey),
          const SizedBox(height: 16),
          const Text(
            'No conversations yet',
            style: TextStyle(fontSize: 18, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => _showSearch(context),
            child: const Text('Start a conversation'),
          ),
        ],
      ),
    );
  }

  Future<void> _showSearch(BuildContext context) async {
    final api = context.read<ApiService>();
    final chat = context.read<ChatProvider>();

    await showSearch(
      context: context,
      delegate: _ChatSearchDelegate(
        api: api,
        onUserSelected: (userID) async {
          final conv = await chat.openDM(userID);
          if (context.mounted) {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => ChatScreen(conversation: conv)),
            );
          }
        },
        onChannelSelected: (channel) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ChannelFeedScreen(channel: channel),
            ),
          );
        },
      ),
    );
  }

  Future<void> _showNewConversation(BuildContext context) async {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: const Text('New Direct Message'),
              onTap: () {
                Navigator.pop(ctx);
                _showSearch(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.bookmark_border_outlined),
              title: const Text('Saved Messages'),
              onTap: () async {
                Navigator.pop(ctx);
                await _openSavedMessages(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.group_outlined),
              title: const Text('New Group'),
              onTap: () {
                Navigator.pop(ctx);
                _showCreateGroup(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.campaign_outlined),
              title: const Text('New Channel'),
              onTap: () async {
                Navigator.pop(ctx);
                final channel = await showCreateChannelDialog(context);
                if (channel != null && context.mounted) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ChannelFeedScreen(channel: channel),
                    ),
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showCreateGroup(BuildContext context) async {
    // Simplified — a full implementation would have a member picker
    final nameCtrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Group'),
        content: TextField(
          controller: nameCtrl,
          decoration: const InputDecoration(labelText: 'Group name'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, nameCtrl.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty && context.mounted) {
      final conv = await context.read<ChatProvider>().createGroup(
        name: result,
        memberIDs: [],
      );
      if (context.mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ChatScreen(conversation: conv)),
        );
      }
    }
  }

  Future<void> _openSavedMessages(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final conv = await context.read<ApiService>().getSavedMessages();
      if (!context.mounted) return;
      await context.read<ChatProvider>().loadConversations();
      if (!context.mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ChatScreen(conversation: conv)),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }
}

class _ConversationTile extends StatelessWidget {
  final Conversation conversation;
  final String currentUserID;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _ConversationTile({
    required this.conversation,
    required this.currentUserID,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final name = conversation.displayName(currentUserID);
    final avatar = conversation.displayAvatar(currentUserID);
    final last = conversation.lastMessage;
    final isBot = conversation.isBotDM(currentUserID);

    return ListTile(
      onTap: onTap,
      onLongPress: onLongPress,
      leading: CircleAvatar(
        backgroundImage: avatar != null
            ? CachedNetworkImageProvider(ApiConfig.resolveMedia(avatar))
            : null,
        child: avatar == null
            ? Text(name.isNotEmpty ? name[0].toUpperCase() : '?')
            : null,
      ),
      title: Row(
        children: [
          if (conversation.isChannel)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Icon(Icons.campaign, size: 16, color: Colors.grey),
            ),
          if (isBot)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Icon(Icons.smart_toy, size: 14, color: Colors.grey),
            ),
          Flexible(
            child: Text(
              name,
              style: const TextStyle(fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      subtitle: last != null
          ? Text(
              last.listPreview,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.grey[600]),
            )
          : null,
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (last != null)
            Text(
              timeago.format(last.createdAt, locale: 'en_short'),
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          if (conversation.unreadCount > 0)
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${conversation.unreadCount}',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}

/// Searches users, bots (both via /users/search) and public channels and shows
/// them in one list. Anything with an "@" — usernames and channel handles —
/// surfaces here, not just plain users.
class _ChatSearchDelegate extends SearchDelegate<String?> {
  final ApiService api;
  final Future<void> Function(String userID) onUserSelected;
  final void Function(Conversation channel) onChannelSelected;

  _ChatSearchDelegate({
    required this.api,
    required this.onUserSelected,
    required this.onChannelSelected,
  });

  @override
  List<Widget> buildActions(BuildContext context) => [
    IconButton(icon: const Icon(Icons.clear), onPressed: () => query = ''),
  ];

  @override
  Widget buildLeading(BuildContext context) => IconButton(
    icon: const Icon(Icons.arrow_back),
    onPressed: () => close(context, null),
  );

  @override
  Widget buildResults(BuildContext context) => _buildSuggestions();

  @override
  Widget buildSuggestions(BuildContext context) => _buildSuggestions();

  Widget _buildSuggestions() {
    final q = query.trim();
    if (q.length < 2) {
      return const Center(child: Text('Search users, bots and channels'));
    }
    // A leading "@" is just how people type handles — strip it before querying.
    final term = q.startsWith('@') ? q.substring(1) : q;
    return FutureBuilder<_SearchResults>(
      future: _search(term),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final results = snapshot.data;
        if (results == null ||
            (results.users.isEmpty && results.channels.isEmpty)) {
          return const Center(child: Text('No results'));
        }
        return ListView(
          children: [
            for (final u in results.users)
              ListTile(
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
                onTap: () {
                  close(context, u.id);
                  onUserSelected(u.id);
                },
              ),
            for (final ch in results.channels)
              ListTile(
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
                onTap: () {
                  close(context, null);
                  onChannelSelected(ch);
                },
              ),
          ],
        );
      },
    );
  }

  Future<_SearchResults> _search(String term) async {
    final results = await Future.wait([
      api.searchUsers(term).catchError((_) => <User>[]),
      api.searchChannels(term).catchError((_) => <Conversation>[]),
    ]);
    return _SearchResults(
      users: results[0] as List<User>,
      channels: results[1] as List<Conversation>,
    );
  }
}

class _SearchResults {
  final List<User> users;
  final List<Conversation> channels;
  _SearchResults({required this.users, required this.channels});
}
