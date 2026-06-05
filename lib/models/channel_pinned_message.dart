import 'message.dart';

class ChannelPinnedMessage {
  final String conversationId;
  final String messageId;
  final String? pinnedBy;
  final String preview;
  final DateTime messageCreatedAt;
  final DateTime pinnedAt;
  final String? senderUsername;
  final Message? message;

  const ChannelPinnedMessage({
    this.conversationId = '',
    required this.messageId,
    this.pinnedBy,
    required this.preview,
    required this.messageCreatedAt,
    required this.pinnedAt,
    this.senderUsername,
    this.message,
  });

  ChannelPinnedMessage copyWith({
    String? conversationId,
    String? messageId,
    String? pinnedBy,
    String? preview,
    DateTime? messageCreatedAt,
    DateTime? pinnedAt,
    String? senderUsername,
    Message? message,
  }) => ChannelPinnedMessage(
    conversationId: conversationId ?? this.conversationId,
    messageId: messageId ?? this.messageId,
    pinnedBy: pinnedBy ?? this.pinnedBy,
    preview: preview ?? this.preview,
    messageCreatedAt: messageCreatedAt ?? this.messageCreatedAt,
    pinnedAt: pinnedAt ?? this.pinnedAt,
    senderUsername: senderUsername ?? this.senderUsername,
    message: message ?? this.message,
  );

  Map<String, dynamic> toJson() => {
    if (conversationId.isNotEmpty) 'conversation_id': conversationId,
    'message_id': messageId,
    if (pinnedBy != null) 'pinned_by': pinnedBy,
    'preview': preview,
    'message_created_at_ms': messageCreatedAt.toUtc().millisecondsSinceEpoch,
    'pinned_at_ms': pinnedAt.toUtc().millisecondsSinceEpoch,
    if (senderUsername != null) 'sender_username': senderUsername,
  };

  factory ChannelPinnedMessage.fromJson(Map<String, dynamic> json) {
    final rawMessage = json['message'];
    final message = rawMessage is Map<String, dynamic>
        ? Message.fromJson(rawMessage)
        : null;
    final messageCreatedAt =
        _parseDate(json['message_created_at_ms']) ??
        _parseDate(json['message_created_at']) ??
        message?.createdAt ??
        DateTime.fromMillisecondsSinceEpoch(0);
    final pinnedAt =
        _parseDate(json['pinned_at_ms']) ??
        _parseDate(json['pinned_at']) ??
        DateTime.fromMillisecondsSinceEpoch(0);

    return ChannelPinnedMessage(
      conversationId: json['conversation_id'] as String? ?? '',
      messageId: json['message_id'] as String? ?? message?.id ?? '',
      pinnedBy: json['pinned_by'] as String?,
      preview: json['preview'] as String? ?? '',
      messageCreatedAt: messageCreatedAt,
      pinnedAt: pinnedAt,
      senderUsername:
          json['sender_username'] as String? ?? message?.sender?.username,
      message: message,
    );
  }

  static DateTime? _parseDate(Object? raw) {
    if (raw is int) {
      return DateTime.fromMillisecondsSinceEpoch(raw, isUtc: true).toLocal();
    }
    if (raw is num) {
      return DateTime.fromMillisecondsSinceEpoch(
        raw.round(),
        isUtc: true,
      ).toLocal();
    }
    if (raw is String && raw.isNotEmpty) {
      return DateTime.tryParse(raw)?.toLocal();
    }
    return null;
  }
}
