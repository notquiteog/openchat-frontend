import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import 'package:timeago/timeago.dart' as timeago;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassButton, GlassModalSheet, SheetState;
import '../../models/chat_folder.dart';
import '../../models/conversation.dart';
import '../../models/user.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/api_service.dart';
import '../../services/message_search_service.dart';
import '../../config/api_config.dart';
import '../../utils/mention_utils.dart';
import '../../utils/local_conversation_preferences.dart';
import '../../utils/smart_inbox_filter.dart';
import '../../widgets/glass.dart';
import '../../widgets/conversation_notification_controls_sheet.dart';
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
  String? _selectedFolderId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final chat = context.read<ChatProvider>();
      chat.loadConversations();
      chat.loadChatFolders();
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final chat = context.watch<ChatProvider>();
    final settings = context.watch<SettingsProvider>();
    final currentUserID = auth.currentUser?.id ?? '';
    final currentUsername = auth.currentUser?.username ?? '';
    final drafts = settings.messageDrafts;
    final pinnedConversationIds = settings.pinnedConversationIds;
    final archivedConversationIds = settings.archivedConversationIds;
    final folders = chat.chatFolders;
    final selectedFolder = folders
        .where((folder) => folder.id == _selectedFolderId)
        .firstOrNull;
    final availableFilters = availableSmartInboxFilters(
      channelsOwnTab: settings.channelsOwnTab,
      botsOwnTab: settings.botsOwnTab,
      hasArchived: archivedConversationIds.isNotEmpty,
    );
    final selectedFilter = effectiveSmartInboxFilter(
      settings.smartInboxFilter,
      channelsOwnTab: settings.channelsOwnTab,
      botsOwnTab: settings.botsOwnTab,
      hasArchived: archivedConversationIds.isNotEmpty,
    );
    final folderSourceConversations = chat.conversations
      ..sort(
        (a, b) => compareConversationsForInbox(
          a,
          b,
          drafts: drafts,
          pinnedConversationIds: pinnedConversationIds,
        ),
      );
    final baseConversations =
        chat.conversations
            .where(
              (conversation) => conversationBelongsInChatsTab(
                conversation,
                currentUserId: currentUserID,
                channelsOwnTab: settings.channelsOwnTab,
                botsOwnTab: settings.botsOwnTab,
              ),
            )
            .toList()
          ..sort(
            (a, b) => compareConversationsForInbox(
              a,
              b,
              drafts: drafts,
              pinnedConversationIds: pinnedConversationIds,
            ),
          );
    final folderCounts = {
      for (final folder in folders)
        folder.id: _folderConversationCount(
          folder,
          folderSourceConversations,
          archivedConversationIds,
        ),
    };
    final filterCounts = {
      for (final filter in availableFilters)
        filter: baseConversations
            .where(
              (conversation) => conversationMatchesSmartInboxFilter(
                conversation,
                filter: filter,
                currentUserId: currentUserID,
                currentUsername: currentUsername,
                archivedConversationIds: archivedConversationIds,
              ),
            )
            .length,
    };
    final conversations = selectedFolder == null
        ? baseConversations
              .where(
                (conversation) => conversationMatchesSmartInboxFilter(
                  conversation,
                  filter: selectedFilter,
                  currentUserId: currentUserID,
                  currentUsername: currentUsername,
                  archivedConversationIds: archivedConversationIds,
                ),
              )
              .toList()
        : _folderConversations(
            selectedFolder,
            folderSourceConversations,
            archivedConversationIds,
          );

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
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed: () => _showFolderManager(context),
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
                await chat.loadChatFolders();
                if (mounted) setState(() => _storiesRefreshKey += 1);
              },
              displacement: MediaQuery.paddingOf(context).top + kToolbarHeight,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.only(
                  top: MediaQuery.paddingOf(context).top + kToolbarHeight,
                  bottom: MediaQuery.paddingOf(context).bottom + 8,
                ),
                children: [
                  StoriesStrip(key: ValueKey(_storiesRefreshKey)),
                  _ChatFolderBar(
                    folders: folders,
                    selectedFolderId: selectedFolder?.id,
                    counts: folderCounts,
                    onAllSelected: () =>
                        setState(() => _selectedFolderId = null),
                    onFolderSelected: (folder) =>
                        setState(() => _selectedFolderId = folder.id),
                    onManage: () => _showFolderManager(context),
                  ),
                  if (selectedFolder == null)
                    _SmartInboxBar(
                      filters: availableFilters,
                      selected: selectedFilter,
                      counts: filterCounts,
                      onSelected: settings.setSmartInboxFilter,
                    ),
                  const SizedBox(height: 8),
                  if (conversations.isEmpty)
                    SizedBox(
                      height: 360,
                      child: selectedFolder != null
                          ? _buildFolderEmpty(context, selectedFolder)
                          : baseConversations.isEmpty
                          ? _buildEmpty(context)
                          : _buildFilterEmpty(context, selectedFilter),
                    )
                  else
                    for (var index = 0; index < conversations.length; index++)
                      _AnimatedConversationTile(
                        key: ValueKey(conversations[index].id),
                        index: index,
                        child: _ConversationTile(
                          conversation: conversations[index],
                          draft: drafts[conversations[index].id],
                          isPinned: pinnedConversationIds.contains(
                            conversations[index].id,
                          ),
                          notificationPreference: settings
                              .notificationPreferenceForConversation(
                                conversations[index].id,
                              ),
                          unreadMentionMessageId: unreadMentionMessageId(
                            conversations[index],
                            currentUsername,
                          ),
                          currentUserID: currentUserID,
                          onTap: () =>
                              _openConversation(context, conversations[index]),
                          onUnreadMentionTap: (messageId) => _openConversation(
                            context,
                            conversations[index],
                            initialMessageId: messageId,
                          ),
                          onLongPress: () => _showConversationActions(
                            context,
                            conversations[index],
                          ),
                        ),
                      ),
                ],
              ),
            ),
      floatingActionButton: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
        child: GlassButton(
          icon: const Icon(Icons.edit_outlined, color: Colors.white, size: 24),
          label: '',
          onTap: () => _showNewConversation(context),
          width: 56,
          height: 56,
          iconColor: Colors.white,
          glowColor: Theme.of(context).colorScheme.primary,
          glowRadius: 1.2,
          interactionScale: 1.08,
          stretch: 0.6,
        ),
      ),
    );
  }

  Future<void> _showConversationActions(
    BuildContext context,
    Conversation conv,
  ) async {
    final settings = context.read<SettingsProvider>();
    final isPinned = settings.isConversationPinned(conv.id);
    final isArchived = settings.isConversationArchived(conv.id);
    final notificationPreference = settings
        .notificationPreferenceForConversation(conv.id);
    final notificationLabel = settings.notificationLabelForConversation(
      conv.id,
    );
    final selected = await GlassModalSheet.show<String>(
      context: context,
      initialState: SheetState.half,
      halfSize: 0.42,
      enableInteractionGlow: true,
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            _SheetTile(
              icon: isPinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
              label: isPinned ? 'Unpin Chat' : 'Pin Chat',
              onTap: () => Navigator.pop(ctx, 'pin'),
            ),
            _SheetTile(
              icon: _notificationPreferenceIcon(notificationPreference),
              label: 'Notifications: $notificationLabel',
              onTap: () => Navigator.pop(ctx, 'notifications'),
            ),
            _SheetTile(
              icon: isArchived
                  ? Icons.unarchive_outlined
                  : Icons.archive_outlined,
              label: isArchived ? 'Unarchive Chat' : 'Archive Chat',
              onTap: () => Navigator.pop(ctx, 'archive'),
            ),
            _SheetTile(
              icon: Icons.delete_outline_rounded,
              label: _deleteActionLabel(context, conv),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (selected == 'pin') {
      await settings.toggleConversationPinned(conv.id);
    } else if (selected == 'notifications' && context.mounted) {
      await showConversationNotificationControlsSheet(
        context,
        conversationId: conv.id,
      );
    } else if (selected == 'archive') {
      await settings.toggleConversationArchived(conv.id);
    } else if (selected == 'delete' && context.mounted) {
      await _confirmDelete(context, conv);
    }
  }

  IconData _notificationPreferenceIcon(
    ConversationNotificationPreference preference,
  ) {
    if (preference.isMutedAt(DateTime.now())) {
      return Icons.notifications_off_outlined;
    }
    if (preference.priority) {
      return Icons.star_outline_rounded;
    }
    return switch (preference.mode) {
      ConversationNotificationMode.mentionsOnly =>
        Icons.notification_important_outlined,
      _ => Icons.notifications_active_outlined,
    };
  }

  String _deleteActionLabel(BuildContext context, Conversation conv) {
    final currentUserId = context.read<AuthProvider>().currentUser?.id;
    if (conv.isDM) return 'Delete Conversation';
    final isOwner = conv.createdBy == currentUserId;
    if (!isOwner) return conv.isChannel ? 'Leave Channel' : 'Leave Group';
    return conv.isChannel ? 'Delete Channel' : 'Delete Group';
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

  void _openConversation(
    BuildContext context,
    Conversation conv, {
    String? initialMessageId,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => conv.isChannel
            ? ChannelFeedScreen(channel: conv, initialPostId: initialMessageId)
            : ChatScreen(
                conversation: conv,
                initialMessageId: initialMessageId,
              ),
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
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
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
              GlassButtonWidget.icon(
                onPressed: () => _showSearch(context),
                icon: const Icon(Icons.search_rounded, size: 18),
                label: const Text('Find someone'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFilterEmpty(
    BuildContext context,
    SmartInboxFilter selectedFilter,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: GlassCard(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.primary.withValues(alpha: 0.10),
                ),
                child: Icon(
                  _smartInboxFilterIcon(selectedFilter),
                  size: 30,
                  color: scheme.primary.withValues(alpha: 0.65),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                _smartInboxEmptyTitle(selectedFilter),
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                _smartInboxEmptyMessage(selectedFilter),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurface.withValues(alpha: 0.50),
                ),
                textAlign: TextAlign.center,
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
    final currentUserId = context.read<AuthProvider>().currentUser?.id ?? '';

    await showSearch(
      context: context,
      delegate: _ChatSearchDelegate(
        api: api,
        chat: chat,
        currentUserId: currentUserId,
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
        onMessageSelected: (result) async {
          var conv = chat.conversations
              .where((conversation) => conversation.id == result.conversationId)
              .firstOrNull;
          if (conv == null) {
            await chat.loadConversations();
            conv = chat.conversations
                .where(
                  (conversation) => conversation.id == result.conversationId,
                )
                .firstOrNull;
          }
          if (!context.mounted || conv == null) return;
          _openConversation(context, conv, initialMessageId: result.messageId);
        },
      ),
    );
  }

  Future<void> _showNewConversation(BuildContext context) async {
    await GlassModalSheet.show(
      context: context,
      initialState: SheetState.half,
      halfSize: 0.38,
      enableInteractionGlow: true,
      builder: (ctx) => SafeArea(
        top: false,
        child: SingleChildScrollView(
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
              const SizedBox(height: 16),
            ],
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

  int _folderConversationCount(
    ChatFolder folder,
    List<Conversation> conversations,
    Set<String> archivedConversationIds,
  ) {
    return _folderConversations(
      folder,
      conversations,
      archivedConversationIds,
    ).length;
  }

  List<Conversation> _folderConversations(
    ChatFolder folder,
    List<Conversation> conversations,
    Set<String> archivedConversationIds,
  ) {
    final ids = folder.conversationIds.toSet();
    return conversations
        .where(
          (conversation) =>
              ids.contains(conversation.id) &&
              (folder.includeArchived ||
                  !archivedConversationIds.contains(conversation.id)),
        )
        .toList();
  }

  Widget _buildFolderEmpty(BuildContext context, ChatFolder folder) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: GlassCard(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.primary.withValues(alpha: 0.10),
                ),
                child: Icon(
                  Icons.folder_open_outlined,
                  size: 30,
                  color: scheme.primary.withValues(alpha: 0.65),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                folder.name,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                'No chats in this folder',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurface.withValues(alpha: 0.50),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 18),
              GlassButtonWidget.icon(
                onPressed: () => _showFolderEditor(context, existing: folder),
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('Edit folder'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showFolderManager(BuildContext context) async {
    await GlassModalSheet.show<void>(
      context: context,
      initialState: SheetState.half,
      halfSize: 0.50,
      enableInteractionGlow: true,
      builder: (ctx) => SafeArea(
        top: false,
        child: Consumer<ChatProvider>(
          builder: (context, chat, _) {
            final folders = chat.chatFolders;
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 10, 10, 6),
                    child: Row(
                      children: [
                        const Icon(Icons.folder_copy_outlined, size: 20),
                        const SizedBox(width: 10),
                        Text(
                          'Chat folders',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: 'New folder',
                          icon: const Icon(Icons.create_new_folder_outlined),
                          onPressed: () {
                            Navigator.pop(ctx);
                            _showFolderEditor(context);
                          },
                        ),
                      ],
                    ),
                  ),
                  if (folders.isEmpty)
                    _SheetTile(
                      icon: Icons.create_new_folder_outlined,
                      label: 'New Folder',
                      onTap: () {
                        Navigator.pop(ctx);
                        _showFolderEditor(context);
                      },
                    )
                  else
                    for (final folder in folders)
                      _FolderManagerTile(
                        folder: folder,
                        count: _folderConversationCount(
                          folder,
                          chat.conversations,
                          context
                              .read<SettingsProvider>()
                              .archivedConversationIds,
                        ),
                        onEdit: () {
                          Navigator.pop(ctx);
                          _showFolderEditor(context, existing: folder);
                        },
                        onDelete: () {
                          Navigator.pop(ctx);
                          _confirmDeleteFolder(context, folder);
                        },
                      ),
                  const SizedBox(height: 12),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _showFolderEditor(
    BuildContext context, {
    ChatFolder? existing,
  }) async {
    final chat = context.read<ChatProvider>();
    final settings = context.read<SettingsProvider>();
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final conversations = chat.conversations
      ..sort(
        (a, b) => compareConversationsForInbox(
          a,
          b,
          drafts: settings.messageDrafts,
          pinnedConversationIds: settings.pinnedConversationIds,
        ),
      );
    final selectedIds = {...?existing?.conversationIds};
    var includeArchived = existing?.includeArchived ?? false;
    String? errorText;

    final draft = await showDialog<_FolderDraft>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) => GlassAlertDialog(
          icon: Icon(
            existing == null
                ? Icons.create_new_folder_outlined
                : Icons.folder_outlined,
          ),
          title: Text(existing == null ? 'New folder' : 'Edit folder'),
          contentPadding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  autofocus: true,
                  maxLength: 64,
                  decoration: InputDecoration(
                    labelText: 'Folder name',
                    errorText: errorText,
                    counterText: '',
                  ),
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  value: includeArchived,
                  onChanged: (value) =>
                      setDialogState(() => includeArchived = value ?? false),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Include archived chats'),
                ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(dialogCtx).height * 0.42,
                  ),
                  child: conversations.isEmpty
                      ? const Center(child: Text('No conversations yet'))
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: conversations.length,
                          itemBuilder: (context, index) {
                            final conversation = conversations[index];
                            final userId =
                                context.read<AuthProvider>().currentUser?.id ??
                                '';
                            final name = conversation.displayName(userId);
                            final selected = selectedIds.contains(
                              conversation.id,
                            );
                            return CheckboxListTile(
                              value: selected,
                              onChanged: (value) {
                                setDialogState(() {
                                  if (value == true) {
                                    selectedIds.add(conversation.id);
                                  } else {
                                    selectedIds.remove(conversation.id);
                                  }
                                });
                              },
                              controlAffinity: ListTileControlAffinity.leading,
                              contentPadding: EdgeInsets.zero,
                              secondary: Icon(
                                conversation.isChannel
                                    ? Icons.campaign_outlined
                                    : conversation.isGroup
                                    ? Icons.group_outlined
                                    : conversation.isBotDM(userId)
                                    ? Icons.smart_toy_outlined
                                    : Icons.person_outline_rounded,
                              ),
                              title: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) {
                  setDialogState(() => errorText = 'Required');
                  return;
                }
                Navigator.pop(
                  dialogCtx,
                  _FolderDraft(
                    name: name,
                    includeArchived: includeArchived,
                    conversationIds: selectedIds.toList(),
                  ),
                );
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    nameCtrl.dispose();
    if (draft == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final saved = await chat.saveChatFolder(
        ChatFolder(
          id: existing?.id ?? '',
          userId: existing?.userId ?? '',
          name: draft.name,
          position: existing?.position ?? chat.chatFolders.length,
          includeArchived: draft.includeArchived,
          conversationIds: draft.conversationIds,
          createdAt: existing?.createdAt,
          updatedAt: existing?.updatedAt,
        ),
      );
      if (mounted) setState(() => _selectedFolderId = saved.id);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Folder failed: $e')));
    }
  }

  Future<void> _confirmDeleteFolder(
    BuildContext context,
    ChatFolder folder,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        icon: const Icon(Icons.folder_delete_outlined),
        title: const Text('Delete folder?'),
        content: Text(folder.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<ChatProvider>().removeChatFolder(folder.id);
      if (mounted && _selectedFolderId == folder.id) {
        setState(() => _selectedFolderId = null);
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Delete failed: $e')));
    }
  }
}

class _FolderDraft {
  final String name;
  final bool includeArchived;
  final List<String> conversationIds;

  const _FolderDraft({
    required this.name,
    required this.includeArchived,
    required this.conversationIds,
  });
}

class _ChatFolderBar extends StatelessWidget {
  final List<ChatFolder> folders;
  final String? selectedFolderId;
  final Map<String, int> counts;
  final VoidCallback onAllSelected;
  final ValueChanged<ChatFolder> onFolderSelected;
  final VoidCallback onManage;

  const _ChatFolderBar({
    required this.folders,
    required this.selectedFolderId,
    required this.counts,
    required this.onAllSelected,
    required this.onFolderSelected,
    required this.onManage,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        itemCount: folders.length + 2,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          if (index == 0) {
            return _FolderChoiceChip(
              icon: Icons.all_inbox_outlined,
              label: 'All',
              selected: selectedFolderId == null,
              onSelected: onAllSelected,
            );
          }
          if (index == folders.length + 1) {
            return IconButton.filledTonal(
              tooltip: 'Folders',
              style: IconButton.styleFrom(
                backgroundColor: scheme.surfaceContainerHighest.withValues(
                  alpha: 0.42,
                ),
                foregroundColor: scheme.primary,
                minimumSize: const Size(40, 36),
              ),
              icon: const Icon(Icons.create_new_folder_outlined, size: 18),
              onPressed: onManage,
            );
          }
          final folder = folders[index - 1];
          return _FolderChoiceChip(
            icon: Icons.folder_outlined,
            label: folder.name,
            count: counts[folder.id] ?? 0,
            selected: selectedFolderId == folder.id,
            onSelected: () => onFolderSelected(folder),
          );
        },
      ),
    );
  }
}

class _FolderChoiceChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final int? count;
  final bool selected;
  final VoidCallback onSelected;

  const _FolderChoiceChip({
    required this.icon,
    required this.label,
    this.count,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ChoiceChip(
      selected: selected,
      onSelected: (_) => onSelected(),
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
      backgroundColor: scheme.surfaceContainerHighest.withValues(alpha: 0.42),
      selectedColor: scheme.primary.withValues(alpha: 0.17),
      side: BorderSide(
        color: selected
            ? scheme.primary.withValues(alpha: 0.55)
            : scheme.outlineVariant.withValues(alpha: 0.28),
      ),
      label: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 24, maxWidth: 160),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 15,
              color: selected
                  ? scheme.primary
                  : scheme.onSurface.withValues(alpha: 0.62),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  color: selected ? scheme.primary : null,
                ),
              ),
            ),
            if (count != null && count! > 0) ...[
              const SizedBox(width: 6),
              _InboxCountBadge(count: count!, active: selected),
            ],
          ],
        ),
      ),
    );
  }
}

class _FolderManagerTile extends StatelessWidget {
  final ChatFolder folder;
  final int count;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _FolderManagerTile({
    required this.folder,
    required this.count,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: scheme.primary.withValues(alpha: 0.12),
        child: Icon(Icons.folder_outlined, size: 18, color: scheme.primary),
      ),
      title: Text(
        folder.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(
        count == 1 ? '1 chat' : '$count chats',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        tooltip: 'Delete folder',
        icon: const Icon(Icons.delete_outline_rounded),
        color: scheme.error,
        onPressed: onDelete,
      ),
      onTap: onEdit,
    );
  }
}

class _SmartInboxBar extends StatelessWidget {
  final List<SmartInboxFilter> filters;
  final SmartInboxFilter selected;
  final Map<SmartInboxFilter, int> counts;
  final ValueChanged<SmartInboxFilter> onSelected;

  const _SmartInboxBar({
    required this.filters,
    required this.selected,
    required this.counts,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        itemCount: filters.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final filter = filters[index];
          final active = filter == selected;
          final count = counts[filter] ?? 0;
          return ChoiceChip(
            selected: active,
            onSelected: (_) => onSelected(filter),
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            backgroundColor: scheme.surfaceContainerHighest.withValues(
              alpha: 0.42,
            ),
            selectedColor: scheme.primary.withValues(alpha: 0.17),
            side: BorderSide(
              color: active
                  ? scheme.primary.withValues(alpha: 0.55)
                  : scheme.outlineVariant.withValues(alpha: 0.28),
            ),
            label: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 24),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _smartInboxFilterIcon(filter),
                    size: 15,
                    color: active
                        ? scheme.primary
                        : scheme.onSurface.withValues(alpha: 0.62),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    smartInboxFilterLabel(filter),
                    style: TextStyle(
                      fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                      color: active ? scheme.primary : null,
                    ),
                  ),
                  if (count > 0) ...[
                    const SizedBox(width: 6),
                    _InboxCountBadge(count: count, active: active),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _InboxCountBadge extends StatelessWidget {
  final int count;
  final bool active;

  const _InboxCountBadge({required this.count, required this.active});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = active ? scheme.primary : scheme.onSurfaceVariant;
    return Container(
      constraints: const BoxConstraints(minWidth: 20),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: active ? 0.16 : 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

IconData _smartInboxFilterIcon(SmartInboxFilter filter) {
  return switch (filter) {
    SmartInboxFilter.all => Icons.all_inbox_outlined,
    SmartInboxFilter.unread => Icons.mark_chat_unread_outlined,
    SmartInboxFilter.mentions => Icons.alternate_email_rounded,
    SmartInboxFilter.dms => Icons.person_outline_rounded,
    SmartInboxFilter.groups => Icons.group_outlined,
    SmartInboxFilter.channels => Icons.campaign_outlined,
    SmartInboxFilter.bots => Icons.smart_toy_outlined,
    SmartInboxFilter.archived => Icons.archive_outlined,
  };
}

String _smartInboxEmptyMessage(SmartInboxFilter filter) {
  return switch (filter) {
    SmartInboxFilter.unread => 'Everything here is caught up',
    SmartInboxFilter.mentions => 'No unread mentions need your attention',
    _ => 'This inbox is clear',
  };
}

String _smartInboxEmptyTitle(SmartInboxFilter filter) {
  return switch (filter) {
    SmartInboxFilter.mentions => 'No unread mentions',
    _ => 'No ${smartInboxFilterLabel(filter)} chats',
  };
}

// ── Animated conversation tile ────────────────────────────────────────────────

/// Staggered slide-up + fade-in entrance for each conversation row.
/// Tiles cascade in with a 40ms delay per index so the list appears to
/// materialise from top to bottom rather than popping in all at once.
class _AnimatedConversationTile extends StatefulWidget {
  final Widget child;
  final int index;

  const _AnimatedConversationTile({
    super.key,
    required this.child,
    required this.index,
  });

  @override
  State<_AnimatedConversationTile> createState() =>
      _AnimatedConversationTileState();
}

class _AnimatedConversationTileState extends State<_AnimatedConversationTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  late final Animation<double> _fade = CurvedAnimation(
    parent: _ctrl,
    curve: Curves.easeOutCubic,
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.18),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));

  @override
  void initState() {
    super.initState();
    // Cascade delay: max 8 tiles stagger so the list doesn't take too long.
    final delay = Duration(milliseconds: 40 * widget.index.clamp(0, 8));
    Future.delayed(delay, () {
      if (mounted) _ctrl.forward();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _fade,
    child: SlideTransition(position: _slide, child: widget.child),
  );
}

// ── Conversation Tile ─────────────────────────────────────────────────────────

class _ConversationTile extends StatelessWidget {
  final Conversation conversation;
  final MessageDraft? draft;
  final bool isPinned;
  final ConversationNotificationPreference notificationPreference;
  final String? unreadMentionMessageId;
  final String currentUserID;
  final VoidCallback onTap;
  final ValueChanged<String>? onUnreadMentionTap;
  final VoidCallback? onLongPress;

  const _ConversationTile({
    required this.conversation,
    this.draft,
    this.isPinned = false,
    this.notificationPreference =
        const ConversationNotificationPreference.all(),
    this.unreadMentionMessageId,
    required this.currentUserID,
    required this.onTap,
    this.onUnreadMentionTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = conversation.displayName(currentUserID);
    final avatar = conversation.displayAvatar(currentUserID);
    final last = conversation.lastMessage;
    final draftPreview = draft?.preview;
    final isBot = conversation.isBotDM(currentUserID);
    final hasUnread = conversation.unreadCount > 0;
    final hasUnreadMention = unreadMentionMessageId != null;
    final hasDraft = draftPreview != null && draftPreview.isNotEmpty;
    final isMuted = notificationPreference.isMutedAt(DateTime.now());
    final isPriority = notificationPreference.priority;
    final isMentionsOnly =
        notificationPreference.mode ==
        ConversationNotificationMode.mentionsOnly;

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
              // Hero wraps the avatar so it morphs smoothly into the chat
              // header avatar when the conversation is opened.
              Hero(
                tag: 'avatar_${conversation.id}',
                child: _ConvAvatar(
                  avatarUrl: avatar,
                  name: name,
                  isGroup: conversation.isGroup,
                  isChannel: conversation.isChannel,
                  hasUnread: hasUnread,
                ),
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
                        if (isPinned)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Icon(
                              Icons.push_pin_rounded,
                              size: 13,
                              color: scheme.primary.withValues(alpha: 0.72),
                            ),
                          ),
                        if (isMuted)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Icon(
                              Icons.notifications_off_outlined,
                              size: 13,
                              color: scheme.onSurface.withValues(alpha: 0.38),
                            ),
                          ),
                        if (isPriority)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Icon(
                              Icons.star_outline_rounded,
                              size: 13,
                              color: scheme.primary.withValues(alpha: 0.70),
                            ),
                          ),
                        if (isMentionsOnly)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Icon(
                              Icons.notification_important_outlined,
                              size: 13,
                              color: scheme.primary.withValues(alpha: 0.70),
                            ),
                          ),
                        if (hasUnreadMention)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Tooltip(
                              message: 'Jump to mention',
                              child: Semantics(
                                button: true,
                                label: 'Jump to unread mention',
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: onUnreadMentionTap == null
                                      ? null
                                      : () => onUnreadMentionTap!(
                                          unreadMentionMessageId!,
                                        ),
                                  child: SizedBox.square(
                                    dimension: 22,
                                    child: Center(
                                      child: Icon(
                                        Icons.alternate_email_rounded,
                                        size: 14,
                                        color: scheme.primary,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
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
                    if (hasDraft || last != null) ...[
                      const SizedBox(height: 2),
                      Text.rich(
                        TextSpan(
                          children: [
                            if (hasDraft)
                              TextSpan(
                                text: 'Draft: ',
                                style: TextStyle(
                                  color: scheme.error.withValues(alpha: 0.82),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            TextSpan(
                              text: hasDraft
                                  ? draftPreview
                                  : last?.listPreview ?? '',
                            ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: hasDraft
                              ? scheme.onSurface.withValues(alpha: 0.65)
                              : hasUnread
                              ? scheme.onSurface.withValues(alpha: 0.75)
                              : scheme.onSurface.withValues(alpha: 0.45),
                          fontSize: 13,
                          fontWeight: hasUnread && !hasDraft
                              ? FontWeight.w500
                              : FontWeight.w400,
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
                  if (hasDraft || last != null)
                    Text(
                      timeago.format(
                        hasDraft ? draft!.updatedAt : last!.createdAt,
                        locale: 'en_short',
                      ),
                      style: TextStyle(
                        fontSize: 11.5,
                        color: hasDraft
                            ? scheme.error.withValues(alpha: 0.74)
                            : isMuted
                            ? scheme.onSurface.withValues(alpha: 0.36)
                            : hasUnread
                            ? scheme.primary
                            : scheme.onSurface.withValues(alpha: 0.38),
                        fontWeight: hasUnread
                            ? FontWeight.w600
                            : FontWeight.w400,
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
                        color: isMuted
                            ? scheme.onSurface.withValues(alpha: 0.24)
                            : scheme.primary,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: (isMuted ? scheme.onSurface : scheme.primary)
                                .withValues(alpha: isMuted ? 0.12 : 0.40),
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
  final ChatProvider chat;
  final String currentUserId;
  final Future<void> Function(String userID) onUserSelected;
  final void Function(Conversation channel) onChannelSelected;
  final Future<void> Function(MessageSearchResult result) onMessageSelected;
  MessageSearchCategory? _messageCategory;

  _ChatSearchDelegate({
    required this.api,
    required this.chat,
    required this.currentUserId,
    required this.onUserSelected,
    required this.onChannelSelected,
    required this.onMessageSelected,
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
  Widget buildResults(BuildContext context) => _buildSuggestions(context);

  @override
  Widget buildSuggestions(BuildContext context) => _buildSuggestions(context);

  Widget _buildSuggestions(BuildContext context) {
    final q = query.trim();
    if (q.length < 2) {
      return const Center(
        child: Text('Search users, channels, and local messages'),
      );
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
            (results.users.isEmpty &&
                results.channels.isEmpty &&
                results.messages.isEmpty)) {
          return const Center(child: Text('No results'));
        }
        return ListView(
          children: [
            _MessageSearchFilters(
              selected: _messageCategory,
              onSelected: (category) {
                _messageCategory = category;
                showSuggestions(context);
              },
            ),
            if (results.messages.isNotEmpty) ...[
              _SearchSectionHeader(
                label: _messageCategory == null
                    ? 'Messages on this device'
                    : '${_messageCategoryLabel(_messageCategory!)} on this device',
              ),
              for (final message in results.messages)
                ListTile(
                  leading: CircleAvatar(
                    child: Icon(_messageCategoryIcon(message.category)),
                  ),
                  title: Text(
                    message.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    _messageSubtitle(message),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Text(
                    timeago.format(message.createdAt),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  onTap: () {
                    close(context, null);
                    onMessageSelected(message);
                  },
                ),
            ],
            if (results.users.isNotEmpty)
              const _SearchSectionHeader(label: 'People and bots'),
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
            if (results.channels.isNotEmpty)
              const _SearchSectionHeader(label: 'Channels'),
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

  String _messageSubtitle(MessageSearchResult message) {
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
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
      child: Row(
        children: [
          for (final (label, category) in _options) ...[
            ChoiceChip(
              label: Text(label),
              selected: selected == category,
              onSelected: (_) => onSelected(category),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

IconData _messageCategoryIcon(MessageSearchCategory category) {
  return switch (category) {
    MessageSearchCategory.media => Icons.photo_library_outlined,
    MessageSearchCategory.files => Icons.insert_drive_file_outlined,
    MessageSearchCategory.links => Icons.link_rounded,
    MessageSearchCategory.voice => Icons.graphic_eq_rounded,
    MessageSearchCategory.polls => Icons.poll_outlined,
    MessageSearchCategory.payments => Icons.payments_outlined,
    MessageSearchCategory.checklists => Icons.checklist_rounded,
    MessageSearchCategory.messages => Icons.chat_bubble_outline_rounded,
  };
}

String _messageCategoryLabel(MessageSearchCategory category) {
  return switch (category) {
    MessageSearchCategory.media => 'Media',
    MessageSearchCategory.files => 'Files',
    MessageSearchCategory.links => 'Links',
    MessageSearchCategory.voice => 'Voice',
    MessageSearchCategory.polls => 'Polls',
    MessageSearchCategory.payments => 'Payments',
    MessageSearchCategory.checklists => 'Lists',
    MessageSearchCategory.messages => 'Messages',
  };
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
                Text(
                  label,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
