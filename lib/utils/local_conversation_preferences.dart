import 'dart:convert';

import 'mention_utils.dart';

const mutedConversationsPreferenceKey = 'muted_conversations';
const conversationNotificationPreferencesPreferenceKey =
    'conversation_notification_preferences_v1';

enum ConversationNotificationMode { all, muted, mentionsOnly }

class ConversationNotificationPreference {
  final ConversationNotificationMode mode;
  final DateTime? mutedUntil;
  final List<String> keywords;
  final bool priority;
  final int? quietHoursStartMinute;
  final int? quietHoursEndMinute;

  /// Per-chat notification sound id (see [messageNotificationSounds]). Null/empty
  /// uses the default sound.
  final String? customSoundId;

  const ConversationNotificationPreference({
    this.mode = ConversationNotificationMode.all,
    this.mutedUntil,
    this.keywords = const [],
    this.priority = false,
    this.quietHoursStartMinute,
    this.quietHoursEndMinute,
    this.customSoundId,
  });

  const ConversationNotificationPreference.all()
    : mode = ConversationNotificationMode.all,
      mutedUntil = null,
      keywords = const [],
      priority = false,
      quietHoursStartMinute = null,
      quietHoursEndMinute = null,
      customSoundId = null;

  const ConversationNotificationPreference.mutedForever()
    : mode = ConversationNotificationMode.muted,
      mutedUntil = null,
      keywords = const [],
      priority = false,
      quietHoursStartMinute = null,
      quietHoursEndMinute = null,
      customSoundId = null;

  const ConversationNotificationPreference.mentionsOnly()
    : mode = ConversationNotificationMode.mentionsOnly,
      mutedUntil = null,
      keywords = const [],
      priority = false,
      quietHoursStartMinute = null,
      quietHoursEndMinute = null,
      customSoundId = null;

  bool isMutedAt(DateTime now) =>
      mode == ConversationNotificationMode.muted &&
      (mutedUntil == null || mutedUntil!.isAfter(now));

  bool isExpiredAt(DateTime now) =>
      mode == ConversationNotificationMode.muted &&
      mutedUntil != null &&
      !mutedUntil!.isAfter(now);

  bool get hasQuietHours =>
      quietHoursStartMinute != null && quietHoursEndMinute != null;

  bool isQuietAt(DateTime now) {
    if (!hasQuietHours || priority) return false;
    final start = quietHoursStartMinute!;
    final end = quietHoursEndMinute!;
    if (start == end) return false;
    final minute = now.hour * 60 + now.minute;
    if (start < end) return minute >= start && minute < end;
    return minute >= start || minute < end;
  }

  bool keywordMatches(String text) {
    if (keywords.isEmpty || text.trim().isEmpty) return false;
    final lower = text.toLowerCase();
    return keywords.any((keyword) => lower.contains(keyword.toLowerCase()));
  }

  bool get isDefault =>
      mode == ConversationNotificationMode.all &&
      keywords.isEmpty &&
      !priority &&
      !hasQuietHours;

  ConversationNotificationPreference copyWith({
    ConversationNotificationMode? mode,
    DateTime? mutedUntil,
    bool clearMutedUntil = false,
    List<String>? keywords,
    bool? priority,
    int? quietHoursStartMinute,
    int? quietHoursEndMinute,
    bool clearQuietHours = false,
    String? customSoundId,
    bool clearCustomSound = false,
  }) {
    return ConversationNotificationPreference(
      mode: mode ?? this.mode,
      mutedUntil: clearMutedUntil ? null : mutedUntil ?? this.mutedUntil,
      keywords: keywords ?? this.keywords,
      priority: priority ?? this.priority,
      quietHoursStartMinute: clearQuietHours
          ? null
          : quietHoursStartMinute ?? this.quietHoursStartMinute,
      quietHoursEndMinute: clearQuietHours
          ? null
          : quietHoursEndMinute ?? this.quietHoursEndMinute,
      customSoundId: clearCustomSound
          ? null
          : customSoundId ?? this.customSoundId,
    );
  }

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    if (mutedUntil != null)
      'muted_until_ms': mutedUntil!.toUtc().millisecondsSinceEpoch,
    if (keywords.isNotEmpty) 'keywords': keywords,
    if (priority) 'priority': true,
    if (quietHoursStartMinute != null)
      'quiet_hours_start_minute': quietHoursStartMinute,
    if (quietHoursEndMinute != null)
      'quiet_hours_end_minute': quietHoursEndMinute,
    if (customSoundId != null && customSoundId!.isNotEmpty)
      'custom_sound_id': customSoundId,
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
    final rawKeywords = json['keywords'];
    final keywords = rawKeywords is List
        ? normalizeNotificationKeywords(rawKeywords.whereType<String>())
        : const <String>[];
    return ConversationNotificationPreference(
      mode: mode,
      mutedUntil: mutedUntilMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              mutedUntilMs,
              isUtc: true,
            ).toLocal(),
      keywords: keywords,
      priority: json['priority'] as bool? ?? false,
      quietHoursStartMinute: json['quiet_hours_start_minute'] as int?,
      quietHoursEndMinute: json['quiet_hours_end_minute'] as int?,
      customSoundId: json['custom_sound_id'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConversationNotificationPreference &&
          other.mode == mode &&
          other.mutedUntil == mutedUntil &&
          _sameKeywords(other.keywords, keywords) &&
          other.priority == priority &&
          other.quietHoursStartMinute == quietHoursStartMinute &&
          other.quietHoursEndMinute == quietHoursEndMinute &&
          other.customSoundId == customSoundId;

  @override
  int get hashCode => Object.hash(
    mode,
    mutedUntil,
    Object.hashAll(keywords),
    priority,
    quietHoursStartMinute,
    quietHoursEndMinute,
    customSoundId,
  );
}

/// Catalog of bundled per-chat notification sounds: id → display name. The id
/// 'default' uses the system default. Other ids map to:
///   * Android: a `messages_<id>` channel with raw resource `res/raw/<id>`,
///   * iOS/macOS: a bundled `<id>.caf` sound file.
/// NOTE: the actual audio asset files must be bundled per platform; until then
/// non-default selections fall back to the default sound at runtime.
const Map<String, String> messageNotificationSounds = {
  'default': 'Default',
  'chime': 'Chime',
  'bell': 'Bell',
  'pop': 'Pop',
  'pebble': 'Pebble',
};

String messageNotificationSoundLabel(String? id) =>
    messageNotificationSounds[id ?? 'default'] ?? 'Default';

List<String> normalizeNotificationKeywords(Iterable<String> raw) {
  final seen = <String>{};
  final out = <String>[];
  for (final value in raw) {
    final keyword = value.trim();
    if (keyword.isEmpty) continue;
    final key = keyword.toLowerCase();
    if (seen.add(key)) out.add(keyword);
  }
  return out;
}

bool _sameKeywords(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
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
  bool mentionedForCurrentUser = false,
  String notificationText = '',
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  final preference =
      preferences[conversationId] ??
      const ConversationNotificationPreference.all();
  final keywordMatch = preference.keywordMatches(notificationText);
  if (preference.isQuietAt(at) && !keywordMatch) return false;
  if (preference.isMutedAt(at)) return false;
  if (keywordMatch) return true;
  if (preference.mode != ConversationNotificationMode.mentionsOnly) {
    return true;
  }
  // @everyone / @all reach mentions-only members too (when decrypted text is
  // available — the server push itself is contentless by design).
  if (mentionedForCurrentUser || textMentionsBroadcast(notificationText)) {
    return true;
  }
  return false;
}

String notificationRuleTextFromData(Map<String, dynamic> data) {
  final parts = <String>[];
  for (final key in const [
    'sender_username',
    'title',
    'body',
    'message_text',
    'message_preview',
    'preview',
    'text',
  ]) {
    final value = data[key];
    if (value is String && value.trim().isNotEmpty) parts.add(value);
  }
  // The WS new_message payload nests the sender as sender:{username:…} — it
  // never carries a top-level sender_username.
  final nested = notificationSenderUsernameFromData(data);
  if (nested != null && !parts.contains(nested)) parts.add(nested);
  return parts.join(' ');
}

/// Extracts the sender's username from an event payload, handling both the
/// flat `sender_username` shape (push payloads) and the nested `sender:
/// {username: …}` shape used by WS `new_message` events.
String? notificationSenderUsernameFromData(Map<String, dynamic> data) {
  final direct = data['sender_username'];
  if (direct is String && direct.trim().isNotEmpty) return direct.trim();
  final sender = data['sender'];
  if (sender is Map) {
    final username = sender['username'];
    if (username is String && username.trim().isNotEmpty) {
      return username.trim();
    }
  }
  return null;
}
