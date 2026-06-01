import 'dart:convert';

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
    );
  } catch (_) {
    return null;
  }
}

NotificationIntent? notificationIntentFromEvent({
  required String type,
  required Map<String, dynamic> data,
  required bool showSensitive,
}) {
  if (type == 'new_message') {
    final convId = data['conversation_id'] as String? ?? 'msg';
    final sender = data['sender_username'] as String?;
    return NotificationIntent(
      kind: NotificationIntentKind.message,
      notificationId: convId.hashCode,
      title: showSensitive && sender != null ? '@$sender' : 'OpenChat',
      body: showSensitive ? 'New message' : 'You have a new message',
    );
  }

  if (type == 'call_offer' || type == 'incoming_call') {
    final caller = data['caller_username'] as String?;
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
