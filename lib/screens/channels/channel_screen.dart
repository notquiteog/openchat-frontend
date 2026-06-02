import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../../config/api_config.dart';
import '../../models/conversation.dart';
import '../../models/message.dart';
import '../../providers/auth_provider.dart';
import '../../providers/call_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/api_service.dart';
import '../../services/attachment_service.dart';
import '../../services/secure_storage_service.dart';
import '../../crypto/pgp_service.dart';
import '../../widgets/conversation_encryption_status.dart';
import '../../widgets/color_choices.dart';
import '../../widgets/glass.dart';
import '../../widgets/message_bubble.dart';
import '../../widgets/sticker_picker.dart';
import '../profile/user_profile_screen.dart';
import 'channel_action_policy.dart';
import 'moderation_screen.dart';

/// Shows the channel-creation dialog and creates the channel. Returns the new
/// [Conversation] on success, or null if cancelled / failed. Shared by the
/// Channels tab and the Chats screen's compose menu so there's one create flow.
Future<Conversation?> showCreateChannelDialog(BuildContext context) async {
  final api = context.read<ApiService>();
  final messenger = ScaffoldMessenger.of(context);
  final nameCtrl = TextEditingController();
  final handleCtrl = TextEditingController();
  final descCtrl = TextEditingController();
  bool isPublic = true;

  final result = await showDialog<Map<String, dynamic>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDlgState) => AlertDialog(
        title: const Text('New channel'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Channel name'),
            ),
            // The @handle only makes sense for public channels; hide it when
            // the channel is private.
            if (isPublic)
              TextField(
                controller: handleCtrl,
                decoration: const InputDecoration(
                  labelText: '@handle (optional)',
                  hintText: 'lowercase, letters/numbers/underscores',
                  prefixText: '@',
                ),
              ),
            TextField(
              controller: descCtrl,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
              ),
            ),
            SwitchListTile(
              title: const Text('Public'),
              subtitle: const Text('Anyone can find and subscribe'),
              value: isPublic,
              onChanged: (v) => setDlgState(() => isPublic = v),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, {
              'name': nameCtrl.text.trim(),
              // Private channels never carry a handle.
              'handle': isPublic ? handleCtrl.text.trim().toLowerCase() : '',
              'description': descCtrl.text.trim(),
              'is_public': isPublic,
            }),
            child: const Text('Create'),
          ),
        ],
      ),
    ),
  );

  if (result == null || (result['name'] as String).isEmpty) return null;

  try {
    final handle = result['handle'] as String;
    return await api.createChannel(
      name: result['name'] as String,
      description: result['description'] as String?,
      isPublic: result['is_public'] as bool,
      handle: handle.isEmpty ? null : handle,
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Failed to create channel: $e')),
    );
    return null;
  }
}

/// Lists the channels you're subscribed to and lets you search / create
/// channels. Subscribed channels show by default (when the search box is
/// empty); typing searches all public channels.
class ChannelListScreen extends StatefulWidget {
  const ChannelListScreen({super.key});

  @override
  State<ChannelListScreen> createState() => _ChannelListScreenState();
}

class _ChannelListScreenState extends State<ChannelListScreen> {
  final _searchCtrl = TextEditingController();
  List<Conversation> _results = [];
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ChatProvider>().loadConversations();
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    if (query.length < 2) {
      setState(() => _results = []);
      return;
    }
    setState(() => _searching = true);
    try {
      final api = context.read<ApiService>();
      final found = await api.searchChannels(query);
      setState(() => _results = found);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _openChannel(Conversation channel) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ChannelFeedScreen(channel: channel)),
    );
  }

  Future<void> _createChannel() async {
    final channel = await showCreateChannelDialog(context);
    if (channel != null && mounted) _openChannel(channel);
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatProvider>();
    final subscribed = chat.conversations.where((c) => c.isChannel).toList();
    final searching = _searchCtrl.text.isNotEmpty;
    final callTopInset = context.select<CallProvider, double>(
      (cp) => cp.minimizedContentTopInset,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Channels'),
        actions: [
          IconButton(icon: const Icon(Icons.add), onPressed: _createChannel),
        ],
      ),
      body: Column(
        children: [
          if (callTopInset > 0) SizedBox(height: callTopInset),
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (q) {
                setState(() {});
                _search(q);
              },
              decoration: InputDecoration(
                hintText: 'Search public channels…',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
                filled: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
              ),
            ),
          ),
          if (_searching) const LinearProgressIndicator(),
          Expanded(
            child: searching
                ? _buildList(_results, emptyText: 'No channels found')
                : _buildList(
                    subscribed,
                    emptyText:
                        'No channels yet — search above or tap + to create one',
                    subscribedView: true,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(
    List<Conversation> channels, {
    required String emptyText,
    bool subscribedView = false,
  }) {
    if (channels.isEmpty) {
      return Center(
        child: Text(
          emptyText,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.grey),
        ),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.only(
        bottom: MediaQuery.paddingOf(context).bottom + 8,
      ),
      itemCount: channels.length,
      itemBuilder: (context, i) {
        final ch = channels[i];
        return ListTile(
          leading: CircleAvatar(
            backgroundImage: ch.avatarUrl != null
                ? CachedNetworkImageProvider(
                    ApiConfig.resolveMedia(ch.avatarUrl!),
                  )
                : null,
            child: ch.avatarUrl == null
                ? Text(ch.name?.substring(0, 1).toUpperCase() ?? 'C')
                : null,
          ),
          title: Row(
            children: [
              Flexible(child: Text(ch.name ?? 'Unnamed')),
              if (ch.handle != null)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Text(
                    '@${ch.handle}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
            ],
          ),
          subtitle: ch.description != null ? Text(ch.description!) : null,
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _openChannel(ch),
        );
      },
    );
  }
}

/// Shows the posts feed for a channel and allows admins to post.
class ChannelFeedScreen extends StatefulWidget {
  final Conversation channel;
  const ChannelFeedScreen({super.key, required this.channel});

  @override
  State<ChannelFeedScreen> createState() => _ChannelFeedScreenState();
}

class _ChannelFeedScreenState extends State<ChannelFeedScreen> {
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  List<Message> _posts = [];
  bool _isSubscribed = false;
  bool _isAdmin = false;
  bool _isModerator = false;
  bool _loading = true;
  bool _archived = false;
  bool _showStickers = false;

  // Mutable copy so edits to name/handle/avatar/privacy reflect immediately.
  late Conversation _channel;
  Conversation get channel => _channel;

  @override
  void initState() {
    super.initState();
    _channel = widget.channel;
    _load();
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final api = context.read<ApiService>();
      final storage = context.read<SecureStorageService>();
      final currentUserId = await storage.getUserID() ?? '';

      // Check subscription + admin status
      final members = await api.getConversationMembers(channel.id);
      final me = members.where((m) => m.userId == currentUserId).firstOrNull;
      _isSubscribed = me != null;
      _isAdmin = me?.isAdmin ?? false;
      _isModerator = me?.isModerator ?? false;

      // Load posts
      final posts = await api.getChannelPosts(channel.id);
      final channelWithMembers = channel.copyWith(members: members);
      final privateKey = await storage.getPrivateKey() ?? '';
      for (final p in posts) {
        ChatProvider.hydrateMessageSenderFromConversation(
          p,
          channelWithMembers,
        );
        _tryDecrypt(p, privateKey);
      }
      setState(() {
        _channel = channelWithMembers;
        _posts = posts.reversed.toList();
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  void _tryDecrypt(Message msg, String privateKey) async {
    if (!msg.isEncrypted) {
      msg.setDecryptedContent(msg.encryptedPayload);
      if (mounted) setState(() {});
      return;
    }
    try {
      final raw = await PgpService.decrypt(
        encryptedArmor: msg.encryptedPayload,
        privateKeyArmored: privateKey,
      );
      msg.setDecryptedContent(raw);
      if (mounted) setState(() {});
    } catch (_) {
      msg.markDecryptionFailed();
    }
  }

  Future<void> _subscribe() async {
    try {
      await context.read<ApiService>().subscribeChannel(channel.id);
      setState(() => _isSubscribed = true);
      if (mounted) context.read<ChatProvider>().loadConversations();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Subscribe failed: $e')));
      }
    }
  }

  Future<void> _unsubscribe() async {
    final api = context.read<ApiService>();
    final chat = context.read<ChatProvider>();
    final action = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Unsubscribe'),
        content: Text('Leave ${channel.name}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'leave'),
            child: const Text('Leave'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, 'leave_delete'),
            child: const Text('Leave + delete mine'),
          ),
        ],
      ),
    );
    if (action == null) return;
    if (action == 'leave_delete') {
      await api.deleteOwnChannelMessages(channel.id);
    }
    await api.unsubscribeChannel(channel.id);
    if (!mounted) return;
    setState(() => _isSubscribed = false);
    chat.loadConversations();
  }

  Future<void> _deleteOwnChannelMessages() async {
    final api = context.read<ApiService>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete your posts?'),
        content: const Text(
          'This deletes all messages you sent in this channel.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete mine'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await api.deleteOwnChannelMessages(channel.id);
      if (mounted) await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  Future<void> _showChannelUserActions(Message msg) async {
    final user = msg.sender;
    if (user == null) return;
    final canModerateUser =
        (_isAdmin || _isModerator) &&
        msg.senderId != context.read<AuthProvider>().currentUser?.id;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text('@${user.username}'),
              onTap: () => Navigator.pop(context, 'profile'),
            ),
            if (canModerateUser) ...[
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text(
                  'Delete their messages',
                  style: TextStyle(color: Colors.red),
                ),
                onTap: () => Navigator.pop(context, 'delete_messages'),
              ),
              ListTile(
                leading: const Icon(Icons.block, color: Colors.red),
                title: const Text(
                  'Ban from channel',
                  style: TextStyle(color: Colors.red),
                ),
                onTap: () => Navigator.pop(context, 'ban'),
              ),
            ],
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'profile':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => UserProfileScreen(user: user)),
        );
      case 'delete_messages':
        await _deleteChannelUserMessages(msg.senderId, user.username);
      case 'ban':
        await _banChannelUser(msg.senderId, user.username);
    }
  }

  Future<void> _deleteChannelUserMessages(
    String userID,
    String username,
  ) async {
    final api = context.read<ApiService>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete @$username\'s messages?'),
        content: const Text('This removes all messages this user sent here.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await api.deleteChannelUserMessages(channel.id, userID);
      if (mounted) await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  Future<void> _banChannelUser(String userID, String username) async {
    final api = context.read<ApiService>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Ban @$username?'),
        content: const Text('They will be removed and blocked from rejoining.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Ban'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await api.banChannelUser(channel.id, userID);
      if (mounted) await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Ban failed: $e')));
      }
    }
  }

  Future<void> _archiveChannel() async {
    final api = context.read<ApiService>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Archive Channel?'),
        content: Text(
          'Archive ${channel.name ?? 'this channel'}? '
          'Subscribers will no longer be able to post or receive new messages.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.orange),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Archive'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await api.archiveChannel(channel.id);
      if (!mounted) return;
      setState(() => _archived = true);
      messenger.showSnackBar(const SnackBar(content: Text('Channel archived')));
      navigator.pop();
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Failed to archive: $e')),
        );
      }
    }
  }

  Future<void> _unarchiveChannel() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<ApiService>().unarchiveChannel(channel.id);
      if (!mounted) return;
      setState(() => _archived = false);
      messenger.showSnackBar(
        const SnackBar(content: Text('Channel unarchived')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Failed to unarchive: $e')),
      );
    }
  }

  Future<void> _deleteChannel() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final api = context.read<ApiService>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Channel?'),
        content: Text(
          'Permanently delete ${channel.name ?? 'this channel'} and all its '
          'posts for everyone. This cannot be undone.',
        ),
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
    if (confirmed != true) return;
    try {
      await api.deleteConversation(channel.id);
      navigator.pop();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed to delete: $e')));
    }
  }

  void _showChannelInfo() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(channel.name ?? 'Channel'),
        content: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                CircleAvatar(
                  radius: 40,
                  backgroundImage: channel.avatarUrl != null
                      ? CachedNetworkImageProvider(
                          ApiConfig.resolveMedia(channel.avatarUrl!),
                        )
                      : null,
                  child: channel.avatarUrl == null
                      ? const Icon(Icons.campaign, size: 36)
                      : null,
                ),
                const SizedBox(height: 12),
                Text(
                  channel.name ?? 'Channel',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                if (channel.handle != null)
                  Text(
                    '@${channel.handle}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                const SizedBox(height: 4),
                Text(
                  channel.isPublic ? 'Public channel' : 'Private channel',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (channel.description != null &&
                    channel.description!.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(channel.description!, textAlign: TextAlign.center),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _editChannelSettings() async {
    final nameCtrl = TextEditingController(text: channel.name ?? '');
    final descCtrl = TextEditingController(text: channel.description ?? '');
    final handleCtrl = TextEditingController(text: channel.handle ?? '');
    bool isPublic = channel.isPublic;
    String? pendingAvatarUrl;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: const Text('Channel Settings'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(
                  child: GestureDetector(
                    onTap: () async {
                      final api = context.read<ApiService>();
                      final messenger = ScaffoldMessenger.of(ctx);
                      final picked = await ImagePicker().pickImage(
                        source: ImageSource.gallery,
                        maxWidth: 512,
                        maxHeight: 512,
                        imageQuality: 85,
                      );
                      if (picked == null) return;
                      final bytes = await picked.readAsBytes();
                      try {
                        final url = await api.uploadAvatar(
                          fileBytes: bytes,
                          filename: picked.name,
                        );
                        setDlgState(() => pendingAvatarUrl = url);
                      } catch (e) {
                        messenger.showSnackBar(
                          SnackBar(content: Text('Avatar upload failed: $e')),
                        );
                      }
                    },
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        CircleAvatar(
                          radius: 36,
                          backgroundImage:
                              (pendingAvatarUrl ?? channel.avatarUrl) != null
                              ? CachedNetworkImageProvider(
                                  ApiConfig.resolveMedia(
                                    pendingAvatarUrl ?? channel.avatarUrl!,
                                  ),
                                )
                              : null,
                          child: (pendingAvatarUrl ?? channel.avatarUrl) == null
                              ? const Icon(Icons.campaign, size: 30)
                              : null,
                        ),
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: CircleAvatar(
                            radius: 12,
                            backgroundColor: Theme.of(ctx).colorScheme.primary,
                            child: const Icon(
                              Icons.camera_alt,
                              size: 14,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: descCtrl,
                  decoration: const InputDecoration(labelText: 'Description'),
                  maxLines: 3,
                ),
                const SizedBox(height: 8),
                // Handle is only editable for public channels.
                if (isPublic)
                  TextField(
                    controller: handleCtrl,
                    decoration: const InputDecoration(
                      labelText: '@handle',
                      prefixText: '@',
                      hintText: 'lowercase, letters/numbers/underscores',
                    ),
                  ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Public'),
                  subtitle: const Text(
                    'Private channels lose their @handle and are hidden from search',
                  ),
                  value: isPublic,
                  onChanged: (v) => setDlgState(() => isPublic = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (saved != true || !mounted) return;

    try {
      final api = context.read<ApiService>();
      await api.updateChannel(
        channel.id,
        name: nameCtrl.text.trim().isEmpty ? null : nameCtrl.text.trim(),
        description: descCtrl.text.trim().isEmpty ? null : descCtrl.text.trim(),
        avatarUrl: pendingAvatarUrl,
        isPublic: isPublic,
        // When public, send the (possibly empty) handle so it can be set or
        // cleared. When private, the server clears the handle regardless.
        handle: isPublic ? handleCtrl.text.trim().toLowerCase() : null,
      );
      // Refetch so the header/info reflect the saved state.
      final updated = await api.getChannel(channel.id);
      if (mounted) {
        setState(() => _channel = updated);
        context.read<ChatProvider>().loadConversations();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Channel updated')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to update: $e')));
      }
    }
  }

  Future<void> _setBackground() async {
    final api = context.read<ApiService>();
    final messenger = ScaffoldMessenger.of(context);

    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('Choose background image'),
              onTap: () => Navigator.pop(context, 'pick'),
            ),
            if (channel.backgroundUrl != null)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('Remove background'),
                onTap: () => Navigator.pop(context, 'remove'),
              ),
          ],
        ),
      ),
    );
    if (action == null) return;

    try {
      if (action == 'remove') {
        await api.setChannelBackground(channel.id, null);
      } else {
        final picked = await ImagePicker().pickImage(
          source: ImageSource.gallery,
          imageQuality: 90,
        );
        if (picked == null) return;
        final bytes = await picked.readAsBytes();
        final url = await api.uploadAvatar(
          fileBytes: bytes,
          filename: picked.name,
        );
        await api.setChannelBackground(channel.id, url);
      }
      final updated = await api.getChannel(channel.id);
      if (mounted) {
        setState(() => _channel = updated);
        messenger.showSnackBar(
          const SnackBar(content: Text('Channel background updated')),
        );
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Decoration _channelBackground() {
    final bg = channel.backgroundUrl;
    if (bg != null && bg.isNotEmpty) {
      return BoxDecoration(
        image: DecorationImage(
          image: CachedNetworkImageProvider(ApiConfig.resolveMedia(bg)),
          fit: BoxFit.cover,
        ),
      );
    }
    return const BoxDecoration();
  }

  Future<void> _setDisappearing() async {
    final api = context.read<ApiService>();
    final messenger = ScaffoldMessenger.of(context);
    const options = <(String, int)>[
      ('Off', 0),
      ('1 hour', 3600),
      ('1 day', 86400),
      ('1 week', 604800),
    ];
    final current = channel.messageTtlSeconds;
    final chosen = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Disappearing messages'),
        children: [
          for (final (label, secs) in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, secs),
              child: Row(
                children: [
                  Icon(
                    secs == current
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Text(label),
                ],
              ),
            ),
        ],
      ),
    );
    if (chosen == null || chosen == current) return;
    try {
      await api.setMessageTtl(channel.id, chosen);
      final updated = await api.getChannel(channel.id);
      if (mounted) setState(() => _channel = updated);
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              chosen == 0
                  ? 'Disappearing messages turned off'
                  : 'Messages now disappear after ${options.firstWhere((o) => o.$2 == chosen).$1}',
            ),
          ),
        );
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<void> _setEncryption() async {
    final api = context.read<ApiService>();
    final chat = context.read<ChatProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final nextEnabled = !channel.encryptionEnabled;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          nextEnabled ? 'Turn encryption on?' : 'Turn encryption off?',
        ),
        content: const Text(
          'Changing encryption wipes all current posts in this channel for everyone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Wipe and change'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await api.setEncryptionEnabled(channel.id, nextEnabled);
      final updated = await api.getChannel(channel.id);
      if (mounted) {
        setState(() {
          _channel = updated;
          _posts = const [];
        });
      }
      await chat.loadConversations();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            nextEnabled ? 'Encryption turned on' : 'Encryption turned off',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<void> _showChatAppearance() async {
    final settings = context.read<SettingsProvider>();
    final api = context.read<ApiService>();
    final auth = context.read<AuthProvider>();
    var style = settings.chatStyleFor(channel.id);

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheet) {
          Future<void> apply(ChatStyle next) async {
            style = next;
            await settings.setChatStyle(channel.id, next);
            await api.updateProfile(
              bubbleColor: next.myBubbleColor,
              clearBubbleColor: next.myBubbleColor == null,
            );
            await auth.refreshCurrentUser();
            setSheet(() {});
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Chat appearance',
                        style: Theme.of(sheetCtx).textTheme.titleMedium,
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => apply(const ChatStyle()),
                        child: const Text('Reset'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text('My bubble color'),
                  const SizedBox(height: 8),
                  ColorChoices(
                    selected: style.myBubbleColor,
                    onSelected: (color) => apply(
                      color == null
                          ? style.copyWith(clearMyBubbleColor: true)
                          : style.copyWith(myBubbleColor: color),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _showChannelModerationMenu() async {
    final auth = context.read<AuthProvider>();
    final currentUserId = auth.currentUser?.id ?? '';
    final canManageLifecycle =
        channel.createdBy == currentUserId ||
        (auth.currentUser?.isSystemAdmin ?? false);
    final placement = ChannelActionPolicy.actionsFor(
      channel: channel,
      isAdmin: _isAdmin,
      isPremium: auth.currentUser?.isPremium ?? false,
      canManageLifecycle: canManageLifecycle,
      isSubscribed: _isSubscribed,
    );
    final action = await showModalBottomSheet<ChannelModerationAction>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final item in placement.moderationMenu)
              ListTile(
                leading: Icon(switch (item) {
                  ChannelModerationAction.openModeration =>
                    Icons.shield_outlined,
                  ChannelModerationAction.archive => Icons.archive_outlined,
                  ChannelModerationAction.unarchive => Icons.unarchive_outlined,
                  ChannelModerationAction.delete => Icons.delete_outline,
                }),
                title: Text(switch (item) {
                  ChannelModerationAction.openModeration => 'Moderation',
                  ChannelModerationAction.archive => 'Archive channel',
                  ChannelModerationAction.unarchive => 'Unarchive channel',
                  ChannelModerationAction.delete => 'Delete channel',
                }),
                onTap: () => Navigator.pop(context, item),
              ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case ChannelModerationAction.openModeration:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ModerationScreen(conversation: channel),
          ),
        );
      case ChannelModerationAction.archive:
        _archiveChannel();
      case ChannelModerationAction.unarchive:
        _unarchiveChannel();
      case ChannelModerationAction.delete:
        _deleteChannel();
    }
  }

  Future<void> _showChannelSettingsMenu() async {
    final isPremium =
        context.read<AuthProvider>().currentUser?.isPremium ?? false;
    final placement = ChannelActionPolicy.actionsFor(
      channel: channel,
      isAdmin: _isAdmin,
      isPremium: isPremium,
      canManageLifecycle: false,
      isSubscribed: _isSubscribed,
    );
    final action = await showModalBottomSheet<ChannelSettingsAction>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final item in placement.settingsMenu)
              ListTile(
                leading: Icon(switch (item) {
                  ChannelSettingsAction.appearance =>
                    Icons.format_color_fill_outlined,
                  ChannelSettingsAction.edit => Icons.settings_outlined,
                  ChannelSettingsAction.background => Icons.wallpaper_outlined,
                  ChannelSettingsAction.autoDelete => Icons.timer_outlined,
                  ChannelSettingsAction.encryption =>
                    channel.encryptionEnabled
                        ? Icons.lock_outline
                        : Icons.lock_open_outlined,
                  ChannelSettingsAction.deleteOwnMessages =>
                    Icons.delete_sweep_outlined,
                }),
                title: Text(switch (item) {
                  ChannelSettingsAction.appearance => 'Chat appearance',
                  ChannelSettingsAction.edit => 'Channel settings',
                  ChannelSettingsAction.background =>
                    'Set chat background (Premium)',
                  ChannelSettingsAction.autoDelete => 'Disappearing messages',
                  ChannelSettingsAction.encryption =>
                    channel.encryptionEnabled
                        ? 'Turn encryption off'
                        : 'Turn encryption on',
                  ChannelSettingsAction.deleteOwnMessages =>
                    'Delete my messages',
                }),
                onTap: () => Navigator.pop(context, item),
              ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case ChannelSettingsAction.appearance:
        _showChatAppearance();
      case ChannelSettingsAction.edit:
        _editChannelSettings();
      case ChannelSettingsAction.background:
        _setBackground();
      case ChannelSettingsAction.autoDelete:
        _setDisappearing();
      case ChannelSettingsAction.encryption:
        _setEncryption();
      case ChannelSettingsAction.deleteOwnMessages:
        _deleteOwnChannelMessages();
    }
  }

  Future<void> _post({
    String? plaintextOverride,
    String messageType = 'text',
    String? attachmentId,
  }) async {
    final text = plaintextOverride ?? _inputCtrl.text.trim();
    if (text.isEmpty) return;
    if (plaintextOverride == null) _inputCtrl.clear();
    setState(() => _showStickers = false);

    final api = context.read<ApiService>();
    final storage = context.read<SecureStorageService>();
    final privateKey = await storage.getPrivateKey() ?? '';

    final String encrypted;
    final String sig;
    if (channel.encryptionEnabled) {
      final members = await api.getConversationMembers(channel.id);
      final fetchedKeys = await Future.wait(
        members.map((m) => api.getFreshUserPublicKey(m.userId)),
      );
      final recipientKeys = [
        for (final k in fetchedKeys)
          if (k != null) k,
      ];

      if (privateKey.isEmpty || recipientKeys.isEmpty) return;

      encrypted = await PgpService.encrypt(
        plaintext: text,
        recipientPublicKeys: recipientKeys,
        signingPrivateKeyArmored: privateKey,
      );
      sig = await PgpService.sign(
        data: '${channel.id}:$encrypted',
        privateKeyArmored: privateKey,
      );
    } else {
      encrypted = text;
      sig = '';
    }

    final msg = await api.postToChannel(
      chanID: channel.id,
      encryptedPayload: encrypted,
      signature: sig,
      messageType: messageType,
      attachmentId: attachmentId,
    );
    msg.setDecryptedContent(text);
    setState(() => _posts.add(msg));
  }

  Future<void> _sendSticker(String stickerID) async {
    await _post(plaintextOverride: stickerID, messageType: 'sticker');
  }

  Future<void> _showAttachmentPicker() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Photo from gallery'),
              onTap: () => Navigator.pop(context, 'gallery_image'),
            ),
            ListTile(
              leading: const Icon(Icons.videocam),
              title: const Text('Video from gallery'),
              onTap: () => Navigator.pop(context, 'gallery_video'),
            ),
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: const Text('File'),
              onTap: () => Navigator.pop(context, 'file'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;

    final attachmentService = AttachmentService(context.read<ApiService>());
    PendingAttachment? pending;
    try {
      pending = switch (choice) {
        'gallery_image' => await attachmentService.pickImage(),
        'gallery_video' => await attachmentService.pickVideo(),
        'file' => await attachmentService.pickFile(),
        _ => null,
      };
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Upload failed: $e')));
      return;
    }
    if (pending == null) return;

    await _post(
      plaintextOverride: jsonEncode(pending.toPayloadJson()),
      messageType: pending.messageType.name,
      attachmentId: pending.attachmentId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final currentUserId = auth.currentUser?.id ?? '';
    final isSystemAdmin = auth.currentUser?.isSystemAdmin ?? false;
    final isPremium = auth.currentUser?.isPremium ?? false;
    // Archiving/unarchiving/deleting a channel is owner-only (or system admin),
    // matching the server. Ordinary admins can't.
    final isOwner = channel.createdBy == currentUserId;
    final canManageLifecycle = isOwner || isSystemAdmin;
    final isArchived = _archived || channel.isArchived;
    final chatStyle = context.watch<SettingsProvider>().chatStyleFor(
      channel.id,
    );
    final meBubbleColor = chatStyle.myBubbleColor != null
        ? Color(chatStyle.myBubbleColor!)
        : auth.currentUser?.bubbleColor != null
        ? Color(auth.currentUser!.bubbleColor!)
        : null;
    final callTopInset = context.select<CallProvider, double>(
      (cp) => cp.minimizedContentTopInset,
    );
    final actionPlacement = ChannelActionPolicy.actionsFor(
      channel: channel,
      isAdmin: _isAdmin,
      isPremium: isPremium,
      canManageLifecycle: canManageLifecycle,
      isSubscribed: _isSubscribed,
    );

    return Scaffold(
      appBar: GlassAppBar(
        titleSpacing: 0,
        title: InkWell(
          onTap: _showChannelInfo,
          child: Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundImage: channel.avatarUrl != null
                    ? CachedNetworkImageProvider(
                        ApiConfig.resolveMedia(channel.avatarUrl!),
                      )
                    : null,
                child: channel.avatarUrl == null
                    ? const Icon(Icons.campaign, size: 18)
                    : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      channel.name ?? 'Channel',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    ConversationEncryptionStatus(conversation: channel),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (actionPlacement.topBar.contains(ChannelTopBarAction.moderation))
            IconButton(
              icon: const Icon(Icons.shield_outlined),
              tooltip: 'Channel moderation',
              onPressed: _showChannelModerationMenu,
            ),
          if (actionPlacement.topBar.contains(ChannelTopBarAction.settings))
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Channel settings',
              onPressed: _showChannelSettingsMenu,
            ),
          if (actionPlacement.topBar.contains(ChannelTopBarAction.unsubscribe))
            IconButton(
              icon: const Icon(Icons.notifications_off_outlined),
              tooltip: 'Unsubscribe',
              onPressed: _unsubscribe,
            )
          else if (actionPlacement.topBar.contains(
                ChannelTopBarAction.subscribe,
              ) &&
              !isArchived)
            TextButton(onPressed: _subscribe, child: const Text('Subscribe')),
        ],
      ),
      body: Column(
        children: [
          if (callTopInset > 0) SizedBox(height: callTopInset),
          if (_archived || channel.isArchived)
            Container(
              width: double.infinity,
              color: Colors.grey[700],
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: const Row(
                children: [
                  Icon(Icons.archive, color: Colors.white70, size: 16),
                  SizedBox(width: 8),
                  Text(
                    'This channel has been archived and is read-only.',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ),
          Expanded(
            child: DecoratedBox(
              decoration: _channelBackground(),
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _posts.isEmpty
                  ? const Center(child: Text('No posts yet'))
                  : ListView.builder(
                      controller: _scrollCtrl,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                      itemCount: _posts.length,
                      itemBuilder: (context, i) {
                        final msg = _posts[i];
                        final isMe = msg.senderId == currentUserId;
                        final showAvatar =
                            !isMe &&
                            (i == _posts.length - 1 ||
                                _posts[i + 1].senderId != msg.senderId);
                        return _AnimatedChannelPost(
                          id: msg.id,
                          child: MessageBubble(
                            message: msg,
                            isMe: isMe,
                            showAvatar: showAvatar,
                            meBubbleColor: meBubbleColor,
                            onAvatarTap: msg.sender != null
                                ? () => _showChannelUserActions(msg)
                                : null,
                          ),
                        );
                      },
                    ),
            ),
          ),

          if (_showStickers) StickerPicker(onStickerSelected: _sendSticker),
          // Admins can always post. When admin-only posting is OFF, any
          // subscriber can post too. Archived channels are read-only.
          if ((_isAdmin || (!channel.ownerOnlyPost && _isSubscribed)) &&
              !_archived &&
              !channel.isArchived)
            ChannelPostBar(
              controller: _inputCtrl,
              showStickers: _showStickers,
              onToggleStickers: () =>
                  setState(() => _showStickers = !_showStickers),
              onAttach: _showAttachmentPicker,
              onPost: _post,
            ),
        ],
      ),
    );
  }
}

class _AnimatedChannelPost extends StatelessWidget {
  final String id;
  final Widget child;

  const _AnimatedChannelPost({required this.id, required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      key: ValueKey(id),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 10 * (1 - value)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

class ChannelPostBar extends StatelessWidget {
  final TextEditingController controller;
  final bool showStickers;
  final VoidCallback onToggleStickers;
  final VoidCallback onAttach;
  final VoidCallback onPost;

  const ChannelPostBar({
    super.key,
    required this.controller,
    required this.showStickers,
    required this.onToggleStickers,
    required this.onAttach,
    required this.onPost,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassSurface(
      blur: 24,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      border: Border(
        top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            IconButton(
              icon: Icon(
                showStickers ? Icons.keyboard : Icons.emoji_emotions_outlined,
              ),
              tooltip: showStickers ? 'Keyboard' : 'Stickers',
              onPressed: onToggleStickers,
            ),
            Expanded(
              child: TextField(
                controller: controller,
                maxLines: null,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onPost(),
                decoration: InputDecoration(
                  hintText: 'Write a post…',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: scheme.surfaceContainerHighest.withValues(
                    alpha: 0.45,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.attach_file_outlined),
              tooltip: 'Attach file',
              onPressed: onAttach,
            ),
            FilledButton(
              onPressed: onPost,
              style: FilledButton.styleFrom(
                shape: const CircleBorder(),
                padding: const EdgeInsets.all(12),
                minimumSize: Size.zero,
              ),
              child: const Icon(Icons.send, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}
