import 'conversation.dart';
import 'user.dart';
import '../utils/invite_links.dart';

class ConversationInviteLink {
  final String id;
  final String conversationId;
  final String token;
  final String createdBy;
  final bool approvalRequired;
  final DateTime? revokedAt;
  final DateTime createdAt;

  const ConversationInviteLink({
    required this.id,
    required this.conversationId,
    required this.token,
    required this.createdBy,
    this.approvalRequired = false,
    this.revokedAt,
    required this.createdAt,
  });

  factory ConversationInviteLink.fromJson(Map<String, dynamic> json) =>
      ConversationInviteLink(
        id: json['id'] as String,
        conversationId: json['conversation_id'] as String,
        token: json['token'] as String,
        createdBy: json['created_by'] as String,
        approvalRequired: json['approval_required'] as bool? ?? false,
        revokedAt: json['revoked_at'] != null
            ? DateTime.parse(json['revoked_at'] as String)
            : null,
        createdAt: DateTime.parse(json['created_at'] as String),
      );

  String get inviteUri => inviteDeepLink(token: token);
}

class ConversationJoinRequest {
  final String conversationId;
  final String userId;
  final DateTime requestedAt;
  final String status;
  final String? reviewedBy;
  final DateTime? reviewedAt;
  final User? user;

  const ConversationJoinRequest({
    required this.conversationId,
    required this.userId,
    required this.requestedAt,
    required this.status,
    this.reviewedBy,
    this.reviewedAt,
    this.user,
  });

  factory ConversationJoinRequest.fromJson(Map<String, dynamic> json) =>
      ConversationJoinRequest(
        conversationId: json['conversation_id'] as String,
        userId: json['user_id'] as String,
        requestedAt: DateTime.parse(json['requested_at'] as String),
        status: json['status'] as String? ?? 'pending',
        reviewedBy: json['reviewed_by'] as String?,
        reviewedAt: json['reviewed_at'] != null
            ? DateTime.parse(json['reviewed_at'] as String)
            : null,
        user: json['user'] != null
            ? User.fromJson(json['user'] as Map<String, dynamic>)
            : null,
      );
}

class InvitePreview {
  final ConversationInviteLink invite;
  final Conversation conversation;
  final bool member;

  const InvitePreview({
    required this.invite,
    required this.conversation,
    required this.member,
  });

  factory InvitePreview.fromJson(Map<String, dynamic> json) => InvitePreview(
    invite: ConversationInviteLink.fromJson(
      json['invite'] as Map<String, dynamic>,
    ),
    conversation: Conversation.fromJson(
      json['conversation'] as Map<String, dynamic>,
    ),
    member: json['member'] as bool? ?? false,
  );
}

class InviteJoinResult {
  final bool joined;
  final bool alreadyMember;
  final bool pending;
  final Conversation? conversation;

  const InviteJoinResult({
    required this.joined,
    this.alreadyMember = false,
    this.pending = false,
    this.conversation,
  });

  factory InviteJoinResult.fromJson(Map<String, dynamic> json) =>
      InviteJoinResult(
        joined: json['joined'] as bool? ?? false,
        alreadyMember: json['already_member'] as bool? ?? false,
        pending: json['join_request'] == 'pending',
        conversation: json['conversation'] != null
            ? Conversation.fromJson(
                json['conversation'] as Map<String, dynamic>,
              )
            : null,
      );
}
