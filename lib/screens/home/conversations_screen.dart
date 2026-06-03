import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import 'package:timeago/timeago.dart' as timeago;
import '../../models/conversation.dart';
import '../../models/user.dart';
import '../../providers/auth_provider.dart';
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
              height: 26,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
            const SizedBox(width: 8),
            const Text('OpenChat'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search_rounded),
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
              displacement:
                  MediaQuery.paddingOf(context).top + kToolbarHeight,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.only(
                  top: MediaQuery.paddingOf(context).top + kToolbarHeight,
                  bottom: MediaQuery.paddingOf(context).bottom + 8,
                ),
                children: [
                  StoriesStrip(key: ValueKey(_storiesRefreshKey)),
                  const SizedBox(height: 4),
                  if (conversations.isEmpty)
                    SizedBox(height: 360, child: _buildEmpty(context))
                  else
                    for (var index = 0; index < conversations.length; index++)
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
      floatingActionButton: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
        child: _GlassFab(
          onPressed: () => _showNewConversation(context),
          icon: Icons.edit_outlined,
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
      final chosenAction = await showDialog<String>(
        context: context,
        builder: (ctx) => GlassAlertDialog(
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
      if (chosenAction == null) return;
      try {
        await chat.leaveConversation(
          conv.id,
          deleteOwnMessages: chosenAction == 'leave_delete',
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
      builder: (ctx) => GlassAlertDialog(
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
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: GlassCard(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.primary.withValues(alpha: 0.10),
                ),
                child: Icon(
                  Icons.chat_bubble_outline_rounded,
                  size: 34,
                  color: scheme.primary.withValues(alpha: 0.65),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'No conversations yet',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                'Start a conversation to get going',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.50),
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () => _showSearch(context),
                icon: const Icon(Icons.search_rounded, size: 18),
                label: const Text('Find someone'),
                style: FilledButton.styleFrom(shape: const StadiumBorder()),
              ),
            ],
          ),
        ),
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
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          child: LiquidGlass(
            blur: 56,
            borderRadius: const BorderRadius.all(Radius.circular(28)),
            padding: EdgeInsets.zero,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8),
                _SheetTile(
                  icon: Icons.person_outline_rounded,
                  label: 'New Direct Message',
                  onTap: () {
                    Navigator.pop(ctx);
                    _showSearch(context);
                  },
                ),
                _SheetTile(
                  icon: Icons.bookmark_border_rounded,
                  label: 'Saved Messages',
                  onTap: () async {
                    Navigator.pop(ctx);
                    await _openSavedMessages(context);
                  },
                ),
                _SheetTile(
                  icon: Icons.group_outlined,
                  label: 'New Group',
                  onTap: () {
                    Navigator.pop(ctx);
                    _showCreateGroup(context);
                  },
                ),
                _SheetTile(
                  icon: Icons.campaign_outlined,
                  label: 'New Channel',
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
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showCreateGroup(BuildContext context) async {
    final nameCtrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
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

// ── Glass FAB ──────────────────────────────────────────────────────────────────

class _GlassFab extends StatelessWidget {
  final VoidCallback onPressed;
  final IconData icon;

  const _GlassFab({required this.onPressed, required this.icon});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onPressed,
      child: LiquidGlass(
        blur: 50,
        borderRadius: const BorderRadius.all(Radius.circular(24)),
        tint: scheme.primary,
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: 0.40),
            blurRadius: 22,
            spreadRadius: -4,
            offset: const Offset(0, 10),
          ),
        ],
        child: SizedBox(
          width: 56,
          height: 56,
          child: Icon(icon, color: Colors.white, size: 24),
        ),
      ),
    );
  }
}

// ── Conversation Tile ─────────────────────────────────────────────────────────

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
    final scheme = Theme.of(context).colorScheme;
    final name = conversation.displayName(currentUserID);
    final avatar = conversation.displayAvatar(currentUserID);
    final last = conversation.lastMessage;
    final isBot = conversation.isBotDM(currentUserID);
    final hasUnread = conversation.unreadCount > 0;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(18),
        splashColor: scheme.primary.withValues(alpha: 0.08),
        highlightColor: scheme.primary.withValues(alpha: 0.04),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              // Avatar with optional unread ring
              _ConvAvatar(
                avatarUrl: avatar,
                name: name,
                isGroup: conversation.isGroup,
                isChannel: conversation.isChannel,
                hasUnread: hasUnread,
              ),
              const SizedBox(width: 14),
              // Content
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        if (conversation.isChannel)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Icon(
                              Icons.campaign_rounded,
                              size: 14,
                              color: scheme.onSurface.withValues(alpha: 0.44),
                            ),
                          ),
                        if (isBot)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Icon(
                              Icons.smart_toy_outlined,
                              size: 13,
                              color: scheme.onSurface.withValues(alpha: 0.44),
                            ),
                          ),
                        Flexible(
                          child: Text(
                            name,
                            style: TextStyle(
                              fontWeight: hasUnread
                                  ? FontWeight.w700
                                  : FontWeight.w600,
                              fontSize: 15,
                              letterSpacing: -0.2,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    if (last != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        last.listPreview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: hasUnread
                              ? scheme.onSurface.withValues(alpha: 0.75)
                              : scheme.onSurface.withValues(alpha: 0.45),
                          fontSize: 13,
                          fontWeight:
                              hasUnread ? FontWeight.w500 : FontWeight.w400,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              // Trailing: time + unread badge
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (last != null)
                    Text(
                      timeago.format(last.createdAt, locale: 'en_short'),
                      style: TextStyle(
                        fontSize: 11.5,
                        color: hasUnread
                            ? scheme.primary
                            : scheme.onSurface.withValues(alpha: 0.38),
                        fontWeight: hasUnread ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  if (hasUnread) ...[
                    const SizedBox(height: 5),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: scheme.primary.withValues(alpha: 0.40),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Text(
                        conversation.unreadCount > 99
                            ? '99+'
                            : '${conversation.unreadCount}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.1,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConvAvatar extends StatelessWidget {
  final String? avatarUrl;
  final String name;
  final bool isGroup;
  final bool isChannel;
  final bool hasUnread;

  const _ConvAvatar({
    this.avatarUrl,
    required this.name,
    required this.isGroup,
    required this.isChannel,
    required this.hasUnread,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    Widget avatar = CircleAvatar(
      radius: 26,
      backgroundColor: scheme.surfaceContainerHighest,
      backgroundImage: avatarUrl != null
          ? CachedNetworkImageProvider(ApiConfig.resolveMedia(avatarUrl!))
          : null,
      child: avatarUrl == null
          ? (isGroup || isChannel
              ? Icon(
                  isChannel ? Icons.campaign_rounded : Icons.group_rounded,
                  size: 22,
                  color: scheme.onSurfaceVariant,
                )
              : Text(
                  name.isNotEmpty ? name[0].toUpperCase() : '?',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 17,
                  ),
                ))
          : null,
    );

    if (hasUnread) {
      return Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: scheme.primary, width: 2),
        ),
        child: avatar,
      );
    }

    return avatar;
  }
}

// ── Search delegate ────────────────────────────────────────────────────────────

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
                        child: Icon(Icons.smart_toy, size: 14, color: Colors.grey),
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

class _SheetTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _SheetTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: scheme.primary.withValues(alpha: 0.12),
                  ),
                  child: Icon(icon, size: 18, color: scheme.primary),
                ),
                const SizedBox(width: 14),
                Text(label,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 15)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
