import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../../config/api_config.dart';
import '../../models/conversation.dart';
import '../../models/message.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/api_service.dart';
import '../../services/attachment_service.dart';
import '../../services/secure_storage_service.dart';
import '../../crypto/pgp_service.dart';
import '../../utils/custom_emoji_payload.dart';
import '../../utils/disappearing_message_duration.dart';
import '../../widgets/conversation_encryption_status.dart';
import '../../widgets/color_choices.dart';
import '../../widgets/custom_emoji_picker.dart';
import '../../widgets/custom_emoji_text_controller.dart';
import '../../widgets/disappearing_messages_picker.dart';
import '../../widgets/glass.dart';
import '../../widgets/message_bubble.dart';
import '../../widgets/sticker_picker.dart';
import '../../widgets/voice_note_recorder.dart';
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
      builder: (ctx, setDlgState) => GlassAlertDialog(
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
    return Scaffold(
      appBar: GlassAppBar(
        title: const Text('Channels'),
        actions: [
          IconButton(icon: const Icon(Icons.add), onPressed: _createChannel),
        ],
      ),
      body: Column(
        children: [
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
    final scheme = Theme.of(context).colorScheme;
    if (channels.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: GlassContainer(
            shape: LiquidRoundedSuperellipse(borderRadius: 999),
            allowElevation: true,
            glowIntensity: 0.05,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: Text(
                emptyText,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: scheme.onSurface.withValues(alpha: 0.55),
                  fontSize: 14,
                ),
              ),
            ),
          ),
        ),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(
        12,
        8,
        12,
        MediaQuery.paddingOf(context).bottom + 8,
      ),
      itemCount: channels.length,
      itemBuilder: (context, i) {
        final ch = channels[i];
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: GlassCard(
            padding: EdgeInsets.zero,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(22),
                onTap: () => _openChannel(ch),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: scheme.primary.withValues(alpha: 0.20),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: CircleAvatar(
                          radius: 24,
                          backgroundImage: ch.avatarUrl != null
                              ? CachedNetworkImageProvider(
                                  ApiConfig.resolveMedia(ch.avatarUrl!),
                                )
                              : null,
                          child: ch.avatarUrl == null
                              ? Text(
                                  ch.name?.substring(0, 1).toUpperCase() ?? 'C',
                                )
                              : null,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    ch.name ?? 'Unnamed',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 15,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (ch.handle != null)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 6),
                                    child: Text(
                                      '@${ch.handle}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: scheme.primary,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            if (ch.description != null)
                              Text(
                                ch.description!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: scheme.onSurface.withValues(
                                    alpha: 0.55,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.arrow_forward_ios_rounded,
                        size: 14,
                        color: scheme.onSurface.withValues(alpha: 0.35),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
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
  final _inputCtrl = CustomEmojiTextEditingController();
  final _scrollCtrl = ScrollController();
  List<Message> _posts = [];
  bool _isSubscribed = false;
  bool _isAdmin = false;
  bool _isModerator = false;
  bool _loading = true;
  bool _archived = false;
  bool _showStickers = false;
  bool _showCustomEmojis = false;
  bool _sendSilent = false;
  DateTime? _scheduledFor;
  List<CustomEmojiEntity> _customEmojiEntities = [];
  String _lastInputText = '';
  bool _suppressInputEntityShift = false;

  // Mutable copy so edits to name/handle/avatar/privacy reflect immediately.
  late Conversation _channel;
  Conversation get channel => _channel;

  @override
  void initState() {
    super.initState();
    _channel = widget.channel;
    _inputCtrl.addListener(_onInputTextChanged);
    _load();
  }

  void _onInputTextChanged() {
    if (_suppressInputEntityShift) return;
    final text = _inputCtrl.text;
    final shifted = shiftCustomEmojiEntitiesForTextEdit(
      oldText: _lastInputText,
      newText: text,
      entities: _customEmojiEntities,
    );
    _syncCustomEmojiEntities(shifted);
    _lastInputText = text;
  }

  void _syncCustomEmojiEntities(List<CustomEmojiEntity> entities) {
    _customEmojiEntities = entities;
    _suppressInputEntityShift = true;
    _inputCtrl.setCustomEmojiEntities(entities);
    _suppressInputEntityShift = false;
  }

  @override
  void dispose() {
    _inputCtrl.removeListener(_onInputTextChanged);
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
      final result = await context.read<ApiService>().subscribeChannel(
        channel.id,
      );
      if (result['join_request'] == 'pending') {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Join request sent')));
        }
        return;
      }
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
      builder: (_) => GlassAlertDialog(
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
      builder: (_) => GlassAlertDialog(
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
      backgroundColor: Colors.transparent,
      builder: (_) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          child: GlassContainer(
            shape: LiquidRoundedSuperellipse(borderRadius: 28),
            allowElevation: true,
            glowIntensity: 0.06,
            padding: EdgeInsets.zero,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8),
                _ChanTile(
                  icon: Icons.person_outline_rounded,
                  label: '@${user.username}',
                  onTap: () => Navigator.pop(context, 'profile'),
                ),
                if (canModerateUser) ...[
                  _ChanTile(
                    icon: Icons.delete_sweep_outlined,
                    label: 'Delete their messages',
                    color: Colors.red,
                    onTap: () => Navigator.pop(context, 'delete_messages'),
                  ),
                  _ChanTile(
                    icon: Icons.block_rounded,
                    label: 'Ban from channel',
                    color: Colors.red,
                    onTap: () => Navigator.pop(context, 'ban'),
                  ),
                ],
                const SizedBox(height: 8),
              ],
            ),
          ),
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
      builder: (_) => GlassAlertDialog(
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
      builder: (_) => GlassAlertDialog(
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
      builder: (_) => GlassAlertDialog(
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
      builder: (ctx) => GlassAlertDialog(
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
      builder: (ctx) => GlassAlertDialog(
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
        builder: (ctx, setDlgState) => GlassAlertDialog(
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
      backgroundColor: Colors.transparent,
      builder: (_) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          child: GlassContainer(
            shape: LiquidRoundedSuperellipse(borderRadius: 28),
            allowElevation: true,
            glowIntensity: 0.06,
            padding: EdgeInsets.zero,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8),
                _ChanTile(
                  icon: Icons.image_outlined,
                  label: 'Choose background image',
                  onTap: () => Navigator.pop(context, 'pick'),
                ),
                if (channel.backgroundUrl != null)
                  _ChanTile(
                    icon: Icons.delete_outline_rounded,
                    label: 'Remove background',
                    color: Colors.red,
                    onTap: () => Navigator.pop(context, 'remove'),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
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
    final current = channel.messageTtlSeconds;
    final chosen = await showDisappearingMessagesPickerDialog(
      context,
      initialSeconds: current,
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
                  : 'Messages now disappear after ${disappearingMessageDurationLabel(chosen)}',
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
      builder: (ctx) => GlassAlertDialog(
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
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.18),
      elevation: 0,
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

          final bottomInset = MediaQuery.of(sheetCtx).viewInsets.bottom;
          return SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(14, 0, 14, 14 + bottomInset),
              child: GlassContainer(
                shape: LiquidRoundedSuperellipse(borderRadius: 28),
                allowElevation: true,
                glowIntensity: 0.06,
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
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
      backgroundColor: Colors.transparent,
      builder: (_) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          child: GlassContainer(
            shape: LiquidRoundedSuperellipse(borderRadius: 28),
            allowElevation: true,
            glowIntensity: 0.06,
            padding: EdgeInsets.zero,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8),
                for (final item in placement.moderationMenu)
                  _ChanTile(
                    icon: switch (item) {
                      ChannelModerationAction.openModeration =>
                        Icons.shield_outlined,
                      ChannelModerationAction.archive => Icons.archive_outlined,
                      ChannelModerationAction.unarchive =>
                        Icons.unarchive_outlined,
                      ChannelModerationAction.delete => Icons.delete_outline,
                    },
                    label: switch (item) {
                      ChannelModerationAction.openModeration => 'Moderation',
                      ChannelModerationAction.archive => 'Archive channel',
                      ChannelModerationAction.unarchive => 'Unarchive channel',
                      ChannelModerationAction.delete => 'Delete channel',
                    },
                    color: item == ChannelModerationAction.delete
                        ? Colors.red
                        : null,
                    onTap: () => Navigator.pop(context, item),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
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
      backgroundColor: Colors.transparent,
      builder: (_) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          child: GlassContainer(
            shape: LiquidRoundedSuperellipse(borderRadius: 28),
            allowElevation: true,
            glowIntensity: 0.06,
            padding: EdgeInsets.zero,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8),
                for (final item in placement.settingsMenu)
                  _ChanTile(
                    icon: switch (item) {
                      ChannelSettingsAction.appearance =>
                        Icons.format_color_fill_outlined,
                      ChannelSettingsAction.edit => Icons.settings_outlined,
                      ChannelSettingsAction.background =>
                        Icons.wallpaper_outlined,
                      ChannelSettingsAction.autoDelete => Icons.timer_outlined,
                      ChannelSettingsAction.encryption =>
                        channel.encryptionEnabled
                            ? Icons.lock_outline_rounded
                            : Icons.lock_open_outlined,
                      ChannelSettingsAction.deleteOwnMessages =>
                        Icons.delete_sweep_outlined,
                    },
                    label: switch (item) {
                      ChannelSettingsAction.appearance => 'Chat appearance',
                      ChannelSettingsAction.edit => 'Channel settings',
                      ChannelSettingsAction.background =>
                        'Set chat background (Premium)',
                      ChannelSettingsAction.autoDelete =>
                        'Disappearing messages',
                      ChannelSettingsAction.encryption =>
                        channel.encryptionEnabled
                            ? 'Turn encryption off'
                            : 'Turn encryption on',
                      ChannelSettingsAction.deleteOwnMessages =>
                        'Delete my messages',
                    },
                    color: item == ChannelSettingsAction.deleteOwnMessages
                        ? Colors.red
                        : null,
                    onTap: () => Navigator.pop(context, item),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
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
    final rawText = _inputCtrl.text;
    final draftEntities = [..._customEmojiEntities];
    final draft = plaintextOverride == null && messageType == 'text'
        ? buildCustomEmojiTextPayload(_inputCtrl.text, _customEmojiEntities)
        : CustomEmojiTextPayload(
            text: (plaintextOverride ?? '').trim(),
            payload: (plaintextOverride ?? '').trim(),
            entities: const [],
          );
    if (draft.text.isEmpty) return;
    if (plaintextOverride == null) {
      _setComposerValue(
        const TextEditingValue(
          text: '',
          selection: TextSelection.collapsed(offset: 0),
        ),
      );
      _syncCustomEmojiEntities(const []);
    }
    setState(() {
      _showStickers = false;
      _showCustomEmojis = false;
    });

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
      final recipientKeys = [for (final k in fetchedKeys) ?k];

      if (privateKey.isEmpty || recipientKeys.isEmpty) {
        if (plaintextOverride == null) {
          _restoreComposer(rawText, draftEntities);
        }
        return;
      }

      encrypted = await PgpService.encrypt(
        plaintext: draft.payload,
        recipientPublicKeys: recipientKeys,
        signingPrivateKeyArmored: privateKey,
      );
      sig = await PgpService.sign(
        data: '${channel.id}:$encrypted',
        privateKeyArmored: privateKey,
      );
    } else {
      encrypted = draft.payload;
      sig = '';
    }

    final msg = await api.postToChannel(
      chanID: channel.id,
      encryptedPayload: encrypted,
      signature: sig,
      messageType: messageType,
      attachmentId: attachmentId,
      silent: _sendSilent,
      scheduledFor: _scheduledFor,
    );
    msg.setDecryptedContent(draft.payload);
    if (_scheduledFor == null) {
      setState(() => _posts.add(msg));
    } else if (mounted) {
      final scheduledFor = _scheduledFor;
      setState(() => _scheduledFor = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Scheduled for ${_formatSchedule(scheduledFor)}'),
        ),
      );
    }
  }

  String _formatSchedule(DateTime? when) {
    if (when == null) return '';
    final local = when.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '${local.month}/${local.day} $h:$m';
  }

  Future<void> _showSendOptions() async {
    final minimumSchedule = DateTime.now().add(const Duration(minutes: 1));
    var draftSchedule =
        _scheduledFor != null && _scheduledFor!.isAfter(minimumSchedule)
        ? _scheduledFor!
        : minimumSchedule;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: GlassContainer(
              shape: LiquidRoundedSuperellipse(borderRadius: 28),
              allowElevation: true,
              glowIntensity: 0.06,
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Drag handle
                  Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.30),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.notifications_off_outlined),
                    title: const Text('Post silently'),
                    value: _sendSilent,
                    onChanged: (v) {
                      setState(() => _sendSilent = v);
                      setSheetState(() {});
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                    child: Row(
                      children: [
                        const Icon(Icons.schedule_outlined),
                        const SizedBox(width: 12),
                        Text(
                          'Schedule delivery',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    height: 216,
                    child: CupertinoDatePicker(
                      mode: CupertinoDatePickerMode.dateAndTime,
                      minimumDate: minimumSchedule,
                      initialDateTime: draftSchedule,
                      minuteInterval: 1,
                      onDateTimeChanged: (value) =>
                          setSheetState(() => draftSchedule = value),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                    child: Row(
                      children: [
                        if (_scheduledFor != null)
                          TextButton.icon(
                            icon: const Icon(Icons.event_busy_outlined),
                            label: const Text('Clear'),
                            onPressed: () {
                              setState(() => _scheduledFor = null);
                              Navigator.pop(ctx);
                            },
                          ),
                        const Spacer(),
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Done'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.icon(
                          icon: const Icon(Icons.schedule_send_outlined),
                          label: const Text('Set'),
                          onPressed: () {
                            setState(() => _scheduledFor = draftSchedule);
                            Navigator.pop(ctx);
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showReactionMenu(Message msg) {
    if (msg.type == MessageType.system) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          child: GlassContainer(
            shape: LiquidRoundedSuperellipse(borderRadius: 28),
            allowElevation: true,
            glowIntensity: 0.06,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 10,
              children: [
                for (final emoji in const ['👍', '❤️', '😂', '🔥', '🎉', '👀'])
                  InkWell(
                    borderRadius: BorderRadius.circular(22),
                    onTap: () {
                      Navigator.pop(ctx);
                      _toggleReaction(msg, emoji);
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(emoji, style: const TextStyle(fontSize: 26)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showPostMenu(Message msg, bool isMe) {
    final isSystem = msg.type == MessageType.system;
    final canDelete = isMe || _isAdmin;
    showDialog<void>(
      context: context,
      builder: (ctx) => GlassSimpleDialog(
        children: [
          if (!isSystem && msg.isDecrypted)
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy text'),
              onTap: () {
                Clipboard.setData(
                  ClipboardData(text: msg.decryptedContent ?? ''),
                );
                Navigator.pop(ctx);
              },
            ),
          if (canDelete)
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Delete', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(ctx);
                _deletePost(msg);
              },
            ),
        ],
      ),
    );
  }

  Future<void> _toggleReaction(Message msg, String emoji) async {
    final messenger = ScaffoldMessenger.of(context);
    final alreadyReacted = msg.reactions.any(
      (reaction) => reaction.emoji == emoji && reaction.reactedByMe,
    );
    _setLocalReaction(msg.id, emoji, !alreadyReacted);
    try {
      final api = context.read<ApiService>();
      if (alreadyReacted) {
        await api.removeReaction(msg.id, emoji);
      } else {
        await api.reactToMessage(msg.id, emoji);
      }
    } catch (e) {
      _setLocalReaction(msg.id, emoji, alreadyReacted);
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('Reaction failed: $e')));
      }
    }
  }

  void _setLocalReaction(String msgID, String emoji, bool reacted) {
    final idx = _posts.indexWhere((post) => post.id == msgID);
    if (idx == -1) return;
    final reactions = List<MessageReactionSummary>.from(_posts[idx].reactions);
    final reactionIdx = reactions.indexWhere(
      (reaction) => reaction.emoji == emoji,
    );
    if (reacted) {
      if (reactionIdx == -1) {
        reactions.add(
          MessageReactionSummary(emoji: emoji, count: 1, reactedByMe: true),
        );
      } else {
        final current = reactions[reactionIdx];
        reactions[reactionIdx] = current.copyWith(
          count: current.reactedByMe ? current.count : current.count + 1,
          reactedByMe: true,
        );
      }
    } else if (reactionIdx != -1) {
      final current = reactions[reactionIdx];
      final count = current.reactedByMe ? current.count - 1 : current.count;
      if (count <= 0) {
        reactions.removeAt(reactionIdx);
      } else {
        reactions[reactionIdx] = current.copyWith(
          count: count,
          reactedByMe: false,
        );
      }
    }
    reactions.sort((a, b) {
      final count = b.count.compareTo(a.count);
      if (count != 0) return count;
      return a.emoji.compareTo(b.emoji);
    });
    if (!mounted) return;
    setState(() {
      _posts[idx] = _posts[idx].copyWith(reactions: reactions);
    });
  }

  Future<void> _deletePost(Message msg) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<ApiService>().deleteMessage(channel.id, msg.id);
      if (mounted) setState(() => _posts.removeWhere((p) => p.id == msg.id));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Delete failed: $e')));
    }
  }

  Future<void> _sendSticker(String stickerID) async {
    await _post(plaintextOverride: stickerID, messageType: 'sticker');
  }

  void _insertCustomEmoji(Map<String, dynamic> emojiData) {
    final id = emojiData['id'] as String? ?? '';
    if (id.isEmpty) return;
    final rawEmoji = (emojiData['emoji'] as String? ?? '🙂').trim();
    final emoji = rawEmoji.isEmpty ? '🙂' : rawEmoji;
    final oldText = _inputCtrl.text;
    final selection = _inputCtrl.selection;
    final start = selection.isValid
        ? math
              .min(selection.start, selection.end)
              .clamp(0, oldText.length)
              .toInt()
        : oldText.length;
    final end = selection.isValid
        ? math
              .max(selection.start, selection.end)
              .clamp(0, oldText.length)
              .toInt()
        : oldText.length;
    final newText = oldText.replaceRange(start, end, emoji);
    final shifted = shiftCustomEmojiEntitiesForTextEdit(
      oldText: oldText,
      newText: newText,
      entities: _customEmojiEntities,
    );
    final entity = CustomEmojiEntity(
      offset: start,
      length: emoji.length,
      customEmojiId: id,
      emoji: emoji,
      fileUrl: emojiData['file_url'] as String?,
      isAnimated: emojiData['is_animated'] as bool? ?? false,
    );
    final nextEntities = [...shifted, entity];
    setState(() => _syncCustomEmojiEntities(nextEntities));
    _setComposerValue(
      TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: start + emoji.length),
      ),
    );
  }

  void _setComposerValue(TextEditingValue value) {
    _suppressInputEntityShift = true;
    _inputCtrl.value = value;
    _lastInputText = value.text;
    _suppressInputEntityShift = false;
  }

  void _restoreComposer(String text, List<CustomEmojiEntity> entities) {
    _setComposerValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ),
    );
    setState(() => _syncCustomEmojiEntities(entities));
  }

  Future<void> _showAttachmentPicker() async {
    final cameraSupported =
        kIsWeb ||
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;

    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          child: GlassContainer(
            shape: LiquidRoundedSuperellipse(borderRadius: 28),
            allowElevation: true,
            glowIntensity: 0.06,
            padding: EdgeInsets.zero,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8),
                _ChanTile(
                  icon: Icons.photo_library_outlined,
                  label: 'Photo from gallery',
                  onTap: () => Navigator.pop(context, 'gallery_image'),
                ),
                if (cameraSupported)
                  _ChanTile(
                    icon: Icons.camera_alt_outlined,
                    label: 'Take photo',
                    onTap: () => Navigator.pop(context, 'camera_image'),
                  ),
                _ChanTile(
                  icon: Icons.videocam_outlined,
                  label: 'Video from gallery',
                  onTap: () => Navigator.pop(context, 'gallery_video'),
                ),
                _ChanTile(
                  icon: Icons.attach_file,
                  label: 'File',
                  onTap: () => Navigator.pop(context, 'file'),
                ),
                _ChanTile(
                  icon: Icons.poll_outlined,
                  label: 'Poll',
                  onTap: () => Navigator.pop(context, 'poll'),
                ),
                _ChanTile(
                  icon: Icons.mic_none_outlined,
                  label: 'Voice note',
                  onTap: () => Navigator.pop(context, 'voice'),
                ),
                _ChanTile(
                  icon: Icons.share_location_outlined,
                  label: 'Share location',
                  onTap: () => Navigator.pop(context, 'location_once'),
                ),
                _ChanTile(
                  icon: Icons.location_on_outlined,
                  label: 'Share live location',
                  onTap: () => Navigator.pop(context, 'location_live'),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
    if (choice == null || !mounted) return;

    // Non-attachment actions handled separately.
    if (choice == 'poll') {
      await _showCreatePollDialog();
      return;
    }
    if (choice == 'location_once') {
      await _shareOneTimeLocation();
      return;
    }
    if (choice == 'location_live') {
      await _shareLiveLocation();
      return;
    }


    final attachmentService = AttachmentService(context.read<ApiService>());
    PendingAttachment? pending;
    VoiceNoteRecording? voiceNote;
    try {
      pending = switch (choice) {
        'gallery_image' => await attachmentService.pickImage(),
        'camera_image' => await attachmentService.pickImage(fromCamera: true),
        'gallery_video' => await attachmentService.pickVideo(),
        'file' => await attachmentService.pickFile(),
        'voice' => await (() async {
          voiceNote = await showVoiceNoteRecorder(context);
          final note = voiceNote;
          if (note == null) return null;
          return attachmentService.uploadVoiceNote(
            note.file,
            duration: note.duration,
          );
        })(),
        _ => null,
      };
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Upload failed: $e')));
      return;
    } finally {
      final file = voiceNote?.file;
      if (file != null) {
        try {
          await file.delete();
        } catch (_) {}
      }
    }
    if (pending == null) return;

    await _post(
      plaintextOverride: jsonEncode(pending.toPayloadJson()),
      messageType: pending.messageType.name,
      attachmentId: pending.attachmentId,
    );
  }

  Future<void> _showCreatePollDialog() async {
    final questionCtrl = TextEditingController();
    final optionCtrls = [TextEditingController(), TextEditingController()];
    var anonymous = true;
    var multiple = false;
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogCtx) => StatefulBuilder(
          builder: (dialogCtx, setDialog) {
            Future<void> submit() async {
              final question = questionCtrl.text.trim();
              final options = optionCtrls
                  .map((c) => c.text.trim())
                  .where((t) => t.isNotEmpty)
                  .toList();
              if (question.isEmpty || options.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Question and option required')),
                );
                return;
              }
              Navigator.pop(dialogCtx);
              try {
                await context.read<ChatProvider>().sendPoll(
                  convID: channel.id,
                  question: question,
                  options: options,
                  isAnonymous: anonymous,
                  allowsMultipleAnswers: multiple,
                );
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(e.toString())));
              }
            }

            return GlassAlertDialog(
              title: const Text('New poll'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: questionCtrl,
                      decoration:
                          const InputDecoration(labelText: 'Question'),
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 12),
                    for (var i = 0; i < optionCtrls.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: TextField(
                          controller: optionCtrls[i],
                          decoration:
                              InputDecoration(labelText: 'Option ${i + 1}'),
                          textInputAction: TextInputAction.next,
                        ),
                      ),
                    Row(
                      children: [
                        TextButton.icon(
                          icon: const Icon(Icons.add),
                          label: const Text('Option'),
                          onPressed: optionCtrls.length >= 10
                              ? null
                              : () => setDialog(
                                    () => optionCtrls
                                        .add(TextEditingController()),
                                  ),
                        ),
                        const Spacer(),
                        if (optionCtrls.length > 1)
                          IconButton(
                            tooltip: 'Remove option',
                            icon: const Icon(Icons.remove_circle_outline),
                            onPressed: () => setDialog(
                              () => optionCtrls.removeLast().dispose(),
                            ),
                          ),
                      ],
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Anonymous'),
                      value: anonymous,
                      onChanged: (v) => setDialog(() => anonymous = v),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Multiple answers'),
                      value: multiple,
                      onChanged: (v) => setDialog(() => multiple = v),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogCtx),
                  child: const Text('Cancel'),
                ),
                FilledButton(onPressed: submit, child: const Text('Post')),
              ],
            );
          },
        ),
      );
    } finally {
      questionCtrl.dispose();
      for (final ctrl in optionCtrls) {
        ctrl.dispose();
      }
    }
  }

  Future<void> _shareOneTimeLocation() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<ChatProvider>().sendOneTimeLocation(
        convID: channel.id,
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _shareLiveLocation() async {
    final messenger = ScaffoldMessenger.of(context);
    final duration = await _selectLiveLocationDuration();
    if (duration == null || !mounted) return;
    try {
      await context.read<ChatProvider>().sendLiveLocation(
        convID: channel.id,
        duration: duration,
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<Duration?> _selectLiveLocationDuration() {
    const options = <(String, Duration)>[
      ('15 minutes', Duration(minutes: 15)),
      ('30 minutes', Duration(minutes: 30)),
      ('1 hour', Duration(hours: 1)),
      ('2 hours', Duration(hours: 2)),
      ('8 hours', Duration(hours: 8)),
      ('1 day', Duration(days: 1)),
    ];
    return showDialog<Duration>(
      context: context,
      builder: (ctx) => GlassSimpleDialog(
        title: const Text('Live location duration'),
        children: [
          for (final option in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, option.$2),
              child: Text(option.$1),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Cancel'),
          ),
        ],
      ),
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
          if (_archived || channel.isArchived)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.16),
                    width: 0.7,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.archive_outlined,
                      size: 15,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.55),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'This channel has been archived and is read-only.',
                        style: TextStyle(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.60),
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: DecoratedBox(
              decoration: _channelBackground(),
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _posts.isEmpty
                  ? Center(
                      child: GlassContainer(
                        shape: LiquidRoundedSuperellipse(borderRadius: 999),
                        allowElevation: true,
                        glowIntensity: 0.05,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                          child: Text(
                            'No posts yet',
                            style: TextStyle(
                              fontSize: 14,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurface.withValues(alpha: 0.55),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    )
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
                            onTap: () => _showReactionMenu(msg),
                            onReactionTap: (emoji) =>
                                _toggleReaction(msg, emoji),
                            onLongPress: () => _showPostMenu(msg, isMe),
                            onAvatarTap: msg.sender != null
                                ? () => _showChannelUserActions(msg)
                                : null,
                          ),
                        );
                      },
                    ),
            ),
          ),

          if (_showCustomEmojis)
            CustomEmojiPicker(onEmojiSelected: _insertCustomEmoji),
          if (_showStickers) StickerPicker(onStickerSelected: _sendSticker),
          // Admins can always post. When admin-only posting is OFF, any
          // subscriber can post too. Archived channels are read-only.
          if ((_isAdmin || (!channel.ownerOnlyPost && _isSubscribed)) &&
              !_archived &&
              !channel.isArchived)
            ChannelPostBar(
              controller: _inputCtrl,
              showStickers: _showStickers,
              showCustomEmojis: _showCustomEmojis,
              onToggleCustomEmojis: () => setState(() {
                _showCustomEmojis = !_showCustomEmojis;
                if (_showCustomEmojis) _showStickers = false;
              }),
              onToggleStickers: () => setState(() {
                _showStickers = !_showStickers;
                if (_showStickers) _showCustomEmojis = false;
              }),
              onAttach: _showAttachmentPicker,
              onOptions: _showSendOptions,
              hasOptions: _sendSilent || _scheduledFor != null,
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
  final bool showCustomEmojis;
  final VoidCallback onToggleCustomEmojis;
  final VoidCallback onToggleStickers;
  final VoidCallback onAttach;
  final VoidCallback? onOptions;
  final bool hasOptions;
  final VoidCallback onPost;

  const ChannelPostBar({
    super.key,
    required this.controller,
    required this.showStickers,
    required this.showCustomEmojis,
    required this.onToggleCustomEmojis,
    required this.onToggleStickers,
    required this.onAttach,
    this.onOptions,
    this.hasOptions = false,
    required this.onPost,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Mirror the chat composer: an active control on the Liquid Glass layer,
    // free-floating above the bottom boundary with the canvas peeking around it.
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 14),
        child: GlassContainer(
          shape: LiquidRoundedSuperellipse(borderRadius: 28),
          allowElevation: true,
          glowIntensity: 0.06,
          padding: const EdgeInsets.fromLTRB(4, 4, 6, 4),
          child: Row(
            children: [
              IconButton(
                icon: Icon(
                  showCustomEmojis
                      ? Icons.keyboard
                      : Icons.add_reaction_outlined,
                ),
                tooltip: showCustomEmojis ? 'Keyboard' : 'Custom emoji',
                onPressed: onToggleCustomEmojis,
              ),
              IconButton(
                icon: Icon(
                  showStickers ? Icons.keyboard : Icons.sticky_note_2_outlined,
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
                  style: const TextStyle(fontWeight: FontWeight.w500),
                  decoration: InputDecoration(
                    hintText: 'Write a post…',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor: scheme.surfaceContainerHighest.withValues(
                      alpha: 0.30,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Tooltip(
                message: 'Attach file',
                child: GlassButtonWidget(
                  onPressed: onAttach,
                  padding: const EdgeInsets.all(10),
                  child: const Icon(Icons.attach_file_outlined, size: 22),
                ),
              ),
              const SizedBox(width: 4),
              Tooltip(
                message: 'Hold for post options',
                child: GestureDetector(
                  onTap: onPost,
                  onLongPress: onOptions,
                  child: GlassContainer(
                    shape: const LiquidOval(),
                    allowElevation: true,
                    glowIntensity: 0.08,
                    padding: const EdgeInsets.all(12),
                    child: Icon(
                      hasOptions ? Icons.schedule_send_outlined : Icons.send,
                      size: 18,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Reusable glass action-sheet tile for channel bottom sheets.
class _ChanTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  const _ChanTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = color ?? scheme.primary;
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
                    color: tint.withValues(alpha: 0.12),
                  ),
                  child: Icon(icon, size: 18, color: tint),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                      color: color,
                    ),
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
