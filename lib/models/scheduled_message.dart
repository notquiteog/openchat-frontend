import 'dart:convert';

import 'message.dart';

class ScheduledMessage {
  final String id;
  final String conversationId;
  final String senderId;
  final bool sealedSender;
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
  final String? controlToken;
  final String? decryptedContent;
  final bool decryptionFailed;

  const ScheduledMessage({
    required this.id,
    required this.conversationId,
    required this.senderId,
    this.sealedSender = false,
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
    this.controlToken,
    this.decryptedContent,
    this.decryptionFailed = false,
  });

  factory ScheduledMessage.fromJson(Map<String, dynamic> json) {
    return ScheduledMessage(
      id: json['id'] as String,
      conversationId: json['conversation_id'] as String,
      senderId: json['sender_id'] as String? ?? '',
      sealedSender: json['sealed_sender'] as bool? ?? false,
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
      controlToken: json['control_token'] as String?,
    );
  }

  ScheduledMessage copyWith({
    DateTime? scheduledFor,
    String? controlToken,
    String? decryptedContent,
    bool? decryptionFailed,
  }) {
    return ScheduledMessage(
      id: id,
      conversationId: conversationId,
      senderId: senderId,
      sealedSender: sealedSender,
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
      controlToken: controlToken ?? this.controlToken,
      decryptedContent: decryptedContent ?? this.decryptedContent,
      decryptionFailed: decryptionFailed ?? this.decryptionFailed,
    );
  }

  String get previewText {
    final raw = decryptedContent?.trim();
    if (raw != null && raw.isNotEmpty) {
      final unwrapped = _tryParseOpenChatMessage(raw);
      final preview = _previewFromDecrypted(
        unwrapped?.payload ?? raw,
        unwrapped?.type,
      ).trim();
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
      MessageType.game => 'Game',
      MessageType.checklist => 'Checklist',
      MessageType.invoice => 'Invoice',
      MessageType.paymentRequest => 'Payment request',
      MessageType.paymentTransfer => 'Payment transfer',
      MessageType.system => 'System message',
    };
  }

  String _previewFromDecrypted(String raw, String? wrappedType) {
    final effectiveType = wrappedType == null ? type : _parseType(wrappedType);
    if (effectiveType == MessageType.location) {
      final location = MessageLocation.tryParse(raw);
      if (location != null) return location.previewLabel;
    }

    final content = MessageContent.parse(raw, effectiveType);
    final text = content.text.trim();
    if (text.isNotEmpty) return text;

    final fileName = content.fileName?.trim();
    if (fileName != null && fileName.isNotEmpty) {
      return '$typeLabel: $fileName';
    }

    return '';
  }

  _ScheduledOpenChatPayload? _tryParseOpenChatMessage(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['openchat_message'] != 1) return null;
      final type = decoded['type'];
      if (type is! String) return null;
      final payloadRaw = decoded['payload'];
      // payload may arrive as a pre-serialized JSON string or as a nested
      // object (rich content types). Normalise to a string either way.
      final payload = payloadRaw is String
          ? payloadRaw
          : payloadRaw != null
          ? jsonEncode(payloadRaw)
          : '';
      return _ScheduledOpenChatPayload(type: type, payload: payload);
    } catch (_) {
      return null;
    }
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

class _ScheduledOpenChatPayload {
  final String type;
  final String payload;

  const _ScheduledOpenChatPayload({required this.type, required this.payload});
}
