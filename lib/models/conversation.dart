import 'message.dart';
import 'user.dart';

enum ConversationType { dm, group, channel }

class Conversation {
  final String id;
  final ConversationType type;
  final String? name;
  final String? description;
  final String? avatarUrl;

  /// Premium-set, conversation-wide chat background (metadata-stripped WEBP).
  /// Visible to every member of a channel / group / bot chat.
  final String? backgroundUrl;
  final bool isPublic;
  final String? handle; // @handle for channels (without the @)
  final DateTime? archivedAt;

  /// When true, only conversation admins can post (broadcast mode).
  final bool ownerOnlyPost;

  /// Disappearing-messages timer in seconds (0 = off).
  final int messageTtlSeconds;
  final bool encryptionEnabled;
  final DateTime createdAt;
  final String createdBy;
  final List<ConversationMember> members;
  final Message? lastMessage;
  final int unreadCount;

  const Conversation({
    required this.id,
    required this.type,
    this.name,
    this.description,
    this.avatarUrl,
    this.backgroundUrl,
    this.isPublic = false,
    this.handle,
    this.archivedAt,
    this.ownerOnlyPost = false,
    this.messageTtlSeconds = 0,
    this.encryptionEnabled = true,
    required this.createdAt,
    required this.createdBy,
    this.members = const [],
    this.lastMessage,
    this.unreadCount = 0,
  });

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
        id: json['id'] as String,
        type: switch (json['type'] as String?) {
          'group' => ConversationType.group,
          'channel' => ConversationType.channel,
          _ => ConversationType.dm,
        },
        name: json['name'] as String?,
        description: json['description'] as String?,
        avatarUrl: json['avatar_url'] as String?,
        backgroundUrl: json['background_url'] as String?,
        isPublic: json['is_public'] as bool? ?? false,
        handle: json['handle'] as String?,
        archivedAt: json['archived_at'] != null
            ? DateTime.parse(json['archived_at'] as String)
            : null,
        ownerOnlyPost: json['owner_only_post'] as bool? ?? false,
        messageTtlSeconds: json['message_ttl_seconds'] as int? ?? 0,
        encryptionEnabled: json['encryption_enabled'] as bool? ?? true,
        createdAt: DateTime.parse(json['created_at'] as String),
        createdBy: json['created_by'] as String,
        members: (json['members'] as List? ?? [])
            .map((e) => ConversationMember.fromJson(e as Map<String, dynamic>))
            .toList(),
        lastMessage: json['last_message'] != null
            ? Message.fromJson(json['last_message'] as Map<String, dynamic>)
            : null,
        unreadCount: json['unread_count'] as int? ?? 0,
      );

  bool get isGroup => type == ConversationType.group;
  bool get isDM => type == ConversationType.dm;
  bool get isChannel => type == ConversationType.channel;
  bool get isArchived => archivedAt != null;

  /// "@handle" if set, otherwise the display name.
  String get atHandle => handle != null ? '@$handle' : (name ?? 'Channel');

  /// The other participant in a DM (null for groups/channels or when members
  /// haven't loaded yet).
  User? otherUser(String currentUserID) {
    if (!isDM || members.isEmpty) return null;
    return members
        .firstWhere(
          (m) => m.userId != currentUserID,
          orElse: () => members.first,
        )
        .user;
  }

  /// True when this is a DM whose partner is a bot account.
  bool isBotDM(String currentUserID) =>
      otherUser(currentUserID)?.isBot ?? false;

  /// For DMs, returns the other participant's name; groups/channels use [name].
  String displayName(String currentUserID) {
    if (isGroup) return name ?? 'Group';
    if (isChannel) return name ?? 'Channel';
    if (members.isEmpty) return 'Unknown';
    final other = members.firstWhere(
      (m) => m.userId != currentUserID,
      orElse: () => members.first,
    );
    return other.user?.username ?? 'Unknown';
  }

  String? displayAvatar(String currentUserID) {
    if (isGroup || isChannel) return avatarUrl;
    if (members.isEmpty) return null;
    final other = members.firstWhere(
      (m) => m.userId != currentUserID,
      orElse: () => members.first,
    );
    return other.user?.avatarUrl;
  }

  /// All current members' public keys, with expired-key members filtered out.
  /// Used to build the multi-recipient envelope when sending a message — a
  /// member whose key has expired can't decrypt anyway, so encrypting to
  /// their key would just waste a PKESK slot (and the key may be unusable
  /// entirely if the encryption subkey is gone).
  List<String> get memberPublicKeys => members
      .where((m) => m.user != null && !m.user!.isKeyExpired)
      .map((m) => m.user!.publicKey)
      .where((k) => k.isNotEmpty)
      .toList();

  List<String> get memberIDs => members.map((m) => m.userId).toList();

  Conversation copyWith({
    Message? lastMessage,
    int? unreadCount,
    List<ConversationMember>? members,
    DateTime? archivedAt,
    bool? ownerOnlyPost,
    bool? encryptionEnabled,
    String? backgroundUrl,
  }) =>
      Conversation(
        id: id,
        type: type,
        name: name,
        description: description,
        avatarUrl: avatarUrl,
        backgroundUrl: backgroundUrl ?? this.backgroundUrl,
        isPublic: isPublic,
        handle: handle,
        archivedAt: archivedAt ?? this.archivedAt,
        ownerOnlyPost: ownerOnlyPost ?? this.ownerOnlyPost,
        messageTtlSeconds: messageTtlSeconds,
        encryptionEnabled: encryptionEnabled ?? this.encryptionEnabled,
        createdAt: createdAt,
        createdBy: createdBy,
        members: members ?? this.members,
        lastMessage: lastMessage ?? this.lastMessage,
        unreadCount: unreadCount ?? this.unreadCount,
      );
}

enum MemberRole { admin, moderator, member }

class ConversationMember {
  final String conversationId;
  final String userId;
  final MemberRole role;
  final DateTime joinedAt;
  final User? user;

  const ConversationMember({
    required this.conversationId,
    required this.userId,
    required this.role,
    required this.joinedAt,
    this.user,
  });

  factory ConversationMember.fromJson(Map<String, dynamic> json) =>
      ConversationMember(
        conversationId: json['conversation_id'] as String,
        userId: json['user_id'] as String,
        role: switch (json['role']) {
          'admin' => MemberRole.admin,
          'moderator' => MemberRole.moderator,
          _ => MemberRole.member,
        },
        joinedAt: DateTime.parse(json['joined_at'] as String),
        user: json['user'] != null
            ? User.fromJson(json['user'] as Map<String, dynamic>)
            : null,
      );

  bool get isAdmin => role == MemberRole.admin;
  bool get isModerator => role == MemberRole.moderator;
}
