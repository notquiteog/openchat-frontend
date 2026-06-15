class SystemAdminAuditEvent {
  final String id;
  final String? actorUserId;
  final String? targetUserId;
  final String action;
  final Map<String, dynamic> metadata;
  final DateTime createdAt;
  final String? actorUsername;
  final String? targetUsername;

  const SystemAdminAuditEvent({
    required this.id,
    this.actorUserId,
    this.targetUserId,
    required this.action,
    this.metadata = const {},
    required this.createdAt,
    this.actorUsername,
    this.targetUsername,
  });

  factory SystemAdminAuditEvent.fromJson(Map<String, dynamic> json) {
    final rawMetadata = json['metadata'];
    return SystemAdminAuditEvent(
      id: json['id'] as String,
      actorUserId: json['actor_user_id'] as String?,
      targetUserId: json['target_user_id'] as String?,
      action: json['action'] as String,
      metadata: rawMetadata is Map
          ? Map<String, dynamic>.from(rawMetadata)
          : const {},
      createdAt: DateTime.parse(json['created_at'] as String),
      actorUsername: json['actor_username'] as String?,
      targetUsername: json['target_username'] as String?,
    );
  }

  String get actorLabel =>
      actorUsername == null ? 'Unknown admin' : '@$actorUsername';

  String get targetLabel {
    if (targetUsername != null) return '@$targetUsername';
    if (targetUserId != null && targetUserId!.length >= 8) {
      return targetUserId!.substring(0, 8);
    }
    return 'system';
  }
}
