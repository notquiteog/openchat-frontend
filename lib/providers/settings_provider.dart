import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/channel_pinned_message.dart';
import '../models/chat_folder.dart';
import '../models/contact_bundle.dart';
import '../models/message.dart';
import '../models/message_reminder.dart';
import '../services/local_private_state_service.dart';
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
  static const _kNotificationCurrentUser = 'notification_current_user_id';

  /// OpenChat brand blue — the historical default seed.
  static const int defaultSeed = 0xFF3D5AFE;

  final LocalPrivateStateService _privateState;

  SettingsProvider({LocalPrivateStateService? privateState})
    : _privateState = privateState ?? LocalPrivateStateService();

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
  final List<ChatFolder> _chatFolders = [];
  final Map<String, ContactBundle> _privateContacts = {};
  final Map<String, String> _unreadMentionMessageIds = {};
  final Set<String> _privacyOnboardingViewedUserIds = {};
  final Map<String, MessageReminder> _messageReminders = {};
  final Set<String> _viewedOnceMediaMessageIds = {};
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
  List<ChatFolder> get chatFolders => List.unmodifiable(_chatFolders);
  Map<String, ContactBundle> get privateContacts =>
      Map.unmodifiable(_privateContacts);
  Map<String, String> get unreadMentionMessageIds =>
      Map.unmodifiable(_unreadMentionMessageIds);
  List<MessageReminder> get messageReminders =>
      List.unmodifiable(_sortedMessageReminders());
  bool hasViewedOnceMedia(String messageId) =>
      _viewedOnceMediaMessageIds.contains(messageId);
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
  ///
  /// This is the single notification-content control. Strict privacy handles
  /// live metadata surfaces instead of silently rewriting this preference.
  bool get notificationSensitiveContent => _notifSensitive;

  /// Local strict privacy mode disables presence-style metadata and link fetches.
  bool get strictPrivacyMode => _strictPrivacyMode;

  /// Fetch link previews through the OpenChat proxy after local decryption.
  bool get linkPreviewsEnabled =>
      _strictPrivacyMode ? false : _linkPreviewsEnabled;

  Future<void> load() {
    _loadFuture ??= _load();
    return _loadFuture!;
  }

  Future<void> reload() {
    _loadFuture = null;
    _loaded = false;
    return load();
  }

  Future<void> _load() async {
    _prefs = await SharedPreferences.getInstance();
    final privateState = await _privateState.readState();
    _seedColor = _prefs!.getInt(_kSeed) ?? defaultSeed;
    _channelsOwnTab = _prefs!.getBool(_kChannelsTab) ?? false;
    _botsOwnTab = _prefs!.getBool(_kBotsTab) ?? false;
    final notificationSettings = decodePrivateNotificationSettings(
      privateState[privateStateNotificationSettingsKey],
    );
    _pushEnabled = notificationSettings.pushEnabled;
    _wsBgEnabled = notificationSettings.wsBackgroundEnabled;
    if (_pushEnabled && _wsBgEnabled) {
      // Legacy state guard: never allow both channels to stay enabled.
      _wsBgEnabled = false;
      await _persistPrivateLocalState();
    }
    _notifSensitive = notificationSettings.sensitiveContent;
    _strictPrivacyMode = _prefs!.getBool(_kStrictPrivacyMode) ?? false;
    _linkPreviewsEnabled = _prefs!.getBool(_kLinkPreviewsEnabled) ?? true;
    _reduceTransparency = _prefs!.getBool(_kReduceTransparency) ?? false;
    _smartInboxFilter = smartInboxFilterFromName(
      _prefs!.getString(_kSmartInboxFilter),
    );
    _pinnedConversationIds
      ..clear()
      ..addAll(
        _stringListFromPrivateState(
          privateState[privateStatePinnedConversationsKey],
        ),
      );
    _archivedConversationIds
      ..clear()
      ..addAll(
        _stringListFromPrivateState(
          privateState[privateStateArchivedConversationsKey],
        ),
      );
    _conversationNotificationPreferences
      ..clear()
      ..addAll(
        decodePrivateConversationNotificationPreferences(
          privateState[privateStateConversationNotificationPreferencesKey],
        ),
      );
    _dropExpiredConversationNotificationPreferences(DateTime.now());
    _chatFolders
      ..clear()
      ..addAll(
        decodePrivateChatFolders(privateState[privateStateChatFoldersKey]),
      );
    _sortChatFolders(_chatFolders);
    _privateContacts
      ..clear()
      ..addAll(
        decodePrivateContacts(privateState[privateStatePrivateContactsKey]),
      );
    await _prefs!.remove(_kConversationNotificationPreferences);
    await _prefs!.remove(_kMutedConversations);
    await _prefs!.remove(_kNotificationCurrentUser);
    await _prefs!.remove(_kPushEnabled);
    await _prefs!.remove(_kWsBgEnabled);
    await _prefs!.remove(_kNotifSensitive);
    _messageDrafts
      ..clear()
      ..addAll(_parsePrivateDrafts(privateState[privateStateMessageDraftsKey]));
    _pinnedChannelMessages
      ..clear()
      ..addAll(
        _parsePrivatePinnedChannelMessages(
          privateState[privateStatePinnedChannelMessagesKey],
        ),
      );
    _unreadMentionMessageIds
      ..clear()
      ..addAll(
        _parsePrivateStringMap(
          privateState[privateStateUnreadMentionMessageIdsKey],
        ),
      );
    _privacyOnboardingViewedUserIds
      ..clear()
      ..addAll(
        _stringListFromPrivateState(
          privateState[privateStatePrivacyOnboardingViewedUserIdsKey],
        ),
      );
    _messageReminders
      ..clear()
      ..addAll(
        _parsePrivateMessageReminders(
          privateState[privateStateMessageRemindersKey],
        ),
      );
    _viewedOnceMediaMessageIds
      ..clear()
      ..addAll(
        _stringListFromPrivateState(
          privateState[privateStateViewedOnceMediaKey],
        ),
      );
    await _removeLegacyLocalStatePlaintext();
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
    await _persistPrivateLocalState();
    await _prefs?.remove(_kPinnedConversations);
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
    await _persistPrivateLocalState();
    await _prefs?.remove(_kArchivedConversations);
  }

  Future<void> toggleConversationArchived(String convID) {
    return setConversationArchived(convID, !isConversationArchived(convID));
  }

  Future<List<ChatFolder>> loadChatFolders() async {
    await load();
    return chatFolders;
  }

  Future<ChatFolder> saveChatFolder(ChatFolder folder) async {
    await load();
    final now = DateTime.now();
    final normalized = _normalizeChatFolder(folder, now);
    final index = _chatFolders.indexWhere((item) => item.id == normalized.id);
    if (index == -1) {
      _chatFolders.add(normalized);
    } else {
      _chatFolders[index] = normalized;
    }
    _sortChatFolders(_chatFolders);
    notifyListeners();
    await _persistPrivateLocalState();
    return normalized;
  }

  Future<void> removeChatFolder(String folderId) async {
    await load();
    final before = _chatFolders.length;
    _chatFolders.removeWhere((folder) => folder.id == folderId);
    if (_chatFolders.length == before) return;
    notifyListeners();
    await _persistPrivateLocalState();
  }

  String? unreadMentionMessageIdFor(String convID) {
    final value = _unreadMentionMessageIds[convID];
    return value == null || value.isEmpty ? null : value;
  }

  Future<void> setUnreadMentionMessage(String convID, String messageID) async {
    if (convID.isEmpty || messageID.isEmpty) return;
    if (_unreadMentionMessageIds[convID] == messageID) return;
    _unreadMentionMessageIds[convID] = messageID;
    notifyListeners();
    await _persistPrivateLocalState();
  }

  Future<void> clearUnreadMention(String convID, {String? messageID}) async {
    final current = _unreadMentionMessageIds[convID];
    if (current == null || (messageID != null && current != messageID)) return;
    _unreadMentionMessageIds.remove(convID);
    notifyListeners();
    await _persistPrivateLocalState();
  }

  Future<void> upsertPrivateContact(ContactBundle contact) async {
    if (!contact.isUsable) return;
    _privateContacts[contact.userId] = contact;
    notifyListeners();
    await _persistPrivateLocalState();
  }

  Future<void> removePrivateContact(String userId) async {
    if (_privateContacts.remove(userId) == null) return;
    notifyListeners();
    await _persistPrivateLocalState();
  }

  bool hasViewedPrivacyOnboarding(String userId) {
    final normalized = userId.trim();
    return normalized.isNotEmpty &&
        _privacyOnboardingViewedUserIds.contains(normalized);
  }

  Future<void> markPrivacyOnboardingViewed(String userId) async {
    final normalized = userId.trim();
    if (normalized.isEmpty) return;
    if (!_privacyOnboardingViewedUserIds.add(normalized)) return;
    notifyListeners();
    await _persistPrivateLocalState();
  }

  Future<MessageReminder> saveMessageReminder({
    required String conversationId,
    required String messageId,
    required String conversationTitle,
    required String messagePreview,
    required DateTime remindAt,
  }) async {
    await load();
    final id = 'reminder-${const Uuid().v4()}';
    final reminder = MessageReminder(
      id: id,
      conversationId: conversationId.trim(),
      messageId: messageId.trim(),
      conversationTitle: conversationTitle.trim(),
      messagePreview: messagePreview.trim(),
      remindAt: remindAt,
      createdAt: DateTime.now(),
    );
    if (reminder.conversationId.isEmpty || reminder.messageId.isEmpty) {
      throw ArgumentError('conversationId and messageId are required');
    }
    _messageReminders[id] = reminder;
    notifyListeners();
    await _persistPrivateLocalState();
    return reminder;
  }

  Future<void> removeMessageReminder(String reminderId) async {
    if (_messageReminders.remove(reminderId) == null) return;
    notifyListeners();
    await _persistPrivateLocalState();
  }

  List<MessageReminder> dueMessageReminders(DateTime now) =>
      _sortedMessageReminders()
          .where((reminder) => !now.isBefore(reminder.remindAt))
          .toList();

  Future<void> markViewOnceMediaViewed(String messageId) async {
    final normalized = messageId.trim();
    if (normalized.isEmpty || !_viewedOnceMediaMessageIds.add(normalized)) {
      return;
    }
    notifyListeners();
    await _persistPrivateLocalState();
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
    await _persistPrivateLocalState();
    await _prefs?.remove(_kConversationNotificationPreferences);
    await _prefs?.remove(_kMutedConversations);
    await _prefs?.remove(_kNotificationCurrentUser);
    await _prefs?.remove(_kPushEnabled);
    await _prefs?.remove(_kWsBgEnabled);
    await _prefs?.remove(_kNotifSensitive);
  }

  Future<void> _persistPrivateLocalState() {
    return _privateState.writeState({
      privateStateNotificationSettingsKey: encodePrivateNotificationSettings(
        pushEnabled: _pushEnabled,
        wsBackgroundEnabled: _wsBgEnabled,
        sensitiveContent: _notifSensitive,
      ),
      privateStateConversationNotificationPreferencesKey:
          encodePrivateConversationNotificationPreferences(
            _conversationNotificationPreferences,
          ),
      privateStateChatFoldersKey: encodePrivateChatFolders(_chatFolders),
      privateStateMessageDraftsKey: _encodePrivateDrafts(_messageDrafts),
      privateStatePinnedChannelMessagesKey: _encodePrivatePinnedChannelMessages(
        _pinnedChannelMessages,
      ),
      privateStatePinnedConversationsKey: _sortedStringList(
        _pinnedConversationIds,
      ),
      privateStateArchivedConversationsKey: _sortedStringList(
        _archivedConversationIds,
      ),
      privateStateUnreadMentionMessageIdsKey: _encodePrivateStringMap(
        _unreadMentionMessageIds,
      ),
      privateStatePrivateContactsKey: encodePrivateContacts(
        _privateContacts.values,
      ),
      privateStatePrivacyOnboardingViewedUserIdsKey: _sortedStringList(
        _privacyOnboardingViewedUserIds,
      ),
      privateStateMessageRemindersKey: _encodePrivateMessageReminders(
        _messageReminders,
      ),
      privateStateViewedOnceMediaKey: _sortedStringList(
        _viewedOnceMediaMessageIds,
      ),
    });
  }

  ChatFolder _normalizeChatFolder(ChatFolder folder, DateTime now) {
    final seenConversationIds = <String>{};
    final conversationIds = <String>[];
    for (final rawId in folder.conversationIds) {
      final id = rawId.trim();
      if (id.isEmpty || !seenConversationIds.add(id)) continue;
      conversationIds.add(id);
    }
    return folder.copyWith(
      id: folder.id.isEmpty ? 'local-${const Uuid().v4()}' : folder.id,
      userId: '',
      name: folder.name.trim(),
      conversationIds: conversationIds,
      createdAt: folder.createdAt ?? now,
      updatedAt: now,
    );
  }

  void _sortChatFolders(List<ChatFolder> folders) {
    folders.sort((a, b) {
      final position = a.position.compareTo(b.position);
      if (position != 0) return position;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
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
    await _persistPrivateLocalState();
    await _prefs?.remove('$_kDraftPrefix$convID');
  }

  Future<void> clearMessageDraft(String convID) async {
    final removed = _messageDrafts.remove(convID);
    if (removed != null) notifyListeners();
    await _persistPrivateLocalState();
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
      await _prefs?.remove('$_kPinnedChannelMessagesPrefix$channelId');
    }
    await _persistPrivateLocalState();
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
      await _prefs?.remove('$_kPinnedChannelMessagesPrefix$channelId');
    }
    await _persistPrivateLocalState();
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
    await _persistPrivateLocalState();
    await _prefs?.remove(_kPushEnabled);
    await _prefs?.remove(_kWsBgEnabled);
  }

  Future<void> setWsBackgroundEnabled(bool value) async {
    _wsBgEnabled = value;
    if (value) {
      _pushEnabled = false;
    }
    notifyListeners();
    await _persistPrivateLocalState();
    await _prefs?.remove(_kWsBgEnabled);
    await _prefs?.remove(_kPushEnabled);
  }

  Future<void> setNotificationSensitiveContent(bool value) async {
    _notifSensitive = value;
    notifyListeners();
    await _persistPrivateLocalState();
    await _prefs?.remove(_kNotifSensitive);
  }

  Future<void> setStrictPrivacyMode(bool value) async {
    _strictPrivacyMode = value;
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

  static Map<String, MessageDraft> _parsePrivateDrafts(Object? raw) {
    if (raw is! Map) return const {};
    final drafts = <String, MessageDraft>{};
    for (final entry in raw.entries) {
      final conversationId = entry.key.toString();
      if (conversationId.isEmpty || entry.value is! Map) continue;
      try {
        final draft = MessageDraft.fromJson(
          Map<String, dynamic>.from(entry.value as Map),
        );
        if (!draft.isEmpty) drafts[conversationId] = draft;
      } catch (_) {}
    }
    return drafts;
  }

  static Map<String, dynamic> _encodePrivateDrafts(
    Map<String, MessageDraft> drafts,
  ) => {
    for (final entry in drafts.entries)
      if (entry.key.isNotEmpty && !entry.value.isEmpty)
        entry.key: entry.value.toJson(),
  };

  static Map<String, List<ChannelPinnedMessage>>
  _parsePrivatePinnedChannelMessages(Object? raw) {
    if (raw is! Map) return const {};
    final pinned = <String, List<ChannelPinnedMessage>>{};
    for (final entry in raw.entries) {
      final channelId = entry.key.toString();
      final rawMessages = entry.value;
      if (channelId.isEmpty || rawMessages is! List) continue;
      final messages =
          rawMessages
              .whereType<Map>()
              .map(
                (item) => ChannelPinnedMessage.fromJson(
                  Map<String, dynamic>.from(item),
                ),
              )
              .where((message) => message.messageId.isNotEmpty)
              .toList()
            ..sort((a, b) => b.pinnedAt.compareTo(a.pinnedAt));
      if (messages.isNotEmpty) pinned[channelId] = messages;
    }
    return pinned;
  }

  static Map<String, dynamic> _encodePrivatePinnedChannelMessages(
    Map<String, List<ChannelPinnedMessage>> pinned,
  ) => {
    for (final entry in pinned.entries)
      if (entry.key.isNotEmpty && entry.value.isNotEmpty)
        entry.key: entry.value.map((message) => message.toJson()).toList(),
  };

  static List<String> _stringListFromPrivateState(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .map((value) => value.toString().trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
  }

  static List<String> _sortedStringList(Iterable<String> values) {
    return values
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
  }

  static Map<String, String> _parsePrivateStringMap(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, String>{};
    for (final entry in raw.entries) {
      final key = entry.key.toString().trim();
      final value = entry.value.toString().trim();
      if (key.isEmpty || value.isEmpty) continue;
      out[key] = value;
    }
    return out;
  }

  static Map<String, String> _encodePrivateStringMap(
    Map<String, String> values,
  ) => {
    for (final entry in values.entries)
      if (entry.key.trim().isNotEmpty && entry.value.trim().isNotEmpty)
        entry.key.trim(): entry.value.trim(),
  };

  List<MessageReminder> _sortedMessageReminders() {
    final reminders = _messageReminders.values.toList()
      ..sort((a, b) => a.remindAt.compareTo(b.remindAt));
    return reminders;
  }

  static Map<String, MessageReminder> _parsePrivateMessageReminders(
    Object? raw,
  ) {
    if (raw is! List) return const {};
    final reminders = <String, MessageReminder>{};
    for (final item in raw.whereType<Map>()) {
      try {
        final reminder = MessageReminder.fromJson(
          Map<String, dynamic>.from(item),
        );
        if (reminder.id.isEmpty ||
            reminder.conversationId.isEmpty ||
            reminder.messageId.isEmpty) {
          continue;
        }
        reminders[reminder.id] = reminder;
      } catch (_) {}
    }
    return reminders;
  }

  static List<Map<String, dynamic>> _encodePrivateMessageReminders(
    Map<String, MessageReminder> reminders,
  ) => reminders.values
      .where(
        (reminder) =>
            reminder.id.isNotEmpty &&
            reminder.conversationId.isNotEmpty &&
            reminder.messageId.isNotEmpty,
      )
      .map((reminder) => reminder.toJson())
      .toList();

  Future<void> _removeLegacyLocalStatePlaintext() async {
    final prefs = _prefs;
    if (prefs == null) return;
    await prefs.remove(_kConversationNotificationPreferences);
    await prefs.remove(_kMutedConversations);
    await prefs.remove(_kNotificationCurrentUser);
    await prefs.remove(_kPushEnabled);
    await prefs.remove(_kWsBgEnabled);
    await prefs.remove(_kNotifSensitive);
    await prefs.remove(_kPinnedConversations);
    await prefs.remove(_kArchivedConversations);
    await _removeKeysWithPrefix(_kDraftPrefix);
    await _removeKeysWithPrefix(_kPinnedChannelMessagesPrefix);
  }

  Future<void> _removeKeysWithPrefix(String prefix) async {
    final prefs = _prefs;
    if (prefs == null) return;
    final keys = prefs
        .getKeys()
        .where((key) => key.startsWith(prefix))
        .toList();
    for (final key in keys) {
      await prefs.remove(key);
    }
  }
}
