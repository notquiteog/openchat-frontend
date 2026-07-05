import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:local_auth/local_auth.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';
import '../../config/api_config.dart';
import '../../models/bot_command.dart';
import '../../models/channel_pinned_message.dart';
import '../channels/moderation_screen.dart';
import '../../models/conversation.dart';
import '../../models/conversation_topic.dart';
import '../../models/key_trust_pin.dart';
import '../../models/message.dart';
import '../../models/user.dart';
import '../../providers/auth_provider.dart';
import '../../providers/call_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/group_call_presence_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/api_service.dart';
import '../../services/mesh/nearby_mesh_service.dart';
import '../../services/sfu_call_controller.dart';
import '../call/sfu_call_screen.dart';
import '../../services/mls_service.dart';
import '../../services/notification_service.dart';
import '../../services/attachment_service.dart';
import '../../services/image_edit_service.dart';
import '../../services/message_search_service.dart';
import '../../services/proxy_service.dart';
import '../../services/secure_storage_service.dart';
import '../../services/translation_service.dart';
import '../call/stage_room_screen.dart';
import '../../widgets/pin_lock_gate.dart';
import '../../utils/custom_emoji_payload.dart';
import '../../utils/disappearing_message_duration.dart';
import '../../utils/local_conversation_preferences.dart';
import '../../utils/message_actions.dart';
import '../../utils/message_albums.dart';
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
import '../../widgets/day_separator.dart';
import '../../widgets/desktop.dart';
import '../../widgets/glass.dart';
import '../../widgets/key_change_banner.dart';
import '../../widgets/key_verification_badge.dart';
import '../../widgets/location_map_preview.dart';
import '../../utils/inbox_payment.dart';
import '../../widgets/attachment_variant_sheet.dart';
import '../../widgets/message_action_sheet.dart';
import '../../widgets/reaction_emoji_picker.dart';
import '../../widgets/reaction_menu.dart';
import '../../widgets/report_message_dialog.dart';
import '../../widgets/mention_autocomplete_panel.dart';
import '../../widgets/message_bubble.dart';
import '../../widgets/scheduled_messages_sheet.dart';
import '../../widgets/sticker_picker.dart';
import '../../widgets/voice_note_recorder.dart';
import '../profile/user_profile_screen.dart';

class ChatScreen extends StatefulWidget {
  final Conversation conversation;
  final String? initialMessageId;

  /// True when this screen lives in the right pane of the desktop split
  /// view instead of being pushed as a route — suppresses the back button.
  final bool embedded;

  const ChatScreen({
    super.key,
    required this.conversation,
    this.initialMessageId,
    this.embedded = false,
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

  /// True while a desktop drag carries files over the chat; drives the
  /// drop-highlight overlay.
  bool _dropHovering = false;
  bool _loadingMore = false;
  bool _historyExhausted = false;
  bool _sendSilent = false;
  bool _suppressLinkPreview = false;
  bool _locked = false;
  bool _unlocked = false;
  DateTime? _scheduledFor;
  int _lastMessageCount = 0;
  String? _lastTailMessageId;
  String? _lastReadReceiptSentMessageId;
  bool _wasNearBottom = true;
  bool _showNewMessagesPill = false;
  int _pendingNewMessageCount = 0;
  Message? _replyingTo;
  Timer? _typingTimer;
  Timer? _draftSaveTimer;
  Timer? _highlightTimer;
  final Map<String, GlobalKey> _messageKeys = {};
  String? _highlightedMessageId;
  final _chatSearchCtrl = TextEditingController();
  bool _chatSearchActive = false;
  String _chatSearchQuery = '';
  MessageSearchCategory? _chatSearchCategory;
  // Active topic ("thread") filtering the open chat; null = show all. Local to
  // the screen so it auto-clears on leave and never cross-talks between chats.
  String? _activeTopicId;
  AttachmentUploadProgress? _attachmentUploadProgress;
  ActiveMentionQuery? _activeMentionQuery;
  ActiveCommandQuery? _activeCommandQuery;
  List<BotCommand> _botCommands = const [];
  // Bot inline mode (Telegram `@bot <query>`): the active whole-input query, the
  // id the send returned (to correlate the WS answer), the latest results, and a
  // debounce so we don't hit the bot on every keystroke.
  ActiveInlineQuery? _activeInlineQuery;
  String? _activeInlineQueryId;
  List<Map<String, dynamic>>? _inlineResults;
  bool _inlineLoading = false;
  Timer? _inlineDebounce;
  StreamSubscription<Map<String, dynamic>>? _inlineSub;
  // Multi-select mode (#1).
  bool _selectionMode = false;
  final Set<String> _selectedIds = {};
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
  KeyTrustPin? _peerPin;
  String? _peerPinUserId;

  // Read the live conversation from the provider (members get loaded
  // asynchronously after the screen opens) and fall back to the one passed in.
  // build() selects this conversation, so updates here trigger a rebuild.
  Conversation get conv {
    return context.read<ChatProvider>().conversationById(
          widget.conversation.id,
        ) ??
        widget.conversation;
  }

  @override
  void initState() {
    super.initState();
    _settings = context.read<SettingsProvider>();
    NotificationService.setActiveConversation(widget.conversation.id);
    context.read<SecureStorageService>().hasConversationPin(conv.id).then((
      locked,
    ) {
      if (locked && mounted) setState(() => _locked = true);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final chat = context.read<ChatProvider>();
      _schedulePeerPinLoad();
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
            showAppToast(context, 'Message is not loaded yet', isError: true);
          }
        }
      }
      unawaited(chat.loadConversationMembers(conv.id));
      unawaited(_syncConversationPins());
      if (conv.isDM) unawaited(_loadBotCommands());
      if (conv.isGroup || conv.isChannel) {
        unawaited(chat.loadTopics(conv.id, channel: conv.isChannel));
      }
      if (mounted && conv.isGroup) {
        unawaited(context.read<GroupCallPresenceProvider>().refresh(conv.id));
      }
    });
    _scrollCtrl.addListener(_onScroll);
    _inputCtrl.addListener(_onInputTextChanged);
    // Bot inline-mode answers arrive out-of-band over WS; correlate them to the
    // active query by inline_query_id + conversation_id.
    _inlineSub = context.read<ChatProvider>().inlineAnswers.listen((event) {
      if (!mounted) return;
      if (event['inline_query_id'] != _activeInlineQueryId) return;
      if (event['conversation_id'] != widget.conversation.id) return;
      final results = (event['results'] as List?)
          ?.whereType<Map<String, dynamic>>()
          .toList();
      setState(() {
        _inlineResults = results ?? const [];
        _inlineLoading = false;
      });
    });
  }

  String? _dmPeerId() {
    if (!conv.isDM) return null;
    final currentUserId = context.read<AuthProvider>().currentUser?.id;
    if (currentUserId == null || currentUserId.isEmpty) return null;
    return conv.members
        .where((member) => member.userId != currentUserId)
        .firstOrNull
        ?.userId;
  }

  void _schedulePeerPinLoad() {
    final peerId = _dmPeerId();
    if (peerId == null || _peerPinUserId == peerId) return;
    _peerPinUserId = peerId;
    unawaited(_loadPeerPin(peerId));
  }

  Future<void> _loadPeerPin(String peerId) async {
    final pin = await context.read<SecureStorageService>().getKeyTrustPin(
      peerId,
    );
    if (!mounted || _peerPinUserId != peerId) return;
    setState(() => _peerPin = pin);
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
    // Whole-input inline mode (`@bot <query>`) takes precedence: while it's
    // active the member-mention and `/command` panels are suppressed so only one
    // autocomplete shows at a time.
    final nextInline = findActiveInlineQuery(
      value.text,
      value.selection.baseOffset,
    );
    _updateInlineQuery(nextInline);

    final collapsed = value.selection.isValid && value.selection.isCollapsed;
    final nextMention = collapsed && nextInline == null
        ? findActiveMentionQuery(value.text, value.selection.baseOffset)
        : null;
    // `/command` only autocompletes in a bot DM with a known command list.
    final nextCommand =
        collapsed && nextInline == null && _botCommands.isNotEmpty
        ? findActiveCommandQuery(value.text, value.selection.baseOffset)
        : null;
    final m = _activeMentionQuery;
    final c = _activeCommandQuery;
    final mentionSame =
        m?.start == nextMention?.start &&
        m?.end == nextMention?.end &&
        m?.query == nextMention?.query;
    final commandSame =
        c?.start == nextCommand?.start &&
        c?.end == nextCommand?.end &&
        c?.query == nextCommand?.query;
    if (mentionSame && commandSame) return;
    if (mounted) {
      setState(() {
        _activeMentionQuery = nextMention;
        _activeCommandQuery = nextCommand;
      });
    } else {
      _activeMentionQuery = nextMention;
      _activeCommandQuery = nextCommand;
    }
  }

  /// Drives bot inline mode from the composer text. Debounces a
  /// [ApiService.sendInlineQuery] whenever the active `@bot <query>` changes, and
  /// clears all inline state when the trigger disappears. Results themselves
  /// arrive asynchronously via the WS [ChatProvider.inlineAnswers] stream.
  void _updateInlineQuery(ActiveInlineQuery? next) {
    if (next == null) {
      if (_activeInlineQuery == null) return;
      _inlineDebounce?.cancel();
      setState(() {
        _activeInlineQuery = null;
        _activeInlineQueryId = null;
        _inlineResults = null;
        _inlineLoading = false;
      });
      return;
    }

    final prev = _activeInlineQuery;
    final same =
        prev?.botUsername == next.botUsername && prev?.query == next.query;
    if (same) return;

    setState(() {
      _activeInlineQuery = next;
      _inlineLoading = true;
      // Drop stale results/id so a late answer for the previous query is ignored.
      _inlineResults = null;
      _activeInlineQueryId = null;
    });

    _inlineDebounce?.cancel();
    _inlineDebounce = Timer(const Duration(milliseconds: 350), () {
      unawaited(_sendInlineQuery(next));
    });
  }

  Future<void> _sendInlineQuery(ActiveInlineQuery query) async {
    final api = context.read<ApiService>();
    final convId = widget.conversation.id;
    try {
      final id = await api.sendInlineQuery(
        convID: convId,
        botUsername: query.botUsername,
        query: query.query,
      );
      if (!mounted) return;
      // Only apply if this is still the query the user is composing.
      if (_activeInlineQuery?.botUsername != query.botUsername ||
          _activeInlineQuery?.query != query.query) {
        return;
      }
      setState(() {
        _activeInlineQueryId = id;
        if (id == null) _inlineLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      if (_activeInlineQuery?.botUsername != query.botUsername ||
          _activeInlineQuery?.query != query.query) {
        return;
      }
      // Bot unreachable / query rejected — stop spinning, show empty state.
      setState(() {
        _inlineLoading = false;
        _inlineResults = const [];
      });
    }
  }

  /// Sends a tapped inline result as a normal message, then tears down inline
  /// state. Reuses the exact [_sendMessage] send path by filling the composer.
  void _onInlinePick(Map<String, dynamic> result) {
    final content = result['input_message_content'];
    final text = (content is Map && content['message_text'] is String)
        ? content['message_text'] as String
        : (result['message_text'] as String?) ?? '';
    if (text.isEmpty) return;

    _inlineDebounce?.cancel();
    setState(() {
      _activeInlineQuery = null;
      _activeInlineQueryId = null;
      _inlineResults = null;
      _inlineLoading = false;
    });
    _setComposerValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ),
    );
    unawaited(_sendMessage());
  }

  Future<void> _loadBotCommands() async {
    final chat = context.read<ChatProvider>();
    if (conv.members.isEmpty) {
      await chat.loadConversationMembers(conv.id);
    }
    if (!mounted) return;
    final uid = context.read<AuthProvider>().currentUser?.id ?? '';
    if (!conv.isBotDM(uid)) return;
    final botUserId = _dmPeerId();
    if (botUserId == null || botUserId.isEmpty) return;
    try {
      final cmds = await context.read<ApiService>().getBotCommands(botUserId);
      if (mounted) setState(() => _botCommands = cmds);
    } catch (_) {
      // Commands are an optional affordance; ignore fetch failures.
    }
  }

  void _insertCommand(BotCommand command) {
    final value = _inputCtrl.value;
    final active = value.selection.isValid && value.selection.isCollapsed
        ? findActiveCommandQuery(value.text, value.selection.baseOffset)
        : _activeCommandQuery;
    if (active == null) return;
    final oldText = value.text;
    final start = active.start.clamp(0, oldText.length).toInt();
    final end = active.end.clamp(start, oldText.length).toInt();
    final replacement = '/${command.command} ';
    final newText = oldText.replaceRange(start, end, replacement);
    final shifted = shiftCustomEmojiEntitiesForTextEdit(
      oldText: oldText,
      newText: newText,
      entities: _customEmojiEntities,
    );
    setState(() {
      _activeCommandQuery = null;
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
      if (nearBottom) {
        final auth = context.read<AuthProvider>();
        final messages = context.read<ChatProvider>().messagesFor(conv.id);
        _maybeSendReadReceipt(messages, auth.currentUser?.id ?? '');
      }
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
    _inlineDebounce?.cancel();
    unawaited(_inlineSub?.cancel());
    _flushDraftSave();
    _inputCtrl.dispose();
    _chatSearchCtrl.dispose();
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

  /// Ensures the outgoing text payload is a JSON object carrying
  /// `suppress_link_preview` so the recipient's client skips the (IP-leaking)
  /// preview fetch. Works whether the draft payload is plain text or already
  /// JSON (e.g. with custom-emoji entities).
  String _payloadWithSuppressedPreview(String payload, String text) {
    Map<String, dynamic>? obj;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) obj = decoded;
    } catch (_) {}
    obj ??= {'text': text};
    obj['suppress_link_preview'] = true;
    return jsonEncode(obj);
  }

  Future<void> _sendMessage() async {
    // A bare 🎲 (plain unicode, no custom-emoji entities, no reply, nothing
    // scheduled) rolls a server-random animated dice instead of sending
    // text — Telegram behavior. Anything else falls through unchanged.
    if (_customEmojiEntities.isEmpty &&
        _replyingTo == null &&
        _scheduledFor == null &&
        isPlainDiceMessage(_inputCtrl.text)) {
      final diceText = _inputCtrl.text;
      _draftSaveTimer?.cancel();
      _hasPendingDraftSave = false;
      _setComposerValue(
        const TextEditingValue(
          text: '',
          selection: TextSelection.collapsed(offset: 0),
        ),
      );
      final messenger = ScaffoldMessenger.of(context);
      try {
        await context.read<ChatProvider>().rollDice(conv.id);
        if (!mounted) return;
        unawaited(_settings.clearMessageDraft(widget.conversation.id));
        _scrollToBottom();
      } catch (e) {
        if (!mounted) return;
        _restoreComposedMessage(diceText, null, const []);
        messenger.showSnackBar(SnackBar(content: Text(_sendErrorMessage(e))));
      }
      return;
    }

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
      final payload = _suppressLinkPreview
          ? _payloadWithSuppressedPreview(draft.payload, draft.text)
          : draft.payload;
      final chat = context.read<ChatProvider>();
      final activeTopic = _selectedTopic(chat, conv);
      if (activeTopic?.isClosed == true) {
        _restoreComposedMessage(rawText, replyingTo, draftEntities);
        showAppToast(context, 'This topic is closed', isError: true);
        return;
      }
      final sent = await chat.sendMessage(
        convID: conv.id,
        plaintext: payload,
        replyTo: replyTo,
        silent: _sendSilent,
        scheduledFor: _scheduledFor,
        topicId: _activeTopicId,
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
        setState(() {
          _scheduledFor = null;
          _suppressLinkPreview = false;
        });
      } else {
        _restoreComposedMessage(rawText, replyingTo, draftEntities);
        messenger.showSnackBar(
          const SnackBar(content: Text('Message could not be sent')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      _restoreComposedMessage(rawText, replyingTo, draftEntities);
      messenger.showSnackBar(SnackBar(content: Text(_sendErrorMessage(e))));
    }
  }

  String _sendErrorMessage(Object error) {
    if (error is ApiException) {
      return 'Could not send message (${error.statusCode} ${error.code}): ${error.message}';
    }
    if (error is ChatSendException) return error.message;
    return 'Could not send message: $error';
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

    _maybeSendReadReceipt(messages, currentUserID);
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

  void _maybeSendReadReceipt(List<Message> messages, String currentUserID) {
    if (!_wasNearBottom || messages.isEmpty || currentUserID.isEmpty) return;
    final tailMessageId = messages.last.id;
    if (tailMessageId == _lastReadReceiptSentMessageId) return;
    _lastReadReceiptSentMessageId = tailMessageId;
    unawaited(
      context.read<ChatProvider>().sendReadReceipt(conv.id, tailMessageId),
    );
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
              const GlassSheetGrabber(),
              GlassSheetHeader(
                icon: Icons.schedule_send_outlined,
                title: 'Delivery options',
                subtitle: 'Send quietly or schedule this message.',
                onClose: () => Navigator.pop(ctx),
              ),
              GlassListTile(
                leading: const Icon(Icons.notifications_off_outlined),
                title: const Text(
                  'Send silently',
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
              GlassListTile(
                leading: const Icon(Icons.link_off_rounded),
                title: const Text(
                  'No link preview',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                trailing: GlassSwitch(
                  value: _suppressLinkPreview,
                  onChanged: (v) {
                    setState(() => _suppressLinkPreview = v);
                    setSheetState(() {});
                  },
                  activeColor: Theme.of(context).colorScheme.primary,
                  enableHaptics: true,
                ),
                onTap: () {
                  setState(() => _suppressLinkPreview = !_suppressLinkPreview);
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
    final settings = context.read<SettingsProvider>();
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
        unawaited(settings.recordRecentSticker(stickerID));
        _scrollToBottom();
      } else if (mounted) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Sticker could not be sent')),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(_sendErrorMessage(e))));
      }
    }
  }

  void _insertCustomEmoji(Map<String, dynamic> emojiData) {
    final id = emojiData['id'] as String? ?? '';
    if (id.isEmpty) return;
    unawaited(context.read<SettingsProvider>().recordRecentEmoji(id));
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

  List<SpecialMention> _specialMentionSuggestions() {
    return specialMentionSuggestions(
      active: _activeMentionQuery,
      allowed:
          conv.type == ConversationType.group ||
          conv.type == ConversationType.channel,
    );
  }

  void _insertSpecialMention(SpecialMention special) {
    final value = _inputCtrl.value;
    final active = value.selection.isValid && value.selection.isCollapsed
        ? findActiveMentionQuery(value.text, value.selection.baseOffset)
        : _activeMentionQuery;
    if (active == null) return;
    final oldText = value.text;
    final start = active.start.clamp(0, oldText.length).toInt();
    final end = active.end.clamp(start, oldText.length).toInt();
    final replacement = '@${special.handle} ';
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
      showAppToast(context, 'Message is not loaded', isError: true);
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

  Message? _replyPreviewFor(Message msg, Map<String, Message> messagesById) {
    final replyTo = msg.effectiveReplyTo;
    if (replyTo == null) return null;
    return messagesById[replyTo];
  }

  Future<void> _jumpToReply(Message msg) async {
    final replyTo = msg.effectiveReplyTo;
    if (replyTo == null) return;
    final chat = context.read<ChatProvider>();
    final found = await chat.ensureMessageLoaded(conv.id, replyTo);
    if (!mounted) return;
    if (!found) {
      showAppToast(
        context,
        'Original message is not loaded yet',
        isError: true,
      );
      return;
    }
    await _jumpToMessage(replyTo);
  }

  void _openChatSearch() {
    setState(() {
      _chatSearchActive = true;
      _showStickers = false;
      _showCustomEmojis = false;
    });
  }

  void _closeChatSearch() {
    if (!_chatSearchActive && _chatSearchQuery.isEmpty) return;
    setState(() {
      _chatSearchActive = false;
      _chatSearchQuery = '';
      _chatSearchCategory = null;
      _chatSearchCtrl.clear();
    });
  }

  Future<void> _openChatSearchResult(MessageSearchResult result) async {
    final chat = context.read<ChatProvider>();
    final found = await chat.ensureMessageLoaded(conv.id, result.messageId);
    if (!mounted) return;
    if (!found) {
      showAppToast(context, 'Message is not loaded yet', isError: true);
      return;
    }
    setState(() {
      _chatSearchActive = false;
      _activeTopicId = null;
      _showStickers = false;
      _showCustomEmojis = false;
    });
    await Future<void>.delayed(const Duration(milliseconds: 40));
    if (mounted) await _jumpToMessage(result.messageId);
  }

  void _showSharedMediaGallery(String currentUserID) {
    final messages = context.read<ChatProvider>().messagesFor(conv.id);
    unawaited(
      showSharedContentSheet(
        context,
        conversation: conv,
        currentUserId: currentUserID,
        channel: false,
        initialSection: SharedContentSection.media,
        initialMessages: messages,
        onMessageSelected: (message) => _jumpToMessage(message.id),
      ),
    );
  }

  Future<void> _showAttachmentPicker() async {
    // image_picker's camera source is only implemented on mobile (and web);
    // on desktop it throws "requires a cameraDelegate", so only offer it where
    // it actually works.
    final cameraSupported =
        kIsWeb ||
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;

    var choice = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => GlassBottomSheetFrame(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const GlassSheetGrabber(),
            GlassSheetHeader(
              icon: Icons.add_rounded,
              title: 'Add to message',
              subtitle:
                  'Hold photo, video, file, or location for more ways '
                  'to send.',
              onClose: () => Navigator.pop(sheetCtx),
            ),
            const SizedBox(height: 4),
            // Media & location — chevron rows reveal "send as…" variants on hold.
            GlassMenuSection(
              entries: [
                GlassMenuEntry(
                  icon: Icons.photo_library_outlined,
                  label: 'Photo',
                  showChevron: true,
                  // One picker for both: a single selection sends solo, several
                  // send as an album.
                  onTap: () => Navigator.pop(sheetCtx, 'gallery_photos'),
                  onLongPress: () => Navigator.pop(sheetCtx, 'photo_variants'),
                ),
                if (cameraSupported)
                  GlassMenuEntry(
                    icon: Icons.camera_alt_outlined,
                    label: 'Take photo',
                    onTap: () => Navigator.pop(sheetCtx, 'camera_image'),
                  ),
                GlassMenuEntry(
                  icon: Icons.videocam_outlined,
                  label: 'Video',
                  showChevron: true,
                  onTap: () => Navigator.pop(sheetCtx, 'gallery_video'),
                  onLongPress: () => Navigator.pop(sheetCtx, 'video_variants'),
                ),
                GlassMenuEntry(
                  icon: Icons.attach_file_rounded,
                  label: 'File',
                  showChevron: true,
                  onTap: () => Navigator.pop(sheetCtx, 'file'),
                  onLongPress: () => Navigator.pop(sheetCtx, 'file_variants'),
                ),
                GlassMenuEntry(
                  icon: Icons.share_location_outlined,
                  label: 'Share location',
                  showChevron: true,
                  onTap: () => Navigator.pop(sheetCtx, 'location_once'),
                  onLongPress: () =>
                      Navigator.pop(sheetCtx, 'location_variants'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            GlassMenuSection(
              entries: [
                GlassMenuEntry(
                  icon: Icons.poll_outlined,
                  label: 'Poll',
                  onTap: () => Navigator.pop(sheetCtx, 'poll'),
                ),
                GlassMenuEntry(
                  icon: Icons.event_available_outlined,
                  label: 'Meeting',
                  onTap: () => Navigator.pop(sheetCtx, 'meeting'),
                ),
                GlassMenuEntry(
                  icon: Icons.person_add_alt_1_outlined,
                  label: 'Share contact',
                  onTap: () => Navigator.pop(sheetCtx, 'contact'),
                ),
                GlassMenuEntry(
                  icon: Icons.mic_none_outlined,
                  label: 'Voice note',
                  onTap: () => Navigator.pop(sheetCtx, 'voice'),
                ),
                GlassMenuEntry(
                  icon: Icons.payments_outlined,
                  label: 'Pay or request',
                  onTap: () => Navigator.pop(sheetCtx, 'payment'),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );

    if (choice == null || !mounted) return;
    // Long-pressed tiles resolve to a concrete choice via a small variant
    // sheet (view-once / spoiler / live) before the normal dispatch below.
    if (choice.endsWith('_variants')) {
      choice = await showAttachmentVariantSheet(context, choice);
      if (choice == null || !mounted) return;
    }
    if (choice == 'poll') {
      await _showCreatePollDialog();
      return;
    }
    if (choice == 'meeting') {
      await _showCreateMeetingDialog();
      return;
    }
    if (choice == 'contact') {
      await _shareContact();
      return;
    }
    if (choice == 'gallery_photos') {
      await _sendPhotos();
      return;
    }
    if (choice == 'edit_image') {
      await _sendEditedPhoto();
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
    final viewOnce = choice.startsWith('view_once_');
    final hasSpoiler = choice.startsWith('spoiler_');

    EncryptedAttachmentUpload? pending;
    VoiceNoteRecording? voiceNote;
    try {
      pending = switch (choice) {
        'view_once_image' => await attachmentService.pickImageForOutbox(
          onProgress: _setAttachmentUploadProgress,
        ),
        'spoiler_image' => await attachmentService.pickImageForOutbox(
          onProgress: _setAttachmentUploadProgress,
        ),
        'camera_image' => await attachmentService.pickImageForOutbox(
          fromCamera: true,
          onProgress: _setAttachmentUploadProgress,
        ),
        'gallery_video' => await attachmentService.pickVideoForOutbox(
          onProgress: _setAttachmentUploadProgress,
        ),
        'view_once_video' => await attachmentService.pickVideoForOutbox(
          onProgress: _setAttachmentUploadProgress,
        ),
        'spoiler_video' => await attachmentService.pickVideoForOutbox(
          onProgress: _setAttachmentUploadProgress,
        ),
        'file' => await attachmentService.pickFileForOutbox(
          onProgress: _setAttachmentUploadProgress,
        ),
        'view_once_file' => await attachmentService.pickFileForOutbox(
          onProgress: _setAttachmentUploadProgress,
        ),
        'voice' => await (() async {
          voiceNote = await showVoiceNoteRecorder(context);
          final note = voiceNote;
          if (note == null) return null;
          return attachmentService.prepareVoiceNoteForOutbox(
            note.file,
            duration: note.duration,
            waveform: note.waveform,
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
        viewOnce: viewOnce,
        hasSpoiler: hasSpoiler,
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

  /// Sends files dropped onto the chat (desktop drag-and-drop). Each file
  /// goes through the same encrypt-and-upload path as the attachment picker.
  Future<void> _sendDroppedFiles(List<XFile> files) async {
    if (files.isEmpty || !mounted) return;
    final attachmentService = AttachmentService(context.read<ApiService>());
    final chat = context.read<ChatProvider>();
    final messenger = ScaffoldMessenger.of(context);
    for (final file in files) {
      try {
        _setAttachmentUploadProgress(
          const AttachmentUploadProgress(
            stage: AttachmentUploadStage.preparing,
          ),
        );
        final prepared = await AttachmentService.prepareSelectedFileForUpload(
          file,
        );
        final pending = await attachmentService.encryptPreparedAttachment(
          prepared,
          onProgress: _setAttachmentUploadProgress,
        );
        if (!mounted) return;
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
            SnackBar(content: Text('${file.name} could not be sent')),
          );
        }
      } catch (e) {
        if (!mounted) return;
        messenger.showSnackBar(
          SnackBar(content: Text('Could not send ${file.name}: $e')),
        );
      } finally {
        _clearAttachmentUploadProgress();
      }
      if (!mounted) return;
    }
  }

  /// Sends a single gallery photo after an optional crop/rotate edit.
  Future<void> _sendEditedPhoto() async {
    final attachmentService = AttachmentService(context.read<ApiService>());
    final chat = context.read<ChatProvider>();
    final messenger = ScaffoldMessenger.of(context);
    EncryptedAttachmentUpload? pending;
    try {
      final picked = await attachmentService.pickEditableImage();
      if (picked == null || !mounted) return;
      final edited = await ImageEditService.editImage(picked);
      if (!mounted) return;
      _setAttachmentUploadProgress(
        const AttachmentUploadProgress(stage: AttachmentUploadStage.preparing),
      );
      final prepared = await AttachmentService.prepareGalleryPhotoForUpload(
        edited ?? picked,
      );
      pending = await attachmentService.encryptPreparedAttachment(
        prepared,
        onProgress: _setAttachmentUploadProgress,
      );
    } catch (e) {
      _clearAttachmentUploadProgress();
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('Upload failed: $e')));
      }
      return;
    }

    if (!mounted) {
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

  /// Unified photo send: one multi-select picker; a single selection sends
  /// solo, several send as an album.
  Future<void> _sendPhotos() async {
    final attachmentService = AttachmentService(context.read<ApiService>());
    final chat = context.read<ChatProvider>();
    final messenger = ScaffoldMessenger.of(context);
    List<EncryptedAttachmentUpload> items;
    try {
      items = await attachmentService.pickImagesForAlbum(
        onProgress: _setAttachmentUploadProgress,
      );
    } catch (e) {
      _clearAttachmentUploadProgress();
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('Upload failed: $e')));
      }
      return;
    }
    if (items.isEmpty || !mounted) {
      _clearAttachmentUploadProgress();
      return;
    }
    var ok = 0;
    try {
      _setAttachmentUploadProgress(
        const AttachmentUploadProgress(stage: AttachmentUploadStage.sending),
      );
      for (final item in items) {
        try {
          if (await chat.sendPreparedAttachment(
            convID: conv.id,
            attachment: item,
            onProgress: items.length == 1 ? _setAttachmentUploadProgress : null,
          )) {
            ok++;
          }
        } catch (_) {}
      }
    } finally {
      _clearAttachmentUploadProgress();
    }
    if (!mounted) return;
    if (ok > 0) {
      _scrollToBottom();
    } else {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not send photos')),
      );
    }
  }

  Future<void> _shareContact() async {
    final me = context.read<AuthProvider>().currentUser;
    final candidates = <User>[
      ?me,
      ...conv.members
          .map((m) => m.user)
          .whereType<User>()
          .where((u) => u.id != me?.id),
    ];
    if (candidates.isEmpty) return;
    final chosen = await showModalBottomSheet<User>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => GlassBottomSheetFrame(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const GlassSheetGrabber(),
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Share a contact',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
            ),
            for (final u in candidates)
              GlassListTile(
                leading: CircleAvatar(
                  child: Text(
                    u.username.isNotEmpty ? u.username[0].toUpperCase() : '?',
                  ),
                ),
                title: Text(
                  u.id == me?.id ? '${u.displayName} (You)' : u.displayName,
                ),
                subtitle: Text('@${u.username}'),
                onTap: () => Navigator.pop(sheetCtx, u),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    final contact = MessageContact(
      userId: chosen.id,
      username: chosen.username,
      displayName: chosen.displayName,
      publicKey: chosen.publicKey,
      fingerprint: chosen.keyFingerprint,
    );
    final messenger = ScaffoldMessenger.of(context);
    final sent = await context.read<ChatProvider>().sendMessage(
      convID: conv.id,
      plaintext: jsonEncode({'text': '', 'contact': contact.toJson()}),
      messageType: 'contact',
    );
    if (!mounted) return;
    if (sent) {
      _scrollToBottom();
    } else {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not send contact')),
      );
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
      showAppToast(context, 'No chat member available', isError: true);
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
    var transferClientNonce = 'chat-pay-${const Uuid().v4()}';
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
                showAppToast(context, 'Enter an amount', isError: true);
                return;
              }
              final isCryptoAmount = amountUnit == 'crypto';
              final fiatCurrency = isCryptoAmount
                  ? null
                  : amountUnit.toUpperCase();
              final chat = context.read<ChatProvider>();
              setSheet(() => submitting = true);
              try {
                if (payMode) {
                  final useWallet =
                      paymentSource == 'wallet' &&
                      (!isCryptoAmount || amount <= balanceFor(provider));
                  if (useWallet) {
                    if (isCryptoAmount && amount > balanceFor(provider)) {
                      showAppToast(
                        context,
                        'Not enough app wallet balance',
                        isError: true,
                      );
                      return;
                    }
                    final result = await api.sendPaymentTransfer(
                      toUserID: selectedUserID,
                      provider: provider,
                      amount: isCryptoAmount ? amount : null,
                      fiatAmount: isCryptoAmount ? null : amount,
                      fiatCurrency: fiatCurrency,
                      conversationID: conv.id,
                      note: noteCtrl.text,
                      clientNonce: transferClientNonce,
                    );
                    final transfer =
                        result['transfer'] as Map<String, dynamic>?;
                    if (transfer != null) {
                      await chat.sendPaymentArtifact(
                        convID: conv.id,
                        kind: 'payment_transfer',
                        payload: {
                          'kind': 'payment_transfer',
                          'transfer': transfer,
                        },
                      );
                    }
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
                    final deposit = result['deposit'] as Map<String, dynamic>?;
                    if (deposit != null) {
                      await chat.sendPaymentArtifact(
                        convID: conv.id,
                        kind: 'invoice',
                        payload: {
                          'kind': 'invoice',
                          'invoice': {
                            'id': deposit['id'],
                            'title': 'External payment',
                            'description': noteCtrl.text.trim(),
                            'provider': deposit['provider'],
                            'crypto_amount': deposit['expected_amount'],
                            'crypto_address': deposit['crypto_address'],
                            'status': deposit['status'],
                          },
                        },
                      );
                    }
                    if (!mounted || !sheetCtx.mounted) return;
                    Navigator.pop(sheetCtx);
                    if (deposit != null) _showExternalPaymentAddress(deposit);
                    return;
                  }
                } else {
                  final result = await api.createPaymentRequest(
                    payerID: selectedUserID,
                    conversationID: conv.id,
                    provider: provider,
                    amount: isCryptoAmount ? amount : null,
                    fiatAmount: isCryptoAmount ? null : amount,
                    fiatCurrency: fiatCurrency,
                    title: 'Payment request',
                    note: noteCtrl.text,
                  );
                  final request = result['request'] as Map<String, dynamic>?;
                  if (request != null) {
                    await chat.sendPaymentArtifact(
                      convID: conv.id,
                      kind: 'payment_request',
                      payload: {'kind': 'payment_request', 'request': request},
                    );
                  }
                }
                if (!mounted || !sheetCtx.mounted) return;
                Navigator.pop(sheetCtx);
                _scrollToBottom();
                transferClientNonce = 'chat-pay-${const Uuid().v4()}';
              } catch (e) {
                if (!mounted) return;
                showAppToast(context, e.toString(), isError: true);
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
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const GlassSheetGrabber(),
                  GlassSheetHeader(
                    icon: Icons.payments_outlined,
                    title: payMode ? 'Send payment' : 'Request payment',
                    subtitle:
                        'Use the app wallet or create an external invoice.',
                    onClose: () => Navigator.pop(sheetCtx),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: GlassSegmentedControl(
                            segments: const ['Pay', 'Request'],
                            selectedIndex: payMode ? 0 : 1,
                            onSegmentSelected: (i) =>
                                setSheet(() => payMode = i == 0),
                          ),
                        ),
                        const SizedBox(width: 10),
                        // Opaque pill — the sheet itself is already glass;
                        // nesting another glass surface stacks a second
                        // backdrop pass ("glass for chrome, opaque for
                        // content").
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest
                                .withValues(alpha: 0.45),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '${available.toStringAsFixed(provider == 'btc' ? 8 : 12)} ${provider.toUpperCase()}',
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
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
                  GlassSegmentedControl(
                    segments: [for (final p in providers) p.toUpperCase()],
                    selectedIndex: providers
                        .indexOf(provider)
                        .clamp(0, providers.length - 1),
                    onSegmentSelected: (i) => setSheet(() {
                      provider = providers[i];
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
                    GlassSegmentedControl(
                      segments: const ['App wallet', 'External'],
                      selectedIndex:
                          (canUseWallet ? paymentSource : 'external') ==
                              'wallet'
                          ? 0
                          : 1,
                      onSegmentSelected: (i) => setSheet(
                        () => paymentSource = i == 0 ? 'wallet' : 'external',
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  GlassSegmentedControl(
                    segments: [provider.toUpperCase(), 'USD', 'EUR'],
                    selectedIndex: switch (amountUnit) {
                      'usd' => 1,
                      'eur' => 2,
                      _ => 0,
                    },
                    onSegmentSelected: (i) => setSheet(() {
                      amountUnit = switch (i) {
                        1 => 'usd',
                        2 => 'eur',
                        _ => 'crypto',
                      };
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
                        ? const GlassProgressIndicator.circular(
                            size: 16,
                            strokeWidth: 2,
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
                            showAppToast(context, 'Coordinates copied');
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

  static String formatMeetingSlot(DateTime d) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final local = d.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '${months[local.month - 1]} ${local.day} · $hh:$mm';
  }

  Future<void> _showCreateMeetingDialog() async {
    final titleCtrl = TextEditingController();
    final slots = <DateTime>[];
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogCtx) => StatefulBuilder(
          builder: (dialogCtx, setDialog) {
            Future<void> addSlot() async {
              final date = await showDatePicker(
                context: dialogCtx,
                firstDate: DateTime.now(),
                lastDate: DateTime.now().add(const Duration(days: 365)),
                initialDate: DateTime.now(),
              );
              if (date == null) return;
              if (!dialogCtx.mounted) return;
              final time = await showTimePicker(
                context: dialogCtx,
                initialTime: TimeOfDay.now(),
              );
              if (time == null) return;
              setDialog(
                () => slots.add(
                  DateTime(
                    date.year,
                    date.month,
                    date.day,
                    time.hour,
                    time.minute,
                  ),
                ),
              );
            }

            Future<void> submit() async {
              final title = titleCtrl.text.trim();
              if (title.isEmpty || slots.length < 2) {
                showAppToast(
                  context,
                  'Title and at least 2 time slots required',
                  isError: true,
                );
                return;
              }
              Navigator.pop(dialogCtx);
              slots.sort();
              try {
                final sent = await context.read<ChatProvider>().sendPoll(
                  convID: conv.id,
                  question: '📅 $title',
                  options: slots
                      .map((d) => d.toUtc().toIso8601String())
                      .toList(),
                  meeting: true,
                  isAnonymous: false,
                  silent: _sendSilent,
                );
                if (sent && mounted) _scrollToBottom();
              } catch (e) {
                if (!mounted) return;
                showAppToast(context, e.toString(), isError: true);
              }
            }

            return GlassAlertDialog(
              title: const Text('New meeting'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: titleCtrl,
                      decoration: const InputDecoration(labelText: 'Title'),
                    ),
                    const SizedBox(height: 8),
                    for (var i = 0; i < slots.length; i++)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.schedule),
                        title: Text(formatMeetingSlot(slots[i])),
                        trailing: IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => setDialog(() => slots.removeAt(i)),
                        ),
                      ),
                    TextButton.icon(
                      icon: const Icon(Icons.add),
                      label: const Text('Add time slot'),
                      onPressed: addSlot,
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
      titleCtrl.dispose();
    }
  }

  Future<void> _showCreatePollDialog() async {
    final questionCtrl = TextEditingController();
    final optionCtrls = [TextEditingController(), TextEditingController()];
    final explanationCtrl = TextEditingController();
    var anonymous = true;
    var multiple = false;
    var quiz = false;
    var sealedTally = false;
    var correctOption = 0;
    // Server-blind tallies (#57) only work where ballots can be sealed to every
    // member and counted on-device without revealing the voter: PGP chats only
    // (MLS leaks the sender to the group).
    final canSealTally = conv.usesPgp && !conv.usesMls;

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
                showAppToast(
                  context,
                  'Question and option required',
                  isError: true,
                );
                return;
              }
              Navigator.pop(dialogCtx);
              try {
                final sent = await context.read<ChatProvider>().sendPoll(
                  convID: conv.id,
                  question: question,
                  options: options,
                  isAnonymous: sealedTally ? true : anonymous,
                  allowsMultipleAnswers: multiple,
                  silent: _sendSilent,
                  quiz: quiz,
                  sealedTally: sealedTally,
                  correctOptionId: quiz
                      ? correctOption.clamp(0, options.length - 1)
                      : null,
                  explanation: quiz ? explanationCtrl.text : null,
                );
                if (sent && mounted) _scrollToBottom();
              } catch (e) {
                if (!mounted) return;
                showAppToast(context, e.toString(), isError: true);
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
                        child: Row(
                          children: [
                            if (quiz)
                              IconButton(
                                tooltip: 'Mark correct',
                                icon: Icon(
                                  i == correctOption
                                      ? Icons.radio_button_checked
                                      : Icons.radio_button_unchecked,
                                  color: i == correctOption
                                      ? Theme.of(context).colorScheme.primary
                                      : null,
                                ),
                                onPressed: () =>
                                    setDialog(() => correctOption = i),
                              ),
                            Expanded(
                              child: TextField(
                                controller: optionCtrls[i],
                                decoration: InputDecoration(
                                  labelText: quiz && i == correctOption
                                      ? 'Option ${i + 1} (correct)'
                                      : 'Option ${i + 1}',
                                ),
                                textInputAction: TextInputAction.next,
                              ),
                            ),
                          ],
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
                    if (!quiz)
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
                    GlassListTile(
                      title: const Text(
                        'Quiz mode',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: const Text(
                        'One correct answer, revealed after voting',
                      ),
                      trailing: GlassSwitch(
                        value: quiz,
                        onChanged: (v) => setDialog(() {
                          quiz = v;
                          if (v) {
                            multiple = false;
                            sealedTally = false;
                          }
                        }),
                        activeColor: Theme.of(context).colorScheme.primary,
                        enableHaptics: true,
                      ),
                      onTap: () => setDialog(() {
                        quiz = !quiz;
                        if (quiz) {
                          multiple = false;
                          sealedTally = false;
                        }
                      }),
                    ),
                    if (quiz) ...[
                      const SizedBox(height: 8),
                      TextField(
                        controller: explanationCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Explanation (optional)',
                        ),
                        maxLines: 2,
                      ),
                    ],
                    if (canSealTally && !quiz)
                      GlassListTile(
                        title: const Text(
                          'Sealed tally',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: const Text(
                          'Votes are counted only on members’ devices — '
                          'the server never sees the result. Always anonymous.',
                        ),
                        trailing: GlassSwitch(
                          value: sealedTally,
                          onChanged: (v) => setDialog(() {
                            sealedTally = v;
                            if (v) anonymous = true;
                          }),
                          activeColor: Theme.of(context).colorScheme.primary,
                          enableHaptics: true,
                        ),
                        onTap: () => setDialog(() {
                          sealedTally = !sealedTally;
                          if (sealedTally) anonymous = true;
                        }),
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
      explanationCtrl.dispose();
      for (final ctrl in optionCtrls) {
        ctrl.dispose();
      }
    }
  }

  Future<void> _startCall({required bool isVideo}) async {
    final auth = context.read<AuthProvider>();
    final callProvider = context.read<CallProvider>();

    final recipients = conv.members
        .where((m) => m.userId != (auth.currentUser?.id ?? ''))
        .toList(growable: false);

    if (recipients.isEmpty) {
      showAppToast(context, 'No one else is in this chat', isError: true);
      return;
    }

    // The root CallOverlay shows the call UI off CallProvider state, so we just
    // start the call — no navigation needed.
    try {
      await callProvider.startCall(
        targetUserId: recipients.first.userId,
        targetUsername: conv.isGroup
            ? conv.name
            : recipients.first.user?.username,
        conversationId: conv.id,
        isVideo: isVideo,
        additionalUserIds: recipients.skip(1).map((m) => m.userId).toList(),
      );
    } catch (e) {
      if (!mounted) return;
      showAppToast(context, 'Could not start call: $e', isError: true);
    }
  }

  /// Groups let the user pick the call backend: P2P or the premium SFU. 1:1
  /// chats are always P2P (no chooser). IMPORTANT: P2P group calls are a star
  /// where each invitee connects only to the CALLER — the caller does not relay
  /// media between invitees, so with 3+ people the invitees hear/see only the
  /// caller, not each other. Use the SFU for a full everyone-hears-everyone
  /// group call. The copy below must not claim otherwise.
  void _onCallPressed({required bool isVideo}) {
    // Calls use UDP media that can't be tunnelled through a TCP SOCKS proxy;
    // with the strict toggle on, refuse rather than leak the real IP.
    if (ProxyService.instance.callsBlocked) {
      showAppToast(
        context,
        'Calls are disabled while a proxy is active (strict mode). '
        'Turn off the proxy or disable strict mode to call.',
        isError: true,
      );
      return;
    }
    if (!conv.isGroup) {
      _startCall(isVideo: isVideo);
      return;
    }
    _showGroupCallChooser(isVideo: isVideo);
  }

  void _showGroupCallChooser({required bool isVideo}) {
    final isPremium =
        context.read<AuthProvider>().currentUser?.isPremium == true;
    // Group P2P is a star, not a mesh: only the caller holds a peer connection
    // per participant, so the caller's CPU/uplink is the bottleneck (see
    // call_service.dart). Past ~4 members, nudge toward the SFU by listing it
    // first as recommended (still a free choice — P2P stays available).
    final preferSfu = conv.members.length > 4;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        final isTrueGroup = conv.members.length > 2;
        final p2pTile = GlassActionTile(
          icon: Icons.lan_outlined,
          label: 'Call with P2P',
          subtitle: isTrueGroup
              ? 'Direct peer-to-peer — everyone connects to you only, so '
                    'others won’t hear each other. Use SFU for a full '
                    'group call'
              : 'Direct peer-to-peer — no server sees your media',
          onTap: () {
            Navigator.pop(sheetCtx);
            _startCall(isVideo: isVideo);
          },
        );
        final sfuTile = GlassActionTile(
          icon: Icons.hub_outlined,
          label: 'Call with SFU',
          subtitle: !isPremium
              ? preferSfu
                    ? 'Recommended for this group size — requires '
                          'OpenChat Premium'
                    : 'Requires OpenChat Premium'
              : preferSfu
              ? 'Recommended for this group size — the server forwards media'
              : 'The server forwards media — scales to larger groups',
          trailing: isPremium
              ? null
              : const Icon(Icons.workspace_premium_outlined, size: 20),
          onTap: () {
            Navigator.pop(sheetCtx);
            if (isPremium) {
              _startSfuCall(isVideo: isVideo);
            } else {
              showAppToast(
                context,
                'SFU group calls require OpenChat Premium',
                isError: true,
              );
            }
          },
        );
        return GlassBottomSheetFrame(
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const GlassSheetGrabber(),
                const GlassSheetHeader(
                  icon: Icons.call,
                  title: 'Start a group call',
                  subtitle: 'Choose how to connect',
                ),
                if (preferSfu) ...[sfuTile, p2pTile] else ...[p2pTile, sfuTile],
                GlassActionTile(
                  icon: Icons.podcasts_rounded,
                  label: 'Voice stage room',
                  subtitle: 'Audio room with speakers, listeners & raise-hand',
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => StageRoomScreen(conversation: conv),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 10),
              ],
            ),
          ),
        );
      },
    );
  }

  void _startSfuCall({required bool isVideo}) {
    final sfu = context.read<SfuCallController>();
    final call = context.read<CallProvider>();
    final api = context.read<ApiService>();

    // Sealed conversations get media frame encryption: generate the call key
    // and hand it to every member over sealed signals so their banner "Join"
    // has it ready. Joiners who miss the signal request it on demand.
    String? e2eeKey;
    if (conv.isEncrypted) {
      e2eeKey = call.createSfuKey(conv.id);
      unawaited(() async {
        try {
          var ids = conv.members.map((m) => m.userId).toList();
          if (ids.isEmpty) {
            final members = await api.getConversationMembers(conv.id);
            ids = members.map((m) => m.userId).toList();
          }
          await call.distributeSfuKey(conv.id, ids);
        } catch (_) {}
      }());
    }
    unawaited(
      sfu
          .join(
            conversationId: conv.id,
            title: conv.name ?? 'Group call',
            isVideo: isVideo,
            e2eeKeyB64: e2eeKey,
          )
          .catchError((Object e) {
            if (!mounted) return;
            showAppToast(
              context,
              'Could not start SFU call: $e',
              isError: true,
            );
          }),
    );
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => const SfuCallScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_locked && !_unlocked) {
      return GlassScreenScaffold(
        appBar: const GlassAppBar(title: Text('Locked')),
        body: PinLockGate(
          title: conv.displayName(
            context.read<AuthProvider>().currentUser?.id ?? '',
          ),
          onVerify: (pin) => context
              .read<SecureStorageService>()
              .verifyConversationPin(conv.id, pin),
          onBiometric: () => LocalAuthentication().authenticate(
            localizedReason: 'Unlock this chat',
          ),
          onUnlocked: () => setState(() => _unlocked = true),
        ),
      );
    }
    final convID = widget.conversation.id;
    final currentUserID = context.select<AuthProvider, String>(
      (auth) => auth.currentUser?.id ?? '',
    );
    final meBubbleColorValue = context.select<AuthProvider, int?>(
      (auth) => auth.currentUser?.bubbleColor,
    );
    final chatSlice = context
        .select<
          ChatProvider,
          ({
            Conversation? conversation,
            List<Message> messages,
            List<ConversationTopic> topics,
            Set<String> typingUsers,
            int typingVersion,
            int readReceiptVersion,
            int liveLocationVersion,
          })
        >((chat) {
          final messages = _activeTopicId != null
              ? chat.messagesForTopic(convID, _activeTopicId!)
              : chat.messagesFor(convID);
          return (
            conversation: chat.conversationById(convID),
            messages: messages,
            topics: chat.topicsFor(convID),
            typingUsers: chat.typingUsersFor(convID),
            typingVersion: chat.typingVersionFor(convID),
            readReceiptVersion: chat.readReceiptVersionFor(convID),
            liveLocationVersion: chat.liveLocationVersion,
          );
        });
    final chat = context.read<ChatProvider>();
    final activeConv = chatSlice.conversation ?? widget.conversation;
    final messages = chatSlice.messages;
    final topics = chatSlice.topics;
    final typingUsers = chatSlice.typingUsers;
    final readByOthers = chat.messageIdsReadByOthers(
      activeConv.id,
      currentUserID,
    );
    final messagesById = <String, Message>{
      for (final message in messages) message.id: message,
    };
    _handleMessageListChange(messages, currentUserID);

    // Per-chat look. The current user's bubble color is also stored on their
    // profile so group/channel participants see the same sender color.
    final chatStyle = context.select<SettingsProvider, ChatStyle>(
      (settings) => settings.chatStyleFor(widget.conversation.id),
    );
    // My bubble colour is global (published to the profile); there is no
    // per-chat override.
    final meBubbleColor = meBubbleColorValue != null
        ? Color(meBubbleColorValue)
        : null;
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    return GlassScreenScaffold(
      // The chat thread is a plain (non-extendBody) scaffold: the message list
      // sits BELOW the bar, not behind it. Keep that layout.
      extendBody: false,
      resizeToAvoidBottomInset: false,
      appBar: _buildAppBar(context, activeConv, typingUsers, currentUserID),
      body: DropTarget(
        onDragEntered: (_) => setState(() => _dropHovering = true),
        onDragExited: (_) => setState(() => _dropHovering = false),
        onDragDone: (details) {
          setState(() => _dropHovering = false);
          unawaited(_sendDroppedFiles(details.files));
        },
        child: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: _chatBackground(chatStyle, activeConv),
              ),
            ),
            AnimatedPadding(
              padding: EdgeInsets.only(bottom: keyboardInset),
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              child: Column(
                children: [
                  KeyChangeBanner(
                    conversation: activeConv,
                    currentUserId: currentUserID,
                  ),
                  _GroupCallBanner(conversation: activeConv),
                  _ConversationPinnedBar(
                    conversationId: activeConv.id,
                    onShowAll: () => _showConversationPinsSheet(currentUserID),
                  ),
                  _buildTopicBar(topics, activeConv, currentUserID),
                  if (_chatSearchActive)
                    _InChatSearchPanel(
                      controller: _chatSearchCtrl,
                      query: _chatSearchQuery,
                      selectedCategory: _chatSearchCategory,
                      conversationId: activeConv.id,
                      onQueryChanged: (value) =>
                          setState(() => _chatSearchQuery = value),
                      onCategoryChanged: (category) =>
                          setState(() => _chatSearchCategory = category),
                      onClose: _closeChatSearch,
                      onSelect: (result) =>
                          unawaited(_openChatSearchResult(result)),
                    ),
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
                                : LayoutBuilder(
                                    builder: (context, constraints) => ListView.builder(
                                      controller: _scrollCtrl,
                                      reverse: true,
                                      physics: const BouncingScrollPhysics(
                                        parent: AlwaysScrollableScrollPhysics(),
                                      ),
                                      scrollCacheExtent:
                                          const ScrollCacheExtent.pixels(720),
                                      keyboardDismissBehavior:
                                          ScrollViewKeyboardDismissBehavior
                                              .onDrag,
                                      // Symmetric gutters keep the stream a
                                      // readable column when the pane outgrows
                                      // kChatContentMaxWidth (maximized desktop
                                      // windows, ultrawides).
                                      padding: EdgeInsets.symmetric(
                                        horizontal:
                                            8 +
                                            math.max(
                                              0,
                                              (constraints.maxWidth -
                                                      kChatContentMaxWidth) /
                                                  2,
                                            ),
                                        vertical: 8,
                                      ),
                                      itemCount:
                                          messages.length +
                                          (_loadingMore ? 1 : 0),
                                      itemBuilder: (context, i) {
                                        if (i == messages.length) {
                                          return const Padding(
                                            padding: EdgeInsets.symmetric(
                                              vertical: 12,
                                            ),
                                            child: Center(
                                              child:
                                                  GlassProgressIndicator.circular(
                                                    size: 20,
                                                    strokeWidth: 2,
                                                  ),
                                            ),
                                          );
                                        }

                                        final messageIndex =
                                            messages.length - 1 - i;
                                        final msg = messages[messageIndex];
                                        // Media albums: the run renders once, on
                                        // its newest member; the other members
                                        // keep their rows (so index math, keys,
                                        // and reply jumps survive) at zero
                                        // height.
                                        final albumRun = albumRunAt(
                                          messages,
                                          messageIndex,
                                        );
                                        if (albumRun != null &&
                                            albumRun.last.id != msg.id) {
                                          return SizedBox.shrink(
                                            key: _messageKeys.putIfAbsent(
                                              msg.id,
                                              () => GlobalKey(),
                                            ),
                                          );
                                        }
                                        final isMe =
                                            msg.senderId == currentUserID;
                                        final isLocationMessage =
                                            msg.type == MessageType.location &&
                                            msg.location != null;
                                        final showAvatar =
                                            !isMe &&
                                            (messageIndex ==
                                                    messages.length - 1 ||
                                                messages[messageIndex + 1]
                                                        .senderId !=
                                                    msg.senderId);
                                        final highlighted =
                                            _highlightedMessageId == msg.id;
                                        final replyPreview = _replyPreviewFor(
                                          msg,
                                          messagesById,
                                        );
                                        // First message of a calendar day gets
                                        // a centered day chip above it.
                                        final showDayHeader =
                                            messageIndex == 0 ||
                                            !isSameCalendarDay(
                                              messages[messageIndex - 1]
                                                  .createdAt,
                                              msg.createdAt,
                                            );
                                        final entry = _AnimatedMessageEntry(
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
                                              color:
                                                  (highlighted ||
                                                      (_selectionMode &&
                                                          _selectedIds.contains(
                                                            msg.id,
                                                          )))
                                                  ? Theme.of(context)
                                                        .colorScheme
                                                        .primary
                                                        .withValues(alpha: 0.14)
                                                  : Colors.transparent,
                                              borderRadius:
                                                  BorderRadius.circular(
                                                    chatStyle.bubbleRadius + 10,
                                                  ),
                                            ),
                                            child: MessageBubble(
                                              message: msg,
                                              isMe: isMe,
                                              isChannel: activeConv.isChannel,
                                              albumMessages: albumRun,
                                              showAvatar: showAvatar,
                                              readByOthers:
                                                  isMe &&
                                                  readByOthers.contains(msg.id),
                                              meBubbleColor: meBubbleColor,
                                              bubbleRadius:
                                                  chatStyle.bubbleRadius,
                                              onTap: _selectionMode
                                                  ? () => _toggleSelection(msg)
                                                  : isLocationMessage
                                                  ? () => _openLocationMessage(
                                                      msg,
                                                    )
                                                  : null,
                                              onTapUp:
                                                  _selectionMode ||
                                                      isLocationMessage
                                                  ? null
                                                  : (
                                                      details,
                                                    ) => _showReactionBar(
                                                      msg,
                                                      details.globalPosition,
                                                    ),
                                              onReactionTap: (emoji) =>
                                                  _toggleReaction(msg, emoji),
                                              replyPreview: replyPreview,
                                              onReplyTap:
                                                  msg.effectiveReplyTo == null
                                                  ? null
                                                  : () => _jumpToReply(msg),
                                              isLiveLocationSharing:
                                                  isMe &&
                                                  msg.location?.isLive ==
                                                      true &&
                                                  chat.isLiveLocationActive(
                                                    msg.id,
                                                  ),
                                              onCancelLiveLocation: () =>
                                                  context
                                                      .read<ChatProvider>()
                                                      .stopLiveLocation(msg.id),
                                              onLongPress: _selectionMode
                                                  ? (pos) =>
                                                        _toggleSelection(msg)
                                                  : (pos) => _showMessageMenu(
                                                      context,
                                                      msg,
                                                      isMe,
                                                      anchor: pos,
                                                    ),
                                              onSecondaryTapUp: (details) =>
                                                  _showMessageMenu(
                                                    context,
                                                    msg,
                                                    isMe,
                                                    anchor:
                                                        details.globalPosition,
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
                                        if (!showDayHeader) return entry;
                                        return Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            DaySeparator(
                                              label: daySeparatorLabel(
                                                msg.createdAt,
                                              ),
                                            ),
                                            entry,
                                          ],
                                        );
                                      },
                                    ),
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
                                                Icons
                                                    .keyboard_arrow_down_rounded,
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
                  if (activeConv.locked)
                    const _BurnerExpiredBar()
                  else
                    _buildInputBar(context, currentUserID),
                ],
              ),
            ),
            // Desktop drag-and-drop affordance while files hover over the
            // chat.
            if (_dropHovering) const DropFilesOverlay(),
          ],
        ),
      ),
    );
  }

  /// Background behind the message list. A premium conversation-wide image
  /// (set by an admin, visible to everyone) wins; otherwise the viewer's own
  /// per-DM background image or color applies.
  Decoration _chatBackground(DmChatStyle style, Conversation conversation) {
    final convBg = conversation.backgroundUrl;
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
          Future<void> apply(ChatStyle next) async {
            style = next;
            await settings.setChatStyle(convID, next);
            setSheet(() {});
          }

          return GlassBottomSheetFrame(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const GlassSheetGrabber(),
                GlassSheetHeader(
                  icon: Icons.palette_outlined,
                  title: 'Chat appearance',
                  subtitle:
                      'Tune the background and bubble shape. Your bubble '
                      'colour is set in Settings → Appearance.',
                  actions: [
                    GlassCircleIconButton(
                      tooltip: 'Reset appearance',
                      size: 36,
                      glowIntensity: 0.04,
                      icon: const Icon(Icons.restart_alt_rounded, size: 18),
                      onPressed: () => unawaited(apply(const ChatStyle())),
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
      builder: (sheetCtx) => GlassBottomSheetFrame(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const GlassSheetGrabber(),
            GlassSheetHeader(
              icon: Icons.wallpaper_rounded,
              title: 'Chat background',
              subtitle: 'Choose the shared image behind this conversation.',
              onClose: () => Navigator.pop(sheetCtx),
            ),
            _MenuTile(
              icon: Icons.image_outlined,
              label: 'Choose background image',
              onTap: () => Navigator.pop(sheetCtx, 'pick'),
            ),
            if (conv.backgroundUrl != null)
              _MenuTile(
                icon: Icons.delete_outline,
                label: 'Remove background',
                color: Colors.red,
                onTap: () => Navigator.pop(sheetCtx, 'remove'),
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
    Conversation conv,
    Set<String> typingUsers,
    String currentUserID,
  ) {
    if (_selectionMode) return _buildSelectionAppBar();
    final name = conv.displayName(currentUserID);

    // Live mesh presence: this DM's partner currently holds a verified
    // Bluetooth link (Nearby screen open or keep-alive on), so messages
    // written here deliver offline, instantly.
    final mesh = context.watch<NearbyMeshService>();
    final meshLinked =
        conv.isDM &&
        mesh.peers.any((peer) {
          final fp = peer.fingerprint;
          return peer.session.authenticated &&
              fp != null &&
              context.read<ChatProvider>().dmConversationIdForFingerprint(fp) ==
                  conv.id;
        });

    final dmPartner = !conv.isGroup
        ? conv.members.where((m) => m.userId != currentUserID).firstOrNull?.user
        : null;
    if (conv.isDM) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _schedulePeerPinLoad();
      });
    }
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
      automaticallyImplyLeading: !widget.embedded,
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
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: conv.isBurner && !conv.locked
                            ? _BurnerCountdownLabel(expiresAt: conv.expiresAt!)
                            : ConversationEncryptionStatus(conversation: conv),
                      ),
                      if (meshLinked) ...[
                        const SizedBox(width: 6),
                        Icon(
                          Icons.bluetooth_connected_rounded,
                          size: 12,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 2),
                        Text(
                          'nearby',
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ],
                      if (KeyVerificationBadge.shouldShow(_peerPin)) ...[
                        const SizedBox(width: 6),
                        KeyVerificationBadge(pin: _peerPin, compact: true),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.search_rounded),
          tooltip: 'Search in chat',
          onPressed: _openChatSearch,
        ),
        if (!conv.isChannel) ...[
          IconButton(
            icon: const Icon(Icons.call),
            tooltip: 'Voice call',
            onPressed: () => _onCallPressed(isVideo: false),
          ),
          IconButton(
            icon: const Icon(Icons.videocam),
            tooltip: 'Video call',
            onPressed: () => _onCallPressed(isVideo: true),
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

  /// Horizontal topic ("thread") filter strip for groups/channels. Tapping a
  /// topic filters the message stream to it; "All" clears the filter.
  Widget _buildTopicBar(
    List<ConversationTopic> topics,
    Conversation conv,
    String currentUserID,
  ) {
    if (!(conv.isGroup || conv.isChannel)) return const SizedBox.shrink();
    if (topics.isEmpty && !conv.topicsEnabled) return const SizedBox.shrink();
    final canManageTopics =
        _currentMember(
          currentUserID,
        )?.hasPermission(AdminPermission.manageTopics) ??
        false;
    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        children: [
          _TopicChip(
            label: 'All',
            selected: _activeTopicId == null,
            onTap: () => setState(() => _activeTopicId = null),
          ),
          for (final t in topics)
            _TopicChip(
              label: t.name,
              closed: t.isClosed,
              selected: _activeTopicId == t.id,
              onTap: () => setState(
                () => _activeTopicId = _activeTopicId == t.id ? null : t.id,
              ),
              onLongPress: canManageTopics
                  ? () => _showTopicActions(conv, t)
                  : null,
            ),
        ],
      ),
    );
  }

  ConversationTopic? _selectedTopic(ChatProvider chat, Conversation conv) {
    final id = _activeTopicId;
    if (id == null) return null;
    for (final topic in chat.topicsFor(conv.id)) {
      if (topic.id == id) return topic;
    }
    return null;
  }

  Future<void> _createTopic(Conversation conv) async {
    final name = await _promptTopicName();
    if (name == null || name.trim().isEmpty || !mounted) return;
    final topic = await context.read<ChatProvider>().createTopic(
      conv.id,
      name.trim(),
      channel: conv.isChannel,
    );
    if (!mounted) return;
    if (topic != null) {
      setState(() => _activeTopicId = topic.id);
      showAppToast(context, 'Topic created');
    } else {
      showAppToast(context, 'Could not create topic', isError: true);
    }
  }

  Future<String?> _promptTopicName({
    String initialName = '',
    String title = 'New topic',
    String actionLabel = 'Create',
  }) async {
    final ctrl = TextEditingController(text: initialName);
    ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
    final name = await showDialog<String>(
      context: context,
      builder: (dctx) => GlassAlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 128,
          decoration: const InputDecoration(hintText: 'Topic name'),
          onSubmitted: (v) => Navigator.of(dctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(ctrl.text),
            child: Text(actionLabel),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return name;
  }

  void _showTopicActions(Conversation conv, ConversationTopic topic) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        void runAfterClose(FutureOr<void> Function() action) {
          Navigator.of(sheetCtx).pop();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            unawaited(Future<void>.sync(action));
          });
        }

        return GlassBottomSheetFrame(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const GlassSheetGrabber(),
              GlassSheetHeader(
                icon: topic.isClosed
                    ? Icons.lock_outline_rounded
                    : Icons.forum_outlined,
                title: topic.name,
                subtitle: topic.isClosed ? 'Closed topic' : 'Open topic',
                onClose: () => Navigator.of(sheetCtx).pop(),
              ),
              _MenuTile(
                icon: Icons.edit_outlined,
                label: 'Rename topic',
                onTap: () => runAfterClose(() => _renameTopic(conv, topic)),
              ),
              _MenuTile(
                icon: topic.isClosed
                    ? Icons.lock_open_rounded
                    : Icons.lock_outline_rounded,
                label: topic.isClosed ? 'Reopen topic' : 'Close topic',
                onTap: () => runAfterClose(() => _setTopicClosed(conv, topic)),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _renameTopic(Conversation conv, ConversationTopic topic) async {
    final name = await _promptTopicName(
      initialName: topic.name,
      title: 'Rename topic',
      actionLabel: 'Save',
    );
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == topic.name) return;
    if (!mounted) return;
    final updated = await context.read<ChatProvider>().updateTopic(
      conv.id,
      topic.id,
      name: trimmed,
      channel: conv.isChannel,
    );
    if (!mounted) return;
    showAppToast(
      context,
      updated == null ? 'Could not rename topic' : 'Topic renamed',
      isError: updated == null,
    );
  }

  Future<void> _setTopicClosed(
    Conversation conv,
    ConversationTopic topic,
  ) async {
    final close = !topic.isClosed;
    final updated = await context.read<ChatProvider>().updateTopic(
      conv.id,
      topic.id,
      closed: close,
      channel: conv.isChannel,
    );
    if (!mounted) return;
    showAppToast(
      context,
      updated == null
          ? 'Could not update topic'
          : close
          ? 'Topic closed'
          : 'Topic reopened',
      isError: updated == null,
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
      builder: (sheetCtx) {
        void runAfterClose(FutureOr<void> Function() action) {
          Navigator.of(sheetCtx).pop();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            unawaited(Future<void>.sync(action));
          });
        }

        final title = conv.isDM
            ? 'Chat options'
            : conv.isGroup
            ? 'Group options'
            : 'Channel options';
        return GlassBottomSheetFrame(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const GlassSheetGrabber(),
              GlassSheetHeader(
                icon: Icons.more_horiz_rounded,
                title: title,
                subtitle: conv.displayName(currentUserID),
                onClose: () => Navigator.of(sheetCtx).pop(),
              ),
              _MenuTile(
                icon: Icons.info_outline_rounded,
                label: 'Conversation info',
                onTap: () => runAfterClose(
                  () => _showConversationInfo(context, currentUserID),
                ),
              ),
              _MenuTile(
                icon: Icons.search_rounded,
                label: 'Search in chat',
                onTap: () => runAfterClose(_openChatSearch),
              ),
              _MenuTile(
                icon: Icons.photo_library_outlined,
                label: 'Media gallery',
                onTap: () =>
                    runAfterClose(() => _showSharedMediaGallery(currentUserID)),
              ),
              _MenuTile(
                icon: _notificationPreferenceIcon(notificationPreference),
                label: 'Notifications: $notificationLabel',
                onTap: () => runAfterClose(
                  () => unawaited(
                    showConversationNotificationControlsSheet(
                      context,
                      conversationId: conv.id,
                    ),
                  ),
                ),
              ),
              _MenuTile(
                icon: Icons.schedule_send_outlined,
                label: 'Scheduled messages',
                onTap: () => runAfterClose(
                  () => showScheduledMessagesSheet(
                    context,
                    conversation: conv,
                    channel: false,
                  ),
                ),
              ),
              if (conv.isDM || canManageSettings)
                _MenuTile(
                  icon: Icons.timer_outlined,
                  label: 'Disappearing messages',
                  onTap: () => runAfterClose(() => _setDisappearing(context)),
                ),
              if (!conv.isDM && canManageSettings)
                _MenuTile(
                  icon: Icons.hourglass_empty_rounded,
                  label: 'Slow mode',
                  onTap: () => runAfterClose(() => _setSlowMode(context)),
                ),
              if (!conv.isDM && canManageEncryption)
                _MenuTile(
                  icon: Icons.lock_outline_rounded,
                  label: 'Encryption mode',
                  onTap: () => runAfterClose(() => _setEncryption(context)),
                ),
              if ((conv.isGroup || conv.isChannel) &&
                  (currentMember?.hasPermission(AdminPermission.manageTopics) ??
                      false))
                _MenuTile(
                  icon: Icons.forum_outlined,
                  label: 'New topic',
                  onTap: () => runAfterClose(() => _createTopic(conv)),
                ),
              if (conv.isGroup && canManageInfo)
                _MenuTile(
                  icon: Icons.edit_outlined,
                  label: 'Edit group',
                  dividerBefore: true,
                  onTap: () =>
                      runAfterClose(() => _editGroup(context, currentUserID)),
                ),
              if (conv.isGroup)
                _MenuTile(
                  icon: Icons.group_outlined,
                  label: 'Members',
                  onTap: () =>
                      runAfterClose(() => _showMembers(context, currentUserID)),
                ),
              if (conv.isGroup && canManageInvites)
                _MenuTile(
                  icon: Icons.link_rounded,
                  label: 'Invite links',
                  onTap: () =>
                      runAfterClose(() => _showInviteLinks(context, conv)),
                ),
              if (conv.isGroup &&
                  ((currentMember?.hasPermission(
                            AdminPermission.manageModeration,
                          ) ??
                          false) ||
                      (currentMember?.hasPermission(
                            AdminPermission.manageRoles,
                          ) ??
                          false)))
                _MenuTile(
                  icon: Icons.shield_outlined,
                  label: 'Moderation',
                  onTap: () => runAfterClose(
                    () => _openGroupModeration(context, currentUserID),
                  ),
                ),
              _MenuTile(
                icon: Icons.palette_outlined,
                label: 'Chat appearance',
                dividerBefore: true,
                onTap: () => runAfterClose(() => _showChatAppearance(context)),
              ),
              if (_canSetConversationBackground(currentUserID))
                _MenuTile(
                  icon: Icons.wallpaper_rounded,
                  label: 'Set chat background',
                  onTap: () =>
                      runAfterClose(() => _setConversationBackground(context)),
                ),
              if (conv.isGroup)
                _MenuTile(
                  icon: Icons.delete_sweep_outlined,
                  label: 'Delete messages',
                  color: Colors.red,
                  dividerBefore: true,
                  onTap: () => runAfterClose(
                    () => _deleteGroupMessages(context, currentUserID),
                  ),
                ),
              _MenuTile(
                icon: conv.isDM
                    ? Icons.delete_outline_rounded
                    : Icons.exit_to_app_rounded,
                label: exitLabel,
                color: Colors.red,
                dividerBefore: !conv.isGroup,
                onTap: () => runAfterClose(() => _deleteConversation(context)),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
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
    final activeTopic = _selectedTopic(context.read<ChatProvider>(), conv);
    final topicClosed = activeTopic?.isClosed ?? false;
    final mentionSuggestions = _mentionSuggestions(currentUserID);
    final specialMentions = _specialMentionSuggestions();
    final commandSuggestionList = commandSuggestions(
      commands: _botCommands,
      active: _activeCommandQuery,
    );
    // The composer is an active control, so it lives in the Liquid Glass layer:
    // a free-floating capsule hovering above the bottom boundary with the chat
    // canvas peeking around it.
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 14),
        // Tracks the message stream's max content width so the composer and
        // the bubbles share gutters on wide desktop panes.
        child: Align(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kChatContentMaxWidth),
            child: GlassContainer(
              shape: const LiquidRoundedSuperellipse(borderRadius: 28),
              allowElevation: true,
              glowIntensity: 0.06,
              padding: const EdgeInsets.fromLTRB(4, 4, 6, 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Bot inline mode (`@bot <query>`) — shown while searching or
                  // once the bot has answered. Suppresses the other panels.
                  if (_activeInlineQuery != null &&
                      (_inlineLoading || _inlineResults != null))
                    InlineResultsPanel(
                      results: _inlineResults ?? const [],
                      loading: _inlineLoading,
                      onPick: _onInlinePick,
                    ),
                  if (commandSuggestionList.isNotEmpty)
                    CommandAutocompletePanel(
                      commands: commandSuggestionList,
                      onSelected: _insertCommand,
                    ),
                  if (mentionSuggestions.isNotEmpty ||
                      specialMentions.isNotEmpty)
                    MentionAutocompletePanel(
                      members: mentionSuggestions,
                      specialMentions: specialMentions,
                      onSelected: _insertMention,
                      onSpecialSelected: _insertSpecialMention,
                    ),
                  if (_replyingTo != null) _buildReplyPreview(context),
                  if (topicClosed)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
                      child: Row(
                        children: [
                          Icon(
                            Icons.lock_outline_rounded,
                            size: 16,
                            color: scheme.onSurface.withValues(alpha: 0.62),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'This topic is closed',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: scheme.onSurface.withValues(alpha: 0.66),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Row(
                    children: [
                      IconButton(
                        icon: Icon(
                          _showCustomEmojis
                              ? Icons.keyboard
                              : Icons.add_reaction_outlined,
                        ),
                        tooltip: _showCustomEmojis
                            ? 'Keyboard'
                            : 'Custom emoji',
                        onPressed: topicClosed
                            ? null
                            : () => setState(() {
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
                        onPressed: topicClosed
                            ? null
                            : () => setState(() {
                                _showStickers = !_showStickers;
                                if (_showStickers) _showCustomEmojis = false;
                              }),
                      ),
                      Expanded(
                        child: TextField(
                          controller: _inputCtrl,
                          enabled: !topicClosed,
                          onChanged: topicClosed ? null : (_) => _onTyping(),
                          onSubmitted: topicClosed
                              ? null
                              : (_) => _sendMessage(),
                          maxLines: null,
                          textInputAction: TextInputAction.send,
                          // Punchier weight to stay legible over the refracting glass.
                          style: const TextStyle(fontWeight: FontWeight.w500),
                          decoration: InputDecoration(
                            hintText: topicClosed ? 'Topic closed' : 'Message',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(22),
                              borderSide: BorderSide.none,
                            ),
                            filled: true,
                            fillColor: scheme.surfaceContainerHighest
                                .withValues(alpha: 0.30),
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
                        onPressed: topicClosed ? null : _showAttachmentPicker,
                        tooltip: 'Attach file',
                        icon: const Icon(Icons.attach_file_outlined, size: 22),
                      ),
                      const SizedBox(width: 4),
                      Tooltip(
                        message: 'Hold for send options',
                        child: GestureDetector(
                          onTap: topicClosed ? null : _sendMessage,
                          onLongPress: topicClosed ? null : _showSendOptions,
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

  /// Single tap on a message → the reaction bar (6 recents + an expand button
  /// for the full system/custom-emoji picker). Long-press opens the action menu.
  Future<void> _showReactionBar(Message msg, Offset anchor) async {
    if (msg.type == MessageType.system) return;
    final res = await showMessageReactionBar(
      context: context,
      anchor: anchor,
      recentReactionKeys: _settings.quickReactions(),
    );
    if (res == null || !mounted) return;
    final String key;
    if (res is ReactionExpand) {
      final picked = await showReactionEmojiPicker(context);
      if (picked == null || !mounted) return;
      key = picked;
    } else {
      key = (res as ReactionPicked).key;
    }
    _settings.pushRecentReaction(key);
    _toggleReaction(msg, key);
  }

  // ── Multi-select (#1) ───────────────────────────────────────────────────────

  void _enterSelection(Message msg) {
    setState(() {
      _selectionMode = true;
      _selectedIds
        ..clear()
        ..add(msg.id);
      _showStickers = false;
      _showCustomEmojis = false;
    });
  }

  void _toggleSelection(Message msg) {
    setState(() {
      if (!_selectedIds.add(msg.id)) _selectedIds.remove(msg.id);
      if (_selectedIds.isEmpty) _selectionMode = false;
    });
  }

  void _exitSelection() {
    if (!_selectionMode && _selectedIds.isEmpty) return;
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  List<Message> _selectedMessages() {
    final byId = {
      for (final m in context.read<ChatProvider>().messagesFor(conv.id))
        m.id: m,
    };
    return [
      for (final id in _selectedIds)
        if (byId[id] != null) byId[id]!,
    ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  Future<void> _copySelected() async {
    final msgs = _selectedMessages()
        .where(
          (m) =>
              m.type == MessageType.text &&
              (m.decryptedContent ?? '').isNotEmpty,
        )
        .toList();
    if (msgs.isEmpty) return;
    final text = msgs.map((m) => m.decryptedContent ?? '').join('\n\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    showAppToast(
      context,
      msgs.length == 1 ? 'Copied' : 'Copied ${msgs.length} messages',
    );
    _exitSelection();
  }

  Future<void> _deleteSelected() async {
    final ids = _selectedIds.toList();
    if (ids.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: Text(
          ids.length == 1
              ? 'Delete message?'
              : 'Delete ${ids.length} messages?',
        ),
        content: const Text('This cannot be undone.'),
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
    await context.read<ChatProvider>().deleteMessages(conv.id, ids);
    _exitSelection();
  }

  PreferredSizeWidget _buildSelectionAppBar() {
    final count = _selectedIds.length;
    final canCopy = _selectedMessages().any(
      (m) =>
          m.type == MessageType.text && (m.decryptedContent ?? '').isNotEmpty,
    );
    return GlassAppBar(
      automaticallyImplyLeading: false,
      leading: IconButton(
        icon: const Icon(Icons.close_rounded),
        tooltip: 'Cancel',
        onPressed: _exitSelection,
      ),
      title: Text('$count selected'),
      actions: [
        if (canCopy)
          IconButton(
            icon: const Icon(Icons.copy_rounded),
            tooltip: 'Copy',
            onPressed: _copySelected,
          ),
        IconButton(
          icon: const Icon(Icons.delete_outline_rounded),
          tooltip: 'Delete',
          onPressed: _deleteSelected,
        ),
      ],
    );
  }

  Future<void> _showMessageMenu(
    BuildContext context,
    Message msg,
    bool isMe, {
    Offset? anchor,
  }) async {
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
    final currentUserID = context.read<AuthProvider>().currentUser?.id ?? '';
    final canPin = !isSystem && _canPinMessages(currentUserID);
    final isPinned = context
        .read<SettingsProvider>()
        .isConversationMessagePinned(conv.id, msg.id);
    final actions = <MessageActionSheetItem<String>>[
      if (!isSystem)
        const MessageActionSheetItem(
          value: 'reply',
          icon: Icons.reply_rounded,
          label: 'Reply',
        ),
      if (!isSystem &&
          !isMe &&
          msg.sender != null &&
          (conv.isGroup || conv.isChannel))
        const MessageActionSheetItem(
          value: 'reply_private',
          icon: Icons.lock_outline_rounded,
          label: 'Reply privately',
        ),
      if (msg.effectiveReplyTo != null)
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
      if (isForwardable(msg)) ...[
        const MessageActionSheetItem(
          value: 'forward',
          icon: Icons.forward_rounded,
          label: 'Forward',
        ),
        const MessageActionSheetItem(
          value: 'forward_anon',
          icon: Icons.fast_forward_rounded,
          label: 'Forward anonymously',
        ),
      ],
      if (hasCopyableText || canDownloadMessageAttachment(msg))
        const MessageActionSheetItem(
          value: 'share',
          icon: Icons.share_rounded,
          label: 'Share',
        ),
      const MessageActionSheetItem(
        value: 'copy_link',
        icon: Icons.link_rounded,
        label: 'Copy message link',
      ),
      if (msg.reactions.isNotEmpty)
        const MessageActionSheetItem(
          value: 'reactions',
          icon: Icons.emoji_emotions_outlined,
          label: 'Who reacted',
        ),
      if (!isSystem)
        const MessageActionSheetItem(
          value: 'remind',
          icon: Icons.alarm_add_outlined,
          label: 'Remind me',
        ),
      if (!isSystem)
        const MessageActionSheetItem(
          value: 'select',
          icon: Icons.checklist_rounded,
          label: 'Select',
        ),
      if (canPin)
        MessageActionSheetItem(
          value: isPinned ? 'unpin' : 'pin',
          icon: isPinned ? Icons.push_pin : Icons.push_pin_outlined,
          label: isPinned ? 'Unpin' : 'Pin',
        ),
      // Channels route unattributed posts' tips to the owner, so any
      // non-self post qualifies there; elsewhere we need a visible sender.
      if (!isMe && !isSystem && (conv.isChannel || msg.sender != null))
        const MessageActionSheetItem(
          value: 'tip',
          icon: Icons.bolt_rounded,
          label: 'Tip',
        ),
      if (hasCopyableText && TranslationService.isSupported)
        MessageActionSheetItem(
          value: 'translate',
          icon: Icons.translate_rounded,
          label: context.read<ChatProvider>().translationFor(msg.id) == null
              ? 'Translate'
              : 'Hide translation',
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
    ];
    final media = MediaQuery.sizeOf(context);
    final selected = await showMessageContextMenu<String>(
      context: context,
      anchor: anchor ?? Offset(media.width / 2, media.height / 2),
      actions: actions,
    );
    if (selected == null || !mounted) return;

    switch (selected) {
      case 'reply':
        setState(() => _replyingTo = msg);
      case 'reply_private':
        await _replyPrivately(msg);
      case 'jump_reply':
        await _jumpToReply(msg);
      case 'copy_text':
        await _copyMessageText(msg);
      case 'copy_link':
        await _copyMessageLink(msg);
      case 'reactions':
        await _showReactors(msg);
      case 'forward':
        await _forwardMessage(msg);
      case 'forward_anon':
        await _forwardMessage(msg, anonymous: true);
      case 'share':
        await _shareMessage(msg);
      case 'remind':
        await _remindAboutMessage(msg);
      case 'tip':
        await _showTipSheet(msg);
      case 'translate':
        await _translateMessage(msg);
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
      case 'select':
        _enterSelection(msg);
      case 'pin':
        await _setConversationMessagePinned(msg, true);
      case 'unpin':
        await _setConversationMessagePinned(msg, false);
      case 'delete':
        this.context.read<ChatProvider>().deleteMessage(conv.id, msg.id);
    }
  }

  /// Pin/unpin gating (#2): channels keep their own /posts route; DM/self allow
  /// either member; groups require the manage_pins permission.
  bool _canPinMessages(String currentUserID) {
    if (conv.isChannel) return false;
    if (!conv.isGroup) return true;
    for (final m in conv.members) {
      if (m.userId == currentUserID) {
        return m.hasPermission(AdminPermission.managePins);
      }
    }
    return false;
  }

  Future<void> _setConversationMessagePinned(Message msg, bool pinned) async {
    final api = context.read<ApiService>();
    final settings = context.read<SettingsProvider>();
    try {
      if (pinned) {
        await api.pinConversationMessage(conv.id, msg.id);
        await settings.setConversationMessagePinned(
          conv.id,
          ChannelPinnedMessage(
            conversationId: conv.id,
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
        await api.unpinConversationMessage(conv.id, msg.id);
        await settings.unpinConversationMessage(conv.id, msg.id);
      }
    } catch (e) {
      if (mounted) {
        showAppToast(
          context,
          pinned ? 'Pin failed: $e' : 'Unpin failed: $e',
          isError: true,
        );
      }
    }
  }

  /// Server-safe preview: never shows ciphertext — falls back to a type label
  /// for an undecrypted message (the table stores only message_id).
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

  /// Hydrate this device's pin cache from the server on open and refresh.
  /// Previews are recomputed from locally-decrypted messages so the banner
  /// never renders ciphertext (mirrors the channel sync).
  Future<void> _syncConversationPins() async {
    if (conv.isChannel) return;
    final api = context.read<ApiService>();
    final settings = context.read<SettingsProvider>();
    final chat = context.read<ChatProvider>();
    try {
      final serverPins = await api.getConversationPinnedMessages(conv.id);
      if (!mounted) return;
      final loaded = {for (final m in chat.messagesFor(conv.id)) m.id: m};
      final mapped = [
        for (final p in serverPins)
          ChannelPinnedMessage(
            conversationId: conv.id,
            messageId: p.messageId,
            preview: loaded[p.messageId] != null
                ? _pinnedMessagePreview(loaded[p.messageId]!)
                : p.preview,
            messageCreatedAt: p.messageCreatedAt,
            pinnedAt: p.pinnedAt,
            senderUsername:
                loaded[p.messageId]?.sender?.username ?? p.senderUsername,
            message: loaded[p.messageId] ?? p.message,
          ),
      ];
      await settings.replaceConversationPinnedMessages(conv.id, mapped);
    } catch (_) {
      // Best-effort: a freshly-opened chat still works without server pins.
    }
  }

  Future<void> _unpinConversationMessageById(String messageId) async {
    final api = context.read<ApiService>();
    final settings = context.read<SettingsProvider>();
    try {
      await api.unpinConversationMessage(conv.id, messageId);
      await settings.unpinConversationMessage(conv.id, messageId);
    } catch (e) {
      if (mounted) showAppToast(context, 'Unpin failed: $e', isError: true);
    }
  }

  void _showConversationPinsSheet(String currentUserID) {
    final canManage = _canPinMessages(currentUserID);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        final pins = sheetCtx
            .watch<SettingsProvider>()
            .pinnedMessagesForConversation(conv.id);
        if (pins.isEmpty) {
          return const GlassBottomSheetFrame(
            padding: EdgeInsets.fromLTRB(8, 10, 8, 20),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GlassSheetGrabber(),
                  Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No pinned messages'),
                  ),
                ],
              ),
            ),
          );
        }
        return GlassBottomSheetFrame(
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 12),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const GlassSheetGrabber(),
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'Pinned messages',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final p in pins)
                        GlassListTile(
                          leading: const Icon(Icons.push_pin_rounded),
                          title: Text(
                            p.preview,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: p.senderUsername != null
                              ? Text('@${p.senderUsername}')
                              : null,
                          trailing: canManage
                              ? GestureDetector(
                                  onTap: () {
                                    Navigator.pop(sheetCtx);
                                    unawaited(
                                      _unpinConversationMessageById(
                                        p.messageId,
                                      ),
                                    );
                                  },
                                  child: const Icon(
                                    Icons.close_rounded,
                                    size: 20,
                                  ),
                                )
                              : null,
                          onTap: () {
                            Navigator.pop(sheetCtx);
                            unawaited(_jumpToMessage(p.messageId));
                          },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// On-device translate-toggle for a message. Detection + translation run
  /// through ML Kit locally; packs download on first use for that language.
  Future<void> _translateMessage(Message msg) async {
    final chat = context.read<ChatProvider>();
    if (chat.translationFor(msg.id) != null) {
      chat.setMessageTranslation(msg.id, null);
      return;
    }
    final text = msg.decryptedContent ?? '';
    if (text.trim().isEmpty) return;
    final localeCode = Localizations.localeOf(context).languageCode;
    final target =
        BCP47Code.fromRawValue(localeCode) ?? TranslateLanguage.english;
    showAppToast(context, 'Translating on-device…');
    try {
      final source = await TranslationService.detectLanguage(text);
      if (!mounted) return;
      if (source == null) {
        showAppToast(context, 'Could not detect the language', isError: true);
        return;
      }
      if (source == target) {
        showAppToast(context, 'Message is already in your language');
        return;
      }
      final translated = await TranslationService.translate(
        text,
        source: source,
        target: target,
      );
      if (!mounted) return;
      chat.setMessageTranslation(msg.id, translated);
    } catch (e) {
      if (mounted) {
        showAppToast(context, 'Translation failed: $e', isError: true);
      }
    }
  }

  /// Wallet tip for someone else's post. Anonymous: the server only ever
  /// shares per-provider aggregates, so there is no "from" UI here at all.
  Future<void> _showTipSheet(Message msg) async {
    final api = context.read<ApiService>();
    var providers = <String>['btc', 'xmr'];
    var balances = <Map<String, dynamic>>[];
    try {
      final status = await api.getBillingStatus();
      if (status['enabled'] != true) {
        if (mounted) {
          showAppToast(
            context,
            'Payments are not enabled on this server',
            isError: true,
          );
        }
        return;
      }
      final enabled = ((status['providers'] as List?) ?? const [])
          .whereType<String>()
          .where((p) => p == 'btc' || p == 'xmr')
          .toList();
      if (enabled.isNotEmpty) providers = enabled;
      balances = (await api.getPaymentBalances())
          .whereType<Map<String, dynamic>>()
          .toList();
    } catch (_) {}
    if (!mounted) return;

    var provider = providers.first;
    var submitting = false;
    final amountCtrl = TextEditingController();
    const presets = {
      'btc': [0.0001, 0.0005, 0.001],
      'xmr': [0.01, 0.05, 0.1],
    };

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
        context: context,
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
                showAppToast(context, 'Enter an amount', isError: true);
                return;
              }
              if (amount > balanceFor(provider)) {
                showAppToast(
                  context,
                  'Not enough app wallet balance',
                  isError: true,
                );
                return;
              }
              setSheet(() => submitting = true);
              try {
                await context.read<ChatProvider>().tipMessage(
                  convID: conv.id,
                  msgID: msg.id,
                  provider: provider,
                  amount: amount,
                );
                if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                if (mounted) showAppToast(context, 'Tip sent');
              } catch (e) {
                if (mounted) showAppToast(context, e.toString(), isError: true);
              } finally {
                if (sheetCtx.mounted) setSheet(() => submitting = false);
              }
            }

            final available = balanceFor(provider);
            return GlassBottomSheetFrame(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const GlassSheetGrabber(),
                  GlassSheetHeader(
                    icon: Icons.bolt_rounded,
                    title: 'Tip this post',
                    subtitle:
                        'Paid instantly from your app wallet. Tips are anonymous.',
                    onClose: () => Navigator.pop(sheetCtx),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: GlassSegmentedControl(
                            segments: [
                              for (final p in providers) p.toUpperCase(),
                            ],
                            selectedIndex: providers
                                .indexOf(provider)
                                .clamp(0, providers.length - 1),
                            onSegmentSelected: (i) =>
                                setSheet(() => provider = providers[i]),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest
                                .withValues(alpha: 0.45),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '${available.toStringAsFixed(provider == 'btc' ? 8 : 12)} ${provider.toUpperCase()}',
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final preset in presets[provider] ?? const [0.001])
                        ActionChip(
                          label: Text('$preset'),
                          onPressed: () => setSheet(
                            () => amountCtrl.text = preset.toString(),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: amountCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Amount (${provider.toUpperCase()})',
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (_) => setSheet(() {}),
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: submitting ? null : submit,
                    icon: const Icon(Icons.bolt_rounded),
                    label: Text(submitting ? 'Sending…' : 'Send tip'),
                  ),
                ],
              ),
            );
          },
        ),
      );
    } finally {
      amountCtrl.dispose();
    }
  }

  Future<void> _remindAboutMessage(Message msg) async {
    final now = DateTime.now();
    final selected = await showDialog<DateTime>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: const Text('Remind me'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ReminderChoiceTile(
              label: 'In 15 minutes',
              onTap: () =>
                  Navigator.pop(ctx, now.add(const Duration(minutes: 15))),
            ),
            _ReminderChoiceTile(
              label: 'In 1 hour',
              onTap: () =>
                  Navigator.pop(ctx, now.add(const Duration(hours: 1))),
            ),
            _ReminderChoiceTile(
              label: 'Tomorrow morning',
              onTap: () => Navigator.pop(
                ctx,
                DateTime(now.year, now.month, now.day + 1, 9),
              ),
            ),
            _ReminderChoiceTile(
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
    final settings = context.read<SettingsProvider>();
    final preview = (msg.decryptedContent ?? msg.listPreview).trim();
    await settings.saveMessageReminder(
      conversationId: conv.id,
      messageId: msg.id,
      conversationTitle: conv.displayName(
        context.read<AuthProvider>().currentUser?.id ?? '',
      ),
      messagePreview: preview.isEmpty ? msg.listPreview : preview,
      remindAt: selected,
    );
    if (!mounted) return;
    showAppToast(context, 'Reminder set for ${_formatReminderTime(selected)}');
  }

  String _formatReminderTime(DateTime value) {
    final local = value.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.month}/${local.day} $hour:$minute';
  }

  Future<void> _reportMessage(Message msg) async {
    // The anonymous, provable CSAM report (to system admins) is only possible
    // when this message's AMF franking verified as valid on receipt. Group/
    // channel admins exist for groups and channels, not DMs/self.
    await showReportMessageDialog(
      context: context,
      conversationId: conv.id,
      messageId: msg.id,
      reportedUserId: msg.senderId,
      isChannel: conv.isChannel,
      hasAdmins: conv.isGroup || conv.isChannel,
      messageEncrypted: msg.isEncrypted,
      csamBlob: context.read<ChatProvider>().frankingReportFor(msg.id),
    );
  }

  Future<void> _copyMessageText(Message msg) async {
    await Clipboard.setData(ClipboardData(text: msg.decryptedContent ?? ''));
    if (!mounted) return;
    showAppToast(context, 'Message text copied');
  }

  Future<void> _copyMessageLink(Message msg) async {
    await Clipboard.setData(
      ClipboardData(
        text: messageDeepLink(conversationId: conv.id, messageId: msg.id),
      ),
    );
    if (!mounted) return;
    showAppToast(context, 'Message link copied');
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

  Future<void> _forwardMessage(Message msg, {bool anonymous = false}) async {
    if (!isForwardable(msg)) return;
    final target = await _pickForwardTarget();
    if (target == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final chat = context.read<ChatProvider>();
    bool sent;
    try {
      if (msg.type == MessageType.poll && msg.poll != null) {
        final poll = msg.poll!;
        final options = [...poll.options]
          ..sort((a, b) => a.index.compareTo(b.index));
        sent = await chat.sendPoll(
          convID: target.id,
          question: poll.question,
          options: [for (final option in options) option.text],
          isAnonymous: poll.isAnonymous,
          allowsMultipleAnswers: poll.allowsMultipleAnswers,
          quiz: poll.isQuiz,
          meeting: poll.isMeeting,
          correctOptionId: poll.correctOptionIds.isNotEmpty
              ? poll.correctOptionIds.first
              : null,
          explanation: poll.explanation,
        );
      } else {
        final payload = buildForwardPayload(
          msg,
          anonymous: anonymous,
          fromUsername: msg.sender?.username,
          wireTypeOf: messageTypeWireName,
        );
        if (payload == null) {
          messenger.showSnackBar(
            const SnackBar(content: Text("Can't forward this message")),
          );
          return;
        }
        sent = await chat.sendMessage(
          convID: target.id,
          plaintext: payload.plaintext,
          messageType: payload.messageType,
          attachmentId: payload.attachmentId,
        );
      }
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Could not forward message: $e')),
      );
      return;
    }
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(content: Text(sent ? 'Forwarded' : 'Could not forward message')),
    );
  }

  Future<void> _replyPrivately(Message msg) async {
    final sender = msg.sender;
    if (sender == null) return;
    final settings = context.read<SettingsProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final Conversation? opened;
    try {
      opened = await openDmHandlingInboxPrice(context, sender.id);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not open DM: $e')));
      return;
    }
    if (opened == null || !mounted) return;
    final dm = opened;
    // Pre-fill the DM composer with a quote of the group message (the original
    // isn't in the DM, so the snippet travels as text).
    final quoted = (msg.decryptedContent ?? '').trim();
    if (quoted.isNotEmpty) {
      final block = quoted.split('\n').map((l) => '> $l').join('\n');
      await settings.setMessageDraft(dm.id, '$block\n\n');
    }
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ChatScreen(conversation: dm)),
    );
  }

  Future<void> _showReactors(Message msg) async {
    final messenger = ScaffoldMessenger.of(context);
    List<Map<String, dynamic>> reactors;
    try {
      reactors = await context.read<ApiService>().getMessageReactors(msg.id);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not load reactions: $e')),
      );
      return;
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => GlassBottomSheetFrame(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const GlassSheetGrabber(),
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Reactions',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
            ),
            if (reactors.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('No reactions'),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [for (final r in reactors) _reactorTile(r)],
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _reactorTile(Map<String, dynamic> r) {
    final username = (r['username'] as String?) ?? 'unknown';
    final display = (r['display_name'] as String?);
    final title = (display != null && display.isNotEmpty)
        ? display
        : '@$username';
    return GlassListTile(
      leading: CircleAvatar(
        child: Text(username.isNotEmpty ? username[0].toUpperCase() : '?'),
      ),
      title: Text(title),
      subtitle: Text('@$username'),
      trailing: Text(
        (r['emoji'] as String?) ?? '',
        style: const TextStyle(fontSize: 22),
      ),
    );
  }

  Future<Conversation?> _pickForwardTarget() async {
    final chat = context.read<ChatProvider>();
    final selfId = context.read<AuthProvider>().currentUser?.id ?? '';
    final targets = chat.conversations
        .where((c) => c.id != conv.id)
        .toList(growable: false);
    if (targets.isEmpty) {
      showAppToast(
        context,
        'No other conversations to forward to',
        isError: true,
      );
      return null;
    }
    return showModalBottomSheet<Conversation>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetCtx) {
        final scheme = Theme.of(sheetCtx).colorScheme;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Forward to',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: targets.length,
                  itemBuilder: (_, i) {
                    final c = targets[i];
                    final label = c.displayName(selfId);
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: scheme.primaryContainer,
                        child: Text(
                          label.isNotEmpty ? label[0].toUpperCase() : '#',
                          style: TextStyle(color: scheme.onPrimaryContainer),
                        ),
                      ),
                      title: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => Navigator.pop(sheetCtx, c),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _shareMessage(Message msg) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (canDownloadMessageAttachment(msg)) {
        final file = await saveMessageAttachment(
          message: msg,
          attachmentService: AttachmentService(context.read<ApiService>()),
        );
        final caption = msg.decryptedContent ?? '';
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(file.path)],
            text: caption.isNotEmpty ? caption : null,
          ),
        );
      } else {
        final text = msg.decryptedContent ?? '';
        if (text.isEmpty) return;
        await SharePlus.instance.share(ShareParams(text: text));
      }
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Share failed: $e')));
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
                'Changing encryption mode wipes all current messages in this chat for everyone.',
              ),
              const SizedBox(height: 12),
              for (final mode in EncryptionMode.values)
                GlassListTile(
                  leading: Icon(
                    mode == conv.encryptionMode
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  title: Text(mode.shortLabel),
                  onTap: mode == conv.encryptionMode
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
    if (selected == null || selected == conv.encryptionMode) return;
    try {
      final bootstrap = selected == EncryptionMode.mls
          ? await mls.createBootstrapForConversation(conv)
          : null;
      await api.setEncryptionMode(
        conv.id,
        selected.apiValue,
        mlsBootstrap: bootstrap,
      );
      await chat.loadConversations();
      await chat.loadMessages(conv.id);
      messenger.showSnackBar(
        SnackBar(
          content: Text('Encryption mode set to ${selected.shortLabel}'),
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

  /// Opens the moderation surface (mutes, anti-spam, reports queue, audit log,
  /// admins-only posting, ring-all toggle) for a GROUP. Channels reach the same
  /// screen from channel_screen; groups had no entry point at all, so group
  /// admins could not moderate despite full backend support.
  Future<void> _openGroupModeration(
    BuildContext context,
    String currentUserID,
  ) async {
    final member = _currentMember(currentUserID);
    final auth = context.read<AuthProvider>();
    final navigator = Navigator.of(context);
    final canManageLifecycle =
        conv.createdBy == currentUserID ||
        (auth.currentUser?.isSystemAdmin ?? false);
    final result = await navigator.push<ChannelModerationResult>(
      MaterialPageRoute(
        builder: (_) => ModerationScreen(
          conversation: conv,
          canManageModeration:
              member?.hasPermission(AdminPermission.manageModeration) ?? false,
          canManageRoles:
              member?.hasPermission(AdminPermission.manageRoles) ?? false,
          canManageSettings:
              member?.hasPermission(AdminPermission.manageSettings) ?? false,
          canManageInfo:
              member?.hasPermission(AdminPermission.manageInfo) ?? false,
          canManageEncryption:
              member?.hasPermission(AdminPermission.manageEncryption) ?? false,
          onEditSettings: () => _editGroup(context, currentUserID),
          onSetEncryption: () => _setEncryption(context),
          canManageLifecycle: canManageLifecycle,
          isArchived: conv.isArchived,
        ),
      ),
    );
    if (!mounted || result == null) return;
    // The group was deleted from the moderation screen — leave the chat.
    if (result == ChannelModerationResult.deleted) {
      navigator.pop();
    }
  }

  void _editGroup(BuildContext context, String currentUserID) {
    final canManageInfo =
        _currentMember(
          currentUserID,
        )?.hasPermission(AdminPermission.manageInfo) ??
        false;
    if (!canManageInfo) {
      showAppToast(
        context,
        'Missing permission to edit this group',
        isError: true,
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
                      if (uploading) const GlassProgressIndicator.circular(),
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
                      return GlassListTile(
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
                                child: GlassProgressIndicator.circular(
                                  size: 16,
                                  strokeWidth: 2,
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
                            return GlassListTile(
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
                                            showAppToast(
                                              context,
                                              '@$username added',
                                            );
                                          }
                                        } catch (e) {
                                          if (context.mounted) {
                                            showAppToast(
                                              context,
                                              'Failed to add: $e',
                                              isError: true,
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

/// A pill chip in the topic filter strip.
class _TopicChip extends StatelessWidget {
  final String label;
  final bool closed;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _TopicChip({
    required this.label,
    this.closed = false,
    required this.selected,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPress: onLongPress,
        child: GlassContainer(
          shape: const LiquidRoundedSuperellipse(borderRadius: 999),
          allowElevation: true,
          glowIntensity: selected ? 0.10 : 0.04,
          // Cheaper per-chip shader keeps horizontal thread-strip scrolling
          // smooth (the strip is a ListView of these chips).
          quality: GlassQuality.minimal,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (closed) ...[
                  Icon(
                    Icons.lock_outline_rounded,
                    size: 13,
                    color: selected
                        ? scheme.primary
                        : scheme.onSurface.withValues(alpha: 0.56),
                  ),
                  const SizedBox(width: 5),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected
                        ? scheme.primary
                        : scheme.onSurface.withValues(alpha: 0.72),
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

/// Glass action-sheet tile — used in the chat overflow menu and member menus.
/// Pass [color] to render a destructive/warning action in red (or any colour).
class _MenuTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;
  final bool dividerBefore;

  const _MenuTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
    this.dividerBefore = false,
  });

  @override
  Widget build(BuildContext context) => GlassActionTile(
    icon: icon,
    label: label,
    onTap: onTap,
    color: color,
    dividerBefore: dividerBefore,
  );
}

class _ReminderChoiceTile extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _ReminderChoiceTile({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GlassListTile(
      leading: const Icon(Icons.alarm_outlined, size: 20),
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      onTap: onTap,
    );
  }
}

/// Top-of-chat banner shown when a group has a live SFU call and the local user
/// isn't already in it — tapping joins (premium-gated).
/// App-bar subtitle for an active "burner" group: a live countdown to its
/// auto-destruct time, in place of the usual encryption-status line.
class _BurnerCountdownLabel extends StatefulWidget {
  const _BurnerCountdownLabel({required this.expiresAt});

  final DateTime expiresAt;

  @override
  State<_BurnerCountdownLabel> createState() => _BurnerCountdownLabelState();
}

class _BurnerCountdownLabelState extends State<_BurnerCountdownLabel> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _remaining() {
    final left = widget.expiresAt.difference(DateTime.now());
    if (left.isNegative) return 'Expiring…';
    if (left.inDays >= 1) return 'Expires in ${left.inDays}d';
    if (left.inHours >= 1) return 'Expires in ${left.inHours}h';
    if (left.inMinutes >= 1) return 'Expires in ${left.inMinutes}m';
    return 'Expires in <1m';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.local_fire_department_rounded,
          size: 12,
          color: scheme.error,
        ),
        const SizedBox(width: 3),
        Text(
          _remaining(),
          style: TextStyle(
            fontSize: 12,
            color: scheme.error.withValues(alpha: 0.9),
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// Replaces the composer once a "burner" group/channel has expired: the chat is
/// frozen and its messages have been purged server- and client-side.
class _BurnerExpiredBar extends StatelessWidget {
  const _BurnerExpiredBar();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: GlassContainer(
          shape: LiquidRoundedSuperellipse(borderRadius: 20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Icon(
                  Icons.local_fire_department_rounded,
                  color: scheme.error,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'This group has expired. Messages were permanently deleted.',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface.withValues(alpha: 0.8),
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

class _InChatSearchPanel extends StatelessWidget {
  final TextEditingController controller;
  final String query;
  final MessageSearchCategory? selectedCategory;
  final String conversationId;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<MessageSearchCategory?> onCategoryChanged;
  final VoidCallback onClose;
  final ValueChanged<MessageSearchResult> onSelect;

  const _InChatSearchPanel({
    required this.controller,
    required this.query,
    required this.selectedCategory,
    required this.conversationId,
    required this.onQueryChanged,
    required this.onCategoryChanged,
    required this.onClose,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final term = query.trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: GlassContainer(
        shape: LiquidRoundedSuperellipse(borderRadius: 20),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: controller,
                      autofocus: true,
                      textInputAction: TextInputAction.search,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search_rounded),
                        hintText: 'Search this chat',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onChanged: onQueryChanged,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Close search',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: onClose,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 34,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    _ChatSearchFilterChip(
                      label: 'All',
                      selected: selectedCategory == null,
                      onTap: () => onCategoryChanged(null),
                    ),
                    for (final category in MessageSearchCategory.values)
                      _ChatSearchFilterChip(
                        label: _chatSearchCategoryLabel(category),
                        selected: selectedCategory == category,
                        onTap: () => onCategoryChanged(category),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 160),
                child: term.length < 2
                    ? SizedBox(
                        key: const ValueKey('hint'),
                        height: 96,
                        child: Center(
                          child: Text(
                            'Type 2 or more characters',
                            style: TextStyle(
                              color: scheme.onSurface.withValues(alpha: 0.56),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      )
                    : SizedBox(
                        key: ValueKey(
                          '$term/${selectedCategory?.name ?? 'all'}',
                        ),
                        height: 220,
                        child: FutureBuilder<List<MessageSearchResult>>(
                          future: context.read<ChatProvider>().searchMessages(
                            term,
                            conversationId: conversationId,
                            categories: selectedCategory == null
                                ? null
                                : {selectedCategory!},
                            limit: 50,
                          ),
                          builder: (context, snapshot) {
                            if (snapshot.connectionState ==
                                ConnectionState.waiting) {
                              return const Center(
                                child: GlassProgressIndicator.circular(
                                  size: 22,
                                  strokeWidth: 2,
                                ),
                              );
                            }
                            final results = snapshot.data ?? const [];
                            if (results.isEmpty) {
                              return Center(
                                child: Text(
                                  'No matches in this chat',
                                  style: TextStyle(
                                    color: scheme.onSurface.withValues(
                                      alpha: 0.56,
                                    ),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              );
                            }
                            return ListView.separated(
                              keyboardDismissBehavior:
                                  ScrollViewKeyboardDismissBehavior.onDrag,
                              itemCount: results.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 6),
                              itemBuilder: (context, index) {
                                final result = results[index];
                                return GlassListTile(
                                  leading: Icon(
                                    _chatSearchCategoryIcon(result.category),
                                  ),
                                  title: Text(
                                    result.snippet.isNotEmpty
                                        ? result.snippet
                                        : result.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    '${_chatSearchCategoryLabel(result.category)} · ${_chatSearchDateLabel(result.createdAt)}',
                                  ),
                                  onTap: () => onSelect(result),
                                );
                              },
                            );
                          },
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

class _ChatSearchFilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ChatSearchFilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

String _chatSearchCategoryLabel(MessageSearchCategory category) {
  return switch (category) {
    MessageSearchCategory.messages => 'Messages',
    MessageSearchCategory.media => 'Media',
    MessageSearchCategory.files => 'Files',
    MessageSearchCategory.links => 'Links',
    MessageSearchCategory.voice => 'Voice',
    MessageSearchCategory.polls => 'Polls',
    MessageSearchCategory.payments => 'Payments',
    MessageSearchCategory.checklists => 'Lists',
  };
}

IconData _chatSearchCategoryIcon(MessageSearchCategory category) {
  return switch (category) {
    MessageSearchCategory.messages => Icons.chat_bubble_outline_rounded,
    MessageSearchCategory.media => Icons.photo_library_outlined,
    MessageSearchCategory.files => Icons.insert_drive_file_outlined,
    MessageSearchCategory.links => Icons.link_rounded,
    MessageSearchCategory.voice => Icons.graphic_eq_rounded,
    MessageSearchCategory.polls => Icons.poll_outlined,
    MessageSearchCategory.payments => Icons.payments_outlined,
    MessageSearchCategory.checklists => Icons.checklist_rounded,
  };
}

String _chatSearchDateLabel(DateTime date) {
  final local = date.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '${local.month}/${local.day}/${local.year} $hour:$minute';
}

/// Compact pinned-messages banner (#2) above the message list. Tapping opens
/// the full pinned-messages sheet. Renders nothing when no pins exist, so it
/// adds no layout when absent (keeps existing chat goldens byte-identical).
class _ConversationPinnedBar extends StatelessWidget {
  const _ConversationPinnedBar({
    required this.conversationId,
    required this.onShowAll,
  });

  final String conversationId;
  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    final pins = context
        .watch<SettingsProvider>()
        .pinnedMessagesForConversation(conversationId);
    if (pins.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final first = pins.first;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
      child: GlassButton.custom(
        onTap: onShowAll,
        height: 56,
        shape: const LiquidRoundedSuperellipse(borderRadius: 16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.push_pin_rounded, size: 18, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pins.length == 1
                          ? 'Pinned message'
                          : '${pins.length} pinned messages',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: scheme.primary,
                      ),
                    ),
                    Text(
                      first.preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: scheme.onSurface.withValues(alpha: 0.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GroupCallBanner extends StatelessWidget {
  const _GroupCallBanner({required this.conversation});

  final Conversation conversation;

  @override
  Widget build(BuildContext context) {
    final info = context.watch<GroupCallPresenceProvider>().infoFor(
      conversation.id,
    );
    final sfu = context.watch<SfuCallController>();
    final inThisCall = sfu.isActive && sfu.conversationId == conversation.id;
    if (info == null || !info.active || inThisCall) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    final count = info.participantIds.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
      child: GlassButton.custom(
        onTap: () => _join(context),
        height: 56,
        shape: const LiquidRoundedSuperellipse(borderRadius: 16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              const Icon(Icons.hub_outlined, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  count > 0
                      ? 'Group call in progress · $count in call'
                      : 'Group call in progress',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'Join',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                ),
              ),
              const Icon(Icons.chevron_right, size: 18),
            ],
          ),
        ),
      ),
    );
  }

  void _join(BuildContext context) {
    final isPremium =
        context.read<AuthProvider>().currentUser?.isPremium == true;
    if (!isPremium) {
      showAppToast(
        context,
        'Joining an SFU group call requires OpenChat Premium',
        isError: true,
      );
      return;
    }
    final sfu = context.read<SfuCallController>();
    final call = context.read<CallProvider>();
    final participantIds =
        context
            .read<GroupCallPresenceProvider>()
            .infoFor(conversation.id)
            ?.participantIds ??
        const <String>[];
    final navigator = Navigator.of(context);
    unawaited(() async {
      String? e2eeKey;
      if (conversation.isEncrypted) {
        // The frame key arrived in a sealed signal when the call started; if
        // this device missed it (offline, fresh login), ask a participant.
        e2eeKey =
            call.sfuKeyFor(conversation.id) ??
            await call.requestSfuKey(
              conversation.id,
              fromUserIds: participantIds,
            );
        if (e2eeKey == null) {
          if (context.mounted) {
            showAppToast(
              context,
              'Could not fetch the call\'s encryption key — try again in a moment',
              isError: true,
            );
          }
          return;
        }
      }
      try {
        // join() flips isActive synchronously, so push only after it starts —
        // SfuCallScreen pops itself when the controller is inactive.
        final joining = sfu.join(
          conversationId: conversation.id,
          title: conversation.name ?? 'Group call',
          isVideo: false,
          e2eeKeyB64: e2eeKey,
        );
        navigator.push(
          MaterialPageRoute<void>(
            fullscreenDialog: true,
            builder: (_) => const SfuCallScreen(),
          ),
        );
        await joining;
      } catch (e) {
        if (!context.mounted) return;
        showAppToast(context, 'Could not join call: $e', isError: true);
      }
    }());
  }
}

/// A liquid-glass checkbox row for the report-destination chooser.
