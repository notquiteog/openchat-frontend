class ChatFolderRules {
  final bool enabled;
  final bool unreadOnly;
  final bool mentionsOnly;
  final bool dms;
  final bool groups;
  final bool channels;
  final bool bots;
  final bool mutedOnly;
  final bool archivedOnly;
  final bool paymentsOnly;

  const ChatFolderRules({
    this.enabled = false,
    this.unreadOnly = false,
    this.mentionsOnly = false,
    this.dms = false,
    this.groups = false,
    this.channels = false,
    this.bots = false,
    this.mutedOnly = false,
    this.archivedOnly = false,
    this.paymentsOnly = false,
  });

  bool get hasTypeRule => dms || groups || channels || bots;

  bool get hasAnyRule =>
      enabled &&
      (unreadOnly ||
          mentionsOnly ||
          hasTypeRule ||
          mutedOnly ||
          archivedOnly ||
          paymentsOnly);

  ChatFolderRules copyWith({
    bool? enabled,
    bool? unreadOnly,
    bool? mentionsOnly,
    bool? dms,
    bool? groups,
    bool? channels,
    bool? bots,
    bool? mutedOnly,
    bool? archivedOnly,
    bool? paymentsOnly,
  }) => ChatFolderRules(
    enabled: enabled ?? this.enabled,
    unreadOnly: unreadOnly ?? this.unreadOnly,
    mentionsOnly: mentionsOnly ?? this.mentionsOnly,
    dms: dms ?? this.dms,
    groups: groups ?? this.groups,
    channels: channels ?? this.channels,
    bots: bots ?? this.bots,
    mutedOnly: mutedOnly ?? this.mutedOnly,
    archivedOnly: archivedOnly ?? this.archivedOnly,
    paymentsOnly: paymentsOnly ?? this.paymentsOnly,
  );

  factory ChatFolderRules.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const ChatFolderRules();
    return ChatFolderRules(
      enabled: json['enabled'] as bool? ?? false,
      unreadOnly: json['unread_only'] as bool? ?? false,
      mentionsOnly: json['mentions_only'] as bool? ?? false,
      dms: json['dms'] as bool? ?? false,
      groups: json['groups'] as bool? ?? false,
      channels: json['channels'] as bool? ?? false,
      bots: json['bots'] as bool? ?? false,
      mutedOnly: json['muted_only'] as bool? ?? false,
      archivedOnly: json['archived_only'] as bool? ?? false,
      paymentsOnly: json['payments_only'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    if (unreadOnly) 'unread_only': true,
    if (mentionsOnly) 'mentions_only': true,
    if (dms) 'dms': true,
    if (groups) 'groups': true,
    if (channels) 'channels': true,
    if (bots) 'bots': true,
    if (mutedOnly) 'muted_only': true,
    if (archivedOnly) 'archived_only': true,
    if (paymentsOnly) 'payments_only': true,
  };
}

class ChatFolder {
  final String id;
  final String userId;
  final String name;
  final int position;
  final bool includeArchived;
  final List<String> conversationIds;
  final ChatFolderRules rules;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const ChatFolder({
    required this.id,
    required this.userId,
    required this.name,
    this.position = 0,
    this.includeArchived = false,
    this.conversationIds = const [],
    this.rules = const ChatFolderRules(),
    this.createdAt,
    this.updatedAt,
  });

  bool get isRuleBased => rules.hasAnyRule;

  ChatFolder copyWith({
    String? id,
    String? userId,
    String? name,
    int? position,
    bool? includeArchived,
    List<String>? conversationIds,
    ChatFolderRules? rules,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => ChatFolder(
    id: id ?? this.id,
    userId: userId ?? this.userId,
    name: name ?? this.name,
    position: position ?? this.position,
    includeArchived: includeArchived ?? this.includeArchived,
    conversationIds: conversationIds ?? this.conversationIds,
    rules: rules ?? this.rules,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  factory ChatFolder.fromJson(Map<String, dynamic> json) => ChatFolder(
    id: json['id'] as String? ?? '',
    userId: json['user_id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    position: (json['position'] as num?)?.toInt() ?? 0,
    includeArchived: json['include_archived'] as bool? ?? false,
    conversationIds: (json['conversation_ids'] as List? ?? const [])
        .map((id) => id.toString())
        .where((id) => id.isNotEmpty)
        .toList(),
    rules: ChatFolderRules.fromJson(
      json['rules'] is Map
          ? Map<String, dynamic>.from(json['rules'] as Map)
          : null,
    ),
    createdAt: _parseDate(json['created_at']),
    updatedAt: _parseDate(json['updated_at']),
  );

  Map<String, dynamic> toJson() => {
    if (id.isNotEmpty) 'id': id,
    if (userId.isNotEmpty) 'user_id': userId,
    'name': name.trim(),
    'position': position,
    'include_archived': includeArchived,
    'conversation_ids': conversationIds,
    if (rules.hasAnyRule) 'rules': rules.toJson(),
    if (createdAt != null) 'created_at': createdAt!.toUtc().toIso8601String(),
    if (updatedAt != null) 'updated_at': updatedAt!.toUtc().toIso8601String(),
  };

  static DateTime? _parseDate(Object? raw) {
    if (raw is String && raw.isNotEmpty) {
      return DateTime.tryParse(raw)?.toLocal();
    }
    return null;
  }
}
