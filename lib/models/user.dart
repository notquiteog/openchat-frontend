class User {
  final String id;
  final String username;
  final String? profileDisplayName;
  final String publicKey;
  final String keyFingerprint;
  final String? avatarUrl;
  final String? bio;
  final int? bubbleColor;
  final bool isBot;
  final bool publicDiscovery;
  final String role; // "user" | "system_admin"
  final bool isFlaggedScammer;
  final bool isBanned;
  final bool allowGroupAdd;
  final DateTime createdAt;
  final DateTime? lastSeen;
  final DateTime? premiumUntil;

  /// PGP public-key expiry. null = never expires (the OpenChat default).
  /// When this is set and in the past, the user cannot send or receive
  /// messages until they rotate to a fresh key.
  final DateTime? publicKeyExpiresAt;

  const User({
    required this.id,
    required this.username,
    this.profileDisplayName,
    required this.publicKey,
    required this.keyFingerprint,
    this.avatarUrl,
    this.bio,
    this.bubbleColor,
    this.isBot = false,
    this.publicDiscovery = true,
    this.role = 'user',
    this.isFlaggedScammer = false,
    this.isBanned = false,
    this.allowGroupAdd = true,
    required this.createdAt,
    this.lastSeen,
    this.premiumUntil,
    this.publicKeyExpiresAt,
  });

  factory User.fromJson(Map<String, dynamic> json) => User(
    id: json['id'] as String,
    username: json['username'] as String,
    profileDisplayName: json['display_name'] as String?,
    publicKey: json['public_key'] as String? ?? '',
    keyFingerprint: json['key_fingerprint'] as String? ?? '',
    avatarUrl: json['avatar_url'] as String?,
    bio: json['bio'] as String?,
    bubbleColor: _parseBubbleColor(json['bubble_color']),
    isBot: json['is_bot'] as bool? ?? false,
    publicDiscovery: json['public_discovery'] as bool? ?? true,
    role: json['role'] as String? ?? 'user',
    isFlaggedScammer: json['is_flagged_scammer'] as bool? ?? false,
    isBanned: json['is_banned'] as bool? ?? false,
    allowGroupAdd: json['allow_group_add'] as bool? ?? true,
    createdAt: DateTime.parse(json['created_at'] as String),
    lastSeen: json['last_seen'] != null
        ? DateTime.parse(json['last_seen'] as String)
        : null,
    premiumUntil: json['premium_until'] != null
        ? DateTime.parse(json['premium_until'] as String)
        : null,
    publicKeyExpiresAt: json['public_key_expires_at'] != null
        ? DateTime.parse(json['public_key_expires_at'] as String)
        : null,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'username': username,
    if (profileDisplayName != null) 'display_name': profileDisplayName,
    'public_key': publicKey,
    'key_fingerprint': keyFingerprint,
    if (avatarUrl != null) 'avatar_url': avatarUrl,
    if (bio != null) 'bio': bio,
    if (bubbleColor != null) 'bubble_color': bubbleColorToJson(bubbleColor!),
    'is_bot': isBot,
    'public_discovery': publicDiscovery,
    'role': role,
    'is_flagged_scammer': isFlaggedScammer,
    'is_banned': isBanned,
    'allow_group_add': allowGroupAdd,
    'created_at': createdAt.toIso8601String(),
    if (lastSeen != null) 'last_seen': lastSeen!.toIso8601String(),
    if (premiumUntil != null) 'premium_until': premiumUntil!.toIso8601String(),
    if (publicKeyExpiresAt != null)
      'public_key_expires_at': publicKeyExpiresAt!.toIso8601String(),
  };

  bool get isSystemAdmin => role == 'system_admin';

  static int? _parseBubbleColor(Object? value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is String && RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(value)) {
      return int.parse('FF${value.substring(1)}', radix: 16);
    }
    return null;
  }

  static String bubbleColorToJson(int color) =>
      '#${(color & 0x00FFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  /// Active premium subscription if premium_until is set and in the future.
  bool get isPremium =>
      premiumUntil != null && premiumUntil!.isAfter(DateTime.now());

  /// True when the PGP key's lifetime has elapsed. Such users cannot send
  /// or receive messages until they rotate.
  bool get isKeyExpired =>
      publicKeyExpiresAt != null &&
      !DateTime.now().isBefore(publicKeyExpiresAt!);

  bool get isOnline {
    if (lastSeen == null) return false;
    return DateTime.now().difference(lastSeen!).inMinutes < 5;
  }

  String get handle => username.isEmpty ? '' : '@$username';

  String get shortId => id.length >= 8 ? id.substring(0, 8) : id;

  String get displayName {
    final name = profileDisplayName?.trim();
    if (name != null && name.isNotEmpty) return name;
    return username.isNotEmpty ? '@$username' : 'User $shortId';
  }

  String get avatarInitial {
    final name = profileDisplayName?.trim();
    if (name != null && name.isNotEmpty) return name[0].toUpperCase();
    return username.isNotEmpty
        ? username[0].toUpperCase()
        : (id.isNotEmpty ? id[0].toUpperCase() : 'U');
  }

  // Short fingerprint for display (last 8 chars)
  String get shortFingerprint => keyFingerprint.length >= 8
      ? keyFingerprint.substring(keyFingerprint.length - 8)
      : keyFingerprint;

  User copyWith({
    String? avatarUrl,
    String? profileDisplayName,
    String? bio,
    int? bubbleColor,
    bool? isFlaggedScammer,
    bool? isBanned,
    bool? allowGroupAdd,
    bool? publicDiscovery,
    DateTime? premiumUntil,
    DateTime? lastSeen,
  }) => User(
    id: id,
    username: username,
    profileDisplayName: profileDisplayName ?? this.profileDisplayName,
    publicKey: publicKey,
    keyFingerprint: keyFingerprint,
    avatarUrl: avatarUrl ?? this.avatarUrl,
    bio: bio ?? this.bio,
    bubbleColor: bubbleColor ?? this.bubbleColor,
    isBot: isBot,
    publicDiscovery: publicDiscovery ?? this.publicDiscovery,
    role: role,
    isFlaggedScammer: isFlaggedScammer ?? this.isFlaggedScammer,
    isBanned: isBanned ?? this.isBanned,
    allowGroupAdd: allowGroupAdd ?? this.allowGroupAdd,
    createdAt: createdAt,
    lastSeen: lastSeen ?? this.lastSeen,
    premiumUntil: premiumUntil ?? this.premiumUntil,
    publicKeyExpiresAt: publicKeyExpiresAt,
  );
}
