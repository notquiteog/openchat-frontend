/// A named thread ("topic") within a group or channel conversation. Mirrors the
/// backend models.ConversationTopic. Messages are associated with a topic via
/// [Message.effectiveTopicId] (the plaintext `topic_id` column, or the encrypted
/// artifact metadata for E2EE conversations).
class ConversationTopic {
  final String id;
  final String conversationId;
  final String name;
  final String? iconColor;
  final String createdBy;
  final DateTime? closedAt;
  final DateTime createdAt;

  const ConversationTopic({
    required this.id,
    required this.conversationId,
    required this.name,
    this.iconColor,
    required this.createdBy,
    this.closedAt,
    required this.createdAt,
  });

  bool get isClosed => closedAt != null;

  ConversationTopic copyWith({
    String? name,
    String? iconColor,
    DateTime? closedAt,
    bool clearClosedAt = false,
  }) {
    return ConversationTopic(
      id: id,
      conversationId: conversationId,
      name: name ?? this.name,
      iconColor: iconColor ?? this.iconColor,
      createdBy: createdBy,
      closedAt: clearClosedAt ? null : (closedAt ?? this.closedAt),
      createdAt: createdAt,
    );
  }

  factory ConversationTopic.fromJson(Map<String, dynamic> json) {
    return ConversationTopic(
      id: json['id'] as String,
      conversationId: json['conversation_id'] as String,
      name: json['name'] as String? ?? '',
      iconColor: json['icon_color'] as String?,
      createdBy: json['created_by'] as String? ?? '',
      closedAt: json['closed_at'] != null
          ? DateTime.parse(json['closed_at'] as String)
          : null,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}
