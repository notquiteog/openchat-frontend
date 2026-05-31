import 'dart:convert';
import 'user.dart';

enum MessageType { text, sticker, file, image, video, system }

/// Parsed content for media messages. Text messages just use [text] directly.
class MessageContent {
  final String text;
  final String? attachmentId;
  final String? fileName;
  final int? fileSize;
  final String? mimeType;
  // AES-256-GCM key/nonce — included only inside the PGP-encrypted payload,
  // never stored on the server or exposed in plaintext.
  final String? fileKey;
  final String? fileNonce;

  const MessageContent({
    required this.text,
    this.attachmentId,
    this.fileName,
    this.fileSize,
    this.mimeType,
    this.fileKey,
    this.fileNonce,
  });

  bool get hasAttachment => attachmentId != null;

  factory MessageContent.text(String content) => MessageContent(text: content);

  factory MessageContent.fromJson(Map<String, dynamic> json) => MessageContent(
        text: json['text'] as String? ?? '',
        attachmentId: json['attachment_id'] as String?,
        fileName: json['file_name'] as String?,
        fileSize: json['file_size'] as int?,
        mimeType: json['mime_type'] as String?,
        fileKey: json['file_key'] as String?,
        fileNonce: json['file_nonce'] as String?,
      );

  /// Parses a decrypted payload string — falls back to plain text if not JSON.
  static MessageContent parse(String raw, MessageType type) {
    if (type == MessageType.text || type == MessageType.sticker || type == MessageType.system) {
      return MessageContent.text(raw);
    }
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return MessageContent.fromJson(json);
    } catch (_) {
      return MessageContent.text(raw);
    }
  }

  Map<String, dynamic> toJson() => {
        'text': text,
        if (attachmentId != null) 'attachment_id': attachmentId,
        if (fileName != null) 'file_name': fileName,
        if (fileSize != null) 'file_size': fileSize,
        if (mimeType != null) 'mime_type': mimeType,
        if (fileKey != null) 'file_key': fileKey,
        if (fileNonce != null) 'file_nonce': fileNonce,
      };
}

/// Outcome of a call, surfaced in a DM as a deletable `system` message.
/// Encoded as JSON inside the (E2E-encrypted) payload by the caller's client
/// when a call ends — see [ChatProvider.postCallEvent].
enum CallOutcome { missed, answered }

class CallEventInfo {
  final CallOutcome outcome;
  final bool isVideo;

  /// Conversation duration in seconds (only meaningful for [CallOutcome.answered]).
  final int durationSecs;

  const CallEventInfo({
    required this.outcome,
    required this.isVideo,
    this.durationSecs = 0,
  });

  /// Parses a decrypted `system` payload. Returns null if it isn't a call event.
  static CallEventInfo? tryParse(String raw) {
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final ev = json['call_event'] as String?;
      if (ev == null) return null;
      return CallEventInfo(
        outcome: ev == 'answered' ? CallOutcome.answered : CallOutcome.missed,
        isVideo: json['video'] as bool? ?? false,
        durationSecs: json['duration'] as int? ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  String get _durationLabel {
    final m = durationSecs ~/ 60;
    final s = durationSecs % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// Human-readable label, e.g. "Missed video call" or "Call · 2:05".
  String get label {
    final kind = isVideo ? 'video call' : 'voice call';
    return switch (outcome) {
      CallOutcome.missed => 'Missed $kind',
      CallOutcome.answered =>
        durationSecs > 0 ? 'Call ended · $_durationLabel' : 'Call ended',
    };
  }
}

class Message {
  final String id;
  final String conversationId;
  final String senderId;
  final MessageType type;
  /// PGP-armored ciphertext — decrypted client-side using the local private key.
  final String encryptedPayload;
  final String signature;
  final String? attachmentId;
  final String? replyTo;
  final DateTime createdAt;
  final DateTime? editedAt;
  // Not final: realtime new_message events arrive without sender details, so
  // ChatProvider backfills this from the loaded conversation members.
  User? sender;

  // Decrypted on client — never stored or sent to server
  MessageContent? _content;
  bool _decryptionFailed = false;

  Message({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.type,
    required this.encryptedPayload,
    required this.signature,
    this.attachmentId,
    this.replyTo,
    required this.createdAt,
    this.editedAt,
    this.sender,
  });

  factory Message.fromJson(Map<String, dynamic> json) => Message(
        id: json['id'] as String,
        conversationId: json['conversation_id'] as String,
        senderId: json['sender_id'] as String,
        type: _parseType(json['message_type'] as String? ?? 'text'),
        encryptedPayload: json['encrypted_payload'] as String,
        signature: json['signature'] as String? ?? '',
        attachmentId: json['attachment_id'] as String?,
        replyTo: json['reply_to'] as String?,
        createdAt: DateTime.parse(json['created_at'] as String),
        editedAt: json['edited_at'] != null
            ? DateTime.parse(json['edited_at'] as String)
            : null,
        sender: json['sender'] != null
            ? User.fromJson(json['sender'] as Map<String, dynamic>)
            : null,
      );

  void setDecryptedContent(String raw) {
    _content = MessageContent.parse(raw, type);
    _decryptionFailed = false;
  }

  void markDecryptionFailed() {
    _decryptionFailed = true;
  }

  MessageContent? get content => _content;
  bool get isDecrypted => _content != null;
  bool get decryptionFailed => _decryptionFailed;
  bool get isEdited => editedAt != null;

  /// Convenience: plain display text (for text/sticker) or caption.
  String? get decryptedContent => _content?.text;

  /// Parsed call event if this is a `system` call-outcome message, else null.
  CallEventInfo? get callEvent {
    if (type != MessageType.system || _content == null) return null;
    return CallEventInfo.tryParse(_content!.text);
  }

  /// One-line text for conversation list previews. Call events render as their
  /// label (e.g. "Missed voice call") rather than the raw JSON payload.
  String get listPreview {
    final ev = callEvent;
    if (ev != null) return ev.label;
    return isDecrypted ? (decryptedContent ?? '') : '🔒 Encrypted';
  }

  static MessageType _parseType(String t) => switch (t) {
        'sticker' => MessageType.sticker,
        'file' => MessageType.file,
        'image' => MessageType.image,
        'video' => MessageType.video,
        'system' => MessageType.system,
        _ => MessageType.text,
      };
}

/// Optimistic local message shown while the server confirms delivery.
class PendingMessage extends Message {
  final bool isSending;

  PendingMessage({
    required super.id,
    required super.conversationId,
    required super.senderId,
    required super.type,
    required super.encryptedPayload,
    required super.signature,
    super.attachmentId,
    super.replyTo,
    required super.createdAt,
    required String plaintext,
    this.isSending = true,
  }) {
    setDecryptedContent(plaintext);
  }
}
