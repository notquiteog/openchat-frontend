class ChatFolder {
  final String id;
  final String userId;
  final String name;
  final int position;
  final bool includeArchived;
  final List<String> conversationIds;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const ChatFolder({
    required this.id,
    required this.userId,
    required this.name,
    this.position = 0,
    this.includeArchived = false,
    this.conversationIds = const [],
    this.createdAt,
    this.updatedAt,
  });

  ChatFolder copyWith({
    String? id,
    String? userId,
    String? name,
    int? position,
    bool? includeArchived,
    List<String>? conversationIds,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => ChatFolder(
    id: id ?? this.id,
    userId: userId ?? this.userId,
    name: name ?? this.name,
    position: position ?? this.position,
    includeArchived: includeArchived ?? this.includeArchived,
    conversationIds: conversationIds ?? this.conversationIds,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  factory ChatFolder.fromJson(Map<String, dynamic> json) => ChatFolder(
    id: json['id'] as String? ?? '',
    userId: json['user_id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    position: json['position'] as int? ?? 0,
    includeArchived: json['include_archived'] as bool? ?? false,
    conversationIds: (json['conversation_ids'] as List? ?? const [])
        .map((id) => id.toString())
        .where((id) => id.isNotEmpty)
        .toList(),
    createdAt: _parseDate(json['created_at']),
    updatedAt: _parseDate(json['updated_at']),
  );

  Map<String, dynamic> toUpsertJson() => {
    if (id.isNotEmpty) 'id': id,
    'name': name.trim(),
    'position': position,
    'include_archived': includeArchived,
    'conversation_ids': conversationIds,
  };

  static DateTime? _parseDate(Object? raw) {
    if (raw is String && raw.isNotEmpty) {
      return DateTime.tryParse(raw)?.toLocal();
    }
    return null;
  }
}
