import 'dart:convert';

import '../utils/global_notification_pause.dart';
import '../utils/local_conversation_preferences.dart';

enum NotificationIntentKind { message, incomingCall }

class NotificationIntent {
  final NotificationIntentKind kind;
  final int notificationId;
  final String title;
  final String body;

  const NotificationIntent({
    required this.kind,
    required this.notificationId,
    required this.title,
    required this.body,
  });
}

NotificationIntent? notificationIntentFromRawLine(
  String rawLine, {
  required bool showSensitive,
  Set<String> mutedConversationIds = const {},
  Map<String, ConversationNotificationPreference>
      conversationNotificationPreferences =
      const {},
  int? notificationsPausedUntilMs,
  int? globalQuietStartMinute,
  int? globalQuietEndMinute,
  bool pauseAllowsCalls = true,
}) {
  try {
    final json = jsonDecode(rawLine) as Map<String, dynamic>;
    final type = json['type'] as String?;
    final data = (json['data'] as Map<String, dynamic>?) ?? {};
    if (type == null) return null;
    return notificationIntentFromEvent(
      type: type,
      data: data,
      showSensitive: showSensitive,
      mutedConversationIds: mutedConversationIds,
      conversationNotificationPreferences: conversationNotificationPreferences,
      notificationsPausedUntilMs: notificationsPausedUntilMs,
      globalQuietStartMinute: globalQuietStartMinute,
      globalQuietEndMinute: globalQuietEndMinute,
      pauseAllowsCalls: pauseAllowsCalls,
    );
  } catch (_) {
    return null;
  }
}

NotificationIntent? notificationIntentFromEvent({
  required String type,
  required Map<String, dynamic> data,
  required bool showSensitive,
  Set<String> mutedConversationIds = const {},
  Map<String, ConversationNotificationPreference>
      conversationNotificationPreferences =
      const {},
  int? notificationsPausedUntilMs,
  int? globalQuietStartMinute,
  int? globalQuietEndMinute,
  bool pauseAllowsCalls = true,
}) {
  final preferences = <String, ConversationNotificationPreference>{
    ...conversationNotificationPreferences,
    for (final id in mutedConversationIds)
      if (!conversationNotificationPreferences.containsKey(id))
        id: const ConversationNotificationPreference.mutedForever(),
  };
  final globallyPaused = isGloballyPausedAt(
    DateTime.now(),
    pausedUntilMs: notificationsPausedUntilMs,
    quietStartMinute: globalQuietStartMinute,
    quietEndMinute: globalQuietEndMinute,
  );

  if (type == 'new_message') {
    if (globallyPaused) return null;
    final convId = data['conversation_id'] as String? ?? 'msg';
    if (!shouldNotifyForConversation(
      conversationId: convId,
      preferences: preferences,
      notificationText: notificationRuleTextFromData(data),
    )) {
      return null;
    }
    // WS events nest the sender (sender:{username:…}); push payloads (when
    // present at all) use the flat sender_username key.
    final sender = notificationSenderUsernameFromData(data);
    return NotificationIntent(
      kind: NotificationIntentKind.message,
      notificationId: convId.hashCode,
      title: showSensitive && sender != null ? '@$sender' : 'OpenChat',
      body: 'New message',
    );
  }

  if (type == 'join_request') {
    if (globallyPaused) return null;
    final convId = data['conversation_id'] as String? ?? 'join';
    if (!shouldNotifyForConversation(
      conversationId: convId,
      preferences: preferences,
    )) {
      return null;
    }
    return NotificationIntent(
      kind: NotificationIntentKind.message,
      notificationId: convId.hashCode,
      title: 'OpenChat',
      body: 'New join request',
    );
  }

  if (type == 'call_offer' || type == 'incoming_call') {
    if (globallyPaused && !pauseAllowsCalls) return null;
    // Calls respect mute / muted-until / quiet hours — previously every call
    // rang through regardless. Mentions-only mode deliberately does NOT
    // suppress calls (it is a message-volume control, not a call block).
    final convId = data['conversation_id'] as String?;
    if (convId != null && convId.isNotEmpty) {
      final pref = preferences[convId];
      final now = DateTime.now();
      if (pref != null && (pref.isMutedAt(now) || pref.isQuietAt(now))) {
        return null;
      }
    }
    final caller = _stringOrNull(data['caller_username']);
    return NotificationIntent(
      kind: NotificationIntentKind.incomingCall,
      notificationId: 1,
      title: 'Incoming call',
      body: showSensitive && caller != null
          ? '@$caller is calling'
          : 'Incoming call',
    );
  }

  return null;
}

String? _stringOrNull(Object? value) {
  if (value is String && value.trim().isNotEmpty) return value.trim();
  return null;
}
