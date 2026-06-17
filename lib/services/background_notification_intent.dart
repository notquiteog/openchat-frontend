import 'dart:convert';

import '../utils/global_notification_pause.dart';
import '../utils/local_conversation_preferences.dart';

enum NotificationIntentKind { message, incomingCall }

/// Receiver-side controls for how much of an incoming message a notification
/// reveals. [showSender] reveals who/where a message is from (the DM sender, or
/// a group/channel name); [showPreview] reveals a snippet of the body. These
/// are independent privacy axes — any of the four combinations is valid.
class NotificationContentVisibility {
  final bool showSender;
  final bool showPreview;

  const NotificationContentVisibility({
    this.showSender = false,
    this.showPreview = false,
  });

  /// Reveal nothing — generic "OpenChat" / "New message". The safe default and
  /// the fallback whenever a preview can't be resolved.
  static const hidden = NotificationContentVisibility();

  @override
  bool operator ==(Object other) =>
      other is NotificationContentVisibility &&
      other.showSender == showSender &&
      other.showPreview == showPreview;

  @override
  int get hashCode => Object.hash(showSender, showPreview);
}

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
  required NotificationContentVisibility visibility,
  String? conversationTitle,
  String? previewText,
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
      visibility: visibility,
      conversationTitle: conversationTitle,
      previewText: previewText,
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
  required NotificationContentVisibility visibility,
  // Caller-resolved bits the background isolates can't derive from a sealed
  // event: [conversationTitle] is the group/channel display name (null/empty =>
  // a 1:1 DM); [previewText] is the locally-decrypted body snippet (null =>
  // unavailable, so the body stays generic regardless of [showPreview]).
  String? conversationTitle,
  String? previewText,
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
      title: _messageTitle(visibility, conversationTitle, sender),
      body: _messageBody(visibility, conversationTitle, sender, previewText),
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
    // The caller is identity, so it follows showSender (a preview snippet is
    // meaningless for a call).
    return NotificationIntent(
      kind: NotificationIntentKind.incomingCall,
      notificationId: 1,
      title: 'Incoming call',
      body: visibility.showSender && caller != null
          ? '@$caller is calling'
          : 'Incoming call',
    );
  }

  return null;
}

/// Title for a message notification: the conversation/sender identity when
/// [NotificationContentVisibility.showSender] is on, else generic "OpenChat".
String _messageTitle(
  NotificationContentVisibility visibility,
  String? conversationTitle,
  String? sender,
) {
  if (!visibility.showSender) return 'OpenChat';
  final groupName = conversationTitle?.trim();
  if (groupName != null && groupName.isNotEmpty) return groupName;
  if (sender != null && sender.isNotEmpty) return '@$sender';
  return 'OpenChat';
}

/// Body for a message notification: the decrypted snippet when
/// [NotificationContentVisibility.showPreview] is on AND a preview was
/// resolved, else generic "New message". Group/channel previews are prefixed
/// with the sender so the body reads "@alice: …".
String _messageBody(
  NotificationContentVisibility visibility,
  String? conversationTitle,
  String? sender,
  String? previewText,
) {
  if (!visibility.showPreview) return 'New message';
  final preview = previewText?.trim();
  if (preview == null || preview.isEmpty) return 'New message';
  final isGroupOrChannel = (conversationTitle?.trim().isNotEmpty ?? false);
  if (isGroupOrChannel && sender != null && sender.isNotEmpty) {
    return '@$sender: $preview';
  }
  return preview;
}

String? _stringOrNull(Object? value) {
  if (value is String && value.trim().isNotEmpty) return value.trim();
  return null;
}
