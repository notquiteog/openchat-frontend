class MessageReminder {
  final String id;
  final String conversationId;
  final String messageId;
  final String conversationTitle;
  final String messagePreview;
  final DateTime remindAt;
  final DateTime createdAt;

  const MessageReminder({
    required this.id,
    required this.conversationId,
    required this.messageId,
    required this.conversationTitle,
    required this.messagePreview,
    required this.remindAt,
    required this.createdAt,
  });

  bool get isDue => !DateTime.now().isBefore(remindAt);

  factory MessageReminder.fromJson(Map<String, dynamic> json) {
    return MessageReminder(
      id: json['id'] as String? ?? '',
      conversationId: json['conversation_id'] as String? ?? '',
      messageId: json['message_id'] as String? ?? '',
      conversationTitle: json['conversation_title'] as String? ?? '',
      messagePreview: json['message_preview'] as String? ?? '',
      remindAt:
          _parseDate(json['remind_at']) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      createdAt: _parseDate(json['created_at']) ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'conversation_id': conversationId,
    'message_id': messageId,
    'conversation_title': conversationTitle,
    'message_preview': messagePreview,
    'remind_at': remindAt.toUtc().toIso8601String(),
    'created_at': createdAt.toUtc().toIso8601String(),
  };

  static DateTime? _parseDate(Object? raw) {
    if (raw is String && raw.isNotEmpty) {
      return DateTime.tryParse(raw)?.toLocal();
    }
    return null;
  }
}
