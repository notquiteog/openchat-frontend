import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:image_picker/image_picker.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as lg;
import 'package:provider/provider.dart';
import '../../config/api_config.dart';
import '../../models/channel_pinned_message.dart';
import '../../models/conversation.dart';
import '../../models/message.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/api_service.dart';
import '../../services/attachment_service.dart';
import 'channel_paywall_sheet.dart';
import '../../services/mls_service.dart';
import '../../services/offline_outbox_service.dart';
import '../../services/secure_storage_service.dart';
import '../../services/websocket_service.dart';
import '../../crypto/pgp_service.dart';
import '../../utils/custom_emoji_payload.dart';
import '../../utils/disappearing_message_duration.dart';
import '../../utils/message_actions.dart';
import '../../utils/mention_utils.dart';
import '../../widgets/attachment_upload_progress.dart';
import '../../widgets/conversation_encryption_status.dart';
import '../../widgets/conversation_info_panel.dart';
import '../../widgets/conversation_invite_links_sheet.dart';
import '../../widgets/color_choices.dart';
import '../../widgets/custom_emoji_picker.dart';
import '../../widgets/custom_emoji_text_controller.dart';
import '../../widgets/disappearing_messages_picker.dart';
import '../../widgets/game_launcher.dart';
import '../../widgets/glass.dart';
import '../../widgets/message_action_sheet.dart';
import '../../widgets/mention_autocomplete_panel.dart';
import '../../widgets/message_bubble.dart';
import '../../widgets/scheduled_messages_sheet.dart';
import '../../widgets/sticker_picker.dart';
import '../../widgets/voice_note_recorder.dart';
import '../profile/user_profile_screen.dart';
import 'channel_action_policy.dart';
import 'channel_analytics_screen.dart';
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
            GlassListTile(
              title: const Text(
                'Public',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: const Text('Anyone can find and subscribe'),
              trailing: GlassSwitch(
                value: isPublic,
                onChanged: (v) => setDlgState(() => isPublic = v),
                activeColor: Theme.of(context).colorScheme.primary,
                enableHaptics: true,
              ),
              onTap: () => setDlgState(() => isPublic = !isPublic),
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
      extendBodyBehindAppBar: true,
      appBar: GlassAppBar(
        title: const Text('Channels'),
        actions: [
          IconButton(icon: const Icon(Icons.add), onPressed: _createChannel),
        ],
      ),
      body: Column(
        children: [
          SizedBox(
            height: MediaQuery.paddingOf(context).top + kToolbarHeight,
          ),
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
          if (_searching) const GlassProgressIndicator.linear(),
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
  final String? initialPostId;

  const ChannelFeedScreen({
    super.key,
    required this.channel,
    this.initialPostId,
  });

  @override
  State<ChannelFeedScreen> createState() => _ChannelFeedScreenState();
}

class _PreparedChannelPostPayload {
  final String encryptedPayload;
  final String signature;
  final String cleartextPayload;
  final String serverMessageType;
  final String senderId;
  final bool isEncrypted;
  final String? postToken;

  const _PreparedChannelPostPayload({
    required this.encryptedPayload,
    required this.signature,
    required this.cleartextPayload,
    required this.serverMessageType,
    required this.senderId,
    required this.isEncrypted,
    this.postToken,
  });
}

class _ChannelFeedScreenState extends State<ChannelFeedScreen> {
  final _inputCtrl = CustomEmojiTextEditingController();
  final _scrollCtrl = ScrollController();
  final Map<String, GlobalKey> _postKeys = {};
  List<Message> _posts = [];
  bool _isSubscribed = false;
  bool _isAdmin = false;
  ConversationMember? _currentMember;
  bool _loading = true;
  bool _archived = false;
  bool _showStickers = false;
  bool _showCustomEmojis = false;
  bool _sendSilent = false;
  DateTime? _scheduledFor;
  AttachmentUploadProgress? _attachmentUploadProgress;
  ActiveMentionQuery? _activeMentionQuery;
  List<CustomEmojiEntity> _customEmojiEntities = [];
  String _lastInputText = '';
  bool _suppressInputEntityShift = false;
  String? _highlightedPostId;
  Timer? _highlightTimer;
  Timer? _draftSaveTimer;
  bool _draftRestored = false;
  bool _hasPendingDraftSave = false;
  String _pendingDraftText = '';
  List<CustomEmojiEntity> _pendingDraftEntities = const [];
  bool _pendingDraftSilent = false;
  DateTime? _pendingDraftScheduledFor;
  late final SettingsProvider _settings;
  late final OfflineOutboxService _outbox;
  late final WebSocketService _ws;
  List<OfflineOutboxItem> _outboxItems = const [];
  Future<void>? _outboxLoadInFlight;
  bool _outboxLoaded = false;
  bool _drainingOutbox = false;

  // Mutable copy so edits to name/handle/avatar/privacy reflect immediately.
  late Conversation _channel;
  Conversation get channel => _channel;

  @override
  void initState() {
    super.initState();
    _channel = widget.channel;
    _settings = context.read<SettingsProvider>();
    _outbox = OfflineOutboxService(
      context.read<SecureStorageService>(),
      storeFileName: 'channel_offline_outbox.json',
      attachmentDirName: 'channel_offline_outbox_attachments',
    );
    _ws = context.read<WebSocketService>();
    _ws.addListener(_onWsConnectionChanged);
    _restoreLocalDraft();
    _inputCtrl.addListener(_onInputTextChanged);
    unawaited(_loadOutbox());
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
    _updateMentionQuery(_inputCtrl.value);
    _scheduleDraftSave(text);
  }

  void _syncCustomEmojiEntities(List<CustomEmojiEntity> entities) {
    _customEmojiEntities = entities;
    _suppressInputEntityShift = true;
    _inputCtrl.setCustomEmojiEntities(entities);
    _suppressInputEntityShift = false;
  }

  void _updateMentionQuery(TextEditingValue value) {
    final next = value.selection.isValid && value.selection.isCollapsed
        ? findActiveMentionQuery(value.text, value.selection.baseOffset)
        : null;
    final current = _activeMentionQuery;
    if (current?.start == next?.start &&
        current?.end == next?.end &&
        current?.query == next?.query) {
      return;
    }
    if (mounted) {
      setState(() => _activeMentionQuery = next);
    } else {
      _activeMentionQuery = next;
    }
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _inputCtrl.removeListener(_onInputTextChanged);
    _ws.removeListener(_onWsConnectionChanged);
    _draftSaveTimer?.cancel();
    _flushDraftSave();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final api = context.read<ApiService>();
      final storage = context.read<SecureStorageService>();
      final chat = context.read<ChatProvider>();
      final settings = context.read<SettingsProvider>();
      final currentUserId = await storage.getUserID() ?? '';

      // Check subscription + admin status
      final members = await api.getConversationMembers(channel.id);
      final me = members.where((m) => m.userId == currentUserId).firstOrNull;
      _currentMember = me;
      _isSubscribed = me != null;
      _isAdmin = me?.isAdmin ?? false;

      // Load posts
      final posts = await api.getChannelPosts(channel.id);
      final channelWithMembers = channel.copyWith(members: members);
      final privateKey = await storage.getPrivateKey() ?? '';
      for (final p in posts) {
        await api.promoteSealedScheduledControlToMessage(channel.id, p.id);
        ChatProvider.hydrateMessageSenderFromConversation(
          p,
          channelWithMembers,
        );
        await _tryDecrypt(p, privateKey, notify: false);
        chat.indexLoadedMessage(p);
      }
      await _syncPinnedMessagesFromServer(
        api: api,
        settings: settings,
        chat: chat,
        channelWithMembers: channelWithMembers,
        privateKey: privateKey,
        loadedPosts: posts,
      );
      await _ensureOutboxLoaded();
      final visiblePosts = _withOutboxOverlays(posts.reversed.toList());
      setState(() {
        _channel = channelWithMembers;
        _posts = visiblePosts;
        _postKeys.removeWhere(
          (messageId, _) => !_posts.any((post) => post.id == messageId),
        );
        _loading = false;
      });
      unawaited(_drainOutbox());
      final initialPostId = widget.initialPostId;
      if (initialPostId != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _jumpToPost(initialPostId);
        });
      }
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  void _onWsConnectionChanged() {
    if (_ws.isMonitoring) {
      unawaited(_drainOutbox());
    }
  }

  Future<void> _loadOutbox() {
    _outboxLoadInFlight ??= _outbox
        .list()
        .then((items) {
          _outboxItems = items;
          _outboxLoaded = true;
          _overlayOutboxOnPosts();
        })
        .whenComplete(() {
          _outboxLoadInFlight = null;
        });
    return _outboxLoadInFlight!;
  }

  Future<void> _ensureOutboxLoaded() {
    final inFlight = _outboxLoadInFlight;
    if (inFlight != null) return inFlight;
    if (_outboxLoaded) return Future.value();
    return _loadOutbox();
  }

  void _overlayOutboxOnPosts() {
    if (!mounted) return;
    setState(() {
      _posts = _withOutboxOverlays(_posts);
      _postKeys.removeWhere(
        (messageId, _) => !_posts.any((post) => post.id == messageId),
      );
    });
  }

  List<Message> _withOutboxOverlays(List<Message> base) {
    final items = _outboxItems
        .where((item) => item.conversationId == channel.id)
        .toList(growable: false);
    final next = base
        .where(
          (message) => message is! PendingMessage || message.outboxId == null,
        )
        .toList();
    if (items.isEmpty) return next;

    for (final item in items) {
      switch (item.action) {
        case OfflineOutboxAction.channelPost ||
            OfflineOutboxAction.channelAttachmentUpload:
          final pending = _pendingPostFromOutbox(item);
          if (pending != null) {
            next.removeWhere((message) => message.id == pending.id);
            next.add(pending);
          }
        case OfflineOutboxAction.channelReaction:
          final msgID = item.data['message_id'] as String?;
          final emoji = item.data['emoji'] as String?;
          final reacted = item.data['reacted'] as bool? ?? false;
          if (msgID == null || emoji == null) break;
          final idx = next.indexWhere((message) => message.id == msgID);
          if (idx == -1) break;
          next[idx] = next[idx].copyWith(
            reactions: _reactionsWithViewerState(
              next[idx].reactions,
              emoji: emoji,
              reacted: reacted,
            ),
          );
        case OfflineOutboxAction.sendMessage ||
            OfflineOutboxAction.editMessage ||
            OfflineOutboxAction.reaction ||
            OfflineOutboxAction.attachmentUpload:
          break;
      }
    }
    next.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return next;
  }

  PendingMessage? _pendingPostFromOutbox(OfflineOutboxItem item) {
    final data = item.data;
    final pendingID = data['pending_message_id'] as String?;
    final plaintext = data['plaintext_payload'] as String?;
    final senderID = data['sender_id'] as String? ?? '';
    if (pendingID == null ||
        pendingID.isEmpty ||
        plaintext == null ||
        senderID.isEmpty) {
      return null;
    }
    final createdAt =
        DateTime.tryParse(data['created_at'] as String? ?? '') ??
        item.createdAt;
    final pending = PendingMessage(
      id: pendingID,
      conversationId: item.conversationId,
      senderId: senderID,
      type: _messageTypeFromWire(
        data['local_message_type'] as String? ??
            data['message_type'] as String? ??
            'text',
      ),
      encryptedPayload:
          data['encrypted_payload'] as String? ??
          data['plaintext_payload'] as String? ??
          '',
      signature: data['signature'] as String? ?? '',
      isEncrypted: data['is_encrypted'] as bool? ?? channel.isEncrypted,
      attachmentId: data['attachment_id'] as String?,
      silent: data['silent'] as bool? ?? false,
      createdAt: createdAt,
      plaintext: plaintext,
      outboxId: item.id,
      status: switch (item.status) {
        OfflineOutboxStatus.failed => PendingMessageStatus.failed,
        OfflineOutboxStatus.sending => PendingMessageStatus.sending,
        OfflineOutboxStatus.queued => PendingMessageStatus.queued,
      },
      lastError: item.lastError,
    );
    ChatProvider.hydrateMessageSenderFromConversation(pending, channel);
    return pending;
  }

  String _newChannelOutboxId() =>
      'channel-outbox-${DateTime.now().microsecondsSinceEpoch}-${_outboxItems.length}';

  Future<void> _upsertOutboxItem(
    OfflineOutboxItem item, {
    bool coalesceReaction = false,
  }) async {
    await _ensureOutboxLoaded();
    final next = List<OfflineOutboxItem>.from(_outboxItems);
    if (coalesceReaction &&
        item.action == OfflineOutboxAction.channelReaction) {
      final msgID = item.data['message_id'];
      final emoji = item.data['emoji'];
      next.removeWhere(
        (existing) =>
            existing.action == OfflineOutboxAction.channelReaction &&
            existing.conversationId == item.conversationId &&
            existing.data['message_id'] == msgID &&
            existing.data['emoji'] == emoji,
      );
    } else {
      next.removeWhere((existing) => existing.id == item.id);
    }
    next.add(item);
    next.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    _outboxItems = next;
    await _outbox.replaceAll(next);
    _overlayOutboxOnPosts();
    if (_ws.isMonitoring && !_drainingOutbox) {
      unawaited(_drainOutbox());
    } else {
      unawaited(_ws.connect());
    }
  }

  Future<void> _removeOutboxItem(String id) async {
    _outboxItems = _outboxItems
        .where((item) => item.id != id)
        .toList(growable: false);
    await _outbox.remove(id);
    _overlayOutboxOnPosts();
  }

  Future<void> _updateOutboxItem(OfflineOutboxItem item) async {
    final next = List<OfflineOutboxItem>.from(_outboxItems);
    final index = next.indexWhere((existing) => existing.id == item.id);
    if (index == -1) {
      next.add(item);
    } else {
      next[index] = item;
    }
    next.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    _outboxItems = next;
    await _outbox.replaceAll(next);
    _overlayOutboxOnPosts();
  }

  bool _shouldRetryOutboxError(Object error) {
    if (error is SocketException || error is TimeoutException) return true;
    if (error is ApiException) {
      return error.statusCode == 408 ||
          error.statusCode == 429 ||
          error.statusCode >= 500;
    }
    return true;
  }

  String _postErrorMessage(Object error) {
    if (error is ApiException) {
      return 'Could not post (${error.statusCode} ${error.code}): ${error.message}';
    }
    if (error is ChatSendException) return error.message;
    return 'Could not post: $error';
  }

  Future<void> _drainOutbox() async {
    if (_drainingOutbox) return;
    if (!_ws.isMonitoring) {
      unawaited(_ws.connect());
      return;
    }
    _drainingOutbox = true;
    try {
      await _ensureOutboxLoaded();
      final currentItems = _outboxItems
          .where((item) => item.conversationId == channel.id)
          .toList(growable: false);
      for (final item in currentItems) {
        if (!_outboxItems.any((current) => current.id == item.id)) continue;
        final sending = item.copyWith(
          status: OfflineOutboxStatus.sending,
          clearLastError: true,
        );
        await _updateOutboxItem(sending);
        try {
          switch (item.action) {
            case OfflineOutboxAction.channelPost:
              await _deliverQueuedChannelPost(sending);
            case OfflineOutboxAction.channelAttachmentUpload:
              await _deliverQueuedChannelAttachment(sending);
            case OfflineOutboxAction.channelReaction:
              await _deliverQueuedChannelReaction(sending);
            case OfflineOutboxAction.sendMessage ||
                OfflineOutboxAction.editMessage ||
                OfflineOutboxAction.reaction ||
                OfflineOutboxAction.attachmentUpload:
              continue;
          }
          await _removeOutboxItem(item.id);
        } catch (e) {
          final retry = _shouldRetryOutboxError(e);
          await _updateOutboxItem(
            sending.copyWith(
              attempts: sending.attempts + 1,
              status: retry
                  ? OfflineOutboxStatus.queued
                  : OfflineOutboxStatus.failed,
              lastError: e.toString(),
            ),
          );
          if (retry) {
            unawaited(_ws.connect());
            return;
          }
        }
      }
    } finally {
      _drainingOutbox = false;
    }
  }

  Future<void> _deliverQueuedChannelPost(OfflineOutboxItem item) async {
    final api = context.read<ApiService>();
    final data = item.data;
    final plaintext = data['plaintext_payload'] as String? ?? '';
    final encryptedPayload = data['encrypted_payload'] as String? ?? '';
    final postToken = data['post_token'] as String?;
    final isEncrypted = data['is_encrypted'] as bool? ?? false;
    final Message confirmed;
    if (postToken != null && postToken.isNotEmpty) {
      confirmed = await api.sendSealedMessage(
        convID: item.conversationId,
        encryptedPayload: encryptedPayload,
        postToken: postToken,
        attachmentId: data['attachment_id'] as String?,
        silent: data['silent'] as bool? ?? false,
      );
    } else {
      if (isEncrypted) {
        throw const ChatSendException(
          'Queued encrypted post is missing its sealed posting token.',
        );
      }
      confirmed = await api.postToChannel(
        chanID: item.conversationId,
        encryptedPayload: encryptedPayload,
        signature: data['signature'] as String? ?? '',
        messageType: data['message_type'] as String? ?? 'text',
        attachmentId: data['attachment_id'] as String?,
        silent: data['silent'] as bool? ?? false,
      );
    }
    _replacePendingWithConfirmed(
      pendingID: data['pending_message_id'] as String?,
      confirmed: confirmed,
      plaintextPayload: plaintext,
    );
  }

  Future<void> _deliverQueuedChannelAttachment(OfflineOutboxItem item) async {
    final api = context.read<ApiService>();
    final data = item.data;
    final ciphertextPath = data['ciphertext_path'] as String?;
    if (ciphertextPath == null || ciphertextPath.isEmpty) {
      throw const ChatSendException('Queued attachment file is missing.');
    }
    final ciphertext = await _outbox.readAttachmentCiphertext(ciphertextPath);
    final encryptedAttachment = EncryptedAttachmentUpload.fromMetadataJson(
      Map<String, dynamic>.from(data['attachment'] as Map? ?? const {}),
      ciphertext: ciphertext,
    );
    final attachment = await AttachmentService(
      api,
    ).uploadEncryptedAttachment(encryptedAttachment);
    final plaintext = jsonEncode(
      attachment.toPayloadJson(caption: data['caption'] as String? ?? ''),
    );
    await _prepareAndSendChannelPayload(
      plaintextPayload: plaintext,
      messageType: attachment.messageType.name,
      pendingID: data['pending_message_id'] as String?,
      attachmentId: attachment.attachmentId,
      silent: data['silent'] as bool? ?? false,
    );
    await _outbox.deleteAttachmentCiphertext(ciphertextPath);
  }

  Future<void> _deliverQueuedChannelReaction(OfflineOutboxItem item) async {
    final data = item.data;
    final msgID = data['message_id'] as String? ?? '';
    final emoji = data['emoji'] as String? ?? '';
    final reacted = data['reacted'] as bool? ?? false;
    final api = context.read<ApiService>();
    if (reacted) {
      await api.reactToMessage(msgID, emoji);
    } else {
      await api.removeReaction(msgID, emoji);
    }
  }

  Future<void> _prepareAndSendChannelPayload({
    required String plaintextPayload,
    required String messageType,
    required String? pendingID,
    String? attachmentId,
    bool silent = false,
  }) async {
    final api = context.read<ApiService>();
    final prepared = await _prepareChannelPostPayload(
      plaintextPayload: plaintextPayload,
      messageType: messageType,
    );
    final confirmed = channel.isEncrypted
        ? await api.sendSealedMessage(
            convID: channel.id,
            encryptedPayload: prepared.encryptedPayload,
            postToken: prepared.postToken ?? '',
            attachmentId: attachmentId,
            silent: silent,
          )
        : await api.postToChannel(
            chanID: channel.id,
            encryptedPayload: prepared.encryptedPayload,
            signature: prepared.signature,
            messageType: prepared.serverMessageType,
            attachmentId: attachmentId,
            silent: silent,
          );
    _replacePendingWithConfirmed(
      pendingID: pendingID,
      confirmed: confirmed,
      plaintextPayload: prepared.cleartextPayload,
    );
  }

  void _replacePendingWithConfirmed({
    required String? pendingID,
    required Message confirmed,
    required String plaintextPayload,
  }) {
    final proof = Message.senderProofFromRaw(plaintextPayload);
    confirmed.setDecryptedContent(
      plaintextPayload,
      verifiedSenderId: proof?.senderId,
    );
    ChatProvider.hydrateMessageSenderFromConversation(confirmed, channel);
    if (mounted) {
      context.read<ChatProvider>().indexLoadedMessage(confirmed);
      setState(() {
        _posts = [
          ..._posts.where(
            (post) => post.id != pendingID && post.id != confirmed.id,
          ),
          confirmed,
        ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
        _postKeys.removeWhere(
          (messageId, _) => !_posts.any((post) => post.id == messageId),
        );
      });
    }
  }

  Future<void> _syncPinnedMessagesFromServer({
    required ApiService api,
    required SettingsProvider settings,
    required ChatProvider chat,
    required Conversation channelWithMembers,
    required String privateKey,
    required List<Message> loadedPosts,
  }) async {
    try {
      final serverPins = await api.getChannelPinnedPosts(channel.id);
      final loadedById = {for (final post in loadedPosts) post.id: post};
      final normalized = <ChannelPinnedMessage>[];
      for (final pin in serverPins) {
        final message = loadedById[pin.messageId] ?? pin.message;
        if (message != null) {
          await api.promoteSealedScheduledControlToMessage(
            channel.id,
            message.id,
          );
          ChatProvider.hydrateMessageSenderFromConversation(
            message,
            channelWithMembers,
          );
          await _tryDecrypt(message, privateKey, notify: false);
          chat.indexLoadedMessage(message);
        }
        normalized.add(_pinnedMessageFromMessage(pin, message));
      }
      await settings.replaceChannelPinnedMessages(channel.id, normalized);
    } catch (_) {
      // Keep the last local pin cache when the shared pin endpoint is offline.
    }
  }

  ChannelPinnedMessage _pinnedMessageFromMessage(
    ChannelPinnedMessage pinned,
    Message? message,
  ) {
    if (message == null) {
      return pinned.copyWith(
        conversationId: pinned.conversationId.isEmpty
            ? channel.id
            : pinned.conversationId,
        preview: pinned.preview.isEmpty ? 'Pinned message' : pinned.preview,
      );
    }
    return pinned.copyWith(
      conversationId: pinned.conversationId.isEmpty
          ? channel.id
          : pinned.conversationId,
      preview: _pinnedMessagePreview(message),
      messageCreatedAt: message.createdAt,
      senderUsername: message.sender?.username ?? pinned.senderUsername,
      message: message,
    );
  }

  Future<void> _tryDecrypt(
    Message msg,
    String privateKey, {
    bool notify = true,
  }) async {
    if (!msg.isEncrypted) {
      msg.setDecryptedContent(msg.encryptedPayload);
      if (notify && mounted) setState(() {});
      return;
    }
    if (channel.usesMls) {
      final raw = await context.read<MlsService>().decryptPayload(
        api: context.read<ApiService>(),
        conversation: channel,
        encryptedPayload: msg.encryptedPayload,
      );
      if (raw != null && raw.isNotEmpty) {
        final verifiedSenderId = await _verifiedPgpSenderId(raw);
        if (msg.sealedSender && verifiedSenderId == null) {
          msg.markDecryptionFailed();
          return;
        }
        msg.setDecryptedContent(raw, verifiedSenderId: verifiedSenderId);
        ChatProvider.hydrateMessageSenderFromConversation(msg, channel);
        if (notify && mounted) setState(() {});
      } else {
        msg.markDecryptionFailed();
      }
      return;
    }
    if (privateKey.isEmpty) return;
    try {
      final raw = await PgpService.decrypt(
        encryptedArmor: msg.encryptedPayload,
        privateKeyArmored: privateKey,
      );
      final verifiedSenderId = await _verifiedPgpSenderId(raw);
      if (msg.sealedSender && verifiedSenderId == null) {
        msg.markDecryptionFailed();
        return;
      }
      msg.setDecryptedContent(raw, verifiedSenderId: verifiedSenderId);
      ChatProvider.hydrateMessageSenderFromConversation(msg, channel);
      if (notify && mounted) setState(() {});
    } catch (_) {
      msg.markDecryptionFailed();
    }
  }

  Future<String?> _verifiedPgpSenderId(String raw) async {
    final proof = Message.senderProofFromRaw(raw);
    if (proof == null) return null;
    var members = channel.members;
    if (members.isEmpty) {
      try {
        members = await context.read<ApiService>().getConversationMembers(
          channel.id,
        );
        if (mounted) {
          setState(() => _channel = channel.copyWith(members: members));
        } else {
          _channel = channel.copyWith(members: members);
        }
      } catch (_) {
        return null;
      }
    }
    ConversationMember? sender;
    for (final member in members) {
      if (member.userId == proof.senderId) {
        sender = member;
        break;
      }
    }
    final user = sender?.user;
    if (user == null) return null;
    if (user.keyFingerprint.toUpperCase() !=
        proof.keyFingerprint.toUpperCase()) {
      return null;
    }
    final ok = await PgpService.verify(
      data: PgpService.senderProofData(
        conversationId: channel.id,
        messageType: proof.type,
        payload: proof.payload,
      ),
      signatureArmor: proof.signature,
      signerPublicKeyArmored: user.publicKey,
    );
    return ok ? proof.senderId : null;
  }

  Future<void> _subscribe() async {
    final api = context.read<ApiService>();
    // Paid channels gate access behind a subscription plan — show the paywall
    // instead of the free subscribe path when a plan exists.
    try {
      final subInfo = await api.getChannelSubscription(channel.id);
      final plans = (subInfo['plans'] as List?) ?? const [];
      final alreadySubscribed = subInfo['subscription'] != null;
      final isOwner = subInfo['is_owner'] == true;
      if (plans.isNotEmpty && !alreadySubscribed && !isOwner) {
        if (!mounted) return;
        final subscribed = await showChannelPaywall(
          context,
          channelId: channel.id,
          channelName: channel.name ?? 'this channel',
        );
        if (subscribed && mounted) {
          setState(() => _isSubscribed = true);
          context.read<ChatProvider>().loadConversations();
        }
        return;
      }
    } catch (_) {
      // Fall through to the free subscribe path if the plan lookup fails.
    }
    try {
      final result = await api.subscribeChannel(
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
    final isNotSelf =
        msg.senderId != context.read<AuthProvider>().currentUser?.id;
    final canDeleteUserMessages = _canDeleteChannelMessages && isNotSelf;
    final canModerateUser = _canManageChannelModeration && isNotSelf;
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => GlassBottomSheetFrame(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            _ChanTile(
              icon: Icons.person_outline_rounded,
              label: '@${user.username}',
              onTap: () => Navigator.pop(context, 'profile'),
            ),
            if (canDeleteUserMessages)
              _ChanTile(
                icon: Icons.delete_sweep_outlined,
                label: 'Delete their messages',
                color: Colors.red,
                onTap: () => Navigator.pop(context, 'delete_messages'),
              ),
            if (canModerateUser)
              _ChanTile(
                icon: Icons.block_rounded,
                label: 'Ban from channel',
                color: Colors.red,
                onTap: () => Navigator.pop(context, 'ban'),
              ),
            const SizedBox(height: 8),
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
                GlassListTile(
                  title: const Text(
                    'Public',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: const Text(
                    'Private channels lose their @handle and are hidden from search',
                  ),
                  trailing: GlassSwitch(
                    value: isPublic,
                    onChanged: (v) => setDlgState(() => isPublic = v),
                    activeColor: Theme.of(context).colorScheme.primary,
                    enableHaptics: true,
                  ),
                  onTap: () => setDlgState(() => isPublic = !isPublic),
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
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => GlassBottomSheetFrame(
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
    final mls = context.read<MlsService>();
    final messenger = ScaffoldMessenger.of(context);
    final selected = await showDialog<EncryptionMode>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: const Text('Encryption mode'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Changing encryption mode wipes all current posts in this channel for everyone.',
              ),
              const SizedBox(height: 12),
              for (final mode in EncryptionMode.values)
                GlassListTile(
                  leading: Icon(
                    mode == channel.encryptionMode
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  title: Text(mode.shortLabel),
                  onTap: mode == channel.encryptionMode
                      ? null
                      : () => Navigator.pop(ctx, mode),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (selected == null || selected == channel.encryptionMode) return;
    try {
      final bootstrap = selected == EncryptionMode.mls
          ? await mls.createBootstrapForConversation(channel)
          : null;
      await api.setEncryptionMode(
        channel.id,
        selected.apiValue,
        mlsBootstrap: bootstrap,
      );
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
          content: Text('Encryption mode set to ${selected.shortLabel}'),
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

          return GlassBottomSheetFrame(
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
      canOpenModeration: _canManageChannelModeration || _canManageChannelRoles,
      canManageInfo: _canManageChannelInfo,
      canManageInvites: _canManageChannelInvites,
      canManageSettings: _canManageChannelSettings,
      canManageEncryption: _canManageChannelEncryption,
      canViewAnalytics: _isAdmin,
    );
    final action = await showModalBottomSheet<ChannelModerationAction>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => GlassBottomSheetFrame(
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
                  ChannelModerationAction.unarchive => Icons.unarchive_outlined,
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
    final auth = context.read<AuthProvider>();
    final currentUserId = auth.currentUser?.id ?? '';
    final isPremium = auth.currentUser?.isPremium ?? false;
    final placement = ChannelActionPolicy.actionsFor(
      channel: channel,
      isAdmin: _isAdmin,
      isPremium: isPremium,
      canManageLifecycle: false,
      isSubscribed: _isSubscribed,
      canOpenModeration: _canManageChannelModeration || _canManageChannelRoles,
      canManageInfo: _canManageChannelInfo,
      canManageInvites: _canManageChannelInvites,
      canManageSettings: _canManageChannelSettings,
      canManageEncryption: _canManageChannelEncryption,
      canViewAnalytics: _isAdmin,
    );
    final action = await showModalBottomSheet<ChannelSettingsAction>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => GlassBottomSheetFrame(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            for (final item in placement.settingsMenu)
              _ChanTile(
                icon: switch (item) {
                  ChannelSettingsAction.appearance =>
                    Icons.format_color_fill_outlined,
                  ChannelSettingsAction.sharedContent =>
                    Icons.photo_library_outlined,
                  ChannelSettingsAction.analytics => Icons.query_stats_outlined,
                  ChannelSettingsAction.scheduledPosts =>
                    Icons.schedule_send_outlined,
                  ChannelSettingsAction.edit => Icons.settings_outlined,
                  ChannelSettingsAction.inviteLinks => Icons.link_rounded,
                  ChannelSettingsAction.background => Icons.wallpaper_outlined,
                  ChannelSettingsAction.autoDelete => Icons.timer_outlined,
                  ChannelSettingsAction.encryption =>
                    channel.isEncrypted
                        ? Icons.lock_outline_rounded
                        : Icons.lock_open_outlined,
                  ChannelSettingsAction.deleteOwnMessages =>
                    Icons.delete_sweep_outlined,
                  ChannelSettingsAction.subscriptionPlan =>
                    Icons.workspace_premium_outlined,
                },
                label: switch (item) {
                  ChannelSettingsAction.appearance => 'Chat appearance',
                  ChannelSettingsAction.sharedContent => 'Shared content',
                  ChannelSettingsAction.analytics => 'Analytics',
                  ChannelSettingsAction.scheduledPosts => 'Scheduled posts',
                  ChannelSettingsAction.edit => 'Channel settings',
                  ChannelSettingsAction.inviteLinks => 'Invite links',
                  ChannelSettingsAction.background =>
                    'Set chat background (Premium)',
                  ChannelSettingsAction.autoDelete => 'Disappearing messages',
                  ChannelSettingsAction.encryption => 'Encryption mode',
                  ChannelSettingsAction.deleteOwnMessages =>
                    'Delete my messages',
                  ChannelSettingsAction.subscriptionPlan =>
                    'Subscription price',
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
    );
    if (!mounted || action == null) return;
    switch (action) {
      case ChannelSettingsAction.appearance:
        _showChatAppearance();
      case ChannelSettingsAction.sharedContent:
        unawaited(
          showSharedContentSheet(
            context,
            conversation: channel,
            currentUserId: currentUserId,
            channel: true,
            initialMessages: _posts,
            onMessageSelected: (message) => _jumpToPost(message.id),
          ),
        );
      case ChannelSettingsAction.analytics:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ChannelAnalyticsScreen(conversation: channel),
          ),
        );
      case ChannelSettingsAction.scheduledPosts:
        showScheduledMessagesSheet(
          context,
          conversation: channel,
          channel: true,
        );
      case ChannelSettingsAction.edit:
        _editChannelSettings();
      case ChannelSettingsAction.inviteLinks:
        _showInviteLinks();
      case ChannelSettingsAction.background:
        _setBackground();
      case ChannelSettingsAction.autoDelete:
        _setDisappearing();
      case ChannelSettingsAction.encryption:
        _setEncryption();
      case ChannelSettingsAction.deleteOwnMessages:
        _deleteOwnChannelMessages();
      case ChannelSettingsAction.subscriptionPlan:
        _setSubscriptionPrice();
    }
  }

  Future<void> _setSubscriptionPrice() async {
    final providerCtrl = ValueNotifier<String>('btc');
    final priceCtrl = TextEditingController();
    final daysCtrl = TextEditingController(text: '30');
    // Prefill from an existing plan if present.
    try {
      final info = await context.read<ApiService>().getChannelSubscription(
        channel.id,
      );
      final plans = ((info['plans'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();
      if (plans.isNotEmpty) {
        providerCtrl.value = plans.first['provider'] as String? ?? 'btc';
        priceCtrl.text = (plans.first['price'] as num?)?.toString() ?? '';
        daysCtrl.text =
            (plans.first['period_days'] as int?)?.toString() ?? '30';
      }
    } catch (_) {}
    if (!mounted) return;
    final save = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => GlassAlertDialog(
        title: const Text('Subscription price'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<String>(
              valueListenable: providerCtrl,
              builder: (_, provider, _) => Row(
                children: [
                  for (final p in const ['btc', 'xmr'])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: lg.GlassChip(
                        label: p.toUpperCase(),
                        selected: provider == p,
                        onTap: () => providerCtrl.value = p,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: priceCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Price'),
            ),
            TextField(
              controller: daysCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Period (days)'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (save != true || !mounted) return;
    final price = double.tryParse(priceCtrl.text.trim()) ?? 0;
    final days = int.tryParse(daysCtrl.text.trim()) ?? 0;
    if (price <= 0 || days < 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid price and period')),
      );
      return;
    }
    try {
      await context.read<ApiService>().setChannelSubscriptionPlan(
        channel.id,
        provider: providerCtrl.value,
        price: price,
        periodDays: days,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Subscription price saved')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  Future<void> _showInviteLinks() async {
    await showConversationInviteLinksSheet(
      context,
      conversation: channel,
      channel: true,
      onJoinApprovalChanged: (required) {
        if (mounted) {
          setState(() {
            _channel = _channel.copyWith(joinApprovalRequired: required);
          });
        }
        unawaited(context.read<ChatProvider>().refreshConversationsSilently());
      },
    );
  }

  Future<_PreparedChannelPostPayload> _prepareChannelPostPayload({
    required String plaintextPayload,
    required String messageType,
  }) async {
    final api = context.read<ApiService>();
    final storage = context.read<SecureStorageService>();
    final auth = context.read<AuthProvider>();
    final mls = context.read<MlsService>();
    final privateKey = await storage.getPrivateKey() ?? '';
    final userID = auth.currentUser?.id ?? await storage.getUserID() ?? '';
    if (userID.isEmpty) {
      throw const ChatSendException(
        'Your session is incomplete. Sign in again.',
      );
    }

    if (!channel.isEncrypted) {
      return _PreparedChannelPostPayload(
        encryptedPayload: plaintextPayload,
        signature: '',
        cleartextPayload: plaintextPayload,
        serverMessageType: messageType,
        senderId: userID,
        isEncrypted: false,
      );
    }

    if (channel.usesMls) {
      if (privateKey.isEmpty) {
        throw const ChatSendException(
          'Your PGP key is locked or missing. Unlock or import it in Settings to post sealed MLS messages.',
        );
      }
      final artifactPayload = _chatArtifactPayload(
        messageType,
        plaintextPayload,
      );
      final cleartextPayload = await _signedPgpCleartextPayload(
        plaintextPayload: artifactPayload,
        messageType: messageType,
        senderId: userID,
        privateKey: privateKey,
      );
      final encrypted = await mls.encryptPayload(
        api: api,
        conversation: channel,
        plaintextPayload: cleartextPayload,
      );
      return _PreparedChannelPostPayload(
        encryptedPayload: encrypted,
        signature: '',
        cleartextPayload: cleartextPayload,
        serverMessageType: 'text',
        senderId: userID,
        isEncrypted: true,
        postToken: await _sealedPostToken(privateKey),
      );
    }

    if (privateKey.isEmpty) {
      throw const ChatSendException(
        'Your PGP key is locked or missing. Unlock or import it in Settings.',
      );
    }

    List<ConversationMember> members;
    try {
      members = await api.getConversationMembers(channel.id);
      if (members.isNotEmpty && mounted) {
        setState(() => _channel = channel.copyWith(members: members));
      }
    } catch (_) {
      members = channel.members;
    }

    final selfPublicKey = await storage.getPublicKey() ?? '';
    final selfFingerprint = await storage.getFingerprint() ?? '';
    final keysByUser = <String, PgpRecipient>{};
    for (final member in members) {
      if (member.userId == userID) continue;
      if (member.user?.isKeyExpired ?? false) continue;
      try {
        final freshKey = await api.getFreshUserPublicKeyEntry(member.userId);
        if (freshKey != null && freshKey.publicKey.trim().isNotEmpty) {
          keysByUser[member.userId] = PgpRecipient(
            userId: member.userId,
            publicKeyArmored: freshKey.publicKey,
            keyFingerprint: freshKey.fingerprint,
          );
          continue;
        }
        continue;
      } catch (_) {
        final embeddedKey = member.user?.publicKey ?? '';
        final embeddedFingerprint = member.user?.keyFingerprint ?? '';
        if (embeddedKey.trim().isNotEmpty &&
            embeddedFingerprint.trim().isNotEmpty) {
          keysByUser[member.userId] = PgpRecipient(
            userId: member.userId,
            publicKeyArmored: embeddedKey,
            keyFingerprint: embeddedFingerprint,
          );
          continue;
        }
        throw const ChatSendException(
          'Could not load every recipient key. Refresh the channel and try again.',
        );
      }
    }
    if (selfPublicKey.trim().isNotEmpty && selfFingerprint.trim().isNotEmpty) {
      keysByUser[userID] = PgpRecipient(
        userId: userID,
        publicKeyArmored: selfPublicKey,
        keyFingerprint: selfFingerprint,
      );
    }
    final recipients = keysByUser.values.toList()
      ..sort((a, b) => a.userId.compareTo(b.userId));
    if (recipients.isEmpty) {
      throw const ChatSendException(
        'Could not load recipient keys. Refresh the channel and try again.',
      );
    }
    final artifactPayload = _chatArtifactPayload(messageType, plaintextPayload);
    final cleartextPayload = await _signedPgpCleartextPayload(
      plaintextPayload: artifactPayload,
      messageType: messageType,
      senderId: userID,
      privateKey: privateKey,
    );

    final encrypted = await PgpService.encrypt(
      plaintext: cleartextPayload,
      recipients: recipients,
      signingPrivateKeyArmored: privateKey,
    ).timeout(const Duration(seconds: 30));
    final postToken = await _sealedPostToken(privateKey);
    return _PreparedChannelPostPayload(
      encryptedPayload: encrypted,
      signature: '',
      cleartextPayload: cleartextPayload,
      serverMessageType: 'text',
      senderId: userID,
      isEncrypted: true,
      postToken: postToken,
    );
  }

  Future<void> _queueChannelPost({
    required String plaintextPayload,
    required String messageType,
    required String localMessageType,
    required String encryptedPayload,
    required String signature,
    required String senderId,
    required bool isEncrypted,
    String? postToken,
    String? attachmentId,
    bool silent = false,
  }) async {
    final itemID = _newChannelOutboxId();
    final now = DateTime.now();
    await _upsertOutboxItem(
      OfflineOutboxItem(
        id: itemID,
        action: OfflineOutboxAction.channelPost,
        conversationId: channel.id,
        createdAt: now,
        data: {
          'pending_message_id': 'pending-$itemID',
          'sender_id': senderId,
          'plaintext_payload': plaintextPayload,
          'encrypted_payload': encryptedPayload,
          'signature': signature,
          'post_token': ?postToken,
          'message_type': messageType,
          if (isEncrypted) 'local_message_type': localMessageType,
          'is_encrypted': isEncrypted,
          'created_at': now.toUtc().toIso8601String(),
          'attachment_id': ?attachmentId,
          if (silent) 'silent': true,
        },
      ),
    );
  }

  Future<void> _queueChannelAttachmentUpload({
    required EncryptedAttachmentUpload attachment,
    String caption = '',
    bool silent = false,
  }) async {
    final storage = context.read<SecureStorageService>();
    final auth = context.read<AuthProvider>();
    final userID = auth.currentUser?.id ?? await storage.getUserID() ?? '';
    if (userID.isEmpty) {
      throw const ChatSendException(
        'Your session is incomplete. Sign in again.',
      );
    }

    final itemID = _newChannelOutboxId();
    final pendingAttachmentID = 'pending-attachment-$itemID';
    final now = DateTime.now();
    final ciphertextPath = await _outbox.saveAttachmentCiphertext(
      itemID,
      attachment.ciphertext,
    );
    final plaintext = jsonEncode(
      attachment.toPayloadJson(
        attachmentId: pendingAttachmentID,
        caption: caption,
      ),
    );
    await _upsertOutboxItem(
      OfflineOutboxItem(
        id: itemID,
        action: OfflineOutboxAction.channelAttachmentUpload,
        conversationId: channel.id,
        createdAt: now,
        data: {
          'pending_message_id': 'pending-$itemID',
          'sender_id': userID,
          'plaintext_payload': plaintext,
          'message_type': attachment.messageType.name,
          'attachment_id': pendingAttachmentID,
          'attachment': attachment.toMetadataJson(),
          'ciphertext_path': ciphertextPath,
          'caption': caption,
          'is_encrypted': channel.isEncrypted,
          'created_at': now.toUtc().toIso8601String(),
          if (silent) 'silent': true,
        },
      ),
    );
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
      _draftSaveTimer?.cancel();
      _hasPendingDraftSave = false;
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

    final chat = context.read<ChatProvider>();
    final api = context.read<ApiService>();
    final scheduledFor = _scheduledFor;
    final silent = _sendSilent;
    late final _PreparedChannelPostPayload prepared;
    try {
      prepared = await _prepareChannelPostPayload(
        plaintextPayload: draft.payload,
        messageType: messageType,
      );
    } catch (e) {
      if (plaintextOverride == null) {
        _restoreComposer(rawText, draftEntities);
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_postErrorMessage(e))));
      }
      return;
    }

    if (scheduledFor == null && !_ws.isMonitoring) {
      await _queueChannelPost(
        plaintextPayload: prepared.cleartextPayload,
        messageType: prepared.serverMessageType,
        localMessageType: messageType,
        encryptedPayload: prepared.encryptedPayload,
        signature: prepared.signature,
        senderId: prepared.senderId,
        isEncrypted: prepared.isEncrypted,
        postToken: prepared.postToken,
        attachmentId: attachmentId,
        silent: silent,
      );
      if (plaintextOverride == null) {
        unawaited(_settings.clearMessageDraft(channel.id));
      }
      return;
    }

    Message? msg;
    try {
      if (channel.isEncrypted) {
        if (scheduledFor == null) {
          msg = await api.sendSealedMessage(
            convID: channel.id,
            encryptedPayload: prepared.encryptedPayload,
            postToken: prepared.postToken ?? '',
            attachmentId: attachmentId,
            silent: silent,
          );
        } else {
          await api.scheduleSealedMessage(
            convID: channel.id,
            encryptedPayload: prepared.encryptedPayload,
            postToken: prepared.postToken ?? '',
            scheduledFor: scheduledFor,
            attachmentId: attachmentId,
            silent: silent,
          );
        }
      } else {
        msg = await api.postToChannel(
          chanID: channel.id,
          encryptedPayload: prepared.encryptedPayload,
          signature: prepared.signature,
          messageType: prepared.serverMessageType,
          attachmentId: attachmentId,
          silent: silent,
          scheduledFor: scheduledFor,
        );
      }
    } catch (e) {
      if (scheduledFor == null && _shouldRetryOutboxError(e)) {
        await _queueChannelPost(
          plaintextPayload: prepared.cleartextPayload,
          messageType: prepared.serverMessageType,
          localMessageType: messageType,
          encryptedPayload: prepared.encryptedPayload,
          signature: prepared.signature,
          senderId: prepared.senderId,
          isEncrypted: prepared.isEncrypted,
          postToken: prepared.postToken,
          attachmentId: attachmentId,
          silent: silent,
        );
        if (plaintextOverride == null) {
          unawaited(_settings.clearMessageDraft(channel.id));
        }
        return;
      }
      if (plaintextOverride == null) {
        _restoreComposer(rawText, draftEntities);
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_postErrorMessage(e))));
      }
      return;
    }
    final confirmed = msg;
    if (confirmed != null) {
      final proof = Message.senderProofFromRaw(prepared.cleartextPayload);
      confirmed.setDecryptedContent(
        prepared.cleartextPayload,
        verifiedSenderId: proof?.senderId,
      );
      ChatProvider.hydrateMessageSenderFromConversation(confirmed, channel);
    }
    if (plaintextOverride == null) {
      unawaited(_settings.clearMessageDraft(channel.id));
    }
    if (scheduledFor == null) {
      if (confirmed == null) return;
      setState(() => _posts.add(confirmed));
      chat.indexLoadedMessage(confirmed);
    } else if (mounted) {
      setState(() => _scheduledFor = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Scheduled for ${_formatSchedule(scheduledFor)}'),
        ),
      );
    }
  }

  MessageType _messageTypeFromWire(String value) {
    return switch (value) {
      'sticker' => MessageType.sticker,
      'file' => MessageType.file,
      'image' => MessageType.image,
      'video' => MessageType.video,
      'voice' => MessageType.voice,
      'audio' => MessageType.audio,
      'animation' => MessageType.animation,
      'video_note' => MessageType.videoNote,
      'live_photo' => MessageType.livePhoto,
      'poll' => MessageType.poll,
      'location' => MessageType.location,
      'venue' => MessageType.venue,
      'contact' => MessageType.contact,
      'dice' => MessageType.dice,
      'checklist' => MessageType.checklist,
      'invoice' => MessageType.invoice,
      'payment_request' => MessageType.paymentRequest,
      'payment_transfer' => MessageType.paymentTransfer,
      'system' => MessageType.system,
      _ => MessageType.text,
    };
  }

  Future<String> _signedPgpCleartextPayload({
    required String plaintextPayload,
    required String messageType,
    required String senderId,
    required String privateKey,
  }) async {
    final fingerprint =
        await context.read<SecureStorageService>().getFingerprint() ?? '';
    final signature = await PgpService.sign(
      data: PgpService.senderProofData(
        conversationId: channel.id,
        messageType: messageType,
        payload: plaintextPayload,
      ),
      privateKeyArmored: privateKey,
    ).timeout(const Duration(seconds: 30));
    return jsonEncode({
      'openchat_message': 1,
      'type': messageType,
      'payload': plaintextPayload,
      'sender': {
        'id': senderId,
        'key_fingerprint': fingerprint,
        'signature': signature,
      },
    });
  }

  String _chatArtifactPayload(String kind, String plaintextPayload) {
    if (ChatArtifact.tryParse(plaintextPayload) != null) {
      return plaintextPayload;
    }
    Object payload = plaintextPayload;
    try {
      final decoded = jsonDecode(plaintextPayload);
      if (decoded is Map || decoded is List) payload = decoded;
    } catch (_) {}
    return ChatArtifact.encodePayload(kind: kind, payload: payload);
  }

  Future<String> _sealedPostToken(String privateKey) async {
    final api = context.read<ApiService>();
    final storage = context.read<SecureStorageService>();
    final encrypted = await api.getEncryptedSealedPostToken(channel.id);
    final token = await PgpService.decrypt(
      encryptedArmor: encrypted,
      privateKeyArmored: privateKey,
    );
    await storage.savePgpPostToken(channel.id, token);
    return token;
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
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => GlassBottomSheetFrame(
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
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.30),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              GlassListTile(
                leading: const Icon(Icons.notifications_off_outlined),
                title: const Text(
                  'Post silently',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                trailing: GlassSwitch(
                  value: _sendSilent,
                  onChanged: (v) {
                    setState(() => _sendSilent = v);
                    _scheduleDraftSave(_inputCtrl.text);
                    setSheetState(() {});
                  },
                  activeColor: Theme.of(context).colorScheme.primary,
                  enableHaptics: true,
                ),
                onTap: () {
                  setState(() => _sendSilent = !_sendSilent);
                  _scheduleDraftSave(_inputCtrl.text);
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
                          _scheduleDraftSave(_inputCtrl.text);
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
                        _scheduleDraftSave(_inputCtrl.text);
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
    );
  }

  void _showReactionMenu(Message msg) {
    if (msg.type == MessageType.system) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => GlassBottomSheetFrame(
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
    );
  }

  Future<void> _showPostMenu(Message msg, bool isMe) async {
    final isSystem = msg.type == MessageType.system;
    final canDelete = isMe || _canDeleteChannelMessages;
    final settings = context.read<SettingsProvider>();
    final canPin = !isSystem && _canPinChannelPosts;
    final isPinned = settings.isChannelMessagePinned(channel.id, msg.id);
    final hasCopyableText =
        !isSystem && msg.isDecrypted && (msg.decryptedContent ?? '').isNotEmpty;
    final selected = await showMessageActionSheet<String>(
      context: context,
      message: msg,
      actions: [
        if (canPin)
          MessageActionSheetItem(
            value: 'pin',
            icon: isPinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
            label: isPinned ? 'Unpin message' : 'Pin message',
          ),
        if (hasCopyableText)
          const MessageActionSheetItem(
            value: 'copy_text',
            icon: Icons.copy_rounded,
            label: 'Copy text',
          ),
        const MessageActionSheetItem(
          value: 'copy_link',
          icon: Icons.link_rounded,
          label: 'Copy message link',
        ),
        if (!isSystem)
          const MessageActionSheetItem(
            value: 'remind',
            icon: Icons.alarm_add_outlined,
            label: 'Remind me',
          ),
        if (canDownloadMessageAttachment(msg))
          MessageActionSheetItem(
            value: 'download',
            icon: Icons.download_rounded,
            label: 'Download attachment',
            subtitle: suggestedAttachmentFileName(msg),
          ),
        if (!isMe && msg.sender != null)
          MessageActionSheetItem(
            value: 'sender',
            icon: Icons.person_outline_rounded,
            label: 'Sender actions',
            subtitle: '@${msg.sender!.username}',
          ),
        if (!isMe && !isSystem && msg.sender != null)
          const MessageActionSheetItem(
            value: 'report',
            icon: Icons.flag_outlined,
            label: 'Report',
            color: Colors.orange,
            dividerBefore: true,
          ),
        if (canDelete)
          const MessageActionSheetItem(
            value: 'delete',
            icon: Icons.delete_outline_rounded,
            label: 'Delete',
            color: Colors.red,
            dividerBefore: true,
          ),
      ],
    );
    if (!mounted || selected == null) return;

    switch (selected) {
      case 'pin':
        await _setPostPinned(msg, !isPinned);
      case 'copy_text':
        await _copyPostText(msg);
      case 'copy_link':
        await _copyPostLink(msg);
      case 'remind':
        await _remindAboutPost(msg);
      case 'download':
        await _downloadPostAttachment(msg);
      case 'sender':
        await _showChannelUserActions(msg);
      case 'report':
        await _reportPost(msg);
      case 'delete':
        await _deletePost(msg);
    }
  }

  Future<void> _remindAboutPost(Message msg) async {
    final now = DateTime.now();
    final selected = await showDialog<DateTime>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: const Text('Remind me'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ChannelReminderChoiceTile(
              label: 'In 15 minutes',
              onTap: () =>
                  Navigator.pop(ctx, now.add(const Duration(minutes: 15))),
            ),
            _ChannelReminderChoiceTile(
              label: 'In 1 hour',
              onTap: () =>
                  Navigator.pop(ctx, now.add(const Duration(hours: 1))),
            ),
            _ChannelReminderChoiceTile(
              label: 'Tomorrow morning',
              onTap: () => Navigator.pop(
                ctx,
                DateTime(now.year, now.month, now.day + 1, 9),
              ),
            ),
            _ChannelReminderChoiceTile(
              label: 'Pick date and time',
              onTap: () async {
                final date = await showDatePicker(
                  context: ctx,
                  initialDate: now.add(const Duration(days: 1)),
                  firstDate: now,
                  lastDate: now.add(const Duration(days: 365)),
                );
                if (date == null || !ctx.mounted) return;
                final time = await showTimePicker(
                  context: ctx,
                  initialTime: TimeOfDay.fromDateTime(
                    now.add(const Duration(hours: 1)),
                  ),
                );
                if (time == null || !ctx.mounted) return;
                Navigator.pop(
                  ctx,
                  DateTime(
                    date.year,
                    date.month,
                    date.day,
                    time.hour,
                    time.minute,
                  ),
                );
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    final preview = (msg.decryptedContent ?? msg.listPreview).trim();
    await context.read<SettingsProvider>().saveMessageReminder(
      conversationId: channel.id,
      messageId: msg.id,
      conversationTitle: channel.displayName(
        context.read<AuthProvider>().currentUser?.id ?? '',
      ),
      messagePreview: preview.isEmpty ? msg.listPreview : preview,
      remindAt: selected,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Reminder set for ${_formatReminderTime(selected)}'),
      ),
    );
  }

  String _formatReminderTime(DateTime value) {
    final local = value.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.month}/${local.day} $hour:$minute';
  }

  Future<void> _reportPost(Message msg) async {
    final reasonCtrl = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: const Text('Report post'),
        content: TextField(
          controller: reasonCtrl,
          autofocus: true,
          maxLength: 500,
          maxLines: 3,
          decoration: const InputDecoration(labelText: 'Reason'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, reasonCtrl.text.trim()),
            child: const Text('Report'),
          ),
        ],
      ),
    );
    reasonCtrl.dispose();
    if (reason == null || !mounted) return;
    try {
      await context.read<ApiService>().createModerationReport(
        channel.id,
        channel: true,
        messageID: msg.id,
        reportedUserID: msg.senderId,
        reason: reason,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Report sent')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to report: $e')));
    }
  }

  Future<void> _copyPostText(Message msg) async {
    await Clipboard.setData(ClipboardData(text: msg.decryptedContent ?? ''));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Post text copied')));
  }

  Future<void> _copyPostLink(Message msg) async {
    await Clipboard.setData(
      ClipboardData(
        text: messageDeepLink(conversationId: channel.id, messageId: msg.id),
      ),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Post link copied')));
  }

  Future<void> _downloadPostAttachment(Message msg) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final file = await saveMessageAttachment(
        message: msg,
        attachmentService: AttachmentService(context.read<ApiService>()),
      );
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Saved to ${file.path}')));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Download failed: $e')));
    }
  }

  bool _hasChannelPermission(String permission) =>
      _currentMember?.hasPermission(permission) ?? false;

  bool get _canManageChannelInfo =>
      _hasChannelPermission(AdminPermission.manageInfo);

  bool get _canManageChannelSettings =>
      _hasChannelPermission(AdminPermission.manageSettings);

  bool get _canManageChannelEncryption =>
      _hasChannelPermission(AdminPermission.manageEncryption);

  bool get _canManageChannelInvites =>
      _hasChannelPermission(AdminPermission.manageInvites);

  bool get _canManageChannelRoles =>
      _hasChannelPermission(AdminPermission.manageRoles);

  bool get _canManageChannelModeration =>
      _hasChannelPermission(AdminPermission.manageModeration);

  bool get _canDeleteChannelMessages =>
      _hasChannelPermission(AdminPermission.deleteMessages);

  bool get _canPostInBroadcastMode =>
      _hasChannelPermission(AdminPermission.postMessages);

  bool get _canPinChannelPosts {
    final user = context.read<AuthProvider>().currentUser;
    return _hasChannelPermission(AdminPermission.managePins) ||
        user?.isSystemAdmin == true;
  }

  Future<void> _setPostPinned(Message msg, bool pinned) async {
    final api = context.read<ApiService>();
    final settings = context.read<SettingsProvider>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (pinned) {
        await api.pinChannelPost(channel.id, msg.id);
        await settings.setChannelMessagePinned(
          channel.id,
          ChannelPinnedMessage(
            conversationId: channel.id,
            messageId: msg.id,
            preview: _pinnedMessagePreview(msg),
            messageCreatedAt: msg.createdAt,
            pinnedAt: DateTime.now(),
            senderUsername: msg.sender?.username,
            message: msg,
          ),
          true,
        );
      } else {
        await api.unpinChannelPost(channel.id, msg.id);
        await settings.unpinChannelMessage(channel.id, msg.id);
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(pinned ? 'Pin failed: $e' : 'Unpin failed: $e')),
      );
    }
  }

  String _pinnedMessagePreview(Message msg) {
    final preview = msg.listPreview.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (preview.isNotEmpty) return preview;
    return switch (msg.type) {
      MessageType.image => 'Photo',
      MessageType.video => 'Video',
      MessageType.voice => 'Voice message',
      MessageType.audio => 'Audio',
      MessageType.file => 'File',
      MessageType.sticker => 'Sticker',
      MessageType.poll => 'Poll',
      MessageType.location => 'Location',
      _ => 'Message',
    };
  }

  void _jumpToPinnedMessage(ChannelPinnedMessage pinnedMessage) {
    _jumpToPost(
      pinnedMessage.messageId,
      missingMessage: 'Pinned message is not loaded yet',
    );
  }

  void _jumpToPost(
    String messageId, {
    String missingMessage = 'Message is not loaded yet',
  }) {
    final postContext = _postKeys[messageId]?.currentContext;
    if (postContext == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(missingMessage)));
      return;
    }
    Scrollable.ensureVisible(
      postContext,
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeOutCubic,
      alignment: 0.35,
    );
    _highlightTimer?.cancel();
    setState(() => _highlightedPostId = messageId);
    _highlightTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _highlightedPostId = null);
    });
  }

  void _showPinnedMessagesSheet(
    List<ChannelPinnedMessage> pinnedMessages,
    bool canManagePins,
  ) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => GlassBottomSheetFrame(
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 12),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: Row(
                  children: [
                    const Icon(Icons.push_pin_rounded, size: 18),
                    const SizedBox(width: 10),
                    Text(
                      pinnedMessages.length == 1
                          ? 'Pinned message'
                          : '${pinnedMessages.length} pinned messages',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.52,
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: pinnedMessages.length,
                  itemBuilder: (context, index) {
                    final pinned = pinnedMessages[index];
                    return _PinnedMessageSheetTile(
                      pinnedMessage: pinned,
                      onTap: () {
                        Navigator.pop(ctx);
                        _jumpToPinnedMessage(pinned);
                      },
                      onUnpin: canManagePins
                          ? () {
                              Navigator.pop(ctx);
                              _unpinPinnedMessage(pinned);
                            }
                          : null,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _unpinPinnedMessage(ChannelPinnedMessage pinnedMessage) async {
    final api = context.read<ApiService>();
    final settings = context.read<SettingsProvider>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await api.unpinChannelPost(channel.id, pinnedMessage.messageId);
      await settings.unpinChannelMessage(channel.id, pinnedMessage.messageId);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Unpin failed: $e')));
    }
  }

  Future<void> _toggleReaction(Message msg, String emoji) async {
    final messenger = ScaffoldMessenger.of(context);
    if (msg is PendingMessage) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Post is still queued')),
      );
      return;
    }
    final alreadyReacted = msg.reactions.any(
      (reaction) => reaction.emoji == emoji && reaction.reactedByMe,
    );
    _setLocalReaction(msg.id, emoji, !alreadyReacted);
    if (!_ws.isMonitoring) {
      await _upsertOutboxItem(
        OfflineOutboxItem(
          id: _newChannelOutboxId(),
          action: OfflineOutboxAction.channelReaction,
          conversationId: channel.id,
          createdAt: DateTime.now(),
          data: {
            'message_id': msg.id,
            'emoji': emoji,
            'reacted': !alreadyReacted,
          },
        ),
        coalesceReaction: true,
      );
      return;
    }
    try {
      final api = context.read<ApiService>();
      if (alreadyReacted) {
        await api.removeReaction(msg.id, emoji);
      } else {
        await api.reactToMessage(msg.id, emoji);
      }
    } catch (e) {
      if (_shouldRetryOutboxError(e)) {
        await _upsertOutboxItem(
          OfflineOutboxItem(
            id: _newChannelOutboxId(),
            action: OfflineOutboxAction.channelReaction,
            conversationId: channel.id,
            createdAt: DateTime.now(),
            data: {
              'message_id': msg.id,
              'emoji': emoji,
              'reacted': !alreadyReacted,
            },
          ),
          coalesceReaction: true,
        );
        return;
      }
      _setLocalReaction(msg.id, emoji, alreadyReacted);
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('Reaction failed: $e')));
      }
    }
  }

  void _setLocalReaction(String msgID, String emoji, bool reacted) {
    final idx = _posts.indexWhere((post) => post.id == msgID);
    if (idx == -1) return;
    final reactions = _reactionsWithViewerState(
      _posts[idx].reactions,
      emoji: emoji,
      reacted: reacted,
    );
    if (!mounted) return;
    setState(() {
      _posts[idx] = _posts[idx].copyWith(reactions: reactions);
    });
  }

  List<MessageReactionSummary> _reactionsWithViewerState(
    List<MessageReactionSummary> reactions, {
    required String emoji,
    required bool reacted,
  }) {
    final next = List<MessageReactionSummary>.from(reactions);
    final reactionIdx = reactions.indexWhere(
      (reaction) => reaction.emoji == emoji,
    );
    if (reacted) {
      if (reactionIdx == -1) {
        next.add(
          MessageReactionSummary(emoji: emoji, count: 1, reactedByMe: true),
        );
      } else {
        final current = next[reactionIdx];
        next[reactionIdx] = current.copyWith(
          count: current.reactedByMe ? current.count : current.count + 1,
          reactedByMe: true,
        );
      }
    } else if (reactionIdx != -1) {
      final current = next[reactionIdx];
      final count = current.reactedByMe ? current.count - 1 : current.count;
      if (count <= 0) {
        next.removeAt(reactionIdx);
      } else {
        next[reactionIdx] = current.copyWith(count: count, reactedByMe: false);
      }
    }
    next.sort((a, b) {
      final count = b.count.compareTo(a.count);
      if (count != 0) return count;
      return a.emoji.compareTo(b.emoji);
    });
    return next;
  }

  Future<void> _deletePost(Message msg) async {
    final messenger = ScaffoldMessenger.of(context);
    final api = context.read<ApiService>();
    final settings = context.read<SettingsProvider>();
    try {
      await api.deleteMessage(channel.id, msg.id);
      await settings.unpinChannelMessage(channel.id, msg.id);
      if (mounted) {
        setState(() {
          _posts.removeWhere((p) => p.id == msg.id);
          _postKeys.remove(msg.id);
        });
      }
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
    _scheduleDraftSave(newText);
  }

  void _setComposerValue(TextEditingValue value) {
    _suppressInputEntityShift = true;
    _inputCtrl.value = value;
    _lastInputText = value.text;
    _suppressInputEntityShift = false;
    _updateMentionQuery(value);
  }

  List<ConversationMember> _mentionSuggestions(String currentUserId) {
    return mentionSuggestionsForMembers(
      members: channel.members,
      active: _activeMentionQuery,
      currentUserId: currentUserId,
    );
  }

  void _insertMention(ConversationMember member) {
    final username = member.user?.username.trim();
    if (username == null || username.isEmpty) return;
    final value = _inputCtrl.value;
    final active = value.selection.isValid && value.selection.isCollapsed
        ? findActiveMentionQuery(value.text, value.selection.baseOffset)
        : _activeMentionQuery;
    if (active == null) return;

    final oldText = value.text;
    final start = active.start.clamp(0, oldText.length).toInt();
    final end = active.end.clamp(start, oldText.length).toInt();
    final replacement = '@$username ';
    final newText = oldText.replaceRange(start, end, replacement);
    final shifted = shiftCustomEmojiEntitiesForTextEdit(
      oldText: oldText,
      newText: newText,
      entities: _customEmojiEntities,
    );

    setState(() {
      _activeMentionQuery = null;
      _showStickers = false;
      _showCustomEmojis = false;
      _syncCustomEmojiEntities(shifted);
    });
    _setComposerValue(
      TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: start + replacement.length),
      ),
    );
    _scheduleDraftSave(newText);
  }

  void _restoreComposer(String text, List<CustomEmojiEntity> entities) {
    _setComposerValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ),
    );
    setState(() => _syncCustomEmojiEntities(entities));
    _pendingDraftText = text;
    _pendingDraftEntities = entities;
    _pendingDraftSilent = _sendSilent;
    _pendingDraftScheduledFor = _scheduledFor;
    _hasPendingDraftSave = false;
    unawaited(
      _settings.setMessageDraft(
        channel.id,
        text,
        customEmojiEntities: entities,
        sendSilent: _sendSilent,
        scheduledFor: _scheduledFor,
      ),
    );
  }

  void _restoreLocalDraft() {
    if (_draftRestored) return;
    _draftRestored = true;
    final draft = _settings.messageDraftFor(widget.channel.id);
    if (draft == null || draft.isEmpty || _inputCtrl.text.isNotEmpty) return;
    final scheduledFor = draft.scheduledFor;
    final restoredSchedule =
        scheduledFor != null &&
            scheduledFor.isAfter(DateTime.now().add(const Duration(seconds: 5)))
        ? scheduledFor
        : null;
    _setComposerValue(
      TextEditingValue(
        text: draft.text,
        selection: TextSelection.collapsed(offset: draft.text.length),
      ),
    );
    setState(() {
      _sendSilent = draft.sendSilent;
      _scheduledFor = restoredSchedule;
      _syncCustomEmojiEntities(draft.customEmojiEntities);
    });
    _pendingDraftText = draft.text;
    _pendingDraftEntities = draft.customEmojiEntities;
    _pendingDraftSilent = draft.sendSilent;
    _pendingDraftScheduledFor = restoredSchedule;
  }

  void _scheduleDraftSave(String text) {
    _pendingDraftText = text;
    _pendingDraftEntities = [..._customEmojiEntities];
    _pendingDraftSilent = _sendSilent;
    _pendingDraftScheduledFor = _scheduledFor;
    _hasPendingDraftSave = true;
    _draftSaveTimer?.cancel();
    _draftSaveTimer = Timer(const Duration(milliseconds: 300), _flushDraftSave);
  }

  void _flushDraftSave() {
    if (!_hasPendingDraftSave) return;
    _hasPendingDraftSave = false;
    unawaited(
      _settings.setMessageDraft(
        channel.id,
        _pendingDraftText,
        customEmojiEntities: _pendingDraftEntities,
        sendSilent: _pendingDraftSilent,
        scheduledFor: _pendingDraftScheduledFor,
      ),
    );
  }

  void _setAttachmentUploadProgress(AttachmentUploadProgress progress) {
    if (!mounted) return;
    setState(() => _attachmentUploadProgress = progress);
  }

  void _clearAttachmentUploadProgress() {
    if (!mounted || _attachmentUploadProgress == null) return;
    setState(() => _attachmentUploadProgress = null);
  }

  Future<void> _showAttachmentPicker() async {
    final cameraSupported =
        kIsWeb ||
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;

    final choice = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => GlassBottomSheetFrame(
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
              icon: Icons.casino_outlined,
              label: 'Game',
              onTap: () => Navigator.pop(context, 'game'),
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
    );
    if (choice == null || !mounted) return;

    // Non-attachment actions handled separately.
    if (choice == 'poll') {
      await _showCreatePollDialog();
      return;
    }
    if (choice == 'game') {
      await showGameLauncher(context, convID: channel.id, isChannel: true);
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
    EncryptedAttachmentUpload? pending;
    VoiceNoteRecording? voiceNote;
    try {
      pending = switch (choice) {
        'gallery_image' => await attachmentService.pickImageForOutbox(
          onProgress: _setAttachmentUploadProgress,
        ),
        'camera_image' => await attachmentService.pickImageForOutbox(
          fromCamera: true,
          onProgress: _setAttachmentUploadProgress,
        ),
        'gallery_video' => await attachmentService.pickVideoForOutbox(
          onProgress: _setAttachmentUploadProgress,
        ),
        'file' => await attachmentService.pickFileForOutbox(
          onProgress: _setAttachmentUploadProgress,
        ),
        'voice' => await (() async {
          voiceNote = await showVoiceNoteRecorder(context);
          final note = voiceNote;
          if (note == null) return null;
          return attachmentService.prepareVoiceNoteForOutbox(
            note.file,
            duration: note.duration,
            onProgress: _setAttachmentUploadProgress,
          );
        })(),
        _ => null,
      };
    } catch (e) {
      _clearAttachmentUploadProgress();
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
    if (pending == null) {
      _clearAttachmentUploadProgress();
      return;
    }

    try {
      _setAttachmentUploadProgress(
        const AttachmentUploadProgress(stage: AttachmentUploadStage.sending),
      );
      if (_scheduledFor == null && !_ws.isMonitoring) {
        await _queueChannelAttachmentUpload(
          attachment: pending,
          silent: _sendSilent,
        );
        return;
      }
      final uploaded = await attachmentService.uploadEncryptedAttachment(
        pending,
        onProgress: _setAttachmentUploadProgress,
      );
      await _post(
        plaintextOverride: jsonEncode(uploaded.toPayloadJson()),
        messageType: uploaded.messageType.name,
        attachmentId: uploaded.attachmentId,
      );
    } catch (e) {
      if (_scheduledFor == null && _shouldRetryOutboxError(e)) {
        await _queueChannelAttachmentUpload(
          attachment: pending,
          silent: _sendSilent,
        );
        return;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Upload failed: $e')));
    } finally {
      _clearAttachmentUploadProgress();
    }
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
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(e.toString())));
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
                      decoration: const InputDecoration(labelText: 'Question'),
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 12),
                    for (var i = 0; i < optionCtrls.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: TextField(
                          controller: optionCtrls[i],
                          decoration: InputDecoration(
                            labelText: 'Option ${i + 1}',
                          ),
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
                                  () =>
                                      optionCtrls.add(TextEditingController()),
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
                    GlassListTile(
                      title: const Text(
                        'Anonymous',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      trailing: GlassSwitch(
                        value: anonymous,
                        onChanged: (v) => setDialog(() => anonymous = v),
                        activeColor: Theme.of(context).colorScheme.primary,
                        enableHaptics: true,
                      ),
                      onTap: () => setDialog(() => anonymous = !anonymous),
                    ),
                    GlassListTile(
                      title: const Text(
                        'Multiple answers',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      trailing: GlassSwitch(
                        value: multiple,
                        onChanged: (v) => setDialog(() => multiple = v),
                        activeColor: Theme.of(context).colorScheme.primary,
                        enableHaptics: true,
                      ),
                      onTap: () => setDialog(() => multiple = !multiple),
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
    final canManagePins = _canPinChannelPosts;
    final isArchived = _archived || channel.isArchived;
    final settings = context.watch<SettingsProvider>();
    final pinnedMessages = settings.pinnedMessagesForChannel(channel.id);
    final chatStyle = settings.chatStyleFor(channel.id);
    final meBubbleColor = chatStyle.myBubbleColor != null
        ? Color(chatStyle.myBubbleColor!)
        : auth.currentUser?.bubbleColor != null
        ? Color(auth.currentUser!.bubbleColor!)
        : null;
    final mentionSuggestions = _mentionSuggestions(currentUserId);
    final actionPlacement = ChannelActionPolicy.actionsFor(
      channel: channel,
      isAdmin: _isAdmin,
      isPremium: isPremium,
      canManageLifecycle: canManageLifecycle,
      isSubscribed: _isSubscribed,
      canOpenModeration: _canManageChannelModeration || _canManageChannelRoles,
      canManageInfo: _canManageChannelInfo,
      canManageInvites: _canManageChannelInvites,
      canManageSettings: _canManageChannelSettings,
      canManageEncryption: _canManageChannelEncryption,
      canViewAnalytics: _isAdmin,
    );

    return Scaffold(
      extendBodyBehindAppBar: true,
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
          SizedBox(
            height: MediaQuery.paddingOf(context).top + kToolbarHeight,
          ),
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
          if (pinnedMessages.isNotEmpty)
            _PinnedChannelMessagesBar(
              latestPinnedMessage: pinnedMessages.first,
              pinnedCount: pinnedMessages.length,
              onTap: () => _jumpToPinnedMessage(pinnedMessages.first),
              onShowAll: () =>
                  _showPinnedMessagesSheet(pinnedMessages, canManagePins),
            ),
          Expanded(
            child: DecoratedBox(
              decoration: _channelBackground(),
              child: _loading
                  ? const Center(child: GlassProgressIndicator.circular())
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
                        final isPinned = settings.isChannelMessagePinned(
                          channel.id,
                          msg.id,
                        );
                        final showAvatar =
                            !isMe &&
                            (i == _posts.length - 1 ||
                                _posts[i + 1].senderId != msg.senderId);
                        final postKey = _postKeys.putIfAbsent(
                          msg.id,
                          GlobalKey.new,
                        );
                        return KeyedSubtree(
                          key: postKey,
                          child: _AnimatedChannelPost(
                            id: msg.id,
                            child: _PinnedChannelPostFrame(
                              isPinned: isPinned,
                              isHighlighted: _highlightedPostId == msg.id,
                              isMe: isMe,
                              child: MessageBubble(
                                message: msg,
                                isMe: isMe,
                                isChannel: true,
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
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),

          if (_showCustomEmojis)
            CustomEmojiPicker(onEmojiSelected: _insertCustomEmoji),
          if (_showStickers) StickerPicker(onStickerSelected: _sendSticker),
          if (_attachmentUploadProgress != null)
            AttachmentUploadProgressChip(progress: _attachmentUploadProgress!),
          // Admins can always post. When admin-only posting is OFF, any
          // subscriber can post too. Archived channels are read-only.
          if ((_canPostInBroadcastMode ||
                  (!channel.ownerOnlyPost && _isSubscribed)) &&
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
              mentionSuggestions: mentionSuggestions,
              onMentionSelected: _insertMention,
              onPost: _post,
            ),
        ],
      ),
    );
  }
}

class _PinnedChannelMessagesBar extends StatelessWidget {
  final ChannelPinnedMessage latestPinnedMessage;
  final int pinnedCount;
  final VoidCallback onTap;
  final VoidCallback onShowAll;

  const _PinnedChannelMessagesBar({
    required this.latestPinnedMessage,
    required this.pinnedCount,
    required this.onTap,
    required this.onShowAll,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: GlassContainer(
          shape: const LiquidRoundedSuperellipse(borderRadius: 22),
          allowElevation: true,
          glowIntensity: 0.05,
          padding: const EdgeInsets.fromLTRB(12, 9, 6, 9),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 34,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(width: 10),
              Icon(Icons.push_pin_rounded, size: 18, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      pinnedCount == 1
                          ? 'Pinned message'
                          : '$pinnedCount pinned messages',
                      style: TextStyle(
                        color: scheme.primary,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      latestPinnedMessage.preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurface.withValues(alpha: 0.72),
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Pinned messages',
                icon: const Icon(Icons.keyboard_arrow_down_rounded),
                onPressed: onShowAll,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PinnedMessageSheetTile extends StatelessWidget {
  final ChannelPinnedMessage pinnedMessage;
  final VoidCallback onTap;
  final VoidCallback? onUnpin;

  const _PinnedMessageSheetTile({
    required this.pinnedMessage,
    required this.onTap,
    this.onUnpin,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassListTile(
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: scheme.primary.withValues(alpha: 0.12),
        child: Icon(Icons.push_pin_rounded, size: 17, color: scheme.primary),
      ),
      title: Text(
        pinnedMessage.preview,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: pinnedMessage.senderUsername == null
          ? null
          : Text('@${pinnedMessage.senderUsername}'),
      trailing: onUnpin == null
          ? null
          : IconButton(
              tooltip: 'Unpin message',
              icon: const Icon(Icons.close_rounded),
              onPressed: onUnpin,
            ),
      onTap: onTap,
    );
  }
}

class _PinnedChannelPostFrame extends StatelessWidget {
  final bool isPinned;
  final bool isHighlighted;
  final bool isMe;
  final Widget child;

  const _PinnedChannelPostFrame({
    required this.isPinned,
    required this.isHighlighted,
    required this.isMe,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (!isPinned && !isHighlighted) return child;
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      margin: EdgeInsets.symmetric(vertical: isHighlighted ? 4 : 0),
      padding: EdgeInsets.symmetric(
        horizontal: isHighlighted ? 6 : 0,
        vertical: isHighlighted ? 4 : 0,
      ),
      decoration: isHighlighted
          ? BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: scheme.primary.withValues(alpha: 0.22),
                width: 0.8,
              ),
            )
          : null,
      child: Column(
        crossAxisAlignment: isMe
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isPinned)
            Padding(
              padding: EdgeInsets.only(
                left: isMe ? 0 : 40,
                right: isMe ? 6 : 0,
                bottom: 2,
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.11),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.push_pin_rounded,
                      size: 12,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Pinned',
                      style: TextStyle(
                        color: scheme.primary,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          child,
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
  final List<ConversationMember> mentionSuggestions;
  final VoidCallback onToggleCustomEmojis;
  final VoidCallback onToggleStickers;
  final VoidCallback onAttach;
  final VoidCallback? onOptions;
  final ValueChanged<ConversationMember> onMentionSelected;
  final bool hasOptions;
  final VoidCallback onPost;

  const ChannelPostBar({
    super.key,
    required this.controller,
    required this.showStickers,
    required this.showCustomEmojis,
    this.mentionSuggestions = const [],
    required this.onToggleCustomEmojis,
    required this.onToggleStickers,
    required this.onAttach,
    this.onOptions,
    required this.onMentionSelected,
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (mentionSuggestions.isNotEmpty)
                MentionAutocompletePanel(
                  members: mentionSuggestions,
                  onSelected: onMentionSelected,
                ),
              Row(
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
                      showStickers
                          ? Icons.keyboard
                          : Icons.sticky_note_2_outlined,
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
                  GlassCircleIconButton(
                    onPressed: onAttach,
                    tooltip: 'Attach file',
                    icon: const Icon(Icons.attach_file_outlined, size: 22),
                  ),
                  const SizedBox(width: 4),
                  Tooltip(
                    message: 'Hold for post options',
                    child: GestureDetector(
                      onTap: onPost,
                      onLongPress: onOptions,
                      child: GlassContainer(
                        shape: const LiquidRoundedSuperellipse(
                          borderRadius: 999,
                        ),
                        allowElevation: true,
                        glowIntensity: 0.08,
                        padding: const EdgeInsets.all(12),
                        child: Icon(
                          hasOptions
                              ? Icons.schedule_send_outlined
                              : Icons.send,
                          size: 18,
                        ),
                      ),
                    ),
                  ),
                ],
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
    return GlassListTile(
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: tint.withValues(alpha: 0.12),
        ),
        child: Icon(icon, size: 18, color: tint),
      ),
      title: Text(
        label,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 15,
          color: color,
        ),
      ),
      onTap: onTap,
    );
  }
}

class _ChannelReminderChoiceTile extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _ChannelReminderChoiceTile({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GlassListTile(
      leading: const Icon(Icons.alarm_outlined, size: 20),
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      onTap: onTap,
    );
  }
}
