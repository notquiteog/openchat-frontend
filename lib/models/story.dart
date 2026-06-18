import 'conversation.dart';
import 'user.dart';

class Story {
  final String id;
  final String userId;

  /// Ties a user's story posts into one "story" reel — posts sharing a groupId
  /// belong to the same story. Empty only for legacy/locally-built stories; use
  /// [groupKey] to read it with a safe fallback to [id].
  final String groupId;
  final String? conversationId;
  final String caption;
  final List<dynamic> entities;
  final String? attachmentId;
  final String? fileName;
  final int fileSize;
  final String? mimeType;
  final String? fileKey;
  final String? fileNonce;
  final String? background;

  /// E2E story metadata: a PGP envelope (encrypted to the audience) holding
  /// {file_key, file_nonce, caption, file_name, mime_type, entities}. When
  /// set, the plaintext columns above are empty server-side and the viewer
  /// fills them in locally after decrypting (see [withDecryptedMeta]).
  final String? encryptedPayload;
  final String mediaType;
  final String privacy;
  final bool pinned;
  final bool noForwards;
  final int viewCount;
  final int reactionCount;
  final bool viewerHasViewed;
  final String? viewerReaction;
  final DateTime expiresAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? archivedAt;
  final User? user;
  final Conversation? conversation;

  const Story({
    required this.id,
    required this.userId,
    this.groupId = '',
    this.conversationId,
    this.caption = '',
    this.entities = const [],
    this.attachmentId,
    this.fileName,
    this.fileSize = 0,
    this.mimeType,
    this.fileKey,
    this.fileNonce,
    this.background,
    this.encryptedPayload,
    this.mediaType = 'image',
    this.privacy = 'contacts',
    this.pinned = false,
    this.noForwards = false,
    this.viewCount = 0,
    this.reactionCount = 0,
    this.viewerHasViewed = false,
    this.viewerReaction,
    required this.expiresAt,
    required this.createdAt,
    required this.updatedAt,
    this.archivedAt,
    this.user,
    this.conversation,
  });

  factory Story.fromJson(Map<String, dynamic> json) => Story(
    id: json['id'] as String,
    userId: json['user_id'] as String,
    groupId: json['group_id'] as String? ?? (json['id'] as String),
    conversationId: json['conversation_id'] as String?,
    caption: json['caption'] as String? ?? '',
    entities: (json['entities'] as List?) ?? const [],
    attachmentId: json['attachment_id'] as String?,
    fileName: json['file_name'] as String?,
    fileSize: (json['file_size'] as num?)?.toInt() ?? 0,
    mimeType: json['mime_type'] as String?,
    fileKey: json['file_key'] as String?,
    fileNonce: json['file_nonce'] as String?,
    background: json['background'] as String?,
    encryptedPayload: json['encrypted_payload'] as String?,
    mediaType: json['media_type'] as String? ?? 'image',
    privacy: json['privacy'] as String? ?? 'contacts',
    pinned: json['pinned'] as bool? ?? false,
    noForwards: json['no_forwards'] as bool? ?? false,
    viewCount: json['view_count'] as int? ?? 0,
    reactionCount: json['reaction_count'] as int? ?? 0,
    viewerHasViewed: json['viewer_has_viewed'] as bool? ?? false,
    viewerReaction: json['viewer_reaction'] as String?,
    expiresAt: DateTime.parse(json['expires_at'] as String),
    createdAt: DateTime.parse(json['created_at'] as String),
    updatedAt: DateTime.parse(json['updated_at'] as String),
    archivedAt: json['archived_at'] != null
        ? DateTime.parse(json['archived_at'] as String)
        : null,
    user: json['user'] != null
        ? User.fromJson(json['user'] as Map<String, dynamic>)
        : null,
    conversation: json['conversation'] != null
        ? Conversation.fromJson(json['conversation'] as Map<String, dynamic>)
        : null,
  );

  /// Whether the story's metadata is end-to-end encrypted and not yet
  /// decrypted locally.
  bool get needsMetaDecryption =>
      (encryptedPayload?.isNotEmpty ?? false) &&
      (fileKey == null || fileKey!.isEmpty);

  /// Returns a copy with the decrypted metadata fields filled in.
  Story withDecryptedMeta(Map<String, dynamic> meta) => Story(
    id: id,
    userId: userId,
    groupId: groupId,
    conversationId: conversationId,
    caption: meta['caption'] as String? ?? caption,
    entities: (meta['entities'] as List?) ?? entities,
    attachmentId: attachmentId,
    fileName: meta['file_name'] as String? ?? fileName,
    fileSize: fileSize,
    mimeType: meta['mime_type'] as String? ?? mimeType,
    fileKey: meta['file_key'] as String? ?? fileKey,
    fileNonce: meta['file_nonce'] as String? ?? fileNonce,
    background: meta['background'] as String? ?? background,
    encryptedPayload: encryptedPayload,
    mediaType: mediaType,
    privacy: privacy,
    pinned: pinned,
    noForwards: noForwards,
    viewCount: viewCount,
    reactionCount: reactionCount,
    viewerHasViewed: viewerHasViewed,
    viewerReaction: viewerReaction,
    expiresAt: expiresAt,
    createdAt: createdAt,
    updatedAt: updatedAt,
    archivedAt: archivedAt,
    user: user,
    conversation: conversation,
  );

  /// The story reel this post belongs to, falling back to [id] for legacy rows
  /// that predate grouping.
  String get groupKey => groupId.isNotEmpty ? groupId : id;

  bool get isVideo =>
      mediaType == 'video' || (mimeType?.startsWith('video/') ?? false);
  bool get isImage =>
      mediaType == 'image' || (mimeType?.startsWith('image/') ?? false);
  bool get isText => mediaType == 'text';
  bool get isArchived =>
      archivedAt != null || expiresAt.isBefore(DateTime.now());

  String displayTitle(String currentUserId) {
    if (conversation != null) {
      return conversation!.name ?? conversation!.handle ?? 'Channel';
    }
    if (userId == currentUserId) return 'Your story';
    return user?.username != null ? '@${user!.username}' : 'Story';
  }

  String? displayAvatar(String currentUserId) {
    if (conversation != null) return conversation!.avatarUrl;
    return user?.avatarUrl;
  }
}
