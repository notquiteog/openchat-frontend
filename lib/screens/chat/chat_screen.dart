import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../../config/api_config.dart';
import '../../models/conversation.dart';
import '../../models/message.dart';
import '../../providers/auth_provider.dart';
import '../../providers/call_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/key_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/api_service.dart';
import '../../services/call_service.dart';
import '../../services/notification_service.dart';
import '../../services/attachment_service.dart';
import '../../services/secure_storage_service.dart';
import '../../widgets/message_bubble.dart';
import '../../widgets/sticker_picker.dart';
import '../profile/user_profile_screen.dart';

class ChatScreen extends StatefulWidget {
  final Conversation conversation;
  const ChatScreen({super.key, required this.conversation});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  bool _showStickers = false;
  bool _loadingMore = false;
  Message? _replyingTo;
  Timer? _typingTimer;
  bool _biometricKeyEnabled = false;

  // Read the live conversation from the provider (members get loaded
  // asynchronously after the screen opens) and fall back to the one passed in.
  // build() watches ChatProvider, so updates here trigger a rebuild.
  Conversation get conv {
    for (final c in context.read<ChatProvider>().conversations) {
      if (c.id == widget.conversation.id) return c;
    }
    return widget.conversation;
  }

  @override
  void initState() {
    super.initState();
    NotificationService.setActiveConversation(widget.conversation.id);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Capture context-dependent reads before the async gap.
      final storage = context.read<SecureStorageService>();
      final chat = context.read<ChatProvider>();
      _biometricKeyEnabled = await storage.shouldRequireBiometricKeyUnlock();
      if (mounted) setState(() {});
      chat.loadMessages(conv.id);
      chat.loadConversationMembers(conv.id);
    });
    _scrollCtrl.addListener(_onScroll);
  }

  Future<void> _unlockAndReload() async {
    final keys = context.read<KeyProvider>();
    final ok = await keys.authenticateAndUnlockKey();
    if (ok && mounted) {
      context.read<ChatProvider>().loadMessages(conv.id);
    }
  }

  void _onScroll() {
    if (_loadingMore) return;
    if (_scrollCtrl.position.pixels <= 100) {
      setState(() => _loadingMore = true);
      context.read<ChatProvider>().loadMoreMessages(conv.id).whenComplete(() {
        if (mounted) setState(() => _loadingMore = false);
      });
    }
  }

  @override
  void dispose() {
    NotificationService.setActiveConversation(null);
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _typingTimer?.cancel();
    super.dispose();
  }

  void _onTyping() {
    _typingTimer?.cancel();
    context.read<ChatProvider>().sendTyping(conv.id);
    _typingTimer = Timer(const Duration(seconds: 3), () {});
  }

  String _typingLabel(Set<String> userIDs, String currentUserID) {
    final names = userIDs.where((id) => id != currentUserID).map((id) {
      for (final m in conv.members) {
        if (m.userId == id) return m.user?.username ?? 'Someone';
      }
      return 'Someone';
    }).toList();
    if (names.isEmpty) return '';
    if (names.length == 1) return '${names[0]} is typing…';
    if (names.length == 2) return '${names[0]}, ${names[1]} are typing…';
    return '${names[0]} and ${names.length - 1} others are typing…';
  }

  Future<void> _sendMessage() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty) return;
    _inputCtrl.clear();
    final messenger = ScaffoldMessenger.of(context);
    final replyTo = _replyingTo?.id;
    final replyingTo = _replyingTo;
    setState(() {
      _showStickers = false;
      _replyingTo = null;
    });
    try {
      final sent = await context.read<ChatProvider>().sendMessage(
            convID: conv.id,
            plaintext: text,
            replyTo: replyTo,
          );
      if (!mounted) return;
      if (sent) {
        _scrollToBottom();
      } else {
        _restoreComposedMessage(text, replyingTo);
        messenger.showSnackBar(
          const SnackBar(content: Text('Message could not be sent')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      _restoreComposedMessage(text, replyingTo);
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _sendSticker(String stickerID) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _showStickers = false;
      _replyingTo = null;
    });
    try {
      final sent = await context.read<ChatProvider>().sendMessage(
            convID: conv.id,
            plaintext: stickerID,
            messageType: 'sticker',
          );
      if (sent) {
        _scrollToBottom();
      } else if (mounted) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Sticker could not be sent')),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  void _restoreComposedMessage(String text, Message? replyingTo) {
    if (_inputCtrl.text.isEmpty) {
      _inputCtrl.text = text;
      _inputCtrl.selection = TextSelection.collapsed(offset: text.length);
    }
    setState(() => _replyingTo = replyingTo);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _showAttachmentPicker() async {
    // image_picker's camera source is only implemented on mobile (and web);
    // on desktop it throws "requires a cameraDelegate", so only offer it where
    // it actually works.
    final cameraSupported = kIsWeb ||
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;

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
            if (cameraSupported)
              ListTile(
                leading: const Icon(Icons.camera_alt),
                title: const Text('Take photo'),
                onTap: () => Navigator.pop(context, 'camera_image'),
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

    final attachmentService = AttachmentService(
      context.read(), // ApiService
    );

    PendingAttachment? pending;
    try {
      pending = switch (choice) {
        'gallery_image' => await attachmentService.pickImage(),
        'camera_image' => await attachmentService.pickImage(fromCamera: true),
        'gallery_video' => await attachmentService.pickVideo(),
        'file' => await attachmentService.pickFile(),
        _ => null,
      };
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: $e')),
        );
      }
      return;
    }

    if (pending == null || !mounted) return;

    try {
      final sent = await context.read<ChatProvider>().sendAttachment(
            convID: conv.id,
            attachment: pending,
          );
      if (sent) {
        _scrollToBottom();
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Attachment could not be sent')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }
  }

  Future<void> _startCall({required bool isVideo}) async {
    final auth = context.read<AuthProvider>();
    final callProvider = context.read<CallProvider>();
    final api = context.read<ApiService>();
    final callService = context.read<CallService>();

    // For DMs, call the other person
    final otherMember = conv.members
        .where((m) => m.userId != (auth.currentUser?.id ?? ''))
        .firstOrNull;

    if (otherMember == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Cannot start call in a group — open a DM first')),
      );
      return;
    }

    // Refresh ICE/TURN servers immediately before dialing: TURN credentials are
    // short-lived, so the set fetched at login may have expired.
    try {
      final servers = await api.getIceServers();
      if (servers.isNotEmpty) callService.updateIceServers(servers);
    } catch (_) {
      // Fall back to whatever servers are already configured.
    }

    // The root CallOverlay shows the call UI off CallProvider state, so we just
    // start the call — no navigation needed.
    try {
      await callProvider.startCall(
        targetUserId: otherMember.userId,
        targetUsername: otherMember.user?.username,
        conversationId: conv.id,
        isVideo: isVideo,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not start call: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final chat = context.watch<ChatProvider>();
    final keys = context.watch<KeyProvider>();
    final messages = chat.messagesFor(conv.id);
    final currentUserID = auth.currentUser?.id ?? '';
    final typingUsers = chat.typingUsersFor(conv.id);
    final keyLocked = _biometricKeyEnabled && !keys.isKeySessionUnlocked;

    // Per-DM look (background + bubble colour/shape). Only DMs are customizable.
    final dmStyle = conv.isDM
        ? context.watch<SettingsProvider>().dmStyleFor(conv.id)
        : const DmChatStyle();
    final meBubbleColor =
        dmStyle.myBubbleColor != null ? Color(dmStyle.myBubbleColor!) : null;
    final theirBubbleColor = dmStyle.theirBubbleColor != null
        ? Color(dmStyle.theirBubbleColor!)
        : null;

    return Scaffold(
      appBar: _buildAppBar(context, typingUsers, currentUserID),
      body: Column(
        children: [
          if (keyLocked) _KeyLockedBanner(onUnlock: _unlockAndReload),
          Expanded(
            child: DecoratedBox(
              decoration: _chatBackground(dmStyle),
              child: GestureDetector(
                onTap: () => setState(() => _showStickers = false),
                child: messages.isEmpty
                    ? const Center(child: Text('No messages yet'))
                    : ListView.builder(
                        controller: _scrollCtrl,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 8),
                        itemCount: messages.length,
                        itemBuilder: (context, i) {
                          final msg = messages[i];
                          final isMe = msg.senderId == currentUserID;
                          final showAvatar = !isMe &&
                              (i == 0 ||
                                  messages[i - 1].senderId != msg.senderId);
                          return MessageBubble(
                            message: msg,
                            isMe: isMe,
                            showAvatar: showAvatar,
                            meBubbleColor: meBubbleColor,
                            theirBubbleColor: theirBubbleColor,
                            bubbleRadius: dmStyle.bubbleRadius,
                            onLongPress: () =>
                                _showMessageMenu(context, msg, isMe),
                            onAvatarTap: msg.sender != null
                                ? () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => UserProfileScreen(
                                            user: msg.sender!),
                                      ),
                                    )
                                : null,
                          );
                        },
                      ),
              ),
            ),
          ),
          if (_showStickers) StickerPicker(onStickerSelected: _sendSticker),
          if (typingUsers.isNotEmpty)
            _TypingIndicator(
              label: _typingLabel(typingUsers, currentUserID),
            ),
          _buildInputBar(context),
        ],
      ),
    );
  }

  /// Background behind the message list. A premium conversation-wide image
  /// (set by an admin, visible to everyone) wins; otherwise the viewer's own
  /// per-DM background image or colour applies.
  Decoration _chatBackground(DmChatStyle style) {
    final convBg = conv.backgroundUrl;
    if (convBg != null && convBg.isNotEmpty) {
      return BoxDecoration(
        image: DecorationImage(
          image: CachedNetworkImageProvider(ApiConfig.resolveMedia(convBg)),
          fit: BoxFit.cover,
        ),
      );
    }
    if (style.backgroundImagePath != null) {
      return BoxDecoration(
        image: DecorationImage(
          image: FileImage(File(style.backgroundImagePath!)),
          fit: BoxFit.cover,
        ),
      );
    }
    if (style.backgroundColor != null) {
      return BoxDecoration(color: Color(style.backgroundColor!));
    }
    return const BoxDecoration();
  }

  /// Per-DM appearance editor: chat background (colour or image) and the user's
  /// own bubble colour + corner shape. DMs only — groups/channels stay uniform.
  Future<void> _showChatAppearance(BuildContext context) async {
    final settings = context.read<SettingsProvider>();
    final convID = conv.id;
    var style = settings.dmStyleFor(convID);

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheet) {
          void apply(DmChatStyle next) {
            style = next;
            settings.setDmStyle(convID, next);
            setSheet(() {});
          }

          return SafeArea(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('Chat appearance',
                            style: Theme.of(sheetCtx).textTheme.titleMedium),
                        const Spacer(),
                        TextButton(
                          onPressed: () => apply(const DmChatStyle()),
                          child: const Text('Reset'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text('Background colour'),
                    const SizedBox(height: 8),
                    _ColorChoices(
                      selected: style.backgroundColor,
                      onSelected: (c) => apply(c == null
                          ? style.copyWith(clearBackgroundColor: true)
                          : style.copyWith(
                              backgroundColor: c, clearBackgroundImage: true)),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        OutlinedButton.icon(
                          icon: const Icon(Icons.image_outlined, size: 18),
                          label: const Text('Background image'),
                          onPressed: () async {
                            final picked = await ImagePicker().pickImage(
                                source: ImageSource.gallery, imageQuality: 90);
                            if (picked != null) {
                              apply(style.copyWith(
                                  backgroundImagePath: picked.path,
                                  clearBackgroundColor: true));
                            }
                          },
                        ),
                        if (style.backgroundImagePath != null)
                          TextButton(
                            onPressed: () => apply(
                                style.copyWith(clearBackgroundImage: true)),
                            child: const Text('Remove'),
                          ),
                      ],
                    ),
                    const Divider(height: 24),
                    const Text('My bubble colour'),
                    const SizedBox(height: 8),
                    _ColorChoices(
                      selected: style.myBubbleColor,
                      onSelected: (c) => apply(c == null
                          ? style.copyWith(clearMyBubbleColor: true)
                          : style.copyWith(myBubbleColor: c)),
                    ),
                    const SizedBox(height: 12),
                    const Text('Their bubble colour'),
                    const SizedBox(height: 8),
                    _ColorChoices(
                      selected: style.theirBubbleColor,
                      onSelected: (c) => apply(c == null
                          ? style.copyWith(clearTheirBubbleColor: true)
                          : style.copyWith(theirBubbleColor: c)),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const Text('Bubble shape'),
                        Expanded(
                          child: Slider(
                            value: style.bubbleRadius,
                            min: 0,
                            max: 28,
                            divisions: 14,
                            label: style.bubbleRadius.round().toString(),
                            onChanged: (v) =>
                                apply(style.copyWith(bubbleRadius: v)),
                          ),
                        ),
                      ],
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

  /// Premium users can set a shared background on group chats (admins only) and
  /// bot chats. Regular DMs use the personal "Chat appearance" instead, and
  /// channels are handled from the channel screen.
  bool _canSetConversationBackground(String currentUserID) {
    final user = context.read<AuthProvider>().currentUser;
    if (user == null || !user.isPremium) return false;
    if (conv.isBotDM(currentUserID)) return true;
    if (conv.isGroup) {
      return conv.members.any((m) => m.userId == currentUserID && m.isAdmin);
    }
    return false;
  }

  Future<void> _setConversationBackground(BuildContext context) async {
    final api = context.read<ApiService>();
    final chat = context.read<ChatProvider>();
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
            if (conv.backgroundUrl != null)
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
        await api.setConversationBackground(conv.id, null);
      } else {
        final picked = await ImagePicker()
            .pickImage(source: ImageSource.gallery, imageQuality: 90);
        if (picked == null) return;
        final bytes = await picked.readAsBytes();
        // uploadAvatar re-encodes to WEBP with all metadata stripped, exactly
        // what a shared background needs.
        final url =
            await api.uploadAvatar(fileBytes: bytes, filename: picked.name);
        await api.setConversationBackground(conv.id, url);
      }
      await chat.loadConversations();
      messenger.showSnackBar(
        const SnackBar(content: Text('Chat background updated')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  PreferredSizeWidget _buildAppBar(
      BuildContext context, Set<String> typingUsers, String currentUserID) {
    final name = conv.displayName(currentUserID);
    final typingLabel = _typingLabel(typingUsers, currentUserID);
    final subtitle = typingLabel.isNotEmpty
        ? typingLabel
        : conv.isGroup
            ? '${conv.members.length} members'
            : 'tap for info';

    final dmPartner = !conv.isGroup
        ? conv.members.where((m) => m.userId != currentUserID).firstOrNull?.user
        : null;
    final avatarUrl = conv.displayAvatar(currentUserID);

    void openInfo() {
      if (dmPartner != null) {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => UserProfileScreen(user: dmPartner)),
        );
      } else {
        _showConversationInfo(context, currentUserID);
      }
    }

    return AppBar(
      titleSpacing: 0,
      title: InkWell(
        onTap: openInfo,
        child: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundImage: avatarUrl != null
                  ? CachedNetworkImageProvider(
                      ApiConfig.resolveMedia(avatarUrl))
                  : null,
              child: avatarUrl == null
                  ? (conv.isGroup
                      ? const Icon(Icons.group, size: 18)
                      : Text(name.isNotEmpty ? name[0].toUpperCase() : '?'))
                  : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(name,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: typingUsers.isNotEmpty
                          ? Colors.green
                          : Colors.grey[400],
                    ),
                  ),
                  if (conv.messageTtlSeconds > 0)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.timer_outlined,
                            size: 12, color: Colors.grey[400]),
                        const SizedBox(width: 3),
                        Text(
                          'Disappearing · ${_ttlLabel(conv.messageTtlSeconds)}',
                          style:
                              TextStyle(fontSize: 11, color: Colors.grey[400]),
                        ),
                      ],
                    ),
                  if (!conv.isDM)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          conv.encryptionEnabled
                              ? Icons.lock_outline
                              : Icons.lock_open_outlined,
                          size: 12,
                          color: Colors.grey[400],
                        ),
                        const SizedBox(width: 3),
                        Text(
                          conv.encryptionEnabled
                              ? 'Encrypted'
                              : 'Encryption off',
                          style:
                              TextStyle(fontSize: 11, color: Colors.grey[400]),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        // Audio call (DMs only)
        if (!conv.isGroup) ...[
          IconButton(
            icon: const Icon(Icons.call),
            tooltip: 'Voice call',
            onPressed: () => _startCall(isVideo: false),
          ),
          IconButton(
            icon: const Icon(Icons.videocam),
            tooltip: 'Video call',
            onPressed: () => _startCall(isVideo: true),
          ),
        ],
        PopupMenuButton<String>(
          onSelected: (v) {
            switch (v) {
              case 'info':
                _showConversationInfo(context, currentUserID);
              case 'edit':
                _editGroup(context, currentUserID);
              case 'members':
                _showMembers(context, currentUserID);
              case 'appearance':
                _showChatAppearance(context);
              case 'background':
                _setConversationBackground(context);
              case 'disappearing':
                _setDisappearing(context);
              case 'encryption':
                _setEncryption(context);
              case 'delete':
                _deleteConversation(context);
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(
                value: 'info', child: Text('Conversation info')),
            if (conv.isDM ||
                conv.members.any((m) => m.userId == currentUserID && m.isAdmin))
              const PopupMenuItem(
                  value: 'disappearing', child: Text('Disappearing messages')),
            if (!conv.isDM &&
                conv.members.any((m) => m.userId == currentUserID && m.isAdmin))
              PopupMenuItem(
                value: 'encryption',
                child: Text(conv.encryptionEnabled
                    ? 'Turn encryption off'
                    : 'Turn encryption on'),
              ),
            if (conv.isGroup)
              const PopupMenuItem(value: 'edit', child: Text('Edit group')),
            if (conv.isGroup)
              const PopupMenuItem(value: 'members', child: Text('Members')),
            // Per-DM look: backgrounds + bubble colour/shape (DMs only).
            if (conv.isDM)
              const PopupMenuItem(
                  value: 'appearance', child: Text('Chat appearance')),
            // Premium conversation-wide background, visible to everyone.
            if (_canSetConversationBackground(currentUserID))
              const PopupMenuItem(
                  value: 'background', child: Text('Set chat background')),
            const PopupMenuItem(
              value: 'delete',
              child: Text('Delete conversation',
                  style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildInputBar(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border:
            Border(top: BorderSide(color: Colors.grey.withValues(alpha: 0.2))),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_replyingTo != null) _buildReplyPreview(context),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(_showStickers
                        ? Icons.keyboard
                        : Icons.emoji_emotions_outlined),
                    onPressed: () =>
                        setState(() => _showStickers = !_showStickers),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _inputCtrl,
                      onChanged: (_) => _onTyping(),
                      onSubmitted: (_) => _sendMessage(),
                      maxLines: null,
                      textInputAction: TextInputAction.send,
                      decoration: InputDecoration(
                        hintText: 'Message',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        filled: true,
                        fillColor: Colors.grey.withValues(alpha: 0.1),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.attach_file_outlined),
                    onPressed: _showAttachmentPicker,
                  ),
                  FilledButton(
                    onPressed: _sendMessage,
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
          ],
        ),
      ),
    );
  }

  Widget _buildReplyPreview(BuildContext context) {
    final msg = _replyingTo!;
    final senderName = msg.sender?.username ?? 'Unknown';
    final preview = msg.decryptedContent ?? 'Encrypted message';
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(
          left: BorderSide(
              color: Theme.of(context).colorScheme.primary, width: 3),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  senderName,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.primary,
                    fontSize: 13,
                  ),
                ),
                Text(
                  preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() => _replyingTo = null),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  void _showMessageMenu(BuildContext context, Message msg, bool isMe) {
    // Call events (and other system messages) carry no user text to copy or
    // reply to — only offer deletion. In a DM either participant can delete any
    // message; elsewhere only the sender can.
    final isSystem = msg.type == MessageType.system;
    final canDelete = isMe || conv.isDM;
    showDialog<void>(
      context: context,
      builder: (_) => SimpleDialog(
        children: [
          if (!isSystem && msg.isDecrypted)
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy text'),
              onTap: () {
                Clipboard.setData(
                    ClipboardData(text: msg.decryptedContent ?? ''));
                Navigator.pop(context);
              },
            ),
          if (!isSystem)
            ListTile(
              leading: const Icon(Icons.reply),
              title: const Text('Reply'),
              onTap: () {
                Navigator.pop(context);
                setState(() => _replyingTo = msg);
              },
            ),
          // Only the sender can edit, and only plain-text messages.
          if (isMe && msg.type == MessageType.text && msg.isDecrypted)
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit'),
              onTap: () {
                Navigator.pop(context);
                _editMessage(msg);
              },
            ),
          if (canDelete)
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Delete', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(context);
                context.read<ChatProvider>().deleteMessage(conv.id, msg.id);
              },
            ),
        ],
      ),
    );
  }

  String _ttlLabel(int seconds) {
    if (seconds % 604800 == 0) return '${seconds ~/ 604800}w';
    if (seconds % 86400 == 0) return '${seconds ~/ 86400}d';
    if (seconds % 3600 == 0) return '${seconds ~/ 3600}h';
    if (seconds % 60 == 0) return '${seconds ~/ 60}m';
    return '${seconds}s';
  }

  Future<void> _setDisappearing(BuildContext context) async {
    final api = context.read<ApiService>();
    final chat = context.read<ChatProvider>();
    final messenger = ScaffoldMessenger.of(context);
    const options = <(String, int)>[
      ('Off', 0),
      ('1 hour', 3600),
      ('1 day', 86400),
      ('1 week', 604800),
    ];
    final current = conv.messageTtlSeconds;
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
      await api.setMessageTtl(conv.id, chosen);
      await chat.loadConversations();
      messenger.showSnackBar(SnackBar(
        content: Text(chosen == 0
            ? 'Disappearing messages turned off'
            : 'Messages now disappear after ${options.firstWhere((o) => o.$2 == chosen).$1}'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<void> _setEncryption(BuildContext context) async {
    final api = context.read<ApiService>();
    final chat = context.read<ChatProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final nextEnabled = !conv.encryptionEnabled;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title:
            Text(nextEnabled ? 'Turn encryption on?' : 'Turn encryption off?'),
        content: const Text(
          'Changing encryption wipes all current messages in this chat for everyone.',
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
      await api.setEncryptionEnabled(conv.id, nextEnabled);
      await chat.loadConversations();
      await chat.loadMessages(conv.id);
      messenger.showSnackBar(SnackBar(
        content: Text(
            nextEnabled ? 'Encryption turned on' : 'Encryption turned off'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<void> _editMessage(Message msg) async {
    final ctrl = TextEditingController(text: msg.decryptedContent ?? '');
    final chat = context.read<ChatProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final newText = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit message'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: null,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newText == null || newText.isEmpty || newText == msg.decryptedContent) {
      return;
    }
    try {
      await chat.editMessage(
          convID: conv.id, msgID: msg.id, newPlaintext: newText);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed to edit: $e')));
    }
  }

  void _showConversationInfo(BuildContext context, String currentUserID) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(conv.displayName(currentUserID)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (conv.description != null && conv.description!.isNotEmpty) ...[
              Text(conv.description!),
              const SizedBox(height: 8),
            ],
            Text(
              '${conv.members.length} member${conv.members.length == 1 ? '' : 's'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
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

  void _editGroup(BuildContext context, String currentUserID) {
    final isAdmin =
        conv.members.any((m) => m.userId == currentUserID && m.isAdmin);
    if (!isAdmin) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only group admins can edit the group')),
      );
      return;
    }

    final nameCtrl = TextEditingController(text: conv.name ?? '');
    final descCtrl = TextEditingController(text: conv.description ?? '');
    String? pendingAvatar = conv.avatarUrl;
    bool uploading = false;

    showDialog<void>(
      context: context,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx, setSt) {
          final api = context.read<ApiService>();
          final messenger = ScaffoldMessenger.of(context);
          Future<void> pickAvatar() async {
            final picked = await ImagePicker()
                .pickImage(source: ImageSource.gallery, imageQuality: 90);
            if (picked == null) return;
            setSt(() => uploading = true);
            try {
              final bytes = await picked.readAsBytes();
              final url = await api.uploadAvatar(
                  fileBytes: bytes, filename: picked.name);
              setSt(() {
                pendingAvatar = url;
                uploading = false;
              });
            } catch (e) {
              setSt(() => uploading = false);
              messenger
                  .showSnackBar(SnackBar(content: Text('Upload failed: $e')));
            }
          }

          return AlertDialog(
            title: const Text('Edit group'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: uploading ? null : pickAvatar,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      CircleAvatar(
                        radius: 40,
                        backgroundImage: pendingAvatar != null
                            ? CachedNetworkImageProvider(
                                ApiConfig.resolveMedia(pendingAvatar!))
                            : null,
                        child: pendingAvatar == null
                            ? const Icon(Icons.group, size: 32)
                            : null,
                      ),
                      if (uploading) const CircularProgressIndicator(),
                      if (!uploading)
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: CircleAvatar(
                            radius: 12,
                            backgroundColor: Theme.of(dctx).colorScheme.primary,
                            child: const Icon(Icons.camera_alt,
                                size: 14, color: Colors.white),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: 'Group name'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: descCtrl,
                  decoration: const InputDecoration(labelText: 'Description'),
                  maxLines: 2,
                ),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dctx),
                  child: const Text('Cancel')),
              FilledButton(
                onPressed: uploading
                    ? null
                    : () async {
                        final name = nameCtrl.text.trim();
                        final desc = descCtrl.text.trim();
                        final api = context.read<ApiService>();
                        final chat = context.read<ChatProvider>();
                        final messenger = ScaffoldMessenger.of(context);
                        Navigator.pop(dctx);
                        try {
                          await api.updateConversation(
                            conv.id,
                            name: name.isEmpty ? null : name,
                            description: desc.isEmpty ? null : desc,
                            avatarUrl: pendingAvatar,
                          );
                          await chat.loadConversations();
                          await chat.loadConversationMembers(conv.id);
                        } catch (e) {
                          messenger.showSnackBar(
                              SnackBar(content: Text('Failed to update: $e')));
                        }
                      },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showMembers(BuildContext context, String currentUserID) {
    final isAdmin =
        conv.members.any((m) => m.userId == currentUserID && m.isAdmin);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (ctx, scrollCtrl) => SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
                child: Row(
                  children: [
                    Text('Members',
                        style: Theme.of(context).textTheme.titleMedium),
                    const Spacer(),
                    if (isAdmin)
                      TextButton.icon(
                        icon: const Icon(Icons.person_add_outlined, size: 18),
                        label: const Text('Add'),
                        onPressed: () {
                          Navigator.pop(context);
                          _showAddMember(context);
                        },
                      ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  controller: scrollCtrl,
                  children: conv.members.map((m) {
                    final username = m.user?.username ?? m.userId;
                    final isSelf = m.userId == currentUserID;
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundImage: m.user?.avatarUrl != null
                            ? CachedNetworkImageProvider(
                                ApiConfig.resolveMedia(m.user!.avatarUrl!))
                            : null,
                        child: m.user?.avatarUrl == null
                            ? Text(username[0].toUpperCase())
                            : null,
                      ),
                      title: Text(isSelf ? '$username (you)' : username),
                      trailing: m.isAdmin
                          ? const Chip(
                              label: Text('Admin'),
                              padding: EdgeInsets.zero,
                              visualDensity: VisualDensity.compact,
                            )
                          : (isAdmin && !isSelf)
                              ? IconButton(
                                  icon: const Icon(Icons.remove_circle_outline,
                                      color: Colors.red, size: 20),
                                  tooltip: 'Remove member',
                                  onPressed: () => _removeMember(
                                      context, m.userId, username),
                                )
                              : null,
                      onTap: m.user != null
                          ? () {
                              Navigator.pop(context);
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      UserProfileScreen(user: m.user!),
                                ),
                              );
                            }
                          : null,
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAddMember(BuildContext context) {
    final searchCtrl = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) {
        // These must live outside the StatefulBuilder closure, otherwise each
        // setStateDialog rebuild would re-initialise them and wipe the results.
        List<dynamic> results = [];
        bool searching = false;
        return StatefulBuilder(builder: (ctx, setStateDialog) {
          Future<void> search(String q) async {
            if (q.trim().length < 2) return;
            setStateDialog(() => searching = true);
            try {
              final users =
                  await context.read<ApiService>().searchUsers(q.trim());
              setStateDialog(() {
                results = users;
                searching = false;
              });
            } catch (_) {
              setStateDialog(() => searching = false);
            }
          }

          return AlertDialog(
            title: const Text('Add Member'),
            content: SizedBox(
              width: 320,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: searchCtrl,
                    decoration: InputDecoration(
                      hintText: 'Search by username…',
                      suffixIcon: searching
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2)),
                            )
                          : IconButton(
                              icon: const Icon(Icons.search),
                              onPressed: () => search(searchCtrl.text),
                            ),
                    ),
                    onSubmitted: search,
                  ),
                  if (results.isNotEmpty)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: results.length,
                        itemBuilder: (_, i) {
                          final u = results[i];
                          final username = u.username as String;
                          final alreadyIn =
                              conv.members.any((m) => m.userId == u.id);
                          return ListTile(
                            dense: true,
                            leading: CircleAvatar(
                              radius: 16,
                              child: Text(username[0].toUpperCase()),
                            ),
                            title: Text('@$username'),
                            trailing: alreadyIn
                                ? const Text('Already in group',
                                    style: TextStyle(
                                        fontSize: 11, color: Colors.grey))
                                : TextButton(
                                    child: const Text('Add'),
                                    onPressed: () async {
                                      Navigator.pop(ctx);
                                      try {
                                        await context
                                            .read<ApiService>()
                                            .addMember(conv.id, u.id as String);
                                        if (context.mounted) {
                                          context
                                              .read<ChatProvider>()
                                              .loadConversationMembers(conv.id);
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(SnackBar(
                                                  content: Text(
                                                      '@$username added')));
                                        }
                                      } catch (e) {
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(SnackBar(
                                                  content: Text(
                                                      'Failed to add: $e')));
                                        }
                                      }
                                    },
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
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Close')),
            ],
          );
        });
      },
    );
  }

  Future<void> _removeMember(
      BuildContext context, String userID, String username) async {
    final api = context.read<ApiService>();
    final chat = context.read<ChatProvider>();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove member?'),
        content: Text('Remove @$username from this group?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await api.removeMember(conv.id, userID);
      if (mounted) {
        navigator.pop();
        chat.loadConversationMembers(conv.id);
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  Future<void> _deleteConversation(BuildContext context) async {
    final api = context.read<ApiService>();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final label = conv.isDM
        ? 'conversation'
        : conv.isGroup
            ? 'group'
            : 'channel';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete $label?'),
        content: Text(
          conv.isDM
              ? 'This will permanently delete all messages for both participants.'
              : 'This will permanently delete the $label and all its messages for everyone.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await api.deleteConversation(conv.id);
      if (mounted) navigator.pop();
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('Failed to delete: $e')));
      }
    }
  }
}

class _KeyLockedBanner extends StatelessWidget {
  final VoidCallback onUnlock;
  const _KeyLockedBanner({required this.onUnlock});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.secondaryContainer,
      child: InkWell(
        onTap: onUnlock,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.lock_outline,
                  size: 18, color: theme.colorScheme.onSecondaryContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Messages are locked — tap to authenticate and decrypt',
                  style: TextStyle(
                    color: theme.colorScheme.onSecondaryContainer,
                    fontSize: 13,
                  ),
                ),
              ),
              Icon(Icons.fingerprint,
                  color: theme.colorScheme.onSecondaryContainer),
            ],
          ),
        ),
      ),
    );
  }
}

class _TypingIndicator extends StatefulWidget {
  final String label;
  const _TypingIndicator({required this.label});

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
      child: Row(
        children: [
          _BouncingDots(controller: _ctrl),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              widget.label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            ),
          ),
        ],
      ),
    );
  }
}

class _BouncingDots extends AnimatedWidget {
  const _BouncingDots({required AnimationController controller})
      : super(listenable: controller);

  @override
  Widget build(BuildContext context) {
    final t = (listenable as AnimationController).value;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (i) {
        // Each dot leads the next by 1/3 of the cycle.
        final phase = (t - i / 3.0) % 1.0;
        // Bounce up during first half of cycle, sit at rest the second half.
        final lift = phase < 0.5 ? math.sin(phase * 2 * math.pi) : 0.0;
        return Transform.translate(
          offset: Offset(0, -5.0 * lift),
          child: Container(
            width: 5,
            height: 5,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              color: Colors.grey[400],
              shape: BoxShape.circle,
            ),
          ),
        );
      }),
    );
  }
}

/// A compact swatch picker: a "default" (no override) choice followed by a
/// preset palette. Emits the chosen colour as an ARGB int, or null for default.
class _ColorChoices extends StatelessWidget {
  final int? selected;
  final void Function(int?) onSelected;

  const _ColorChoices({required this.selected, required this.onSelected});

  static const List<Color> _palette = [
    Color(0xFFEF5350),
    Color(0xFFEC407A),
    Color(0xFFAB47BC),
    Color(0xFF7E57C2),
    Color(0xFF5C6BC0),
    Color(0xFF42A5F5),
    Color(0xFF26A69A),
    Color(0xFF66BB6A),
    Color(0xFFD4E157),
    Color(0xFFFFCA28),
    Color(0xFFFFA726),
    Color(0xFF8D6E63),
    Color(0xFF26323A),
    Color(0xFFECEFF1),
  ];

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        // Default / clear choice.
        GestureDetector(
          onTap: () => onSelected(null),
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: selected == null ? primary : Colors.grey,
                width: selected == null ? 3 : 1,
              ),
            ),
            child: const Icon(Icons.format_color_reset, size: 16),
          ),
        ),
        for (final c in _palette)
          GestureDetector(
            onTap: () => onSelected(c.toARGB32()),
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: c,
                shape: BoxShape.circle,
                border: Border.all(
                  color:
                      selected == c.toARGB32() ? primary : Colors.transparent,
                  width: 3,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
