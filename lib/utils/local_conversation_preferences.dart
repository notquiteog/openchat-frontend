import 'dart:convert';

const mutedConversationsPreferenceKey = 'muted_conversations';
const conversationNotificationPreferencesPreferenceKey =
    'conversation_notification_preferences_v1';
const notificationCurrentUserPreferenceKey = 'notification_current_user_id';

enum ConversationNotificationMode { all, muted, mentionsOnly }

class ConversationNotificationPreference {
  final ConversationNotificationMode mode;
  final DateTime? mutedUntil;

  const ConversationNotificationPreference({
    this.mode = ConversationNotificationMode.all,
    this.mutedUntil,
  });

  const ConversationNotificationPreference.all()
    : mode = ConversationNotificationMode.all,
      mutedUntil = null;

  const ConversationNotificationPreference.mutedForever()
    : mode = ConversationNotificationMode.muted,
      mutedUntil = null;

  const ConversationNotificationPreference.mentionsOnly()
    : mode = ConversationNotificationMode.mentionsOnly,
      mutedUntil = null;

  bool isMutedAt(DateTime now) =>
      mode == ConversationNotificationMode.muted &&
      (mutedUntil == null || mutedUntil!.isAfter(now));

  bool isExpiredAt(DateTime now) =>
      mode == ConversationNotificationMode.muted &&
      mutedUntil != null &&
      !mutedUntil!.isAfter(now);

  bool get isDefault => mode == ConversationNotificationMode.all;

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    if (mutedUntil != null)
      'muted_until_ms': mutedUntil!.toUtc().millisecondsSinceEpoch,
  };

  factory ConversationNotificationPreference.fromJson(
    Map<String, dynamic> json,
  ) {
    final modeName = json['mode'] as String?;
    final mode = ConversationNotificationMode.values.firstWhere(
      (value) => value.name == modeName,
      orElse: () => ConversationNotificationMode.all,
    );
    final mutedUntilMs = json['muted_until_ms'] as int?;
    return ConversationNotificationPreference(
      mode: mode,
      mutedUntil: mutedUntilMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              mutedUntilMs,
              isUtc: true,
            ).toLocal(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConversationNotificationPreference &&
          other.mode == mode &&
          other.mutedUntil == mutedUntil;

  @override
  int get hashCode => Object.hash(mode, mutedUntil);
}

Map<String, ConversationNotificationPreference>
decodeConversationNotificationPreferences(String? raw) {
  if (raw == null || raw.isEmpty) return const {};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return const {};
    final out = <String, ConversationNotificationPreference>{};
    for (final entry in decoded.entries) {
      if (entry.value is! Map<String, dynamic>) continue;
      final pref = ConversationNotificationPreference.fromJson(
        entry.value as Map<String, dynamic>,
      );
      if (!pref.isDefault) out[entry.key] = pref;
    }
    return out;
  } catch (_) {
    return const {};
  }
}

String encodeConversationNotificationPreferences(
  Map<String, ConversationNotificationPreference> preferences,
) {
  final normalized = <String, Map<String, dynamic>>{};
  for (final entry in preferences.entries) {
    if (entry.value.isDefault) continue;
    normalized[entry.key] = entry.value.toJson();
  }
  return jsonEncode(normalized);
}

Set<String> activeMutedConversationIds(
  Map<String, ConversationNotificationPreference> preferences, {
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  return preferences.entries
      .where((entry) => entry.value.isMutedAt(at))
      .map((entry) => entry.key)
      .toSet();
}

bool shouldNotifyForConversation({
  required String conversationId,
  required Map<String, ConversationNotificationPreference> preferences,
  required String currentUserId,
  Iterable<String> mentionedUserIds = const [],
  bool mentionedForCurrentUser = false,
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  final preference =
      preferences[conversationId] ??
      const ConversationNotificationPreference.all();
  if (preference.isMutedAt(at)) return false;
  if (preference.mode != ConversationNotificationMode.mentionsOnly) {
    return true;
  }
  if (mentionedForCurrentUser) return true;
  if (currentUserId.isEmpty) return false;
  return mentionedUserIds.contains(currentUserId);
}

Set<String> mentionedUserIdsFromNotificationData(Map<String, dynamic> data) {
  final out = <String>{};
  void addString(String value) {
    final trimmed = value.trim();
    if (trimmed.isNotEmpty) out.add(trimmed);
  }

  final single = data['mentioned_user_id'];
  if (single is String) addString(single);

  final raw = data['mentioned_user_ids'];
  if (raw is List) {
    for (final value in raw) {
      if (value is String) addString(value);
    }
  } else if (raw is String) {
    final trimmed = raw.trim();
    if (trimmed.startsWith('[')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is List) {
          for (final value in decoded) {
            if (value is String) addString(value);
          }
        }
      } catch (_) {}
    } else {
      for (final value in trimmed.split(',')) {
        addString(value);
      }
    }
  }
  return out;
}

bool notificationDataMentionsCurrentUser(
  Map<String, dynamic> data,
  String currentUserId,
) {
  final mentioned = data['mentioned'];
  if (mentioned == true) return true;
  if (mentioned is String &&
      (mentioned == 'true' || mentioned == '1' || mentioned == currentUserId)) {
    return true;
  }
  if (currentUserId.isEmpty) return false;
  return mentionedUserIdsFromNotificationData(data).contains(currentUserId);
}
