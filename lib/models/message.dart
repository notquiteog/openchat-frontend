import 'dart:convert';
import 'link_preview.dart';
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
  game,
  checklist,
  invoice,
  paymentRequest,
  paymentTransfer,
  system,
}

enum LocationMessageKind { oneTime, live }

class MessageLocation {
  final LocationMessageKind kind;
  final double latitude;
  final double longitude;
  final double? accuracy;
  final String shareId;
  final DateTime? endsAt;
  final bool ended;

  const MessageLocation({
    required this.kind,
    required this.latitude,
    required this.longitude,
    required this.shareId,
    this.accuracy,
    this.endsAt,
    this.ended = false,
  });

  bool get isLive => kind == LocationMessageKind.live;
  bool get isActive =>
      isLive && !ended && endsAt != null && endsAt!.isAfter(DateTime.now());

  Duration? get _remaining {
    if (endsAt == null) return null;
    final diff = endsAt!.difference(DateTime.now());
    if (diff <= Duration.zero) return null;
    return diff;
  }

  String get remainingLabel {
    final remaining = _remaining;
    if (remaining == null) return '';
    if (remaining.inDays >= 1) {
      return '· ${remaining.inDays}d remaining';
    }
    if (remaining.inHours >= 1) {
      return '· ${remaining.inHours}h remaining';
    }
    if (remaining.inMinutes >= 1) {
      return '· ${remaining.inMinutes}m remaining';
    }
    return '· ${remaining.inSeconds}s remaining';
  }

  String get previewLabel {
    if (kind == LocationMessageKind.oneTime) return '📍 Location shared';
    if (ended) return '📍 Live location ended';
    if (isActive) return '📍 Live location $remainingLabel';
    return '📍 Live location';
  }

  String get copyLabel =>
      '${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}';

  String get mapUrl {
    final lat = latitude.toStringAsFixed(6);
    final lng = longitude.toStringAsFixed(6);
    return 'https://staticmap.openstreetmap.de/staticmap.php?center=$lat,$lng&zoom=15&size=640x360&markers=$lat,$lng,pin';
  }

  String get thumbnailUrl {
    final lat = latitude.toStringAsFixed(6);
    final lng = longitude.toStringAsFixed(6);
    return 'https://staticmap.openstreetmap.de/staticmap.php?center=$lat,$lng&zoom=14&size=560x260&markers=$lat,$lng,pin';
  }

  Map<String, dynamic> toJson() => {
    'kind': kind == LocationMessageKind.live ? 'live' : 'one_time',
    'latitude': latitude,
    'longitude': longitude,
    if (accuracy != null) 'accuracy': accuracy,
    'share_id': shareId,
    if (endsAt != null) 'ends_at': endsAt!.toUtc().toIso8601String(),
    'ended': ended,
  };

  MessageLocation copyWith({
    LocationMessageKind? kind,
    double? latitude,
    double? longitude,
    double? accuracy,
    String? shareId,
    DateTime? endsAt,
    bool? ended,
  }) => MessageLocation(
    kind: kind ?? this.kind,
    latitude: latitude ?? this.latitude,
    longitude: longitude ?? this.longitude,
    shareId: shareId ?? this.shareId,
    accuracy: accuracy ?? this.accuracy,
    endsAt: endsAt ?? this.endsAt,
    ended: ended ?? this.ended,
  );

  static MessageLocation? tryParse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return _fromMap(decoded);
    } catch (_) {
      return null;
    }
  }

  static MessageLocation? _fromMap(Map<String, dynamic> raw) {
    const allowedKeys = {
      'kind',
      'latitude',
      'longitude',
      'accuracy',
      'share_id',
      'ends_at',
      'ended',
    };
    if (raw.keys.any((key) => !allowedKeys.contains(key))) return null;

    final lat = _parseDouble(raw['latitude']);
    final lng = _parseDouble(raw['longitude']);
    if (lat == null || lng == null) return null;
    if (!lat.isFinite || !lng.isFinite || lat < -90 || lat > 90) return null;
    if (lng < -180 || lng > 180) return null;

    final kindRaw = raw['kind'];
    if (kindRaw is! String) return null;
    final kind = switch (kindRaw) {
      'live' => LocationMessageKind.live,
      'one_time' => LocationMessageKind.oneTime,
      _ => null,
    };
    if (kind == null) return null;

    final shareId = raw['share_id'];
    if (shareId is! String || shareId.trim().isEmpty) return null;

    final ended = raw['ended'];
    if (ended is! bool) return null;

    DateTime? endsAt;
    if (raw.containsKey('ends_at')) {
      final endsAtRaw = raw['ends_at'];
      if (endsAtRaw is! String) return null;
      endsAt = DateTime.tryParse(endsAtRaw);
      if (endsAt == null) return null;
    }
    if (kind == LocationMessageKind.live && endsAt == null) return null;

    double? accuracy;
    if (raw.containsKey('accuracy')) {
      accuracy = _parseDouble(raw['accuracy']);
      if (accuracy == null || !accuracy.isFinite || accuracy < 0) return null;
    }

    return MessageLocation(
      kind: kind,
      latitude: lat,
      longitude: lng,
      shareId: shareId,
      accuracy: accuracy,
      endsAt: endsAt,
      ended: ended,
    );
  }

  static double? _parseDouble(Object? value) {
    if (value is num) return value.toDouble();
    return null;
  }
}

class CustomEmojiEntity {
  final String type;
  final int offset;
  final int length;
  final String customEmojiId;
  final String emoji;
  final String? fileUrl;
  final bool isAnimated;

  const CustomEmojiEntity({
    this.type = 'custom_emoji',
    required this.offset,
    required this.length,
    required this.customEmojiId,
    required this.emoji,
    this.fileUrl,
    this.isAnimated = false,
  });

  factory CustomEmojiEntity.fromJson(Map<String, dynamic> json) {
    final id =
        json['custom_emoji_id'] as String? ??
        json['customEmojiId'] as String? ??
        '';
    final emoji = json['emoji'] as String? ?? '';
    return CustomEmojiEntity(
      type: json['type'] as String? ?? 'custom_emoji',
      offset: MessageContent._parseInt(json['offset']) ?? 0,
      length: MessageContent._parseInt(json['length']) ?? emoji.length,
      customEmojiId: id,
      emoji: emoji,
      fileUrl: json['file_url'] as String?,
      isAnimated: json['is_animated'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'type': type,
    'offset': offset,
    'length': length,
    'custom_emoji_id': customEmojiId,
    'emoji': emoji,
    if (fileUrl != null) 'file_url': fileUrl,
    if (isAnimated) 'is_animated': true,
  };

  CustomEmojiEntity copyWith({int? offset, int? length}) => CustomEmojiEntity(
    type: type,
    offset: offset ?? this.offset,
    length: length ?? this.length,
    customEmojiId: customEmojiId,
    emoji: emoji,
    fileUrl: fileUrl,
    isAnimated: isAnimated,
  );
}

class BotInlineKeyboardButton {
  final String text;
  final String? url;
  final String? callbackData;

  const BotInlineKeyboardButton({
    required this.text,
    this.url,
    this.callbackData,
  });

  bool get isUsable =>
      text.trim().isNotEmpty &&
      ((url?.trim().isNotEmpty ?? false) ||
          (callbackData?.trim().isNotEmpty ?? false));

  factory BotInlineKeyboardButton.fromJson(Map<String, dynamic> json) =>
      BotInlineKeyboardButton(
        text: json['text']?.toString() ?? '',
        url: json['url']?.toString(),
        callbackData: json['callback_data']?.toString(),
      );

  Map<String, dynamic> toJson() => {
    'text': text,
    if (url != null) 'url': url,
    if (callbackData != null) 'callback_data': callbackData,
  };
}

class BotInlineKeyboardMarkup {
  final List<List<BotInlineKeyboardButton>> rows;

  const BotInlineKeyboardMarkup({required this.rows});

  bool get isNotEmpty => rows.any((row) => row.isNotEmpty);

  factory BotInlineKeyboardMarkup.fromJson(Map<String, dynamic> json) {
    final rawRows = json['inline_keyboard'];
    if (rawRows is! List) return const BotInlineKeyboardMarkup(rows: []);
    final rows = <List<BotInlineKeyboardButton>>[];
    for (final rawRow in rawRows.whereType<List>()) {
      final row = rawRow
          .whereType<Map>()
          .map(
            (item) => BotInlineKeyboardButton.fromJson(
              Map<String, dynamic>.from(item),
            ),
          )
          .where((button) => button.isUsable)
          .toList(growable: false);
      if (row.isNotEmpty) rows.add(row);
    }
    return BotInlineKeyboardMarkup(rows: rows);
  }

  static BotInlineKeyboardMarkup? tryParse(Object? raw) {
    if (raw is Map<String, dynamic>) {
      final markup = BotInlineKeyboardMarkup.fromJson(raw);
      return markup.isNotEmpty ? markup : null;
    }
    if (raw is Map) {
      final markup = BotInlineKeyboardMarkup.fromJson(
        raw.map((key, value) => MapEntry(key.toString(), value)),
      );
      return markup.isNotEmpty ? markup : null;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'inline_keyboard': rows
        .map((row) => row.map((button) => button.toJson()).toList())
        .toList(),
  };
}

/// Parsed content for media messages. Text messages just use [text] directly.
/// A shared contact card (`MessageType.contact`) — identity + PGP key so the
/// recipient can add and verify the person without a server intermediary.
class MessageContact {
  final String? userId;
  final String username;
  final String? displayName;
  final String? publicKey;
  final String? fingerprint;

  const MessageContact({
    this.userId,
    required this.username,
    this.displayName,
    this.publicKey,
    this.fingerprint,
  });

  factory MessageContact.fromJson(Map<String, dynamic> json) => MessageContact(
    userId: json['user_id'] as String?,
    username: json['username'] as String? ?? '',
    displayName: json['display_name'] as String?,
    publicKey: json['public_key'] as String?,
    fingerprint: json['fingerprint'] as String?,
  );

  Map<String, dynamic> toJson() => {
    if (userId != null) 'user_id': userId,
    'username': username,
    if (displayName != null) 'display_name': displayName,
    if (publicKey != null) 'public_key': publicKey,
    if (fingerprint != null) 'fingerprint': fingerprint,
  };

  String get displayLabel =>
      (displayName != null && displayName!.isNotEmpty) ? displayName! : username;
}

class MessageContent {
  final String text;
  final List<CustomEmojiEntity> entities;
  final String? attachmentId;
  final String? fileName;
  final int? fileSize;
  final String? mimeType;
  final int? durationMs;
  final LinkPreview? linkPreview;
  final bool viewOnce;
  // Tap-to-reveal: media is rendered blurred until the viewer taps it.
  final bool hasSpoiler;
  // Don't generate/fetch a link preview for URLs in this message (privacy).
  final bool suppressLinkPreview;
  // Voice-note amplitude samples (0..1), rendered as the playback waveform.
  final List<double>? waveform;
  final BotInlineKeyboardMarkup? replyMarkup;
  // Shared contact card (MessageType.contact).
  final MessageContact? contact;
  // "Forwarded from @username" attribution (null for anonymous forwards).
  final String? forwardedFrom;
  // AES-256-GCM key/nonce — included only inside the PGP-encrypted payload,
  // never stored on the server or exposed in plaintext.
  final String? fileKey;
  final String? fileNonce;

  const MessageContent({
    required this.text,
    this.entities = const [],
    this.attachmentId,
    this.fileName,
    this.fileSize,
    this.mimeType,
    this.durationMs,
    this.linkPreview,
    this.viewOnce = false,
    this.hasSpoiler = false,
    this.suppressLinkPreview = false,
    this.waveform,
    this.replyMarkup,
    this.contact,
    this.forwardedFrom,
    this.fileKey,
    this.fileNonce,
  });

  bool get hasAttachment => attachmentId != null;

  factory MessageContent.text(
    String content, {
    List<CustomEmojiEntity> entities = const [],
  }) => MessageContent(text: content, entities: entities);

  factory MessageContent.fromJson(Map<String, dynamic> json) => MessageContent(
    text: json['text'] as String? ?? '',
    entities: _parseEntities(json['entities'] ?? json['caption_entities']),
    attachmentId: json['attachment_id'] as String?,
    fileName: json['file_name'] as String?,
    fileSize: json['file_size'] as int?,
    mimeType: json['mime_type'] as String?,
    durationMs: _parseInt(json['duration_ms']),
    linkPreview: json['link_preview'] is Map
        ? LinkPreview.fromJson(
            Map<String, dynamic>.from(json['link_preview'] as Map),
          )
        : null,
    viewOnce: json['view_once'] as bool? ?? false,
    hasSpoiler: json['has_spoiler'] as bool? ?? false,
    suppressLinkPreview: json['suppress_link_preview'] as bool? ?? false,
    waveform: _parseWaveform(json['waveform']),
    contact: json['contact'] is Map
        ? MessageContact.fromJson(
            Map<String, dynamic>.from(json['contact'] as Map),
          )
        : null,
    forwardedFrom: json['forwarded_from'] as String?,
    replyMarkup: BotInlineKeyboardMarkup.tryParse(json['reply_markup']),
    fileKey: json['file_key'] as String?,
    fileNonce: json['file_nonce'] as String?,
  );

  /// Parses a decrypted payload string — falls back to plain text if not JSON.
  static MessageContent parse(String raw, MessageType type) {
    if (type == MessageType.text) {
      final parsed = _tryParseTextPayload(raw);
      if (parsed != null) return parsed;
      return MessageContent.text(raw);
    }
    if (type == MessageType.sticker || type == MessageType.system) {
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
    if (entities.isNotEmpty)
      'entities': entities.map((entity) => entity.toJson()).toList(),
    if (attachmentId != null) 'attachment_id': attachmentId,
    if (fileName != null) 'file_name': fileName,
    if (fileSize != null) 'file_size': fileSize,
    if (mimeType != null) 'mime_type': mimeType,
    if (durationMs != null) 'duration_ms': durationMs,
    if (linkPreview != null) 'link_preview': linkPreview!.toJson(),
    if (viewOnce) 'view_once': true,
    if (hasSpoiler) 'has_spoiler': true,
    if (suppressLinkPreview) 'suppress_link_preview': true,
    if (waveform != null && waveform!.isNotEmpty) 'waveform': waveform,
    if (contact != null) 'contact': contact!.toJson(),
    if (forwardedFrom != null) 'forwarded_from': forwardedFrom,
    if (replyMarkup != null) 'reply_markup': replyMarkup!.toJson(),
    if (fileKey != null) 'file_key': fileKey,
    if (fileNonce != null) 'file_nonce': fileNonce,
  };

  static List<double>? _parseWaveform(Object? raw) {
    if (raw is! List || raw.isEmpty) return null;
    final out = <double>[];
    for (final v in raw) {
      if (v is num) out.add(v.toDouble().clamp(0.0, 1.0));
    }
    return out.isEmpty ? null : out;
  }

  static int? _parseInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.round();
    return null;
  }

  static MessageContent? _tryParseTextPayload(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      if (!decoded.containsKey('entities') &&
          !decoded.containsKey('link_preview') &&
          !decoded.containsKey('reply_markup') &&
          !decoded.containsKey('suppress_link_preview') &&
          !decoded.containsKey('forwarded_from')) {
        return null;
      }
      return MessageContent.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  static List<CustomEmojiEntity> _parseEntities(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => CustomEmojiEntity.fromJson(Map<String, dynamic>.from(e)))
        .where((e) => e.type == 'custom_emoji' && e.customEmojiId.isNotEmpty)
        .toList();
  }
}

class ChatArtifact {
  static const marker = 'openchat_artifact';
  static const version = 1;

  final String kind;
  final Object? payload;
  final Map<String, dynamic> metadata;

  const ChatArtifact({
    required this.kind,
    required this.payload,
    this.metadata = const {},
  });

  String get legacyPayload {
    final value = payload;
    if (value is String) return value;
    if (value == null) return '';
    return jsonEncode(value);
  }

  Map<String, dynamic>? get payloadMap {
    final value = payload;
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((key, value) => MapEntry(key.toString(), value));
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    marker: version,
    'kind': kind,
    'payload': payload,
    if (metadata.isNotEmpty) 'metadata': metadata,
  };

  String encode() => jsonEncode(toJson());

  static String encodePayload({
    required String kind,
    required Object? payload,
    Map<String, dynamic> metadata = const {},
  }) {
    return ChatArtifact(
      kind: kind,
      payload: payload,
      metadata: metadata,
    ).encode();
  }

  static ChatArtifact? tryParse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded[marker] != version) return null;
      final kind = decoded['kind'];
      if (kind is! String || kind.isEmpty) return null;
      final metadata = decoded['metadata'];
      return ChatArtifact(
        kind: kind,
        payload: decoded['payload'],
        metadata: metadata is Map
            ? metadata.map((key, value) => MapEntry(key.toString(), value))
            : const {},
      );
    } catch (_) {
      return null;
    }
  }
}

/// True when composed text is exactly one plain dice emoji — sent as a
/// server-rolled animated dice message (Telegram behavior) instead of text.
/// Callers must additionally check there are no custom-emoji entities.
bool isPlainDiceMessage(String text) => text.trim() == '🎲';

/// A server-authoritative dice / randomiser roll.
class DiceContent {
  final String emoji;
  final int value;
  final int max;

  const DiceContent({
    required this.emoji,
    required this.value,
    required this.max,
  });

  static DiceContent? tryParse(String raw) {
    if (!raw.contains('dice')) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final dice = json['dice'];
      if (dice is! Map) return null;
      return DiceContent(
        emoji: dice['emoji']?.toString() ?? '🎲',
        value: (dice['value'] as num?)?.toInt() ?? 1,
        max: (dice['max'] as num?)?.toInt() ?? 6,
      );
    } catch (_) {
      return null;
    }
  }

  /// A friendly outcome label, e.g. "Heads" for a coin or "6 / 6" for a die.
  String get label {
    if (emoji == '🪙') return value == 1 ? 'Heads' : 'Tails';
    return '$value / $max';
  }
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
  String senderId;
  final bool sealedSender;
  MessageType type;

  /// PGP-armored ciphertext — decrypted client-side using the local private key.
  final String encryptedPayload;
  final String signature;
  final bool isEncrypted;
  final int autoDeleteSeconds;
  final DateTime? autoDeleteExpiresAt;
  final String? attachmentId;
  final String? replyTo;
  final String? topicId;
  final String? mediaGroupId;
  final bool silent;
  final String? controlToken;
  final List<MessageReactionSummary> reactions;
  Poll? poll;
  final DateTime createdAt;
  final DateTime? editedAt;
  // Not final: realtime new_message events arrive without sender details, so
  // ChatProvider backfills this from the loaded conversation members.
  User? sender;

  // Decrypted on client — never stored or sent to server
  MessageContent? _content;
  MessageLocation? _location;
  ChatArtifact? _artifact;
  String? _decryptedPayload;
  bool _decryptionFailed = false;

  Message({
    required this.id,
    required this.conversationId,
    required this.senderId,
    this.sealedSender = false,
    required this.type,
    required this.encryptedPayload,
    required this.signature,
    this.isEncrypted = true,
    this.autoDeleteSeconds = 0,
    this.autoDeleteExpiresAt,
    this.attachmentId,
    this.replyTo,
    this.topicId,
    this.mediaGroupId,
    this.silent = false,
    this.controlToken,
    this.reactions = const [],
    this.poll,
    required this.createdAt,
    this.editedAt,
    this.sender,
  });

  factory Message.fromJson(Map<String, dynamic> json) => Message(
    id: json['id'] as String,
    conversationId: json['conversation_id'] as String,
    senderId: json['sender_id'] as String? ?? '',
    sealedSender: json['sealed_sender'] as bool? ?? false,
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
    mediaGroupId: json['media_group_id'] as String?,
    silent: json['silent'] as bool? ?? false,
    controlToken: json['control_token'] as String?,
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

  void setDecryptedContent(String raw, {String? verifiedSenderId}) {
    final wrapped = _tryParseOpenChatMessage(raw);
    if (wrapped != null) {
      type = _parseType(wrapped.type);
      raw = wrapped.payload;
      if (verifiedSenderId != null && verifiedSenderId.isNotEmpty) {
        senderId = verifiedSenderId;
      }
    }
    final artifact = ChatArtifact.tryParse(raw);
    if (artifact != null) {
      type = _parseType(artifact.kind);
      raw = artifact.legacyPayload;
      _artifact = artifact;
    } else {
      _artifact = null;
    }
    _decryptedPayload = raw;
    if (type == MessageType.location) {
      final location = MessageLocation.tryParse(raw);
      _location = location;
      if (location == null) {
        _content = MessageContent.parse(raw, type);
      } else {
        _content = MessageContent.text(location.copyLabel);
      }
    } else {
      _content = MessageContent.parse(raw, type);
    }
    _decryptionFailed = false;
  }

  void markDecryptionFailed() {
    _decryptionFailed = true;
  }

  MessageContent? get content => _content;
  ChatArtifact? get artifact => _artifact;
  String? get decryptedPayload => _decryptedPayload;
  String? get effectiveReplyTo => replyTo ?? _metadataString('reply_to');
  String? get effectiveTopicId => topicId ?? _metadataString('topic_id');
  String? get effectiveMediaGroupId =>
      mediaGroupId ?? _metadataString('media_group_id');
  bool get isDecrypted => _content != null;
  bool get decryptionFailed => _decryptionFailed;
  bool get isEdited => editedAt != null;

  String? _metadataString(String key) {
    final value = _artifact?.metadata[key];
    return value is String && value.isNotEmpty ? value : null;
  }

  bool get hasAutoDelete =>
      autoDeleteSeconds > 0 && autoDeleteExpiresAt != null;

  /// Convenience: plain display text (for text/sticker) or caption.
  String? get decryptedContent => _content?.text;
  MessageLocation? get location => _location;
  bool get isActiveLiveLocation =>
      _location?.isLive == true && _location?.isActive == true;

  /// Parsed call event if this is a `system` call-outcome message, else null.
  CallEventInfo? get callEvent {
    if (type != MessageType.system || _content == null) return null;
    return CallEventInfo.tryParse(_content!.text);
  }

  /// True if this is a `system` screenshot-notice message (someone captured a
  /// view-once / disappearing attachment).
  bool get isScreenshotNotice {
    if (type != MessageType.system || _content == null) return false;
    final text = _content!.text;
    if (!text.contains('screenshot_notice')) return false;
    try {
      return (jsonDecode(text) as Map<String, dynamic>)['screenshot_notice'] ==
          true;
    } catch (_) {
      return false;
    }
  }

  /// Parsed SMP control payload if this is an in-band SMP verification message,
  /// else null. SMP messages are carried as `system` messages and are never
  /// shown in the chat — the SMP provider consumes them.
  Map<String, dynamic>? get smpControl {
    if (type != MessageType.system || _content == null) return null;
    final text = _content!.text;
    if (!text.contains('openchat_smp')) return null;
    try {
      final json = jsonDecode(text) as Map<String, dynamic>;
      if (json['openchat_smp'] == 1) return json;
    } catch (_) {}
    return null;
  }

  /// Parsed social-recovery share payload if this is an in-band guardian
  /// share delivery, else null. Carried as `system` messages, never rendered —
  /// the receiving client stores the share and suppresses the bubble.
  Map<String, dynamic>? get recoveryShareControl {
    if (type != MessageType.system || _content == null) return null;
    final text = _content!.text;
    if (!text.contains('openchat_recovery_share')) return null;
    try {
      final json = jsonDecode(text) as Map<String, dynamic>;
      if (json['openchat_recovery_share'] == 1) return json;
    } catch (_) {}
    return null;
  }

  /// True for any system control message that must not render in the chat list.
  bool get isHiddenControl => smpControl != null || recoveryShareControl != null;

  /// Parsed server-rolled dice/randomiser, or null. The value is set by the
  /// server (the client only animates to it), so it's read from the plaintext
  /// payload of this non-encrypted message type.
  DiceContent? get dice {
    if (type != MessageType.dice) return null;
    // Try each source and return the first that actually parses. The decrypted
    // *content* text is empty for a dice (MessageContent.fromJson finds no
    // "text" field), so a plain `decryptedContent ?? ...` chain stops at "" and
    // never reaches the real payload — leaving the bubble blank. The raw dice
    // JSON always lives in decryptedPayload / encryptedPayload.
    for (final raw in [decryptedPayload, encryptedPayload, decryptedContent]) {
      if (raw == null || raw.isEmpty) continue;
      final parsed = DiceContent.tryParse(raw);
      if (parsed != null) return parsed;
    }
    return null;
  }

  /// The provably-fair game round this message hosts, or null. The payload is
  /// {"game":{"round_id":"..."}}; the live round state is fetched/streamed by id.
  String? get gameRoundId {
    if (type != MessageType.game) return null;
    for (final raw in [decryptedPayload, encryptedPayload, decryptedContent]) {
      if (raw == null || raw.isEmpty) continue;
      try {
        final json = jsonDecode(raw);
        if (json is Map && json['game'] is Map) {
          final id = (json['game'] as Map)['round_id'];
          if (id is String && id.isNotEmpty) return id;
        }
      } catch (_) {}
    }
    return null;
  }

  /// One-line text for conversation list previews. Call events render as their
  /// label (e.g. "Missed voice call") rather than the raw JSON payload.
  String get listPreview {
    if (type == MessageType.location && location != null) {
      return location!.previewLabel;
    }
    if (type == MessageType.poll && poll != null) {
      return 'Poll: ${poll!.question}';
    }
    if (type == MessageType.checklist) {
      return 'Checklist';
    }
    if (type == MessageType.dice) {
      return '🎲 Dice roll';
    }
    if (type == MessageType.game) {
      return '🎲 Game';
    }
    if (type == MessageType.invoice ||
        type == MessageType.paymentRequest ||
        type == MessageType.paymentTransfer) {
      return switch (type) {
        MessageType.invoice => 'Invoice',
        MessageType.paymentRequest => 'Payment request',
        _ => 'Payment sent',
      };
    }
    final ev = callEvent;
    if (ev != null) return ev.label;
    if (isScreenshotNotice) return 'Screenshot taken';
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
    'game' => MessageType.game,
    'checklist' => MessageType.checklist,
    'invoice' => MessageType.invoice,
    'payment_request' => MessageType.paymentRequest,
    'payment_transfer' => MessageType.paymentTransfer,
    'system' => MessageType.system,
    _ => MessageType.text,
  };

  static _OpenChatMessagePayload? _tryParseOpenChatMessage(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['openchat_message'] != 1) return null;
      final type = decoded['type'];
      final payload = decoded['payload'];
      if (type is! String || payload is! String) return null;
      final sender = decoded['sender'];
      return _OpenChatMessagePayload(
        type: type,
        payload: payload,
        senderId: sender is Map ? sender['id'] as String? : null,
        senderFingerprint: sender is Map
            ? sender['key_fingerprint'] as String?
            : null,
        senderSignature: sender is Map ? sender['signature'] as String? : null,
        senderCreatedAt: sender is Map ? sender['created_at'] as String? : null,
      );
    } catch (_) {
      return null;
    }
  }

  static OpenChatSenderProof? senderProofFromRaw(String raw) {
    final wrapped = _tryParseOpenChatMessage(raw);
    if (wrapped == null ||
        wrapped.senderId == null ||
        wrapped.senderFingerprint == null ||
        wrapped.senderSignature == null) {
      return null;
    }
    return OpenChatSenderProof(
      type: wrapped.type,
      payload: wrapped.payload,
      senderId: wrapped.senderId!,
      keyFingerprint: wrapped.senderFingerprint!,
      signature: wrapped.senderSignature!,
      createdAt: wrapped.senderCreatedAt,
    );
  }

  Message copyWith({
    String? encryptedPayload,
    String? signature,
    List<MessageReactionSummary>? reactions,
    Poll? poll,
    DateTime? editedAt,
    User? sender,
    String? controlToken,
  }) {
    final payloadChanged =
        encryptedPayload != null && encryptedPayload != this.encryptedPayload;
    final msg = Message(
      id: id,
      conversationId: conversationId,
      senderId: senderId,
      sealedSender: sealedSender,
      type: type,
      encryptedPayload: encryptedPayload ?? this.encryptedPayload,
      signature: signature ?? this.signature,
      isEncrypted: isEncrypted,
      autoDeleteSeconds: autoDeleteSeconds,
      autoDeleteExpiresAt: autoDeleteExpiresAt,
      attachmentId: attachmentId,
      replyTo: replyTo,
      topicId: topicId,
      mediaGroupId: mediaGroupId,
      silent: silent,
      controlToken: controlToken ?? this.controlToken,
      reactions: reactions ?? this.reactions,
      poll: poll ?? this.poll,
      createdAt: createdAt,
      editedAt: editedAt ?? this.editedAt,
      sender: sender ?? this.sender,
    );
    if (payloadChanged) {
      if (!isEncrypted) {
        msg.setDecryptedContent(msg.encryptedPayload);
      }
    } else {
      if (_content != null) msg._content = _content;
      if (_location != null) msg._location = _location;
      if (_artifact != null) msg._artifact = _artifact;
      if (_decryptedPayload != null) msg._decryptedPayload = _decryptedPayload;
    }
    msg._decryptionFailed = _decryptionFailed;
    return msg;
  }
}

class _OpenChatMessagePayload {
  final String type;
  final String payload;
  final String? senderId;
  final String? senderFingerprint;
  final String? senderSignature;
  final String? senderCreatedAt;

  const _OpenChatMessagePayload({
    required this.type,
    required this.payload,
    this.senderId,
    this.senderFingerprint,
    this.senderSignature,
    this.senderCreatedAt,
  });
}

class OpenChatSenderProof {
  final String type;
  final String payload;
  final String senderId;
  final String keyFingerprint;
  final String signature;
  // Non-null for messages signed with the v2 sender-proof scheme.
  final String? createdAt;

  const OpenChatSenderProof({
    required this.type,
    required this.payload,
    required this.senderId,
    required this.keyFingerprint,
    required this.signature,
    this.createdAt,
  });
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
  // Quiz mode (type == 'quiz'): the correct option index(es) + an optional
  // explanation, typically revealed by the server only after the user votes.
  final List<int> correctOptionIds;
  final String? explanation;

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
    this.correctOptionIds = const [],
    this.explanation,
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
    correctOptionIds: (json['correct_option_ids'] as List? ?? [])
        .map((e) => (e as num).toInt())
        .toList(),
    explanation: json['explanation'] as String?,
  );

  bool get isQuiz => type == 'quiz';
  bool get isMeeting => type == 'meeting';

  /// The correct option (quiz mode), once the server has revealed it.
  bool isCorrectOption(int index) => correctOptionIds.contains(index);

  bool isSelected(String optionId) => voterOptionIds.contains(optionId);

  Poll copyWith({
    String? question,
    String? description,
    List<PollOption>? options,
    List<String>? voterOptionIds,
  }) => Poll(
    id: id,
    messageId: messageId,
    question: question ?? this.question,
    description: description ?? this.description,
    type: type,
    isAnonymous: isAnonymous,
    allowsMultipleAnswers: allowsMultipleAnswers,
    allowsRevoting: allowsRevoting,
    isClosed: isClosed,
    totalVoterCount: totalVoterCount,
    options: options ?? this.options,
    voterOptionIds: voterOptionIds ?? this.voterOptionIds,
    correctOptionIds: correctOptionIds,
    explanation: explanation,
  );
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

  PollOption copyWith({String? text, int? voterCount}) => PollOption(
    id: id,
    index: index,
    text: text ?? this.text,
    voterCount: voterCount ?? this.voterCount,
    persistentId: persistentId,
  );
}

class MessageReactionSummary {
  final String emoji;
  final int count;
  final bool reactedByMe;

  const MessageReactionSummary({
    required this.emoji,
    required this.count,
    this.reactedByMe = false,
  });

  factory MessageReactionSummary.fromJson(Map<String, dynamic> json) =>
      MessageReactionSummary(
        emoji: json['emoji'] as String? ?? '',
        count: json['count'] as int? ?? 0,
        reactedByMe:
            json['reacted_by_me'] as bool? ??
            json['viewer_reacted'] as bool? ??
            json['selected'] as bool? ??
            false,
      );

  MessageReactionSummary copyWith({int? count, bool? reactedByMe}) =>
      MessageReactionSummary(
        emoji: emoji,
        count: count ?? this.count,
        reactedByMe: reactedByMe ?? this.reactedByMe,
      );
}

enum PendingMessageStatus { sending, queued, failed }

/// Optimistic local message shown while the server confirms delivery.
class PendingMessage extends Message {
  final PendingMessageStatus status;
  final String? outboxId;
  final String? lastError;

  bool get isSending => status == PendingMessageStatus.sending;
  bool get isQueued => status == PendingMessageStatus.queued;
  bool get isFailed => status == PendingMessageStatus.failed;

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
    this.status = PendingMessageStatus.sending,
    this.outboxId,
    this.lastError,
  }) {
    setDecryptedContent(plaintext);
  }
}
