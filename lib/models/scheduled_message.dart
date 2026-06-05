import 'message.dart';

class ScheduledMessage {
  final String id;
  final String conversationId;
  final String senderId;
  final MessageType type;
  final String encryptedPayload;
  final String signature;
  final String? attachmentId;
  final String? replyTo;
  final String? topicId;
  final bool silent;
  final DateTime scheduledFor;
  final DateTime createdAt;
  final DateTime? sentAt;
  final DateTime? canceledAt;
  final List<String> mentionedUserIds;
  final String? decryptedContent;
  final bool decryptionFailed;

  const ScheduledMessage({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.type,
    required this.encryptedPayload,
    required this.signature,
    this.attachmentId,
    this.replyTo,
    this.topicId,
    this.silent = false,
    required this.scheduledFor,
    required this.createdAt,
    this.sentAt,
    this.canceledAt,
    this.mentionedUserIds = const [],
    this.decryptedContent,
    this.decryptionFailed = false,
  });

  factory ScheduledMessage.fromJson(Map<String, dynamic> json) {
    return ScheduledMessage(
      id: json['id'] as String,
      conversationId: json['conversation_id'] as String,
      senderId: json['sender_id'] as String,
      type: _parseType(json['message_type'] as String? ?? 'text'),
      encryptedPayload: json['encrypted_payload'] as String? ?? '',
      signature: json['signature'] as String? ?? '',
      attachmentId: json['attachment_id'] as String?,
      replyTo: json['reply_to'] as String?,
      topicId: json['topic_id'] as String?,
      silent: json['silent'] as bool? ?? false,
      scheduledFor: DateTime.parse(json['scheduled_for'] as String),
      createdAt: DateTime.parse(json['created_at'] as String),
      sentAt: _parseOptionalDate(json['sent_at']),
      canceledAt: _parseOptionalDate(json['canceled_at']),
      mentionedUserIds: (json['mentioned_user_ids'] as List? ?? const [])
          .map((value) => value.toString())
          .toList(),
    );
  }

  ScheduledMessage copyWith({
    DateTime? scheduledFor,
    String? decryptedContent,
    bool? decryptionFailed,
  }) {
    return ScheduledMessage(
      id: id,
      conversationId: conversationId,
      senderId: senderId,
      type: type,
      encryptedPayload: encryptedPayload,
      signature: signature,
      attachmentId: attachmentId,
      replyTo: replyTo,
      topicId: topicId,
      silent: silent,
      scheduledFor: scheduledFor ?? this.scheduledFor,
      createdAt: createdAt,
      sentAt: sentAt,
      canceledAt: canceledAt,
      mentionedUserIds: mentionedUserIds,
      decryptedContent: decryptedContent ?? this.decryptedContent,
      decryptionFailed: decryptionFailed ?? this.decryptionFailed,
    );
  }

  String get previewText {
    final raw = decryptedContent?.trim();
    if (raw != null && raw.isNotEmpty) {
      final preview = _previewFromDecrypted(raw).trim();
      if (preview.isNotEmpty) return preview;
    }
    return typeLabel;
  }

  String get typeLabel {
    return switch (type) {
      MessageType.text => 'Message',
      MessageType.sticker => 'Sticker',
      MessageType.file => 'File',
      MessageType.image => 'Photo',
      MessageType.video => 'Video',
      MessageType.voice => 'Voice message',
      MessageType.audio => 'Audio',
      MessageType.animation => 'Animation',
      MessageType.videoNote => 'Video note',
      MessageType.livePhoto => 'Live photo',
      MessageType.poll => 'Poll',
      MessageType.location => 'Location',
      MessageType.venue => 'Venue',
      MessageType.contact => 'Contact',
      MessageType.dice => 'Dice',
      MessageType.checklist => 'Checklist',
      MessageType.invoice => 'Invoice',
      MessageType.paymentRequest => 'Payment request',
      MessageType.paymentTransfer => 'Payment transfer',
      MessageType.system => 'System message',
    };
  }

  String _previewFromDecrypted(String raw) {
    if (type == MessageType.location) {
      final location = MessageLocation.tryParse(raw);
      if (location != null) return location.previewLabel;
    }

    final content = MessageContent.parse(raw, type);
    final text = content.text.trim();
    if (text.isNotEmpty) return text;

    final fileName = content.fileName?.trim();
    if (fileName != null && fileName.isNotEmpty) {
      return '$typeLabel: $fileName';
    }

    return '';
  }

  static DateTime? _parseOptionalDate(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  static MessageType _parseType(String value) {
    return switch (value) {
      'sticker' => MessageType.sticker,
      'file' => MessageType.file,
      'image' => MessageType.image,
      'video' => MessageType.video,
      'voice' => MessageType.voice,
      'audio' => MessageType.audio,
      'animation' => MessageType.animation,
      'video_note' => MessageType.videoNote,
      'live_photo' => MessageType.livePhoto,
      'poll' => MessageType.poll,
      'location' => MessageType.location,
      'venue' => MessageType.venue,
      'contact' => MessageType.contact,
      'dice' => MessageType.dice,
      'checklist' => MessageType.checklist,
      'invoice' => MessageType.invoice,
      'payment_request' => MessageType.paymentRequest,
      'payment_transfer' => MessageType.paymentTransfer,
      'system' => MessageType.system,
      _ => MessageType.text,
    };
  }
}
