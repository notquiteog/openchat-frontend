import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import 'package:timeago/timeago.dart' as timeago;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassButton, GlassModalSheet, SheetState;
import '../../models/chat_folder.dart';
import '../../models/conversation.dart';
import '../../models/message.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/api_service.dart';
import '../../config/api_config.dart';
import '../../utils/local_conversation_preferences.dart';
import '../../utils/smart_inbox_filter.dart';
import '../../widgets/chat_search_results_view.dart';
import '../../widgets/glass.dart';
import '../../widgets/conversation_notification_controls_sheet.dart';
import '../../widgets/stories_strip.dart';
import '../channels/channel_screen.dart';
import '../broadcast/broadcast_lists_screen.dart';
import '../call/call_history_screen.dart';
import '../chat/chat_screen.dart';
import '../settings/settings_screen.dart';

class ConversationsScreen extends StatefulWidget {
  const ConversationsScreen({super.key});
  @override
  State<ConversationsScreen> createState() => _ConversationsScreenState();
}

/// Where a drag that ended at [offset] should settle when the stories strip
/// occupies the first [extent] logical pixels of the inbox list: fully
/// revealed (0.0), fully hidden ([extent]), or null when the offset is outside
/// the strip and no snap applies. Top-level so it is unit-testable — the full
/// screen can't be pumped in widget tests (ChatProvider opens sockets).
double? storiesSnapTarget(double offset, double extent) {
  if (offset <= 0 || offset >= extent) return null;
  return offset < extent / 2 ? 0.0 : extent;
}

class _ConversationsScreenState extends State<ConversationsScreen> {
  String? _selectedFolderId;

  /// StoriesStrip height (96) + its hairline divider (0.5 + 2 margin). The
  /// list starts scrolled past this, so the strip hides above the fold until
  /// the user pulls down on the inbox (Telegram-archive style reveal).
  static const double _storiesRevealExtent = 98.5;
  late final ScrollController _listCtrl = ScrollController(
    initialScrollOffset: _storiesRevealExtent,
  );
  bool _snappingStories = false;

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
  void dispose() {
    _listCtrl.dispose();
    super.dispose();
  }

  /// Snaps the half-revealed stories strip fully open or fully hidden when a
  /// drag ends inside its extent. Plain scrolls past the strip are untouched.
  bool _onListScrollEnd(ScrollEndNotification notification) {
    if (_snappingStories || !_listCtrl.hasClients) return false;
    if (notification.metrics.axis != Axis.vertical) return false;
    final target = storiesSnapTarget(_listCtrl.offset, _storiesRevealExtent);
    if (target == null) return false;
    _snappingStories = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (_listCtrl.hasClients) {
        await _listCtrl.animateTo(
          target,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
        );
      }
      _snappingStories = false;
    });
    return false;
  }

  /// The strip only exists in the unfiltered inbox. Entering a folder must
  /// not leave the list scrolled past the (now absent) strip, and returning
  /// to the inbox must re-hide it above the fold.
  void _syncStoriesOffsetForFolder(String? folderId) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_listCtrl.hasClients) return;
      _listCtrl.jumpTo(folderId == null ? _storiesRevealExtent : 0);
    });
  }

  void _selectFolder(String? folderId) {
    setState(() => _selectedFolderId = folderId);
    _syncStoriesOffsetForFolder(folderId);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final chat = context.watch<ChatProvider>();
    final settings = context.watch<SettingsProvider>();
    final currentUserID = auth.currentUser?.id ?? '';
    final drafts = settings.messageDrafts;
    final pinnedConversationIds = settings.pinnedConversationIds;
    final archivedConversationIds = settings.archivedConversationIds;
    final unreadMentionMessageIds = settings.unreadMentionMessageIds;
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
          currentUserID,
          unreadMentionMessageIds,
          settings.conversationNotificationPreferences,
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
                archivedConversationIds: archivedConversationIds,
                unreadMentionMessageIds: unreadMentionMessageIds,
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
                  archivedConversationIds: archivedConversationIds,
                  unreadMentionMessageIds: unreadMentionMessageIds,
                ),
              )
              .toList()
        : _folderConversations(
            selectedFolder,
            folderSourceConversations,
            archivedConversationIds,
            currentUserID,
            unreadMentionMessageIds,
            settings.conversationNotificationPreferences,
          );

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassAppBar(
        title: const Text('Chats'),
        actions: [
          IconButton(
            tooltip: 'Calls',
            icon: const Icon(Icons.call_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CallHistoryScreen()),
            ),
          ),
          // Search moved to the bottom bar's morphing pill
          // (GlassSearchableBottomBar in the home shell).
          IconButton(
            tooltip: 'Inbox view',
            icon: Badge(
              isLabelVisible:
                  selectedFolder != null ||
                  selectedFilter != SmartInboxFilter.all,
              smallSize: 8,
              child: const Icon(Icons.tune_rounded),
            ),
            onPressed: () => _showInboxViewSheet(
              context,
              filters: availableFilters,
              selectedFilter: selectedFilter,
              filterCounts: filterCounts,
              folders: folders,
              selectedFolder: selectedFolder,
              folderCounts: folderCounts,
            ),
          ),
          IconButton(
            tooltip: 'More',
            icon: const Icon(Icons.more_vert_rounded),
            onPressed: () => _showOverflowSheet(context),
          ),
        ],
      ),
      // No pull-to-refresh: the inbox is WebSocket-driven (reconnect already
      // resyncs), so the pull gesture is reserved for revealing the stories
      // strip hidden above the fold.
      body: chat.isLoading
          ? const Center(child: GlassProgressIndicator.circular())
          : NotificationListener<ScrollEndNotification>(
              onNotification: _onListScrollEnd,
              child: ListView(
                controller: _listCtrl,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.only(
                  top: MediaQuery.paddingOf(context).top + kToolbarHeight,
                  bottom: MediaQuery.paddingOf(context).bottom + 8,
                ),
                children: [
                  // Instagram-style stories row pinned to the top of the inbox.
                  if (selectedFolder == null) ...[
                    const StoriesStrip(),
                    Container(
                      height: 0.5,
                      margin: const EdgeInsets.only(bottom: 2),
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.07),
                    ),
                  ],
                  if (selectedFolder != null ||
                      selectedFilter != SmartInboxFilter.all)
                    _ActiveInboxScopeBar(
                      icon: selectedFolder != null
                          ? Icons.folder_outlined
                          : _smartInboxFilterIcon(selectedFilter),
                      label:
                          selectedFolder?.name ??
                          smartInboxFilterLabel(selectedFilter),
                      count: conversations.length,
                      onTap: () => _showInboxViewSheet(
                        context,
                        filters: availableFilters,
                        selectedFilter: selectedFilter,
                        filterCounts: filterCounts,
                        folders: folders,
                        selectedFolder: selectedFolder,
                        folderCounts: folderCounts,
                      ),
                      onClear: () {
                        if (selectedFolder != null) {
                          _selectFolder(null);
                        } else {
                          settings.setSmartInboxFilter(SmartInboxFilter.all);
                        }
                      },
                    ),
                  const SizedBox(height: 6),
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
                          showDivider: index < conversations.length - 1,
                          draft: drafts[conversations[index].id],
                          isPinned: pinnedConversationIds.contains(
                            conversations[index].id,
                          ),
                          notificationPreference: settings
                              .notificationPreferenceForConversation(
                                conversations[index].id,
                              ),
                          unreadMentionMessageId: settings
                              .unreadMentionMessageIdFor(
                                conversations[index].id,
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

  Future<void> _showOverflowSheet(BuildContext context) async {
    await GlassModalSheet.show<void>(
      context: context,
      initialState: SheetState.half,
      halfSize: 0.36,
      enableInteractionGlow: true,
      builder: (sheetContext) {
        void runAfterClose(VoidCallback action) {
          Navigator.of(sheetContext).pop();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            action();
          });
        }

        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const GlassSheetGrabber(),
              GlassSheetHeader(
                icon: Icons.more_horiz_rounded,
                title: 'Chats menu',
                subtitle: 'Organize, browse stories, or tune OpenChat.',
                onClose: () => Navigator.of(sheetContext).pop(),
              ),
              GlassActionTile(
                icon: Icons.folder_outlined,
                label: 'Folders',
                subtitle: 'Create focused inboxes and automatic rules',
                onTap: () => runAfterClose(() => _showFolderManager(context)),
              ),
              GlassActionTile(
                icon: Icons.settings_outlined,
                label: 'Settings',
                subtitle: 'Privacy, appearance, devices, and account tools',
                onTap: () => runAfterClose(
                  () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
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
    final selection = await showSearch<ChatSearchSelection?>(
      context: context,
      delegate: _ChatSearchDelegate(),
    );

    if (!context.mounted || selection == null) return;
    await handleChatSearchSelection(
      context,
      selection,
      openConversation: (conv, initialMessageId) =>
          _openConversation(context, conv, initialMessageId: initialMessageId),
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
                icon: Icons.campaign_outlined,
                label: 'Broadcast lists',
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const BroadcastListsScreen(),
                    ),
                  );
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
    // null = permanent; otherwise the burner lifetime in seconds.
    int? ttlSeconds;
    const ttlOptions = <String, int?>{
      'Permanent': null,
      '1 hour': 3600,
      '1 day': 86400,
      '1 week': 604800,
      '1 month': 2592000,
    };
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => GlassAlertDialog(
          title: const Text('New Group'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'Group name'),
                autofocus: true,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Icon(Icons.local_fire_department_outlined, size: 18),
                  const SizedBox(width: 8),
                  const Text('Auto-destruct'),
                  const Spacer(),
                  DropdownButton<int?>(
                    value: ttlSeconds,
                    onChanged: (v) => setLocal(() => ttlSeconds = v),
                    items: [
                      for (final entry in ttlOptions.entries)
                        DropdownMenuItem<int?>(
                          value: entry.value,
                          child: Text(entry.key),
                        ),
                    ],
                  ),
                ],
              ),
              if (ttlSeconds != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'This group and its messages are permanently deleted '
                    'when the timer ends.',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(
                        ctx,
                      ).colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ),
            ],
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
      ),
    );
    if (result != null && result.isNotEmpty && context.mounted) {
      final conv = await context.read<ChatProvider>().createGroup(
        name: result,
        memberIDs: [],
        expiresInSeconds: ttlSeconds,
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

  Future<void> _showInboxViewSheet(
    BuildContext context, {
    required List<SmartInboxFilter> filters,
    required SmartInboxFilter selectedFilter,
    required Map<SmartInboxFilter, int> filterCounts,
    required List<ChatFolder> folders,
    required ChatFolder? selectedFolder,
    required Map<String, int> folderCounts,
  }) async {
    final settings = context.read<SettingsProvider>();
    void selectFilter(BuildContext sheetContext, SmartInboxFilter filter) {
      Navigator.pop(sheetContext);
      if (!mounted) return;
      _selectFolder(null);
      settings.setSmartInboxFilter(filter);
    }

    void selectFolder(BuildContext sheetContext, ChatFolder folder) {
      Navigator.pop(sheetContext);
      if (!mounted) return;
      _selectFolder(folder.id);
      settings.setSmartInboxFilter(SmartInboxFilter.all);
    }

    await GlassModalSheet.show<void>(
      context: context,
      initialState: SheetState.half,
      halfSize: folders.isEmpty ? 0.46 : 0.62,
      enableInteractionGlow: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 10, 4),
                child: Row(
                  children: [
                    const Icon(Icons.tune_rounded, size: 20),
                    const SizedBox(width: 10),
                    Text(
                      'Inbox view',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Manage folders',
                      icon: const Icon(Icons.folder_outlined),
                      onPressed: () {
                        Navigator.pop(sheetContext);
                        _showFolderManager(context);
                      },
                    ),
                  ],
                ),
              ),
              for (final filter in filters)
                _InboxViewOptionTile(
                  icon: _smartInboxFilterIcon(filter),
                  label: filter == SmartInboxFilter.all
                      ? 'All chats'
                      : smartInboxFilterLabel(filter),
                  count: filterCounts[filter] ?? 0,
                  selected: selectedFolder == null && selectedFilter == filter,
                  onTap: () => selectFilter(sheetContext, filter),
                ),
              if (folders.isNotEmpty) ...[
                _SheetSectionHeader(label: 'Folders'),
                for (final folder in folders)
                  _InboxViewOptionTile(
                    icon: Icons.folder_outlined,
                    label: folder.name,
                    count: folderCounts[folder.id] ?? 0,
                    selected: selectedFolder?.id == folder.id,
                    onTap: () => selectFolder(sheetContext, folder),
                  ),
              ],
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  int _folderConversationCount(
    ChatFolder folder,
    List<Conversation> conversations,
    Set<String> archivedConversationIds,
    String currentUserID,
    Map<String, String> unreadMentionMessageIds,
    Map<String, ConversationNotificationPreference> notificationPreferences,
  ) {
    return _folderConversations(
      folder,
      conversations,
      archivedConversationIds,
      currentUserID,
      unreadMentionMessageIds,
      notificationPreferences,
    ).length;
  }

  List<Conversation> _folderConversations(
    ChatFolder folder,
    List<Conversation> conversations,
    Set<String> archivedConversationIds,
    String currentUserID,
    Map<String, String> unreadMentionMessageIds,
    Map<String, ConversationNotificationPreference> notificationPreferences,
  ) {
    if (folder.isRuleBased) {
      return conversations
          .where(
            (conversation) => _conversationMatchesFolderRules(
              conversation,
              folder.rules,
              currentUserID,
              archivedConversationIds,
              unreadMentionMessageIds,
              notificationPreferences,
            ),
          )
          .toList();
    }
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

  bool _conversationMatchesFolderRules(
    Conversation conversation,
    ChatFolderRules rules,
    String currentUserID,
    Set<String> archivedConversationIds,
    Map<String, String> unreadMentionMessageIds,
    Map<String, ConversationNotificationPreference> notificationPreferences,
  ) {
    final archived =
        archivedConversationIds.contains(conversation.id) ||
        conversation.isArchived;
    if (rules.archivedOnly) {
      if (!archived) return false;
    } else if (archived) {
      return false;
    }
    if (rules.unreadOnly && conversation.unreadCount <= 0) return false;
    if (rules.mentionsOnly &&
        !unreadMentionMessageIds.containsKey(conversation.id)) {
      return false;
    }
    if (rules.mutedOnly) {
      final preference = notificationPreferences[conversation.id];
      if (preference == null || !preference.isMutedAt(DateTime.now())) {
        return false;
      }
    }
    if (rules.paymentsOnly) {
      final type = conversation.lastMessage?.type;
      if (type != MessageType.invoice &&
          type != MessageType.paymentRequest &&
          type != MessageType.paymentTransfer) {
        return false;
      }
    }
    if (rules.hasTypeRule) {
      final isBot = conversation.isBotDM(currentUserID);
      final matchesType =
          (rules.dms && conversation.isDM && !isBot) ||
          (rules.groups && conversation.isGroup) ||
          (rules.channels && conversation.isChannel) ||
          (rules.bots && isBot);
      if (!matchesType) return false;
    }
    return true;
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
                          context.read<AuthProvider>().currentUser?.id ?? '',
                          context
                              .read<SettingsProvider>()
                              .unreadMentionMessageIds,
                          context
                              .read<SettingsProvider>()
                              .conversationNotificationPreferences,
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
    var rules = existing?.rules ?? const ChatFolderRules();
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
                GlassListTile(
                  leading: Icon(
                    includeArchived
                        ? Icons.check_box_rounded
                        : Icons.check_box_outline_blank_rounded,
                    color: includeArchived
                        ? Theme.of(dialogCtx).colorScheme.primary
                        : null,
                    size: 20,
                  ),
                  title: const Text(
                    'Include archived chats',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  onTap: () =>
                      setDialogState(() => includeArchived = !includeArchived),
                ),
                const SizedBox(height: 8),
                GlassListTile(
                  leading: Icon(
                    rules.enabled
                        ? Icons.auto_awesome_rounded
                        : Icons.rule_folder_outlined,
                    color: rules.enabled
                        ? Theme.of(dialogCtx).colorScheme.primary
                        : null,
                    size: 20,
                  ),
                  title: const Text(
                    'Automatic rules',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    rules.enabled
                        ? 'Match chats locally from private state'
                        : 'Pick specific chats manually',
                  ),
                  onTap: () => setDialogState(() {
                    rules = rules.copyWith(enabled: !rules.enabled);
                  }),
                ),
                if (rules.enabled) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _FolderRuleChip(
                          label: 'Unread',
                          selected: rules.unreadOnly,
                          onSelected: (v) => setDialogState(
                            () => rules = rules.copyWith(unreadOnly: v),
                          ),
                        ),
                        _FolderRuleChip(
                          label: 'Mentions',
                          selected: rules.mentionsOnly,
                          onSelected: (v) => setDialogState(
                            () => rules = rules.copyWith(mentionsOnly: v),
                          ),
                        ),
                        _FolderRuleChip(
                          label: 'DMs',
                          selected: rules.dms,
                          onSelected: (v) => setDialogState(
                            () => rules = rules.copyWith(dms: v),
                          ),
                        ),
                        _FolderRuleChip(
                          label: 'Groups',
                          selected: rules.groups,
                          onSelected: (v) => setDialogState(
                            () => rules = rules.copyWith(groups: v),
                          ),
                        ),
                        _FolderRuleChip(
                          label: 'Channels',
                          selected: rules.channels,
                          onSelected: (v) => setDialogState(
                            () => rules = rules.copyWith(channels: v),
                          ),
                        ),
                        _FolderRuleChip(
                          label: 'Bots',
                          selected: rules.bots,
                          onSelected: (v) => setDialogState(
                            () => rules = rules.copyWith(bots: v),
                          ),
                        ),
                        _FolderRuleChip(
                          label: 'Muted',
                          selected: rules.mutedOnly,
                          onSelected: (v) => setDialogState(
                            () => rules = rules.copyWith(mutedOnly: v),
                          ),
                        ),
                        _FolderRuleChip(
                          label: 'Archived',
                          selected: rules.archivedOnly,
                          onSelected: (v) => setDialogState(
                            () => rules = rules.copyWith(archivedOnly: v),
                          ),
                        ),
                        _FolderRuleChip(
                          label: 'Payments',
                          selected: rules.paymentsOnly,
                          onSelected: (v) => setDialogState(
                            () => rules = rules.copyWith(paymentsOnly: v),
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else
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
                                  context
                                      .read<AuthProvider>()
                                      .currentUser
                                      ?.id ??
                                  '';
                              final name = conversation.displayName(userId);
                              final selected = selectedIds.contains(
                                conversation.id,
                              );
                              return GlassListTile(
                                leading: Icon(
                                  selected
                                      ? Icons.check_box_rounded
                                      : Icons.check_box_outline_blank_rounded,
                                  color: selected
                                      ? Theme.of(context).colorScheme.primary
                                      : null,
                                  size: 20,
                                ),
                                title: Text(
                                  name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                trailing: Icon(
                                  conversation.isChannel
                                      ? Icons.campaign_outlined
                                      : conversation.isGroup
                                      ? Icons.group_outlined
                                      : conversation.isBotDM(userId)
                                      ? Icons.smart_toy_outlined
                                      : Icons.person_outline_rounded,
                                  size: 18,
                                ),
                                onTap: () => setDialogState(() {
                                  if (selected) {
                                    selectedIds.remove(conversation.id);
                                  } else {
                                    selectedIds.add(conversation.id);
                                  }
                                }),
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
                if (rules.enabled && !rules.hasAnyRule) {
                  setDialogState(() => errorText = 'Choose at least one rule');
                  return;
                }
                Navigator.pop(
                  dialogCtx,
                  _FolderDraft(
                    name: name,
                    includeArchived: includeArchived,
                    conversationIds: selectedIds.toList(),
                    rules: rules,
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
          rules: draft.rules,
          createdAt: existing?.createdAt,
          updatedAt: existing?.updatedAt,
        ),
      );
      if (mounted) _selectFolder(saved.id);
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
        _selectFolder(null);
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
  final ChatFolderRules rules;

  const _FolderDraft({
    required this.name,
    required this.includeArchived,
    required this.conversationIds,
    required this.rules,
  });
}

class _FolderRuleChip extends StatelessWidget {
  final String label;
  final bool selected;
  final ValueChanged<bool> onSelected;

  const _FolderRuleChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return GlassChip(
      selected: selected,
      label: label,
      onTap: () => onSelected(!selected),
    );
  }
}

class _ActiveInboxScopeBar extends StatelessWidget {
  final IconData icon;
  final String label;
  final int count;
  final VoidCallback onTap;
  final VoidCallback onClear;

  const _ActiveInboxScopeBar({
    required this.icon,
    required this.label,
    required this.count,
    required this.onTap,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: GlassCard(
        padding: EdgeInsets.zero,
        margin: EdgeInsets.zero,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(22),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.only(left: 14, right: 4),
              child: Row(
                children: [
                  Icon(icon, size: 18, color: scheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  _InboxCountBadge(count: count, active: true),
                  const SizedBox(width: 2),
                  IconButton(
                    tooltip: 'Clear',
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: onClear,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InboxViewOptionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  const _InboxViewOptionTile({
    required this.icon,
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassActionTile(
      icon: icon,
      label: label,
      selected: selected,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (count > 0) _InboxCountBadge(count: count, active: selected),
          if (selected) ...[
            const SizedBox(width: 8),
            Icon(Icons.check_rounded, color: scheme.primary, size: 20),
          ],
        ],
      ),
      onTap: onTap,
    );
  }
}

class _SheetSectionHeader extends StatelessWidget {
  final String label;

  const _SheetSectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 6),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(
            context,
          ).colorScheme.onSurface.withValues(alpha: 0.56),
          fontWeight: FontWeight.w800,
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
    return GlassListTile(
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
      trailing: GlassCircleIconButton(
        tooltip: 'Delete folder',
        icon: Icon(Icons.delete_outline_rounded, color: scheme.error, size: 18),
        size: 36,
        glowIntensity: 0.04,
        onPressed: onDelete,
      ),
      onTap: onEdit,
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
  final bool showDivider;
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
    this.showDivider = false,
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
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

    return Column(
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            splashColor: scheme.primary.withValues(alpha: 0.06),
            highlightColor: scheme.primary.withValues(alpha: 0.03),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 9, 16, 9),
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
                      isSelf: conversation.isSelf,
                    ),
                  ),
                  const SizedBox(width: 12),
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
                                  color: scheme.onSurface.withValues(
                                    alpha: 0.44,
                                  ),
                                ),
                              ),
                            if (isBot)
                              Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: Icon(
                                  Icons.smart_toy_outlined,
                                  size: 13,
                                  color: scheme.onSurface.withValues(
                                    alpha: 0.44,
                                  ),
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
                                  color: scheme.onSurface.withValues(
                                    alpha: 0.38,
                                  ),
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
                            Expanded(
                              child: Text(
                                name,
                                style: TextStyle(
                                  fontWeight: hasUnread
                                      ? FontWeight.w700
                                      : FontWeight.w600,
                                  fontSize: 16.5,
                                  letterSpacing: -0.2,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (hasDraft || last != null) ...[
                              const SizedBox(width: 8),
                              Text(
                                timeago.format(
                                  hasDraft ? draft!.updatedAt : last!.createdAt,
                                  locale: 'en_short',
                                ),
                                style: TextStyle(
                                  fontSize: 13,
                                  color: hasDraft
                                      ? scheme.error.withValues(alpha: 0.74)
                                      : isMuted
                                      ? scheme.onSurface.withValues(alpha: 0.36)
                                      : hasUnread
                                      ? scheme.primary
                                      : scheme.onSurface.withValues(alpha: 0.4),
                                  fontWeight: hasUnread
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                            ],
                          ],
                        ),
                        if (hasDraft || last != null) ...[
                          const SizedBox(height: 3),
                          Text.rich(
                            TextSpan(
                              children: [
                                if (hasDraft)
                                  TextSpan(
                                    text: 'Draft: ',
                                    style: TextStyle(
                                      color: scheme.error.withValues(
                                        alpha: 0.82,
                                      ),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                TextSpan(
                                  text: hasDraft
                                      ? draftPreview
                                      : last?.listPreview ?? '',
                                ),
                              ],
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              height: 1.25,
                              color: hasDraft
                                  ? scheme.onSurface.withValues(alpha: 0.6)
                                  : hasUnread
                                  ? scheme.onSurface.withValues(alpha: 0.72)
                                  : scheme.onSurface.withValues(alpha: 0.5),
                              fontSize: 14.5,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  // Compact unread count, vertically centred against the avatar.
                  if (hasUnread) ...[
                    const SizedBox(width: 8),
                    Container(
                      constraints: const BoxConstraints(minWidth: 18),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        // iOS systemGray for muted badges keeps white text
                        // legible in both themes.
                        color: isMuted
                            ? const Color(0xFF8E8E93)
                            : scheme.primary,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        conversation.unreadCount > 99
                            ? '99+'
                            : '${conversation.unreadCount}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          height: 1.3,
                          letterSpacing: 0,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        if (showDivider)
          Container(
            margin: const EdgeInsets.only(left: 82),
            height: 0.5,
            color: scheme.onSurface.withValues(alpha: isDark ? 0.14 : 0.1),
          ),
      ],
    );
  }
}

class _ConvAvatar extends StatelessWidget {
  final String? avatarUrl;
  final String name;
  final bool isGroup;
  final bool isChannel;
  final bool isSelf;

  const _ConvAvatar({
    this.avatarUrl,
    required this.name,
    required this.isGroup,
    required this.isChannel,
    this.isSelf = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return CircleAvatar(
      radius: 27,
      backgroundColor: isSelf
          ? scheme.primary.withValues(alpha: 0.15)
          : scheme.surfaceContainerHighest,
      backgroundImage: avatarUrl != null
          ? CachedNetworkImageProvider(ApiConfig.resolveMedia(avatarUrl!))
          : null,
      child: avatarUrl == null
          ? (isSelf
                ? Icon(Icons.bookmark_rounded, size: 23, color: scheme.primary)
                : isGroup || isChannel
                ? Icon(
                    isChannel ? Icons.campaign_rounded : Icons.group_rounded,
                    size: 23,
                    color: scheme.onSurfaceVariant,
                  )
                : Text(
                    name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
                    ),
                  ))
          : null,
    );
  }
}

// ── Search delegate ────────────────────────────────────────────────────────────

/// showSearch shell kept for flows that want a full-screen search route
/// (e.g. "New Direct Message"); the body is the shared results view.
class _ChatSearchDelegate extends SearchDelegate<ChatSearchSelection?> {
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
  Widget buildResults(BuildContext context) =>
      ChatSearchResultsView(query: query, onSelect: (s) => close(context, s));

  @override
  Widget buildSuggestions(BuildContext context) =>
      ChatSearchResultsView(query: query, onSelect: (s) => close(context, s));
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
  Widget build(BuildContext context) =>
      GlassActionTile(icon: icon, label: label, onTap: onTap);
}
