import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/channel_pinned_message.dart';
import '../models/message.dart';
import '../utils/local_conversation_preferences.dart';
import '../utils/smart_inbox_filter.dart';

/// Per-chat visual customization.
class ChatStyle {
  /// Solid background color behind the message list (ARGB int). null = theme default.
  final int? backgroundColor;

  /// Local file path to a background image picked by the user. Takes precedence
  /// over [backgroundColor] when set. Stored as a path because it's a personal,
  /// device-local preference that never leaves the client.
  final String? backgroundImagePath;

  /// Color of the current user's own outgoing bubbles (ARGB int). null = theme primary.
  final int? myBubbleColor;

  /// Corner radius applied to bubbles. Defaults to the app's standard 18.
  final double bubbleRadius;

  const ChatStyle({
    this.backgroundColor,
    this.backgroundImagePath,
    this.myBubbleColor,
    this.bubbleRadius = 18,
  });

  bool get isDefault =>
      backgroundColor == null &&
      backgroundImagePath == null &&
      myBubbleColor == null &&
      bubbleRadius == 18;

  ChatStyle copyWith({
    int? backgroundColor,
    String? backgroundImagePath,
    int? myBubbleColor,
    double? bubbleRadius,
    bool clearBackgroundColor = false,
    bool clearBackgroundImage = false,
    bool clearMyBubbleColor = false,
  }) => ChatStyle(
    backgroundColor: clearBackgroundColor
        ? null
        : (backgroundColor ?? this.backgroundColor),
    backgroundImagePath: clearBackgroundImage
        ? null
        : (backgroundImagePath ?? this.backgroundImagePath),
    myBubbleColor: clearMyBubbleColor
        ? null
        : (myBubbleColor ?? this.myBubbleColor),
    bubbleRadius: bubbleRadius ?? this.bubbleRadius,
  );

  Map<String, dynamic> toJson() => {
    if (backgroundColor != null) 'bg': backgroundColor,
    if (backgroundImagePath != null) 'bg_img': backgroundImagePath,
    if (myBubbleColor != null) 'bubble': myBubbleColor,
    'radius': bubbleRadius,
  };

  factory ChatStyle.fromJson(Map<String, dynamic> json) => ChatStyle(
    backgroundColor: json['bg'] as int?,
    backgroundImagePath: json['bg_img'] as String?,
    myBubbleColor: json['bubble'] as int?,
    bubbleRadius: (json['radius'] as num?)?.toDouble() ?? 18,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatStyle &&
          other.backgroundColor == backgroundColor &&
          other.backgroundImagePath == backgroundImagePath &&
          other.myBubbleColor == myBubbleColor &&
          other.bubbleRadius == bubbleRadius;

  @override
  int get hashCode => Object.hash(
    backgroundColor,
    backgroundImagePath,
    myBubbleColor,
    bubbleRadius,
  );
}

typedef DmChatStyle = ChatStyle;

class MessageDraft {
  final String text;
  final DateTime updatedAt;
  final List<CustomEmojiEntity> customEmojiEntities;
  final bool sendSilent;
  final DateTime? scheduledFor;

  const MessageDraft({
    required this.text,
    required this.updatedAt,
    this.customEmojiEntities = const [],
    this.sendSilent = false,
    this.scheduledFor,
  });

  bool get isEmpty => text.trim().isEmpty;

  String get preview => text.replaceAll(RegExp(r'\s+'), ' ').trim();

  Map<String, dynamic> toJson() => {
    'text': text,
    'updated_at_ms': updatedAt.toUtc().millisecondsSinceEpoch,
    if (customEmojiEntities.isNotEmpty)
      'custom_emoji_entities': customEmojiEntities
          .map((entity) => entity.toJson())
          .toList(),
    if (sendSilent) 'send_silent': true,
    if (scheduledFor != null)
      'scheduled_for_ms': scheduledFor!.toUtc().millisecondsSinceEpoch,
  };

  factory MessageDraft.fromJson(Map<String, dynamic> json) {
    final updatedAtMs = json['updated_at_ms'] as int?;
    final scheduledForMs = json['scheduled_for_ms'] as int?;
    return MessageDraft(
      text: json['text'] as String? ?? '',
      updatedAt: updatedAtMs == null
          ? DateTime.fromMillisecondsSinceEpoch(0)
          : DateTime.fromMillisecondsSinceEpoch(
              updatedAtMs,
              isUtc: true,
            ).toLocal(),
      customEmojiEntities: (json['custom_emoji_entities'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (entity) =>
                CustomEmojiEntity.fromJson(Map<String, dynamic>.from(entity)),
          )
          .where((entity) => entity.customEmojiId.isNotEmpty)
          .toList(),
      sendSilent: json['send_silent'] as bool? ?? false,
      scheduledFor: scheduledForMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              scheduledForMs,
              isUtc: true,
            ).toLocal(),
    );
  }
}

/// App-wide user preferences that persist across launches: the accent color
/// used to seed the Material theme, whether Channels and Bots get their own
/// navigation tabs, per-DM chat styling, and notification settings.
class SettingsProvider extends ChangeNotifier {
  static const _kSeed = 'app_seed_color';
  static const _kChannelsTab = 'channels_own_tab';
  static const _kBotsTab = 'bots_own_tab';
  static const _kDmStylePrefix = 'dm_style_';
  static const _kDraftPrefix = 'message_draft_';
  static const _kPinnedChannelMessagesPrefix = 'pinned_channel_messages_';
  static const _kPushEnabled = 'push_notifications_enabled';
  static const _kWsBgEnabled = 'ws_background_enabled';
  static const _kNotifSensitive = 'notification_sensitive_content';
  static const _kStrictPrivacyMode = 'strict_privacy_mode';
  static const _kLinkPreviewsEnabled = 'link_previews_enabled';
  static const _kReduceTransparency = 'reduce_transparency';
  static const _kSmartInboxFilter = 'smart_inbox_filter';
  static const _kPinnedConversations = 'pinned_conversations';
  static const _kArchivedConversations = 'archived_conversations';
  static const _kMutedConversations = mutedConversationsPreferenceKey;
  static const _kConversationNotificationPreferences =
      conversationNotificationPreferencesPreferenceKey;

  /// OpenChat brand blue — the historical default seed.
  static const int defaultSeed = 0xFF3D5AFE;

  SharedPreferences? _prefs;
  Future<void>? _loadFuture;
  bool _loaded = false;

  int _seedColor = defaultSeed;
  bool _channelsOwnTab = false;
  bool _botsOwnTab = false;
  bool _pushEnabled = false;
  bool _wsBgEnabled = false;
  bool _notifSensitive = false;
  bool _strictPrivacyMode = false;
  bool _linkPreviewsEnabled = true;
  bool _reduceTransparency = false;
  SmartInboxFilter _smartInboxFilter = SmartInboxFilter.all;
  final Map<String, MessageDraft> _messageDrafts = {};
  final Map<String, List<ChannelPinnedMessage>> _pinnedChannelMessages = {};
  final Set<String> _pinnedConversationIds = {};
  final Set<String> _archivedConversationIds = {};
  final Map<String, ConversationNotificationPreference>
  _conversationNotificationPreferences = {};

  int get seedColorValue => _seedColor;
  Color get seedColor => Color(_seedColor);
  bool get channelsOwnTab => _channelsOwnTab;
  bool get botsOwnTab => _botsOwnTab;
  SmartInboxFilter get smartInboxFilter => _smartInboxFilter;
  bool get isLoaded => _loaded;
  Map<String, MessageDraft> get messageDrafts =>
      Map.unmodifiable(_messageDrafts);
  Map<String, List<ChannelPinnedMessage>> get pinnedChannelMessages =>
      Map.unmodifiable(
        _pinnedChannelMessages.map(
          (channelId, messages) =>
              MapEntry(channelId, List.unmodifiable(messages)),
        ),
      );
  Set<String> get pinnedConversationIds =>
      Set.unmodifiable(_pinnedConversationIds);
  Set<String> get archivedConversationIds =>
      Set.unmodifiable(_archivedConversationIds);
  Map<String, ConversationNotificationPreference>
  get conversationNotificationPreferences => Map.unmodifiable(
    _effectiveConversationNotificationPreferences(DateTime.now()),
  );
  Set<String> get mutedConversationIds => Set.unmodifiable(
    activeMutedConversationIds(_conversationNotificationPreferences),
  );

  /// When true the app replaces shader-backed glass with solid frosted panels
  /// throughout, reducing visual complexity for users who prefer it.
  bool get reduceTransparency => _reduceTransparency;

  /// Firebase/APNs push notifications. Off by default (opt-in, privacy warning shown on enable).
  bool get pushNotificationsEnabled => _pushEnabled;

  /// Background WebSocket connection. Off by default (opt-in, battery warning shown on enable).
  bool get wsBackgroundEnabled => _wsBgEnabled;

  /// Show sender name + message preview in notifications. Off = generic "New message" text.
  bool get notificationSensitiveContent =>
      _strictPrivacyMode ? false : _notifSensitive;

  /// Local strict privacy mode disables presence-style metadata and sensitive previews.
  bool get strictPrivacyMode => _strictPrivacyMode;

  /// Fetch link previews through the OpenChat proxy after local decryption.
  bool get linkPreviewsEnabled => _linkPreviewsEnabled;

  Future<void> load() {
    _loadFuture ??= _load();
    return _loadFuture!;
  }

  Future<void> _load() async {
    _prefs = await SharedPreferences.getInstance();
    _seedColor = _prefs!.getInt(_kSeed) ?? defaultSeed;
    _channelsOwnTab = _prefs!.getBool(_kChannelsTab) ?? false;
    _botsOwnTab = _prefs!.getBool(_kBotsTab) ?? false;
    _pushEnabled = _prefs!.getBool(_kPushEnabled) ?? false;
    _wsBgEnabled = _prefs!.getBool(_kWsBgEnabled) ?? false;
    if (_pushEnabled && _wsBgEnabled) {
      // Legacy state guard: never allow both channels to stay enabled.
      _wsBgEnabled = false;
      await _prefs!.setBool(_kWsBgEnabled, false);
    }
    _notifSensitive = _prefs!.getBool(_kNotifSensitive) ?? false;
    _strictPrivacyMode = _prefs!.getBool(_kStrictPrivacyMode) ?? false;
    if (_strictPrivacyMode && _notifSensitive) {
      _notifSensitive = false;
      await _prefs!.setBool(_kNotifSensitive, false);
    }
    _linkPreviewsEnabled = _prefs!.getBool(_kLinkPreviewsEnabled) ?? true;
    _reduceTransparency = _prefs!.getBool(_kReduceTransparency) ?? false;
    _smartInboxFilter = smartInboxFilterFromName(
      _prefs!.getString(_kSmartInboxFilter),
    );
    _pinnedConversationIds
      ..clear()
      ..addAll(_prefs!.getStringList(_kPinnedConversations) ?? const []);
    _archivedConversationIds
      ..clear()
      ..addAll(_prefs!.getStringList(_kArchivedConversations) ?? const []);
    final legacyMutedConversationIds =
        _prefs!.getStringList(_kMutedConversations) ?? const [];
    _conversationNotificationPreferences
      ..clear()
      ..addAll(
        decodeConversationNotificationPreferences(
          _prefs!.getString(_kConversationNotificationPreferences),
        ),
      );
    for (final convID in legacyMutedConversationIds) {
      _conversationNotificationPreferences.putIfAbsent(
        convID,
        () => const ConversationNotificationPreference.mutedForever(),
      );
    }
    _dropExpiredConversationNotificationPreferences(DateTime.now());
    _messageDrafts
      ..clear()
      ..addEntries(
        _prefs!.getKeys().where((key) => key.startsWith(_kDraftPrefix)).map((
          key,
        ) {
          final conversationId = key.substring(_kDraftPrefix.length);
          final draft = _parseDraft(_prefs!.getString(key));
          return draft == null || draft.isEmpty
              ? null
              : MapEntry(conversationId, draft);
        }).whereType<MapEntry<String, MessageDraft>>(),
      );
    _pinnedChannelMessages
      ..clear()
      ..addEntries(
        _prefs!
            .getKeys()
            .where((key) => key.startsWith(_kPinnedChannelMessagesPrefix))
            .map((key) {
              final channelId = key.substring(
                _kPinnedChannelMessagesPrefix.length,
              );
              final messages = _parsePinnedChannelMessages(
                _prefs!.getString(key),
              );
              return messages.isEmpty ? null : MapEntry(channelId, messages);
            })
            .whereType<MapEntry<String, List<ChannelPinnedMessage>>>(),
      );
    _loaded = true;
    notifyListeners();
  }

  Future<void> setSeedColor(Color color) async {
    _seedColor = color.toARGB32();
    notifyListeners();
    await _prefs?.setInt(_kSeed, _seedColor);
  }

  Future<void> resetSeedColor() => setSeedColor(const Color(defaultSeed));

  Future<void> setChannelsOwnTab(bool value) async {
    _channelsOwnTab = value;
    notifyListeners();
    await _prefs?.setBool(_kChannelsTab, value);
  }

  Future<void> setBotsOwnTab(bool value) async {
    _botsOwnTab = value;
    notifyListeners();
    await _prefs?.setBool(_kBotsTab, value);
  }

  Future<void> setSmartInboxFilter(SmartInboxFilter filter) async {
    _smartInboxFilter = filter;
    notifyListeners();
    await _prefs?.setString(_kSmartInboxFilter, filter.name);
  }

  bool isConversationPinned(String convID) =>
      _pinnedConversationIds.contains(convID);

  Future<void> setConversationPinned(String convID, bool pinned) async {
    final changed = pinned
        ? _pinnedConversationIds.add(convID)
        : _pinnedConversationIds.remove(convID);
    if (!changed) return;
    notifyListeners();
    await _prefs?.setStringList(
      _kPinnedConversations,
      _pinnedConversationIds.toList()..sort(),
    );
  }

  Future<void> toggleConversationPinned(String convID) {
    return setConversationPinned(convID, !isConversationPinned(convID));
  }

  bool isConversationArchived(String convID) =>
      _archivedConversationIds.contains(convID);

  Future<void> setConversationArchived(String convID, bool archived) async {
    final changed = archived
        ? _archivedConversationIds.add(convID)
        : _archivedConversationIds.remove(convID);
    if (!changed) return;
    notifyListeners();
    await _prefs?.setStringList(
      _kArchivedConversations,
      _archivedConversationIds.toList()..sort(),
    );
  }

  Future<void> toggleConversationArchived(String convID) {
    return setConversationArchived(convID, !isConversationArchived(convID));
  }

  bool isConversationMuted(String convID) =>
      notificationPreferenceForConversation(convID).isMutedAt(DateTime.now());

  bool isConversationMentionsOnly(String convID) =>
      notificationPreferenceForConversation(convID).mode ==
      ConversationNotificationMode.mentionsOnly;

  ConversationNotificationPreference notificationPreferenceForConversation(
    String convID,
  ) {
    final preference = _conversationNotificationPreferences[convID];
    if (preference == null || preference.isExpiredAt(DateTime.now())) {
      return const ConversationNotificationPreference.all();
    }
    return preference;
  }

  String notificationLabelForConversation(String convID) {
    final preference = notificationPreferenceForConversation(convID);
    final modeLabel = switch (preference.mode) {
      ConversationNotificationMode.all => 'All messages',
      ConversationNotificationMode.mentionsOnly => 'Mentions only',
      ConversationNotificationMode.muted =>
        preference.mutedUntil == null
            ? 'Muted'
            : 'Muted until ${_formatMuteUntil(preference.mutedUntil!)}',
    };
    final parts = <String>[modeLabel];
    if (preference.priority) parts.add('Priority');
    if (preference.keywords.isNotEmpty) {
      parts.add('${preference.keywords.length} keywords');
    }
    if (preference.hasQuietHours) parts.add('Quiet hours');
    return parts.join(' · ');
  }

  Future<void> setConversationNotificationPreference(
    String convID,
    ConversationNotificationPreference preference,
  ) async {
    final normalized =
        preference.isDefault || preference.isExpiredAt(DateTime.now())
        ? const ConversationNotificationPreference.all()
        : preference;
    final current = notificationPreferenceForConversation(convID);
    if (current == normalized) return;
    if (normalized.isDefault) {
      _conversationNotificationPreferences.remove(convID);
    } else {
      _conversationNotificationPreferences[convID] = normalized;
    }
    notifyListeners();
    await _persistConversationNotificationPreferences();
  }

  Future<void> setConversationMuted(String convID, bool muted) async {
    final preference = notificationPreferenceForConversation(convID);
    return setConversationNotificationPreference(
      convID,
      muted
          ? preference.copyWith(
              mode: ConversationNotificationMode.muted,
              clearMutedUntil: true,
            )
          : preference.copyWith(
              mode: ConversationNotificationMode.all,
              clearMutedUntil: true,
            ),
    );
  }

  Future<void> toggleConversationMuted(String convID) {
    return setConversationMuted(convID, !isConversationMuted(convID));
  }

  Future<void> muteConversationUntil(String convID, DateTime mutedUntil) {
    final preference = notificationPreferenceForConversation(convID);
    return setConversationNotificationPreference(
      convID,
      preference.copyWith(
        mode: ConversationNotificationMode.muted,
        mutedUntil: mutedUntil,
      ),
    );
  }

  Future<void> setConversationMentionsOnly(String convID) {
    final preference = notificationPreferenceForConversation(convID);
    return setConversationNotificationPreference(
      convID,
      preference.copyWith(
        mode: ConversationNotificationMode.mentionsOnly,
        clearMutedUntil: true,
      ),
    );
  }

  Future<void> setConversationNotificationKeywords(
    String convID,
    Iterable<String> keywords,
  ) {
    final preference = notificationPreferenceForConversation(convID);
    return setConversationNotificationPreference(
      convID,
      preference.copyWith(keywords: normalizeNotificationKeywords(keywords)),
    );
  }

  Future<void> setConversationPriorityNotifications(
    String convID,
    bool priority,
  ) {
    final preference = notificationPreferenceForConversation(convID);
    return setConversationNotificationPreference(
      convID,
      preference.copyWith(priority: priority),
    );
  }

  Future<void> setConversationQuietHours(
    String convID, {
    required int startMinute,
    required int endMinute,
  }) {
    final preference = notificationPreferenceForConversation(convID);
    return setConversationNotificationPreference(
      convID,
      preference.copyWith(
        quietHoursStartMinute: startMinute.clamp(0, 1439).toInt(),
        quietHoursEndMinute: endMinute.clamp(0, 1439).toInt(),
      ),
    );
  }

  Future<void> clearConversationQuietHours(String convID) {
    final preference = notificationPreferenceForConversation(convID);
    return setConversationNotificationPreference(
      convID,
      preference.copyWith(clearQuietHours: true),
    );
  }

  Map<String, ConversationNotificationPreference>
  _effectiveConversationNotificationPreferences(DateTime now) {
    final effective = <String, ConversationNotificationPreference>{};
    for (final entry in _conversationNotificationPreferences.entries) {
      if (!entry.value.isExpiredAt(now)) effective[entry.key] = entry.value;
    }
    return effective;
  }

  void _dropExpiredConversationNotificationPreferences(DateTime now) {
    _conversationNotificationPreferences.removeWhere(
      (_, preference) => preference.isExpiredAt(now),
    );
  }

  Future<void> _persistConversationNotificationPreferences() async {
    _dropExpiredConversationNotificationPreferences(DateTime.now());
    await _prefs?.setString(
      _kConversationNotificationPreferences,
      encodeConversationNotificationPreferences(
        _conversationNotificationPreferences,
      ),
    );
    await _prefs?.setStringList(
      _kMutedConversations,
      mutedConversationIds.toList()..sort(),
    );
  }

  String _formatMuteUntil(DateTime mutedUntil) {
    final local = mutedUntil.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.month}/${local.day} $hour:$minute';
  }

  MessageDraft? messageDraftFor(String convID) => _messageDrafts[convID];

  Future<void> setMessageDraft(
    String convID,
    String text, {
    List<CustomEmojiEntity> customEmojiEntities = const [],
    bool sendSilent = false,
    DateTime? scheduledFor,
  }) async {
    if (text.trim().isEmpty) {
      await clearMessageDraft(convID);
      return;
    }
    final draft = MessageDraft(
      text: text,
      updatedAt: DateTime.now(),
      customEmojiEntities: customEmojiEntities,
      sendSilent: sendSilent,
      scheduledFor: scheduledFor,
    );
    _messageDrafts[convID] = draft;
    notifyListeners();
    await _prefs?.setString(
      '$_kDraftPrefix$convID',
      jsonEncode(draft.toJson()),
    );
  }

  Future<void> clearMessageDraft(String convID) async {
    final removed = _messageDrafts.remove(convID);
    if (removed != null) notifyListeners();
    await _prefs?.remove('$_kDraftPrefix$convID');
  }

  List<ChannelPinnedMessage> pinnedMessagesForChannel(String channelId) {
    return List.unmodifiable(_pinnedChannelMessages[channelId] ?? const []);
  }

  bool isChannelMessagePinned(String channelId, String messageId) {
    return pinnedMessagesForChannel(
      channelId,
    ).any((message) => message.messageId == messageId);
  }

  Future<void> setChannelMessagePinned(
    String channelId,
    ChannelPinnedMessage pinnedMessage,
    bool pinned,
  ) async {
    final current = List<ChannelPinnedMessage>.from(
      _pinnedChannelMessages[channelId] ?? const [],
    );
    final existingIndex = current.indexWhere(
      (message) => message.messageId == pinnedMessage.messageId,
    );
    var changed = false;
    if (pinned) {
      if (existingIndex != -1) current.removeAt(existingIndex);
      current.insert(0, pinnedMessage);
      changed = true;
    } else if (existingIndex != -1) {
      current.removeAt(existingIndex);
      changed = true;
    }
    if (!changed) return;

    if (current.isEmpty) {
      _pinnedChannelMessages.remove(channelId);
      await _prefs?.remove('$_kPinnedChannelMessagesPrefix$channelId');
    } else {
      current.sort((a, b) => b.pinnedAt.compareTo(a.pinnedAt));
      _pinnedChannelMessages[channelId] = current;
      await _prefs?.setString(
        '$_kPinnedChannelMessagesPrefix$channelId',
        jsonEncode(current.map((message) => message.toJson()).toList()),
      );
    }
    notifyListeners();
  }

  Future<void> replaceChannelPinnedMessages(
    String channelId,
    List<ChannelPinnedMessage> messages,
  ) async {
    final deduped = <String, ChannelPinnedMessage>{};
    for (final message in messages) {
      if (message.messageId.isEmpty) continue;
      deduped[message.messageId] = message;
    }
    final normalized = deduped.values.toList()
      ..sort((a, b) => b.pinnedAt.compareTo(a.pinnedAt));

    if (normalized.isEmpty) {
      _pinnedChannelMessages.remove(channelId);
      await _prefs?.remove('$_kPinnedChannelMessagesPrefix$channelId');
    } else {
      _pinnedChannelMessages[channelId] = normalized;
      await _prefs?.setString(
        '$_kPinnedChannelMessagesPrefix$channelId',
        jsonEncode(normalized.map((message) => message.toJson()).toList()),
      );
    }
    notifyListeners();
  }

  Future<void> unpinChannelMessage(String channelId, String messageId) {
    return setChannelMessagePinned(
      channelId,
      ChannelPinnedMessage(
        messageId: messageId,
        preview: '',
        messageCreatedAt: DateTime.fromMillisecondsSinceEpoch(0),
        pinnedAt: DateTime.fromMillisecondsSinceEpoch(0),
      ),
      false,
    );
  }

  Future<void> setPushNotificationsEnabled(bool value) async {
    _pushEnabled = value;
    if (value) {
      _wsBgEnabled = false;
    }
    notifyListeners();
    await _prefs?.setBool(_kPushEnabled, value);
    if (value) {
      await _prefs?.setBool(_kWsBgEnabled, false);
    }
  }

  Future<void> setWsBackgroundEnabled(bool value) async {
    _wsBgEnabled = value;
    if (value) {
      _pushEnabled = false;
    }
    notifyListeners();
    await _prefs?.setBool(_kWsBgEnabled, value);
    if (value) {
      await _prefs?.setBool(_kPushEnabled, false);
    }
  }

  Future<void> setNotificationSensitiveContent(bool value) async {
    if (_strictPrivacyMode && value) {
      _notifSensitive = false;
      notifyListeners();
      await _prefs?.setBool(_kNotifSensitive, false);
      return;
    }
    _notifSensitive = value;
    notifyListeners();
    await _prefs?.setBool(_kNotifSensitive, value);
  }

  Future<void> setStrictPrivacyMode(bool value) async {
    _strictPrivacyMode = value;
    if (value) {
      _notifSensitive = false;
      await _prefs?.setBool(_kNotifSensitive, false);
    }
    notifyListeners();
    await _prefs?.setBool(_kStrictPrivacyMode, value);
  }

  Future<void> setLinkPreviewsEnabled(bool value) async {
    _linkPreviewsEnabled = value;
    notifyListeners();
    await _prefs?.setBool(_kLinkPreviewsEnabled, value);
  }

  Future<void> setReduceTransparency(bool value) async {
    _reduceTransparency = value;
    notifyListeners();
    await _prefs?.setBool(_kReduceTransparency, value);
  }

  ChatStyle chatStyleFor(String convID) {
    final raw = _prefs?.getString('$_kDmStylePrefix$convID');
    if (raw == null || raw.isEmpty) return const ChatStyle();
    try {
      return ChatStyle.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const ChatStyle();
    }
  }

  DmChatStyle dmStyleFor(String convID) => chatStyleFor(convID);

  Future<void> setChatStyle(String convID, ChatStyle style) async {
    if (style.isDefault) {
      await _prefs?.remove('$_kDmStylePrefix$convID');
    } else {
      await _prefs?.setString(
        '$_kDmStylePrefix$convID',
        jsonEncode(style.toJson()),
      );
    }
    notifyListeners();
  }

  Future<void> setDmStyle(String convID, DmChatStyle style) =>
      setChatStyle(convID, style);

  static MessageDraft? _parseDraft(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return MessageDraft.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static List<ChannelPinnedMessage> _parsePinnedChannelMessages(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw) as List;
      return decoded
          .map(
            (entry) =>
                ChannelPinnedMessage.fromJson(entry as Map<String, dynamic>),
          )
          .where((message) => message.messageId.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }
}
