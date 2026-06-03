import 'dart:convert';
import 'user.dart';

enum MessageType {
  text,
  sticker,
  file,
  image,
  video,
  voice,
  audio,
  animation,
  videoNote,
  livePhoto,
  poll,
  location,
  venue,
  contact,
  dice,
  system,
}

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
    if (type == MessageType.text ||
        type == MessageType.sticker ||
        type == MessageType.system) {
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
  final bool isEncrypted;
  final int autoDeleteSeconds;
  final DateTime? autoDeleteExpiresAt;
  final String? attachmentId;
  final String? replyTo;
  final String? topicId;
  final bool silent;
  final List<MessageReactionSummary> reactions;
  final Poll? poll;
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
    this.isEncrypted = true,
    this.autoDeleteSeconds = 0,
    this.autoDeleteExpiresAt,
    this.attachmentId,
    this.replyTo,
    this.topicId,
    this.silent = false,
    this.reactions = const [],
    this.poll,
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
    isEncrypted: json['is_encrypted'] as bool? ?? true,
    autoDeleteSeconds: json['auto_delete_seconds'] as int? ?? 0,
    autoDeleteExpiresAt: json['auto_delete_expires_at'] != null
        ? DateTime.parse(json['auto_delete_expires_at'] as String)
        : null,
    attachmentId: json['attachment_id'] as String?,
    replyTo: json['reply_to'] as String?,
    topicId: json['topic_id'] as String?,
    silent: json['silent'] as bool? ?? false,
    reactions: (json['reactions'] as List? ?? [])
        .map((e) => MessageReactionSummary.fromJson(e as Map<String, dynamic>))
        .toList(),
    poll: json['poll'] != null
        ? Poll.fromJson(json['poll'] as Map<String, dynamic>)
        : null,
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
  bool get hasAutoDelete =>
      autoDeleteSeconds > 0 && autoDeleteExpiresAt != null;

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
    if (type == MessageType.poll && poll != null) {
      return 'Poll: ${poll!.question}';
    }
    final ev = callEvent;
    if (ev != null) return ev.label;
    return isDecrypted ? (decryptedContent ?? '') : '🔒 Encrypted';
  }

  static MessageType _parseType(String t) => switch (t) {
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
    'system' => MessageType.system,
    _ => MessageType.text,
  };

  Message copyWith({
    List<MessageReactionSummary>? reactions,
    Poll? poll,
    User? sender,
  }) {
    final msg = Message(
      id: id,
      conversationId: conversationId,
      senderId: senderId,
      type: type,
      encryptedPayload: encryptedPayload,
      signature: signature,
      isEncrypted: isEncrypted,
      autoDeleteSeconds: autoDeleteSeconds,
      autoDeleteExpiresAt: autoDeleteExpiresAt,
      attachmentId: attachmentId,
      replyTo: replyTo,
      topicId: topicId,
      silent: silent,
      reactions: reactions ?? this.reactions,
      poll: poll ?? this.poll,
      createdAt: createdAt,
      editedAt: editedAt,
      sender: sender ?? this.sender,
    );
    if (_content != null) msg._content = _content;
    msg._decryptionFailed = _decryptionFailed;
    return msg;
  }
}

class Poll {
  final String id;
  final String? messageId;
  final String question;
  final String? description;
  final String type;
  final bool isAnonymous;
  final bool allowsMultipleAnswers;
  final bool allowsRevoting;
  final bool isClosed;
  final int totalVoterCount;
  final List<PollOption> options;
  final List<String> voterOptionIds;

  const Poll({
    required this.id,
    this.messageId,
    required this.question,
    this.description,
    required this.type,
    required this.isAnonymous,
    required this.allowsMultipleAnswers,
    required this.allowsRevoting,
    required this.isClosed,
    required this.totalVoterCount,
    required this.options,
    this.voterOptionIds = const [],
  });

  factory Poll.fromJson(Map<String, dynamic> json) => Poll(
    id: json['id'] as String,
    messageId: json['message_id'] as String?,
    question: json['question'] as String? ?? '',
    description: json['description'] as String?,
    type: json['type'] as String? ?? 'regular',
    isAnonymous: json['is_anonymous'] as bool? ?? true,
    allowsMultipleAnswers: json['allows_multiple_answers'] as bool? ?? false,
    allowsRevoting: json['allows_revoting'] as bool? ?? false,
    isClosed: (json['is_closed'] as bool?) ?? json['closed_at'] != null,
    totalVoterCount: json['total_voter_count'] as int? ?? 0,
    options: (json['options'] as List? ?? [])
        .map((e) => PollOption.fromJson(e as Map<String, dynamic>))
        .toList(),
    voterOptionIds: (json['voter_option_ids'] as List? ?? [])
        .map((e) => e.toString())
        .toList(),
  );

  bool isSelected(String optionId) => voterOptionIds.contains(optionId);
}

class PollOption {
  final String id;
  final int index;
  final String text;
  final int voterCount;
  final String? persistentId;

  const PollOption({
    required this.id,
    required this.index,
    required this.text,
    required this.voterCount,
    this.persistentId,
  });

  factory PollOption.fromJson(Map<String, dynamic> json) => PollOption(
    id: json['id'] as String? ?? json['persistent_id'] as String? ?? '',
    index: json['option_index'] as int? ?? 0,
    text: json['text'] as String? ?? '',
    voterCount: json['voter_count'] as int? ?? 0,
    persistentId: json['persistent_id'] as String?,
  );
}

class MessageReactionSummary {
  final String emoji;
  final int count;

  const MessageReactionSummary({required this.emoji, required this.count});

  factory MessageReactionSummary.fromJson(Map<String, dynamic> json) =>
      MessageReactionSummary(
        emoji: json['emoji'] as String? ?? '',
        count: json['count'] as int? ?? 0,
      );
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
    super.isEncrypted,
    super.autoDeleteSeconds,
    super.autoDeleteExpiresAt,
    super.attachmentId,
    super.replyTo,
    super.topicId,
    super.silent,
    super.reactions,
    super.poll,
    required super.createdAt,
    required String plaintext,
    this.isSending = true,
  }) {
    setDecryptedContent(plaintext);
  }
}
