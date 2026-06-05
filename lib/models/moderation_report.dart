class ModerationReport {
  final String id;
  final String conversationId;
  final String? messageId;
  final String reporterUserId;
  final String? reportedUserId;
  final String reason;
  final String status;
  final String? resolvedBy;
  final DateTime? resolvedAt;
  final DateTime createdAt;
  final String? reporterUsername;
  final String? reportedUsername;
  final String? resolverUsername;

  const ModerationReport({
    required this.id,
    required this.conversationId,
    this.messageId,
    required this.reporterUserId,
    this.reportedUserId,
    this.reason = '',
    this.status = 'open',
    this.resolvedBy,
    this.resolvedAt,
    required this.createdAt,
    this.reporterUsername,
    this.reportedUsername,
    this.resolverUsername,
  });

  factory ModerationReport.fromJson(Map<String, dynamic> json) =>
      ModerationReport(
        id: json['id'] as String,
        conversationId: json['conversation_id'] as String,
        messageId: json['message_id'] as String?,
        reporterUserId: json['reporter_user_id'] as String,
        reportedUserId: json['reported_user_id'] as String?,
        reason: json['reason'] as String? ?? '',
        status: json['status'] as String? ?? 'open',
        resolvedBy: json['resolved_by'] as String?,
        resolvedAt: json['resolved_at'] != null
            ? DateTime.parse(json['resolved_at'] as String)
            : null,
        createdAt: DateTime.parse(json['created_at'] as String),
        reporterUsername: json['reporter_username'] as String?,
        reportedUsername: json['reported_username'] as String?,
        resolverUsername: json['resolver_username'] as String?,
      );
}
