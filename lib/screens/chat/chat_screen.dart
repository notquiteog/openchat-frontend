import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
import '../../providers/settings_provider.dart';
import '../../services/api_service.dart';
import '../../services/call_service.dart';
import '../../services/notification_service.dart';
import '../../services/attachment_service.dart';
import '../../utils/custom_emoji_payload.dart';
import '../../utils/disappearing_message_duration.dart';
import '../../utils/local_conversation_preferences.dart';
import '../../utils/message_actions.dart';
import '../../utils/mention_utils.dart';
import '../../widgets/attachment_upload_progress.dart';
import '../../widgets/admin_permissions_sheet.dart';
import '../../widgets/conversation_encryption_status.dart';
import '../../widgets/conversation_info_panel.dart';
import '../../widgets/conversation_invite_links_sheet.dart';
import '../../widgets/conversation_notification_controls_sheet.dart';
import '../../widgets/color_choices.dart';
import '../../widgets/custom_emoji_picker.dart';
import '../../widgets/custom_emoji_text_controller.dart';
import '../../widgets/disappearing_messages_picker.dart';
import '../../widgets/glass.dart';
import '../../widgets/location_map_preview.dart';
import '../../widgets/message_action_sheet.dart';
import '../../widgets/mention_autocomplete_panel.dart';
import '../../widgets/message_bubble.dart';
import '../../widgets/scheduled_messages_sheet.dart';
import '../../widgets/sticker_picker.dart';
import '../../widgets/voice_note_recorder.dart';
import '../profile/user_profile_screen.dart';

class ChatScreen extends StatefulWidget {
  final Conversation conversation;
  final String? initialMessageId;

  const ChatScreen({
    super.key,
    required this.conversation,
    this.initialMessageId,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

@visibleForTesting
String conversationExitMenuLabel(
  Conversation conversation, {
  required String currentUserId,
}) {
  if (conversation.isGroup) {
    final isOwner = conversation.createdBy == currentUserId;
    final hasOtherAdmin = conversation.members.any(
      (member) => member.userId != currentUserId && member.isAdmin,
    );
    if (isOwner && !hasOtherAdmin) return 'Leave group';
    return 'Leave group';
  }
  if (conversation.isChannel) return 'Leave channel';
  return 'Delete conversation';
}

class _ChatScreenState extends State<ChatScreen> {
  final _inputCtrl = CustomEmojiTextEditingController();
  final _scrollCtrl = ScrollController();
  bool _showStickers = false;
  bool _showCustomEmojis = false;
  bool _loadingMore = false;
  bool _historyExhausted = false;
  bool _sendSilent = false;
  DateTime? _scheduledFor;
  int _lastMessageCount = 0;
  String? _lastTailMessageId;
  bool _wasNearBottom = true;
  bool _showNewMessagesPill = false;
  int _pendingNewMessageCount = 0;
  Message? _replyingTo;
  Timer? _typingTimer;
  Timer? _draftSaveTimer;
  Timer? _highlightTimer;
  final Map<String, GlobalKey> _messageKeys = {};
  String? _highlightedMessageId;
  AttachmentUploadProgress? _attachmentUploadProgress;
  ActiveMentionQuery? _activeMentionQuery;
  List<CustomEmojiEntity> _customEmojiEntities = [];
  String _lastInputText = '';
  bool _suppressInputEntityShift = false;
  bool _draftRestored = false;
  bool _hasPendingDraftSave = false;
  String _pendingDraftText = '';
  List<CustomEmojiEntity> _pendingDraftEntities = const [];
  bool _pendingDraftSilent = false;
  DateTime? _pendingDraftScheduledFor;
  late final SettingsProvider _settings;

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
    _settings = context.read<SettingsProvider>();
    NotificationService.setActiveConversation(widget.conversation.id);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final chat = context.read<ChatProvider>();
      _restoreLocalDraft();
      final initialMessageId = widget.initialMessageId;
      if (initialMessageId == null) {
        await chat.loadMessages(conv.id);
      } else {
        final found = await chat.ensureMessageLoaded(conv.id, initialMessageId);
        if (mounted) {
          if (found) {
            await _jumpToMessage(initialMessageId);
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Message is not loaded yet')),
            );
          }
        }
      }
      unawaited(chat.loadConversationMembers(conv.id));
    });
    _scrollCtrl.addListener(_onScroll);
    _inputCtrl.addListener(_onInputTextChanged);
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

  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    final nearBottom = _isNearBottom();
    if (nearBottom != _wasNearBottom || (nearBottom && _showNewMessagesPill)) {
      setState(() {
        _wasNearBottom = nearBottom;
        if (nearBottom) {
          _showNewMessagesPill = false;
          _pendingNewMessageCount = 0;
        }
      });
    }

    if (_loadingMore || _historyExhausted) return;
    if (_isNearTop()) {
      setState(() => _loadingMore = true);
      context.read<ChatProvider>().loadMoreMessages(conv.id).then((added) {
        if (!mounted) return;
        setState(() {
          _loadingMore = false;
          if (added == 0) _historyExhausted = true;
        });
      });
    }
  }

  @override
  void dispose() {
    NotificationService.setActiveConversation(null);
    _inputCtrl.removeListener(_onInputTextChanged);
    _draftSaveTimer?.cancel();
    _flushDraftSave();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _typingTimer?.cancel();
    _highlightTimer?.cancel();
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
    final draft = buildCustomEmojiTextPayload(
      _inputCtrl.text,
      _customEmojiEntities,
    );
    if (draft.text.isEmpty) return;
    final rawText = _inputCtrl.text;
    final draftEntities = [..._customEmojiEntities];
    _draftSaveTimer?.cancel();
    _hasPendingDraftSave = false;
    _setComposerValue(
      const TextEditingValue(
        text: '',
        selection: TextSelection.collapsed(offset: 0),
      ),
    );
    final messenger = ScaffoldMessenger.of(context);
    final replyTo = _replyingTo?.id;
    final replyingTo = _replyingTo;
    setState(() {
      _showStickers = false;
      _showCustomEmojis = false;
      _replyingTo = null;
      _syncCustomEmojiEntities(const []);
    });
    try {
      final sent = await context.read<ChatProvider>().sendMessage(
        convID: conv.id,
        plaintext: draft.payload,
        replyTo: replyTo,
        silent: _sendSilent,
        scheduledFor: _scheduledFor,
      );
      if (!mounted) return;
      if (sent) {
        unawaited(_settings.clearMessageDraft(widget.conversation.id));
        if (_scheduledFor == null) {
          _scrollToBottom();
        } else {
          messenger.showSnackBar(
            SnackBar(content: Text('Scheduled for ${_scheduleLabel()}')),
          );
        }
        setState(() => _scheduledFor = null);
      } else {
        _restoreComposedMessage(rawText, replyingTo, draftEntities);
        messenger.showSnackBar(
          const SnackBar(content: Text('Message could not be sent')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      _restoreComposedMessage(rawText, replyingTo, draftEntities);
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  String _scheduleLabel() {
    final when = _scheduledFor;
    if (when == null) return '';
    final local = when.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '${local.month}/${local.day} $h:$m';
  }

  bool _isNearBottom() {
    if (!_scrollCtrl.hasClients) return true;
    return _scrollCtrl.position.pixels <= 96;
  }

  bool _isNearTop() {
    if (!_scrollCtrl.hasClients) return false;
    final position = _scrollCtrl.position;
    if (position.maxScrollExtent <= 0) return false;
    return position.maxScrollExtent - position.pixels <= 240;
  }

  void _handleMessageListChange(List<Message> messages, String currentUserID) {
    final nextTailMessageId = messages.isEmpty ? null : messages.last.id;
    final addedCount = messages.length - _lastMessageCount;
    final hasNewTail =
        addedCount > 0 &&
        nextTailMessageId != null &&
        nextTailMessageId != _lastTailMessageId;

    if (hasNewTail) {
      final newTailMessages = _newTailMessages(messages, addedCount);
      final incomingCount = newTailMessages
          .where((msg) => msg.senderId != currentUserID)
          .length;
      final shouldAutoScroll =
          _lastMessageCount == 0 || _wasNearBottom || incomingCount == 0;

      if (_lastMessageCount == 0) {
        _wasNearBottom = true;
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (shouldAutoScroll) {
            _scrollToBottom();
          } else {
            setState(() {
              _showNewMessagesPill = true;
              _pendingNewMessageCount = math.max(
                1,
                _pendingNewMessageCount + incomingCount,
              );
            });
          }
        });
      }
    } else if (messages.isEmpty && _showNewMessagesPill) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _showNewMessagesPill = false;
          _pendingNewMessageCount = 0;
        });
      });
    }

    _lastMessageCount = messages.length;
    _lastTailMessageId = nextTailMessageId;
  }

  List<Message> _newTailMessages(List<Message> messages, int addedCount) {
    final lastTailId = _lastTailMessageId;
    if (lastTailId != null) {
      final oldTailIndex = messages.indexWhere((msg) => msg.id == lastTailId);
      if (oldTailIndex >= 0 && oldTailIndex < messages.length - 1) {
        return messages.sublist(oldTailIndex + 1);
      }
    }
    return messages.sublist(math.max(0, messages.length - addedCount));
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // drag handle
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 4),
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.24),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.notifications_off_outlined),
                title: const Text('Send silently'),
                value: _sendSilent,
                onChanged: (v) {
                  setState(() => _sendSilent = v);
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
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
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

  Future<void> _sendSticker(String stickerID) async {
    final messenger = ScaffoldMessenger.of(context);
    final replyTo = _replyingTo?.id;
    setState(() {
      _showStickers = false;
      _showCustomEmojis = false;
      _replyingTo = null;
    });
    try {
      final sent = await context.read<ChatProvider>().sendMessage(
        convID: conv.id,
        plaintext: stickerID,
        messageType: 'sticker',
        replyTo: replyTo,
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
    _onTyping();
  }

  void _setComposerValue(TextEditingValue value) {
    _suppressInputEntityShift = true;
    _inputCtrl.value = value;
    _lastInputText = value.text;
    _suppressInputEntityShift = false;
    _updateMentionQuery(value);
  }

  List<ConversationMember> _mentionSuggestions(String currentUserID) {
    return mentionSuggestionsForMembers(
      members: conv.members,
      active: _activeMentionQuery,
      currentUserId: currentUserID,
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
    _onTyping();
  }

  void _restoreComposedMessage(
    String text,
    Message? replyingTo, [
    List<CustomEmojiEntity> entities = const [],
  ]) {
    if (_inputCtrl.text.isEmpty) {
      _setComposerValue(
        TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        ),
      );
    }
    setState(() {
      _replyingTo = replyingTo;
      _syncCustomEmojiEntities(entities);
    });
    _pendingDraftText = text;
    _pendingDraftEntities = entities;
    _pendingDraftSilent = _sendSilent;
    _pendingDraftScheduledFor = _scheduledFor;
    _hasPendingDraftSave = false;
    unawaited(
      _settings.setMessageDraft(
        widget.conversation.id,
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
    final draft = _settings.messageDraftFor(widget.conversation.id);
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
        widget.conversation.id,
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

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!_scrollCtrl.hasClients) return;
      const target = 0.0;
      if ((target - _scrollCtrl.position.pixels).abs() > 1) {
        await _scrollCtrl.animateTo(
          target,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        );
      }
      if (mounted) {
        setState(() {
          _wasNearBottom = true;
          _showNewMessagesPill = false;
          _pendingNewMessageCount = 0;
        });
      }
    });
  }

  Future<void> _jumpToMessage(String msgID) async {
    final messages = context.read<ChatProvider>().messagesFor(conv.id);
    final chronologicalIndex = messages.indexWhere((msg) => msg.id == msgID);
    if (chronologicalIndex < 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Message is not loaded')));
      return;
    }

    if (_scrollCtrl.hasClients) {
      final reverseIndex = messages.length - 1 - chronologicalIndex;
      final estimatedOffset = reverseIndex * 88.0;
      final position = _scrollCtrl.position;
      await _scrollCtrl.animateTo(
        estimatedOffset.clamp(0.0, position.maxScrollExtent).toDouble(),
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    }

    await Future<void>.delayed(const Duration(milliseconds: 40));
    if (!mounted) return;
    final targetContext = _messageKeys[msgID]?.currentContext;
    if (targetContext != null && targetContext.mounted) {
      unawaited(
        Scrollable.ensureVisible(
          targetContext,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          alignment: 0.46,
        ),
      );
    }

    _highlightTimer?.cancel();
    setState(() => _highlightedMessageId = msgID);
    _highlightTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _highlightedMessageId = null);
    });
  }

  Message? _replyPreviewFor(Message msg, List<Message> messages) {
    final replyTo = msg.replyTo;
    if (replyTo == null) return null;
    return messages.where((message) => message.id == replyTo).firstOrNull;
  }

  Future<void> _jumpToReply(Message msg) async {
    final replyTo = msg.replyTo;
    if (replyTo == null) return;
    final chat = context.read<ChatProvider>();
    final found = await chat.ensureMessageLoaded(conv.id, replyTo);
    if (!mounted) return;
    if (!found) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Original message is not loaded yet')),
      );
      return;
    }
    await _jumpToMessage(replyTo);
  }

  Future<void> _showAttachmentPicker() async {
    // image_picker's camera source is only implemented on mobile (and web);
    // on desktop it throws "requires a cameraDelegate", so only offer it where
    // it actually works.
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
            _AttachTile(
              icon: Icons.photo_library_outlined,
              label: 'Photo from gallery',
              onTap: () => Navigator.pop(context, 'gallery_image'),
            ),
            _AttachTile(
              icon: Icons.share_location_outlined,
              label: 'Share location',
              onTap: () => Navigator.pop(context, 'location_once'),
            ),
            _AttachTile(
              icon: Icons.location_on_outlined,
              label: 'Share live location',
              onTap: () => Navigator.pop(context, 'location_live'),
            ),
            if (cameraSupported)
              _AttachTile(
                icon: Icons.camera_alt_outlined,
                label: 'Take photo',
                onTap: () => Navigator.pop(context, 'camera_image'),
              ),
            _AttachTile(
              icon: Icons.videocam_outlined,
              label: 'Video from gallery',
              onTap: () => Navigator.pop(context, 'gallery_video'),
            ),
            _AttachTile(
              icon: Icons.attach_file_rounded,
              label: 'File',
              onTap: () => Navigator.pop(context, 'file'),
            ),
            _AttachTile(
              icon: Icons.poll_outlined,
              label: 'Poll',
              onTap: () => Navigator.pop(context, 'poll'),
            ),
            _AttachTile(
              icon: Icons.mic_none_outlined,
              label: 'Voice note',
              onTap: () => Navigator.pop(context, 'voice'),
            ),
            _AttachTile(
              icon: Icons.payments_outlined,
              label: 'Pay or request',
              onTap: () => Navigator.pop(context, 'payment'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (choice == null || !mounted) return;
    if (choice == 'poll') {
      await _showCreatePollDialog();
      return;
    }
    if (choice == 'payment') {
      await _showPaymentSheet();
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
    final chat = context.read<ChatProvider>();
    final messenger = ScaffoldMessenger.of(context);

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
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('Upload failed: $e')));
      }
      return;
    } finally {
      final file = voiceNote?.file;
      if (file != null) {
        try {
          await file.delete();
        } catch (_) {}
      }
    }

    if (pending == null || !mounted) {
      _clearAttachmentUploadProgress();
      return;
    }

    try {
      _setAttachmentUploadProgress(
        const AttachmentUploadProgress(stage: AttachmentUploadStage.sending),
      );
      final sent = await chat.sendPreparedAttachment(
        convID: conv.id,
        attachment: pending,
        onProgress: _setAttachmentUploadProgress,
      );
      if (sent) {
        _scrollToBottom();
      } else if (mounted) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Attachment could not be sent')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      _clearAttachmentUploadProgress();
    }
  }

  Future<void> _showPaymentSheet() async {
    final currentUserID = context.read<AuthProvider>().currentUser?.id;
    if (currentUserID == null) return;
    final chat = context.read<ChatProvider>();
    if (conv.members.isEmpty) {
      await chat.loadConversationMembers(conv.id);
    }
    if (!mounted) return;

    final members = conv.members
        .where((m) => m.userId != currentUserID && m.user != null)
        .toList();
    if (members.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No chat member available')));
      return;
    }

    final api = context.read<ApiService>();
    var providers = <String>['btc', 'xmr'];
    var balances = <Map<String, dynamic>>[];
    try {
      final status = await api.getBillingStatus();
      final enabled = ((status['providers'] as List?) ?? const [])
          .whereType<String>()
          .where((p) => p == 'btc' || p == 'xmr')
          .toList();
      if (enabled.isNotEmpty) providers = enabled;
      balances = (await api.getPaymentBalances())
          .whereType<Map<String, dynamic>>()
          .toList();
    } catch (_) {}

    if (!mounted || !context.mounted) return;
    final rootContext = context;
    var payMode = true;
    var paymentSource = 'wallet';
    var provider = providers.first;
    var amountUnit = 'crypto';
    var selectedUserID = members.first.userId;
    var submitting = false;
    final amountCtrl = TextEditingController();
    final noteCtrl = TextEditingController();

    double balanceFor(String provider) {
      for (final balance in balances) {
        if (balance['provider'] == provider) {
          final available = balance['available'];
          if (available is num) return available.toDouble();
          if (available is String) return double.tryParse(available) ?? 0;
        }
      }
      return 0;
    }

    try {
      await showModalBottomSheet<void>(
        context: rootContext,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        barrierColor: Colors.black.withValues(alpha: 0.18),
        elevation: 0,
        builder: (sheetCtx) => StatefulBuilder(
          builder: (sheetCtx, setSheet) {
            Future<void> submit() async {
              if (submitting) return;
              final amount = double.tryParse(amountCtrl.text.trim()) ?? 0;
              if (amount <= 0) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Enter an amount')),
                );
                return;
              }
              final isCryptoAmount = amountUnit == 'crypto';
              final fiatCurrency = isCryptoAmount
                  ? null
                  : amountUnit.toUpperCase();
              setSheet(() => submitting = true);
              try {
                if (payMode) {
                  final useWallet =
                      paymentSource == 'wallet' &&
                      (!isCryptoAmount || amount <= balanceFor(provider));
                  if (useWallet) {
                    if (isCryptoAmount && amount > balanceFor(provider)) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Not enough app wallet balance'),
                        ),
                      );
                      return;
                    }
                    await api.sendPaymentTransfer(
                      toUserID: selectedUserID,
                      provider: provider,
                      amount: isCryptoAmount ? amount : null,
                      fiatAmount: isCryptoAmount ? null : amount,
                      fiatCurrency: fiatCurrency,
                      conversationID: conv.id,
                      note: noteCtrl.text,
                    );
                  } else {
                    final result = await api.createExternalPaymentTransfer(
                      toUserID: selectedUserID,
                      provider: provider,
                      amount: isCryptoAmount ? amount : null,
                      fiatAmount: isCryptoAmount ? null : amount,
                      fiatCurrency: fiatCurrency,
                      conversationID: conv.id,
                      note: noteCtrl.text,
                    );
                    if (!mounted || !sheetCtx.mounted) return;
                    Navigator.pop(sheetCtx);
                    final deposit = result['deposit'] as Map<String, dynamic>?;
                    if (deposit != null) _showExternalPaymentAddress(deposit);
                    return;
                  }
                } else {
                  await api.createPaymentRequest(
                    payerID: selectedUserID,
                    conversationID: conv.id,
                    provider: provider,
                    amount: isCryptoAmount ? amount : null,
                    fiatAmount: isCryptoAmount ? null : amount,
                    fiatCurrency: fiatCurrency,
                    title: 'Payment request',
                    note: noteCtrl.text,
                  );
                }
                if (!mounted || !sheetCtx.mounted) return;
                Navigator.pop(sheetCtx);
                _scrollToBottom();
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(e.toString())));
              } finally {
                if (mounted) setSheet(() => submitting = false);
              }
            }

            final amount = double.tryParse(amountCtrl.text.trim()) ?? 0;
            final available = balanceFor(provider);
            final isCryptoAmount = amountUnit == 'crypto';
            final canUseWallet =
                !payMode ||
                !isCryptoAmount ||
                amount <= 0 ||
                available >= amount;
            return GlassBottomSheetFrame(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(
                            value: true,
                            label: Text('Pay'),
                            icon: Icon(Icons.arrow_upward),
                          ),
                          ButtonSegment(
                            value: false,
                            label: Text('Request'),
                            icon: Icon(Icons.arrow_downward),
                          ),
                        ],
                        selected: {payMode},
                        onSelectionChanged: (next) =>
                            setSheet(() => payMode = next.first),
                      ),
                      const Spacer(),
                      Text(
                        '${available.toStringAsFixed(provider == 'btc' ? 8 : 12)} ${provider.toUpperCase()}',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    initialValue: selectedUserID,
                    items: [
                      for (final member in members)
                        DropdownMenuItem(
                          value: member.userId,
                          child: Text('@${member.user!.username}'),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setSheet(() => selectedUserID = value);
                      }
                    },
                    decoration: InputDecoration(
                      labelText: payMode ? 'To' : 'From',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<String>(
                    segments: [
                      for (final p in providers)
                        ButtonSegment(value: p, label: Text(p.toUpperCase())),
                    ],
                    selected: {provider},
                    onSelectionChanged: (next) => setSheet(() {
                      provider = next.first;
                      if (payMode &&
                          amountUnit == 'crypto' &&
                          paymentSource == 'wallet' &&
                          amount > balanceFor(provider)) {
                        paymentSource = 'external';
                      }
                    }),
                  ),
                  const SizedBox(height: 12),
                  if (payMode) ...[
                    SegmentedButton<String>(
                      segments: [
                        ButtonSegment(
                          value: 'wallet',
                          label: const Text('App wallet'),
                          icon: const Icon(Icons.account_balance_wallet),
                          enabled: canUseWallet,
                        ),
                        const ButtonSegment(
                          value: 'external',
                          label: Text('External'),
                          icon: Icon(Icons.qr_code_2),
                        ),
                      ],
                      selected: {canUseWallet ? paymentSource : 'external'},
                      onSelectionChanged: (next) =>
                          setSheet(() => paymentSource = next.first),
                    ),
                    const SizedBox(height: 12),
                  ],
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(
                        value: 'crypto',
                        label: Text(provider.toUpperCase()),
                      ),
                      const ButtonSegment(value: 'usd', label: Text('USD')),
                      const ButtonSegment(value: 'eur', label: Text('EUR')),
                    ],
                    selected: {amountUnit},
                    onSelectionChanged: (next) => setSheet(() {
                      amountUnit = next.first;
                      if (payMode &&
                          amountUnit == 'crypto' &&
                          paymentSource == 'wallet' &&
                          amount > balanceFor(provider)) {
                        paymentSource = 'external';
                      }
                    }),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: amountCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    onChanged: (_) {
                      final nextAmount =
                          double.tryParse(amountCtrl.text.trim()) ?? 0;
                      setSheet(() {
                        if (payMode &&
                            amountUnit == 'crypto' &&
                            paymentSource == 'wallet' &&
                            nextAmount > balanceFor(provider)) {
                          paymentSource = 'external';
                        }
                      });
                    },
                    decoration: InputDecoration(
                      labelText: amountUnit == 'crypto'
                          ? 'Amount ${provider.toUpperCase()}'
                          : 'Amount ${amountUnit.toUpperCase()}',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: noteCtrl,
                    maxLength: 160,
                    decoration: const InputDecoration(
                      labelText: 'Note',
                      border: OutlineInputBorder(),
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: submitting ? null : submit,
                    icon: submitting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            payMode
                                ? Icons.send_outlined
                                : Icons.request_quote_outlined,
                          ),
                    label: Text(payMode ? 'Pay' : 'Request'),
                  ),
                ],
              ),
            );
          },
        ),
      );
    } finally {
      amountCtrl.dispose();
      noteCtrl.dispose();
    }
  }

  Future<void> _shareOneTimeLocation() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final sent = await context.read<ChatProvider>().sendOneTimeLocation(
        convID: conv.id,
      );
      if (!mounted) return;
      if (sent) {
        _scrollToBottom();
      }
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
      final msgID = await context.read<ChatProvider>().sendLiveLocation(
        convID: conv.id,
        duration: duration,
      );
      if (!mounted) return;
      if (msgID != null) {
        _scrollToBottom();
      }
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<Duration?> _selectLiveLocationDuration() async {
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

  void _openLocationMessage(Message msg) {
    final location = msg.location;
    if (location == null) return;
    final coords =
        '${location.latitude.toStringAsFixed(6)}, ${location.longitude.toStringAsFixed(6)}';
    final status = location.isLive
        ? location.isActive
              ? 'Live location${location.remainingLabel}'
              : 'Live location ended'
        : location.previewLabel;

    Navigator.push(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: Text(status),
          ),
          body: SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: InteractiveViewer(
                        minScale: 1,
                        maxScale: 5,
                        child: LocationMapPreview(
                          location: location,
                          compact: false,
                          showCoordinates: true,
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (location.previewLabel.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              location.previewLabel,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        Text(
                          coords,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 10),
                        FilledButton.tonal(
                          onPressed: () {
                            Clipboard.setData(
                              ClipboardData(
                                text:
                                    '${location.latitude}, ${location.longitude}',
                              ),
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Coordinates copied'),
                              ),
                            );
                          },
                          child: const Text('Copy coordinates'),
                        ),
                      ],
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

  void _showExternalPaymentAddress(Map<String, dynamic> deposit) {
    final address = deposit['crypto_address'] as String? ?? '';
    final provider = deposit['provider'] as String? ?? '';
    final amount = deposit['expected_amount'];
    final amountText = amount == null
        ? ''
        : '\n\nSend at least ${_formatCrypto(_asDouble(amount), provider)}.';
    showDialog<void>(
      context: context,
      builder: (dialogCtx) => GlassAlertDialog(
        title: Text('Pay with ${provider.toUpperCase()}'),
        content: SelectableText('$address$amountText'),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: address));
              if (mounted && dialogCtx.mounted) Navigator.pop(dialogCtx);
            },
            child: const Text('Copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Done'),
          ),
        ],
      ),
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
                  .where((text) => text.isNotEmpty)
                  .toList();
              if (question.isEmpty || options.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Question and option required')),
                );
                return;
              }
              Navigator.pop(dialogCtx);
              try {
                final sent = await context.read<ChatProvider>().sendPoll(
                  convID: conv.id,
                  question: question,
                  options: options,
                  isAnonymous: anonymous,
                  allowsMultipleAnswers: multiple,
                  silent: _sendSilent,
                );
                if (sent && mounted) _scrollToBottom();
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
                FilledButton(onPressed: submit, child: const Text('Send')),
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
          content: Text('Cannot start call in a group — open a DM first'),
        ),
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not start call: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final chat = context.watch<ChatProvider>();
    final messages = chat.messagesFor(conv.id);
    final currentUserID = auth.currentUser?.id ?? '';
    final typingUsers = chat.typingUsersFor(conv.id);
    _handleMessageListChange(messages, currentUserID);

    // Per-chat look. The current user's bubble color is also stored on their
    // profile so group/channel participants see the same sender color.
    final chatStyle = context.select<SettingsProvider, ChatStyle>(
      (settings) => settings.chatStyleFor(widget.conversation.id),
    );
    final meBubbleColor = chatStyle.myBubbleColor != null
        ? Color(chatStyle.myBubbleColor!)
        : auth.currentUser?.bubbleColor != null
        ? Color(auth.currentUser!.bubbleColor!)
        : null;
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: _buildAppBar(context, typingUsers, currentUserID),
      body: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(decoration: _chatBackground(chatStyle)),
          ),
          AnimatedPadding(
            padding: EdgeInsets.only(bottom: keyboardInset),
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: Column(
              children: [
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _showStickers = false),
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: messages.isEmpty
                              ? Center(
                                  child: GlassContainer(
                                    shape: LiquidRoundedSuperellipse(
                                      borderRadius: 999,
                                    ),
                                    allowElevation: true,
                                    glowIntensity: 0.05,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 20,
                                        vertical: 12,
                                      ),
                                      child: Text(
                                        'No messages yet',
                                        style: TextStyle(
                                          fontSize: 14,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withValues(alpha: 0.55),
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ),
                                )
                              : ListView.builder(
                                  controller: _scrollCtrl,
                                  reverse: true,
                                  physics: const BouncingScrollPhysics(
                                    parent: AlwaysScrollableScrollPhysics(),
                                  ),
                                  scrollCacheExtent:
                                      const ScrollCacheExtent.pixels(720),
                                  keyboardDismissBehavior:
                                      ScrollViewKeyboardDismissBehavior.onDrag,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 8,
                                  ),
                                  itemCount:
                                      messages.length + (_loadingMore ? 1 : 0),
                                  itemBuilder: (context, i) {
                                    if (i == messages.length) {
                                      return const Padding(
                                        padding: EdgeInsets.symmetric(
                                          vertical: 12,
                                        ),
                                        child: Center(
                                          child: SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          ),
                                        ),
                                      );
                                    }

                                    final messageIndex =
                                        messages.length - 1 - i;
                                    final msg = messages[messageIndex];
                                    final isMe = msg.senderId == currentUserID;
                                    final isLocationMessage =
                                        msg.type == MessageType.location &&
                                        msg.location != null;
                                    final showAvatar =
                                        !isMe &&
                                        (messageIndex == messages.length - 1 ||
                                            messages[messageIndex + 1]
                                                    .senderId !=
                                                msg.senderId);
                                    final highlighted =
                                        _highlightedMessageId == msg.id;
                                    final replyPreview = _replyPreviewFor(
                                      msg,
                                      messages,
                                    );
                                    return _AnimatedMessageEntry(
                                      key: _messageKeys.putIfAbsent(
                                        msg.id,
                                        () => GlobalKey(),
                                      ),
                                      id: msg.id,
                                      child: AnimatedContainer(
                                        duration: const Duration(
                                          milliseconds: 220,
                                        ),
                                        curve: Curves.easeOutCubic,
                                        decoration: BoxDecoration(
                                          color: highlighted
                                              ? Theme.of(context)
                                                    .colorScheme
                                                    .primary
                                                    .withValues(alpha: 0.14)
                                              : Colors.transparent,
                                          borderRadius: BorderRadius.circular(
                                            chatStyle.bubbleRadius + 10,
                                          ),
                                        ),
                                        child: MessageBubble(
                                          message: msg,
                                          isMe: isMe,
                                          showAvatar: showAvatar,
                                          meBubbleColor: meBubbleColor,
                                          bubbleRadius: chatStyle.bubbleRadius,
                                          onTap: isLocationMessage
                                              ? () => _openLocationMessage(msg)
                                              : null,
                                          onTapUp: isLocationMessage
                                              ? null
                                              : (details) => _showReactionMenu(
                                                  context,
                                                  msg,
                                                  details.globalPosition,
                                                ),
                                          onReactionTap: (emoji) =>
                                              _toggleReaction(msg, emoji),
                                          replyPreview: replyPreview,
                                          onReplyTap: msg.replyTo == null
                                              ? null
                                              : () => _jumpToReply(msg),
                                          isLiveLocationSharing:
                                              isMe &&
                                              msg.location?.isLive == true &&
                                              chat.isLiveLocationActive(msg.id),
                                          onCancelLiveLocation: () => context
                                              .read<ChatProvider>()
                                              .stopLiveLocation(msg.id),
                                          onLongPress: () => _showMessageMenu(
                                            context,
                                            msg,
                                            isMe,
                                          ),
                                          onAvatarTap: msg.sender != null
                                              ? () => Navigator.push(
                                                  context,
                                                  MaterialPageRoute(
                                                    builder: (_) =>
                                                        UserProfileScreen(
                                                          user: msg.sender!,
                                                        ),
                                                  ),
                                                )
                                              : null,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                        ),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 12,
                          child: IgnorePointer(
                            ignoring: !_showNewMessagesPill,
                            child: AnimatedSlide(
                              offset: _showNewMessagesPill
                                  ? Offset.zero
                                  : const Offset(0, 0.45),
                              duration: const Duration(milliseconds: 180),
                              curve: Curves.easeOutCubic,
                              child: AnimatedOpacity(
                                opacity: _showNewMessagesPill ? 1 : 0,
                                duration: const Duration(milliseconds: 140),
                                child: Center(
                                  child: GestureDetector(
                                    onTap: _scrollToBottom,
                                    child: GlassContainer(
                                      shape: LiquidRoundedSuperellipse(
                                        borderRadius: 999,
                                      ),
                                      allowElevation: true,
                                      glowIntensity: 0.08,
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                          vertical: 10,
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(
                                              Icons.keyboard_arrow_down_rounded,
                                              size: 18,
                                            ),
                                            const SizedBox(width: 6),
                                            Text(
                                              _pendingNewMessageCount <= 1
                                                  ? 'New messages'
                                                  : '$_pendingNewMessageCount new messages',
                                              style: const TextStyle(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_showCustomEmojis)
                  CustomEmojiPicker(onEmojiSelected: _insertCustomEmoji),
                if (_showStickers)
                  StickerPicker(onStickerSelected: _sendSticker),
                if (_attachmentUploadProgress != null)
                  AttachmentUploadProgressChip(
                    progress: _attachmentUploadProgress!,
                  ),
                if (typingUsers.isNotEmpty)
                  _TypingIndicator(
                    label: _typingLabel(typingUsers, currentUserID),
                  ),
                _buildInputBar(context, currentUserID),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Background behind the message list. A premium conversation-wide image
  /// (set by an admin, visible to everyone) wins; otherwise the viewer's own
  /// per-DM background image or color applies.
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

  /// Appearance editor: DMs keep local background controls; the current user's
  /// own bubble color can be published for any chat type.
  Future<void> _showChatAppearance(BuildContext context) async {
    final settings = context.read<SettingsProvider>();
    final api = context.read<ApiService>();
    final auth = context.read<AuthProvider>();
    final convID = conv.id;
    final isDm = conv.isDM;
    var style = settings.chatStyleFor(convID);

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.18),
      elevation: 0,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheet) {
          Future<void> apply(
            ChatStyle next, {
            bool publishBubble = false,
          }) async {
            style = next;
            await settings.setChatStyle(convID, next);
            if (publishBubble) {
              await api.updateProfile(
                bubbleColor: next.myBubbleColor,
                clearBubbleColor: next.myBubbleColor == null,
              );
              await auth.refreshCurrentUser();
            }
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
                      onPressed: () =>
                          apply(const ChatStyle(), publishBubble: true),
                      child: const Text('Reset'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (isDm) ...[
                  const Text('Background color'),
                  const SizedBox(height: 8),
                  ColorChoices(
                    selected: style.backgroundColor,
                    onSelected: (c) => apply(
                      c == null
                          ? style.copyWith(clearBackgroundColor: true)
                          : style.copyWith(
                              backgroundColor: c,
                              clearBackgroundImage: true,
                            ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.image_outlined, size: 18),
                        label: const Text('Background image'),
                        onPressed: () async {
                          final picked = await ImagePicker().pickImage(
                            source: ImageSource.gallery,
                            imageQuality: 90,
                          );
                          if (picked != null) {
                            apply(
                              style.copyWith(
                                backgroundImagePath: picked.path,
                                clearBackgroundColor: true,
                              ),
                            );
                          }
                        },
                      ),
                      if (style.backgroundImagePath != null)
                        TextButton(
                          onPressed: () =>
                              apply(style.copyWith(clearBackgroundImage: true)),
                          child: const Text('Remove'),
                        ),
                    ],
                  ),
                  const Divider(height: 24),
                ],
                const Text('My bubble color'),
                const SizedBox(height: 8),
                ColorChoices(
                  selected: style.myBubbleColor,
                  onSelected: (c) => apply(
                    c == null
                        ? style.copyWith(clearMyBubbleColor: true)
                        : style.copyWith(myBubbleColor: c),
                    publishBubble: true,
                  ),
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
          );
        },
      ),
    );
  }

  /// Premium users can set a shared background on group chats (admins only) and
  /// bot chats. Regular DMs use the personal "Chat appearance" instead, and
  /// channels are handled from the channel screen.
  ConversationMember? _currentMember(String currentUserID) {
    for (final member in conv.members) {
      if (member.userId == currentUserID) return member;
    }
    return null;
  }

  bool _canSetConversationBackground(String currentUserID) {
    final user = context.read<AuthProvider>().currentUser;
    if (user == null || !user.isPremium) return false;
    if (conv.isBotDM(currentUserID)) return true;
    if (conv.isGroup) {
      return _currentMember(
            currentUserID,
          )?.hasPermission(AdminPermission.manageInfo) ??
          false;
    }
    return false;
  }

  Future<void> _setConversationBackground(BuildContext context) async {
    final api = context.read<ApiService>();
    final chat = context.read<ChatProvider>();
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
            _MenuTile(
              icon: Icons.image_outlined,
              label: 'Choose background image',
              onTap: () => Navigator.pop(context, 'pick'),
            ),
            if (conv.backgroundUrl != null)
              _MenuTile(
                icon: Icons.delete_outline,
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
        await api.setConversationBackground(conv.id, null);
      } else {
        final picked = await ImagePicker().pickImage(
          source: ImageSource.gallery,
          imageQuality: 90,
        );
        if (picked == null) return;
        final bytes = await picked.readAsBytes();
        // uploadAvatar re-encodes to WEBP with all metadata stripped, exactly
        // what a shared background needs.
        final url = await api.uploadAvatar(
          fileBytes: bytes,
          filename: picked.name,
        );
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
    BuildContext context,
    Set<String> typingUsers,
    String currentUserID,
  ) {
    final name = conv.displayName(currentUserID);

    final dmPartner = !conv.isGroup
        ? conv.members.where((m) => m.userId != currentUserID).firstOrNull?.user
        : null;
    final avatarUrl = conv.displayAvatar(currentUserID);
    final exitLabel = conversationExitMenuLabel(
      conv,
      currentUserId: currentUserID,
    );

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

    return GlassAppBar(
      titleSpacing: 0,
      title: InkWell(
        onTap: openInfo,
        child: Row(
          children: [
            Hero(
              tag: 'avatar_${conv.id}',
              child: CircleAvatar(
                radius: 18,
                backgroundImage: avatarUrl != null
                    ? CachedNetworkImageProvider(
                        ApiConfig.resolveMedia(avatarUrl),
                      )
                    : null,
                child: avatarUrl == null
                    ? (conv.isGroup
                          ? const Icon(Icons.group, size: 18)
                          : Text(name.isNotEmpty ? name[0].toUpperCase() : '?'))
                    : null,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  ConversationEncryptionStatus(conversation: conv),
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
        IconButton(
          icon: const Icon(Icons.more_vert),
          tooltip: 'More options',
          onPressed: () =>
              _showChatMenu(context, conv, currentUserID, exitLabel),
        ),
      ],
    );
  }

  void _showChatMenu(
    BuildContext context,
    Conversation conv,
    String currentUserID,
    String exitLabel,
  ) {
    final currentMember = _currentMember(currentUserID);
    final canManageInfo =
        currentMember?.hasPermission(AdminPermission.manageInfo) ?? false;
    final canManageSettings =
        currentMember?.hasPermission(AdminPermission.manageSettings) ?? false;
    final canManageEncryption =
        currentMember?.hasPermission(AdminPermission.manageEncryption) ?? false;
    final canManageInvites =
        currentMember?.hasPermission(AdminPermission.manageInvites) ?? false;
    final settings = context.read<SettingsProvider>();
    final notificationPreference = settings
        .notificationPreferenceForConversation(conv.id);
    final notificationLabel = settings.notificationLabelForConversation(
      conv.id,
    );
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => GlassBottomSheetFrame(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            _MenuTile(
              icon: Icons.info_outline_rounded,
              label: 'Conversation info',
              onTap: () {
                Navigator.pop(context);
                _showConversationInfo(context, currentUserID);
              },
            ),
            _MenuTile(
              icon: _notificationPreferenceIcon(notificationPreference),
              label: 'Notifications: $notificationLabel',
              onTap: () {
                Navigator.pop(context);
                showConversationNotificationControlsSheet(
                  context,
                  conversationId: conv.id,
                );
              },
            ),
            _MenuTile(
              icon: Icons.schedule_send_outlined,
              label: 'Scheduled messages',
              onTap: () {
                Navigator.pop(context);
                showScheduledMessagesSheet(
                  context,
                  conversation: conv,
                  channel: false,
                );
              },
            ),
            if (conv.isDM || canManageSettings)
              _MenuTile(
                icon: Icons.timer_outlined,
                label: 'Disappearing messages',
                onTap: () {
                  Navigator.pop(context);
                  _setDisappearing(context);
                },
              ),
            if (!conv.isDM && canManageSettings)
              _MenuTile(
                icon: Icons.hourglass_empty_rounded,
                label: 'Slow mode',
                onTap: () {
                  Navigator.pop(context);
                  _setSlowMode(context);
                },
              ),
            if (!conv.isDM && canManageEncryption)
              _MenuTile(
                icon: Icons.lock_outline_rounded,
                label: conv.encryptionEnabled
                    ? 'Turn encryption off'
                    : 'Turn encryption on',
                onTap: () {
                  Navigator.pop(context);
                  _setEncryption(context);
                },
              ),
            if (conv.isGroup && canManageInfo)
              _MenuTile(
                icon: Icons.edit_outlined,
                label: 'Edit group',
                onTap: () {
                  Navigator.pop(context);
                  _editGroup(context, currentUserID);
                },
              ),
            if (conv.isGroup)
              _MenuTile(
                icon: Icons.group_outlined,
                label: 'Members',
                onTap: () {
                  Navigator.pop(context);
                  _showMembers(context, currentUserID);
                },
              ),
            if (conv.isGroup && canManageInvites)
              _MenuTile(
                icon: Icons.link_rounded,
                label: 'Invite links',
                onTap: () {
                  Navigator.pop(context);
                  _showInviteLinks(context, conv);
                },
              ),
            _MenuTile(
              icon: Icons.palette_outlined,
              label: 'Chat appearance',
              onTap: () {
                Navigator.pop(context);
                _showChatAppearance(context);
              },
            ),
            if (_canSetConversationBackground(currentUserID))
              _MenuTile(
                icon: Icons.wallpaper_rounded,
                label: 'Set chat background',
                onTap: () {
                  Navigator.pop(context);
                  _setConversationBackground(context);
                },
              ),
            if (conv.isGroup)
              _MenuTile(
                icon: Icons.delete_sweep_outlined,
                label: 'Delete messages',
                color: Colors.red,
                onTap: () {
                  Navigator.pop(context);
                  _deleteGroupMessages(context, currentUserID);
                },
              ),
            _MenuTile(
              icon: conv.isDM
                  ? Icons.delete_outline_rounded
                  : Icons.exit_to_app_rounded,
              label: exitLabel,
              color: Colors.red,
              onTap: () {
                Navigator.pop(context);
                _deleteConversation(context);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _showInviteLinks(BuildContext context, Conversation conv) async {
    await showConversationInviteLinksSheet(
      context,
      conversation: conv,
      channel: false,
      onJoinApprovalChanged: (_) {
        unawaited(context.read<ChatProvider>().refreshConversationsSilently());
      },
    );
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

  Widget _buildInputBar(BuildContext context, String currentUserID) {
    final scheme = Theme.of(context).colorScheme;
    final mentionSuggestions = _mentionSuggestions(currentUserID);
    // The composer is an active control, so it lives in the Liquid Glass layer:
    // a free-floating capsule hovering above the bottom boundary with the chat
    // canvas peeking around it.
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 14),
        child: GlassContainer(
          shape: const LiquidRoundedSuperellipse(borderRadius: 28),
          allowElevation: true,
          glowIntensity: 0.06,
          padding: const EdgeInsets.fromLTRB(4, 4, 6, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (mentionSuggestions.isNotEmpty)
                MentionAutocompletePanel(
                  members: mentionSuggestions,
                  onSelected: _insertMention,
                ),
              if (_replyingTo != null) _buildReplyPreview(context),
              Row(
                children: [
                  IconButton(
                    icon: Icon(
                      _showCustomEmojis
                          ? Icons.keyboard
                          : Icons.add_reaction_outlined,
                    ),
                    tooltip: _showCustomEmojis ? 'Keyboard' : 'Custom emoji',
                    onPressed: () => setState(() {
                      _showCustomEmojis = !_showCustomEmojis;
                      if (_showCustomEmojis) _showStickers = false;
                    }),
                  ),
                  IconButton(
                    icon: Icon(
                      _showStickers
                          ? Icons.keyboard
                          : Icons.sticky_note_2_outlined,
                    ),
                    tooltip: _showStickers ? 'Keyboard' : 'Stickers',
                    onPressed: () => setState(() {
                      _showStickers = !_showStickers;
                      if (_showStickers) _showCustomEmojis = false;
                    }),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _inputCtrl,
                      onChanged: (_) => _onTyping(),
                      onSubmitted: (_) => _sendMessage(),
                      maxLines: null,
                      textInputAction: TextInputAction.send,
                      // Punchier weight to stay legible over the refracting glass.
                      style: const TextStyle(fontWeight: FontWeight.w500),
                      decoration: InputDecoration(
                        hintText: 'Message',
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
                    onPressed: _showAttachmentPicker,
                    tooltip: 'Attach file',
                    icon: const Icon(Icons.attach_file_outlined, size: 22),
                  ),
                  const SizedBox(width: 4),
                  Tooltip(
                    message: 'Hold for send options',
                    child: GestureDetector(
                      onTap: _sendMessage,
                      onLongPress: _showSendOptions,
                      child: GlassContainer(
                        shape: const LiquidRoundedSuperellipse(
                          borderRadius: 999,
                        ),
                        allowElevation: true,
                        glowIntensity: 0.08,
                        padding: const EdgeInsets.all(12),
                        child: Icon(
                          _scheduledFor != null
                              ? Icons.schedule_send_outlined
                              : _sendSilent
                              ? Icons.notifications_off_outlined
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

  Widget _buildReplyPreview(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final msg = _replyingTo!;
    final senderName = msg.sender?.username ?? 'Unknown';
    final preview = msg.decryptedContent ?? 'Encrypted message';
    // A rounded chip nested inside the composer capsule. The accent is a
    // standalone bar (not a one-sided border) so it can coexist with rounding.
    return Container(
      margin: const EdgeInsets.fromLTRB(6, 4, 6, 2),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 32,
            decoration: BoxDecoration(
              color: scheme.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  senderName,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: scheme.primary,
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

  void _showReactionMenu(BuildContext context, Message msg, Offset anchor) {
    if (msg.type == MessageType.system) return;
    const emojis = ['👍', '❤️', '😂', '🔥', '🎉', '👀'];
    showDialog<void>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (ctx) {
        final size = MediaQuery.sizeOf(ctx);
        final viewPadding = MediaQuery.viewPaddingOf(ctx);
        final popupWidth = math.min(292.0, math.max(0.0, size.width - 16));
        const popupHeight = 52.0;
        final maxLeft = math.max(8.0, size.width - popupWidth - 8);
        final maxTop = math.max(
          viewPadding.top + 8,
          size.height - viewPadding.bottom - popupHeight - 8,
        );
        final left = (anchor.dx - popupWidth / 2)
            .clamp(8.0, maxLeft)
            .toDouble();
        final top = (anchor.dy - popupHeight - 10)
            .clamp(viewPadding.top + 8, maxTop)
            .toDouble();

        return Stack(
          children: [
            Positioned(
              left: left,
              top: top,
              width: popupWidth,
              child: _ReactionPopup(
                emojis: emojis,
                onSelected: (emoji) {
                  Navigator.pop(ctx);
                  _toggleReaction(msg, emoji);
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showMessageMenu(
    BuildContext context,
    Message msg,
    bool isMe,
  ) async {
    final isSystem = msg.type == MessageType.system;
    final canDelete = isMe || conv.isDM;
    final hasCopyableText =
        !isSystem && msg.isDecrypted && (msg.decryptedContent ?? '').isNotEmpty;
    final isLiveLocation =
        msg.type == MessageType.location &&
        isMe &&
        context.read<ChatProvider>().isLiveLocationActive(msg.id) &&
        msg.location != null &&
        msg.location!.isLive;
    final selected = await showMessageActionSheet<String>(
      context: context,
      message: msg,
      actions: [
        if (!isSystem)
          const MessageActionSheetItem(
            value: 'reply',
            icon: Icons.reply_rounded,
            label: 'Reply',
          ),
        if (msg.replyTo != null)
          const MessageActionSheetItem(
            value: 'jump_reply',
            icon: Icons.subdirectory_arrow_left_rounded,
            label: 'Jump to replied message',
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
            label: 'View sender',
            subtitle: '@${msg.sender!.username}',
          ),
        if (isMe && msg.type == MessageType.text && msg.isDecrypted)
          const MessageActionSheetItem(
            value: 'edit',
            icon: Icons.edit_outlined,
            label: 'Edit',
          ),
        if (isLiveLocation)
          const MessageActionSheetItem(
            value: 'stop_location',
            icon: Icons.location_off_rounded,
            label: 'Stop location sharing',
            color: Colors.orange,
            dividerBefore: true,
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
    if (selected == null || !mounted) return;

    switch (selected) {
      case 'reply':
        setState(() => _replyingTo = msg);
      case 'jump_reply':
        await _jumpToReply(msg);
      case 'copy_text':
        await _copyMessageText(msg);
      case 'copy_link':
        await _copyMessageLink(msg);
      case 'download':
        await _downloadMessageAttachment(msg);
      case 'sender':
        final sender = msg.sender;
        if (sender != null && mounted) {
          Navigator.push(
            this.context,
            MaterialPageRoute(builder: (_) => UserProfileScreen(user: sender)),
          );
        }
      case 'edit':
        _editMessage(msg);
      case 'stop_location':
        this.context.read<ChatProvider>().stopLiveLocation(msg.id);
      case 'report':
        await _reportMessage(msg);
      case 'delete':
        this.context.read<ChatProvider>().deleteMessage(conv.id, msg.id);
    }
  }

  Future<void> _reportMessage(Message msg) async {
    final reasonCtrl = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: const Text('Report message'),
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
        conv.id,
        channel: conv.isChannel,
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

  Future<void> _copyMessageText(Message msg) async {
    await Clipboard.setData(ClipboardData(text: msg.decryptedContent ?? ''));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Message text copied')));
  }

  Future<void> _copyMessageLink(Message msg) async {
    await Clipboard.setData(
      ClipboardData(
        text: messageDeepLink(conversationId: conv.id, messageId: msg.id),
      ),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Message link copied')));
  }

  Future<void> _downloadMessageAttachment(Message msg) async {
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

  Future<void> _toggleReaction(Message msg, String emoji) async {
    final messenger = ScaffoldMessenger.of(context);
    final alreadyReacted = msg.reactions.any(
      (reaction) => reaction.emoji == emoji && reaction.reactedByMe,
    );
    final chat = context.read<ChatProvider>();
    try {
      await chat.setReaction(
        convID: conv.id,
        msgID: msg.id,
        emoji: emoji,
        reacted: !alreadyReacted,
      );
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('Reaction failed: $e')));
      }
    }
  }

  Future<void> _setDisappearing(BuildContext context) async {
    final api = context.read<ApiService>();
    final chat = context.read<ChatProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final current = conv.messageTtlSeconds;
    final chosen = await showDisappearingMessagesPickerDialog(
      context,
      initialSeconds: current,
    );
    if (chosen == null || chosen == current) return;
    try {
      await api.setMessageTtl(conv.id, chosen);
      await chat.loadConversations();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            chosen == 0
                ? 'Disappearing messages turned off'
                : 'Messages now disappear after ${disappearingMessageDurationLabel(chosen)}',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<void> _setSlowMode(BuildContext context) async {
    final api = context.read<ApiService>();
    final chat = context.read<ChatProvider>();
    final messenger = ScaffoldMessenger.of(context);
    const options = <(String, int)>[
      ('Off', 0),
      ('10 seconds', 10),
      ('30 seconds', 30),
      ('1 minute', 60),
      ('5 minutes', 300),
    ];
    final current = conv.slowModeSeconds;
    final chosen = await showDialog<int>(
      context: context,
      builder: (ctx) => GlassSimpleDialog(
        title: const Text('Slow mode'),
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
      await api.setSlowMode(conv.id, chosen);
      await chat.loadConversations();
      messenger.showSnackBar(
        SnackBar(
          content: Text(chosen == 0 ? 'Slow mode off' : 'Slow mode updated'),
        ),
      );
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
      builder: (ctx) => GlassAlertDialog(
        title: Text(
          nextEnabled ? 'Turn encryption on?' : 'Turn encryption off?',
        ),
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

  Future<void> _editMessage(Message msg) async {
    final ctrl = TextEditingController(text: msg.decryptedContent ?? '');
    final chat = context.read<ChatProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final newText = await showDialog<String>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: const Text('Edit message'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: null,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
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
        convID: conv.id,
        msgID: msg.id,
        newPlaintext: newText,
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed to edit: $e')));
    }
  }

  void _showConversationInfo(BuildContext context, String currentUserID) {
    final messages = context.read<ChatProvider>().messagesFor(conv.id);
    showDialog<void>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: Text(conv.displayName(currentUserID)),
        content: ConversationInfoPanel(
          conversation: conv,
          currentUserId: currentUserID,
          messages: messages,
          onMessageSelected: (message) {
            Navigator.pop(ctx);
            _jumpToMessage(message.id);
          },
          onSharedSectionOpen: (section) {
            Navigator.pop(ctx);
            unawaited(
              showSharedContentSheet(
                context,
                conversation: conv,
                currentUserId: currentUserID,
                channel: false,
                initialSection: section,
                initialMessages: messages,
                onMessageSelected: (message) => _jumpToMessage(message.id),
              ),
            );
          },
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
    final canManageInfo =
        _currentMember(
          currentUserID,
        )?.hasPermission(AdminPermission.manageInfo) ??
        false;
    if (!canManageInfo) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Missing permission to edit this group')),
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
            final picked = await ImagePicker().pickImage(
              source: ImageSource.gallery,
              imageQuality: 90,
            );
            if (picked == null) return;
            setSt(() => uploading = true);
            try {
              final bytes = await picked.readAsBytes();
              final url = await api.uploadAvatar(
                fileBytes: bytes,
                filename: picked.name,
              );
              setSt(() {
                pendingAvatar = url;
                uploading = false;
              });
            } catch (e) {
              setSt(() => uploading = false);
              messenger.showSnackBar(
                SnackBar(content: Text('Upload failed: $e')),
              );
            }
          }

          return GlassAlertDialog(
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
                                ApiConfig.resolveMedia(pendingAvatar!),
                              )
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
                child: const Text('Cancel'),
              ),
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
                            SnackBar(content: Text('Failed to update: $e')),
                          );
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
    final currentMember = _currentMember(currentUserID);
    final canManageMembers =
        currentMember?.hasPermission(AdminPermission.manageMembers) ?? false;
    final canManageRoles =
        currentMember?.hasPermission(AdminPermission.manageRoles) ?? false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (ctx, scrollCtrl) => GlassSurface(
          blur: 56,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
                  child: Row(
                    children: [
                      Text(
                        'Members',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const Spacer(),
                      if (canManageMembers)
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
                                  ApiConfig.resolveMedia(m.user!.avatarUrl!),
                                )
                              : null,
                          child: m.user?.avatarUrl == null
                              ? Text(username[0].toUpperCase())
                              : null,
                        ),
                        title: Text(isSelf ? '$username (you)' : username),
                        subtitle: Text(_roleLabel(m.role)),
                        trailing:
                            (canManageRoles || canManageMembers) && !isSelf
                            ? IconButton(
                                icon: const Icon(Icons.more_vert),
                                onPressed: () {
                                  showModalBottomSheet<void>(
                                    context: context,
                                    isScrollControlled: true,
                                    backgroundColor: Colors.transparent,
                                    builder: (_) => GlassBottomSheetFrame(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const SizedBox(height: 8),
                                          if (canManageRoles)
                                            _MenuTile(
                                              icon: Icons
                                                  .admin_panel_settings_outlined,
                                              label: 'Permissions',
                                              onTap: () {
                                                Navigator.pop(context);
                                                _editGroupMemberPermissions(
                                                  context,
                                                  m,
                                                );
                                              },
                                            ),
                                          if (canManageMembers)
                                            _MenuTile(
                                              icon:
                                                  Icons.person_remove_outlined,
                                              label: 'Remove member',
                                              color: Colors.red,
                                              onTap: () {
                                                Navigator.pop(context);
                                                _removeMember(
                                                  context,
                                                  m.userId,
                                                  username,
                                                );
                                              },
                                            ),
                                          const SizedBox(height: 8),
                                        ],
                                      ),
                                    ),
                                  );
                                },
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
        return StatefulBuilder(
          builder: (ctx, setStateDialog) {
            Future<void> search(String q) async {
              if (q.trim().length < 2) return;
              setStateDialog(() => searching = true);
              try {
                final users = await context.read<ApiService>().searchUsers(
                  q.trim(),
                );
                setStateDialog(() {
                  results = users;
                  searching = false;
                });
              } catch (_) {
                setStateDialog(() => searching = false);
              }
            }

            return GlassAlertDialog(
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
                                    strokeWidth: 2,
                                  ),
                                ),
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
                            final alreadyIn = conv.members.any(
                              (m) => m.userId == u.id,
                            );
                            return ListTile(
                              dense: true,
                              leading: CircleAvatar(
                                radius: 16,
                                child: Text(username[0].toUpperCase()),
                              ),
                              title: Text('@$username'),
                              trailing: alreadyIn
                                  ? const Text(
                                      'Already in group',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey,
                                      ),
                                    )
                                  : TextButton(
                                      child: const Text('Add'),
                                      onPressed: () async {
                                        Navigator.pop(ctx);
                                        try {
                                          await context
                                              .read<ApiService>()
                                              .addMember(
                                                conv.id,
                                                u.id as String,
                                              );
                                          if (context.mounted) {
                                            context
                                                .read<ChatProvider>()
                                                .loadConversationMembers(
                                                  conv.id,
                                                );
                                            ScaffoldMessenger.of(
                                              context,
                                            ).showSnackBar(
                                              SnackBar(
                                                content: Text(
                                                  '@$username added',
                                                ),
                                              ),
                                            );
                                          }
                                        } catch (e) {
                                          if (context.mounted) {
                                            ScaffoldMessenger.of(
                                              context,
                                            ).showSnackBar(
                                              SnackBar(
                                                content: Text(
                                                  'Failed to add: $e',
                                                ),
                                              ),
                                            );
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
                  child: const Text('Close'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  String _roleLabel(MemberRole role) => switch (role) {
    MemberRole.admin => 'Admin',
    MemberRole.moderator => 'Moderator',
    MemberRole.member => 'Member',
  };

  Future<void> _editGroupMemberPermissions(
    BuildContext context,
    ConversationMember member,
  ) async {
    final api = context.read<ApiService>();
    final chat = context.read<ChatProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final username = member.user?.username ?? member.userId;
    await showAdminPermissionsSheet(
      context: context,
      member: member,
      onSave: (role, permissions) async {
        await api.setConversationMemberRole(
          conv.id,
          member.userId,
          role.apiValue,
          adminPermissions: permissions,
        );
        if (!mounted) return;
        await chat.loadConversationMembers(conv.id);
        messenger.showSnackBar(
          SnackBar(content: Text('@$username permissions updated')),
        );
      },
    );
  }

  Future<void> _removeMember(
    BuildContext context,
    String userID,
    String username,
  ) async {
    final api = context.read<ApiService>();
    final chat = context.read<ChatProvider>();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: const Text('Remove member?'),
        content: Text('Remove @$username from this group?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
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

  Future<void> _deleteGroupMessages(
    BuildContext context,
    String currentUserId,
  ) async {
    final currentMember = _currentMember(currentUserId);
    final canDeleteMessages =
        currentMember?.hasPermission(AdminPermission.deleteMessages) ?? false;
    final isAdmin = currentMember?.isAdmin ?? false;
    final chat = context.read<ChatProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => GlassBottomSheetFrame(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
              child: Text(
                'Delete messages',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                canDeleteMessages
                    ? 'Choose which messages to remove from this group.'
                    : 'Delete all messages you have sent in this group?',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ),
            const Divider(height: 1),
            const SizedBox(height: 4),
            _MenuTile(
              icon: Icons.delete_outline,
              label: 'Delete mine',
              onTap: () => Navigator.pop(ctx, 'mine'),
            ),
            if (canDeleteMessages)
              _MenuTile(
                icon: Icons.delete_sweep_outlined,
                label: 'Delete everyone\'s messages',
                color: Colors.red,
                onTap: () => Navigator.pop(ctx, 'all'),
              ),
            if (isAdmin)
              _MenuTile(
                icon: Icons.group_remove_outlined,
                label: 'Delete group',
                color: Colors.red,
                onTap: () => Navigator.pop(ctx, 'group'),
              ),
            _MenuTile(
              icon: Icons.close,
              label: 'Cancel',
              onTap: () => Navigator.pop(ctx),
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    try {
      switch (action) {
        case 'mine':
          await chat.deleteOwnMessages(conv.id);
        case 'all':
          await chat.deleteAllConversationMessages(conv.id);
        case 'group':
          await chat.deleteConversation(conv.id);
          if (mounted) navigator.pop();
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<void> _deleteConversation(BuildContext context) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final chat = context.read<ChatProvider>();
    final currentUserId = context.read<AuthProvider>().currentUser?.id ?? '';

    if (conv.isGroup) {
      final isOwner = conv.createdBy == currentUserId;
      final hasOtherAdmin = conv.members.any(
        (m) => m.userId != currentUserId && m.isAdmin,
      );
      if (isOwner && !hasOtherAdmin) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => GlassAlertDialog(
            title: const Text('Promote another admin first'),
            content: const Text(
              'Group owners can leave after another member is an admin. '
              'Otherwise, delete the group.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        return;
      }

      final action = await showDialog<String>(
        context: context,
        builder: (ctx) => GlassAlertDialog(
          title: const Text('Leave group?'),
          content: const Text(
            'You can leave, or leave and delete your sent messages.',
          ),
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
      if (action == null || !mounted) return;
      try {
        await chat.leaveConversation(
          conv.id,
          deleteOwnMessages: action == 'leave_delete',
        );
        if (mounted) navigator.pop();
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('Failed to leave: $e')));
      }
      return;
    }

    final api = context.read<ApiService>();
    final label = conv.isDM
        ? 'conversation'
        : conv.isGroup
        ? 'group'
        : 'channel';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: Text('Delete $label?'),
        content: Text(
          conv.isDM
              ? 'This will permanently delete all messages for both participants.'
              : 'This will permanently delete the $label and all its messages for everyone.',
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

class _AnimatedMessageEntry extends StatelessWidget {
  final String id;
  final Widget child;

  const _AnimatedMessageEntry({
    super.key,
    required this.id,
    required this.child,
  });

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

class _ReactionPopup extends StatelessWidget {
  final List<String> emojis;
  final ValueChanged<String> onSelected;

  const _ReactionPopup({required this.emojis, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return GlassContainer(
      shape: LiquidRoundedSuperellipse(borderRadius: 999),
      allowElevation: true,
      glowIntensity: 0.08,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final emoji in emojis)
            GestureDetector(
              onTap: () => onSelected(emoji),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                child: Text(emoji, style: const TextStyle(fontSize: 26)),
              ),
            ),
        ],
      ),
    );
  }
}

double _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

String _formatCrypto(double amount, String provider) {
  final decimals = provider == 'btc' ? 8 : 12;
  return '${amount.toStringAsFixed(decimals)} ${provider.toUpperCase()}';
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
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
      child: Row(
        children: [
          GlassContainer(
            shape: LiquidRoundedSuperellipse(borderRadius: 999),
            allowElevation: true,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _BouncingDots(controller: _ctrl),
                const SizedBox(width: 8),
                Text(
                  widget.label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurface.withValues(alpha: 0.60),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
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

/// Glass action-sheet tile — used in the chat overflow menu and member menus.
/// Pass [color] to render a destructive/warning action in red (or any colour).
class _MenuTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  const _MenuTile({
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

class _AttachTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _AttachTile({
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
