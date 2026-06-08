import 'message.dart';
import 'user.dart';

enum ConversationType { dm, group, channel, self }

enum EncryptionMode { plaintext, pgp, mls }

EncryptionMode encryptionModeFromJson(Object? raw) => switch (raw) {
  'plaintext' => EncryptionMode.plaintext,
  'mls' => EncryptionMode.mls,
  _ => EncryptionMode.pgp,
};

extension EncryptionModeApi on EncryptionMode {
  String get apiValue => switch (this) {
    EncryptionMode.plaintext => 'plaintext',
    EncryptionMode.pgp => 'pgp',
    EncryptionMode.mls => 'mls',
  };

  String get shortLabel => switch (this) {
    EncryptionMode.plaintext => 'None',
    EncryptionMode.pgp => 'PGP',
    EncryptionMode.mls => 'MLS',
  };

  bool get isEncrypted => this != EncryptionMode.plaintext;
}

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

  final int newMemberCooldownSeconds;
  final bool antiSpamBlockLinks;
  final bool antiSpamBlockMedia;
  final int antiSpamMentionLimit;

  /// Disappearing-messages timer in seconds (0 = off).
  final int messageTtlSeconds;
  final EncryptionMode encryptionMode;
  final int slowModeSeconds;
  final bool joinApprovalRequired;
  final bool topicsEnabled;
  final bool businessSuiteEnabled;

  /// Join policy: 'open' or 'web_of_trust' (a current member must vouch for the
  /// candidate's key before they can join).
  final String membershipPolicy;

  /// "Burner" group/channel auto-destruct time. Null = permanent. Once passed,
  /// the server locks the conversation and purges its messages.
  final DateTime? expiresAt;

  /// True once a burner conversation has expired (frozen, messages purged).
  final bool locked;
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
    this.newMemberCooldownSeconds = 0,
    this.antiSpamBlockLinks = false,
    this.antiSpamBlockMedia = false,
    this.antiSpamMentionLimit = 0,
    this.messageTtlSeconds = 0,
    this.encryptionMode = EncryptionMode.pgp,
    this.slowModeSeconds = 0,
    this.joinApprovalRequired = false,
    this.topicsEnabled = false,
    this.businessSuiteEnabled = false,
    this.membershipPolicy = 'open',
    this.expiresAt,
    this.locked = false,
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
      'self' => ConversationType.self,
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
    newMemberCooldownSeconds: json['new_member_cooldown_seconds'] as int? ?? 0,
    antiSpamBlockLinks: json['anti_spam_block_links'] as bool? ?? false,
    antiSpamBlockMedia: json['anti_spam_block_media'] as bool? ?? false,
    antiSpamMentionLimit: json['anti_spam_mention_limit'] as int? ?? 0,
    messageTtlSeconds: json['message_ttl_seconds'] as int? ?? 0,
    encryptionMode: encryptionModeFromJson(json['encryption_mode']),
    slowModeSeconds: json['slow_mode_seconds'] as int? ?? 0,
    joinApprovalRequired: json['join_approval_required'] as bool? ?? false,
    topicsEnabled: json['topics_enabled'] as bool? ?? false,
    businessSuiteEnabled: json['business_suite_enabled'] as bool? ?? false,
    membershipPolicy: json['membership_policy'] as String? ?? 'open',
    expiresAt: json['expires_at'] != null
        ? DateTime.parse(json['expires_at'] as String)
        : null,
    locked: json['locked'] as bool? ?? false,
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
  bool get isSelf => type == ConversationType.self;
  bool get isArchived => archivedAt != null;

  /// A "burner" conversation with a scheduled auto-destruct time.
  bool get isBurner => expiresAt != null;

  /// Joining requires a current member to vouch for the candidate's key.
  bool get isWebOfTrust => membershipPolicy == 'web_of_trust';
  bool get isEncrypted => encryptionMode.isEncrypted;
  bool get usesPgp => encryptionMode == EncryptionMode.pgp;
  bool get usesMls => encryptionMode == EncryptionMode.mls;

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
    if (isSelf) return 'Saved Messages';
    if (isGroup) return name ?? 'Group';
    if (isChannel) return name ?? 'Channel';
    if (members.isEmpty) return 'Unknown';
    final other = members.firstWhere(
      (m) => m.userId != currentUserID,
      orElse: () => members.first,
    );
    return other.user?.displayName ?? 'Unknown';
  }

  String? displayAvatar(String currentUserID) {
    if (isSelf) return null; // UI renders a bookmark glyph instead
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
  /// their key would just waste an envelope slot (and the key may be unusable
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
    int? newMemberCooldownSeconds,
    bool? antiSpamBlockLinks,
    bool? antiSpamBlockMedia,
    int? antiSpamMentionLimit,
    EncryptionMode? encryptionMode,
    int? slowModeSeconds,
    bool? joinApprovalRequired,
    bool? topicsEnabled,
    bool? businessSuiteEnabled,
    String? backgroundUrl,
    DateTime? expiresAt,
    bool? locked,
    String? membershipPolicy,
  }) => Conversation(
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
    newMemberCooldownSeconds:
        newMemberCooldownSeconds ?? this.newMemberCooldownSeconds,
    antiSpamBlockLinks: antiSpamBlockLinks ?? this.antiSpamBlockLinks,
    antiSpamBlockMedia: antiSpamBlockMedia ?? this.antiSpamBlockMedia,
    antiSpamMentionLimit: antiSpamMentionLimit ?? this.antiSpamMentionLimit,
    messageTtlSeconds: messageTtlSeconds,
    encryptionMode: encryptionMode ?? this.encryptionMode,
    slowModeSeconds: slowModeSeconds ?? this.slowModeSeconds,
    joinApprovalRequired: joinApprovalRequired ?? this.joinApprovalRequired,
    topicsEnabled: topicsEnabled ?? this.topicsEnabled,
    businessSuiteEnabled: businessSuiteEnabled ?? this.businessSuiteEnabled,
    membershipPolicy: membershipPolicy ?? this.membershipPolicy,
    expiresAt: expiresAt ?? this.expiresAt,
    locked: locked ?? this.locked,
    createdAt: createdAt,
    createdBy: createdBy,
    members: members ?? this.members,
    lastMessage: lastMessage ?? this.lastMessage,
    unreadCount: unreadCount ?? this.unreadCount,
  );
}

enum MemberRole { admin, moderator, member }

extension MemberRoleApi on MemberRole {
  String get apiValue => switch (this) {
    MemberRole.admin => 'admin',
    MemberRole.moderator => 'moderator',
    MemberRole.member => 'member',
  };
}

abstract final class AdminPermission {
  static const manageInfo = 'manage_info';
  static const manageSettings = 'manage_settings';
  static const manageEncryption = 'manage_encryption';
  static const manageTopics = 'manage_topics';
  static const manageMembers = 'manage_members';
  static const manageRoles = 'manage_roles';
  static const manageInvites = 'manage_invites';
  static const approveJoinRequests = 'approve_join_requests';
  static const managePins = 'manage_pins';
  static const deleteMessages = 'delete_messages';
  static const manageModeration = 'manage_moderation';
  static const postMessages = 'post_messages';

  static const values = [
    manageInfo,
    manageSettings,
    manageEncryption,
    manageTopics,
    manageMembers,
    manageRoles,
    manageInvites,
    approveJoinRequests,
    managePins,
    deleteMessages,
    manageModeration,
    postMessages,
  ];

  static Map<String, bool> defaultsForRole(MemberRole role) {
    final defaults = {for (final permission in values) permission: false};
    switch (role) {
      case MemberRole.admin:
        return {for (final permission in values) permission: true};
      case MemberRole.moderator:
        defaults[managePins] = true;
        defaults[deleteMessages] = true;
        defaults[manageModeration] = true;
        return defaults;
      case MemberRole.member:
        return defaults;
    }
  }
}

class ConversationMember {
  final String conversationId;
  final String userId;
  final MemberRole role;
  final Map<String, bool>? adminPermissions;
  final bool isAnonymous;
  final DateTime joinedAt;
  final User? user;

  const ConversationMember({
    required this.conversationId,
    required this.userId,
    required this.role,
    this.adminPermissions,
    this.isAnonymous = false,
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
        adminPermissions: _parseAdminPermissions(json['admin_permissions']),
        isAnonymous: json['is_anonymous'] as bool? ?? false,
        joinedAt: DateTime.parse(json['joined_at'] as String),
        user: json['user'] != null
            ? User.fromJson(json['user'] as Map<String, dynamic>)
            : null,
      );

  bool get isAdmin => role == MemberRole.admin;
  bool get isModerator => role == MemberRole.moderator;

  Map<String, bool> get effectiveAdminPermissions {
    final defaults = AdminPermission.defaultsForRole(role);
    final explicit = adminPermissions;
    if (explicit == null) return defaults;
    return {
      for (final permission in AdminPermission.values)
        permission: explicit[permission] ?? defaults[permission] ?? false,
    };
  }

  bool hasPermission(String permission) =>
      effectiveAdminPermissions[permission] ?? false;
}

Map<String, bool>? _parseAdminPermissions(Object? raw) {
  if (raw is! Map || raw.isEmpty) return null;
  final parsed = <String, bool>{};
  for (final permission in AdminPermission.values) {
    final value = raw[permission];
    if (value is bool) parsed[permission] = value;
  }
  return parsed.isEmpty ? null : parsed;
}
