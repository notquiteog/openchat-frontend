class MlsBootstrap {
  final String groupId;
  final String groupInfo;
  final String ratchetTree;
  final int epoch;
  final String signerPublicKey;
  final String signerSignature;

  const MlsBootstrap({
    required this.groupId,
    required this.groupInfo,
    required this.ratchetTree,
    required this.epoch,
    this.signerPublicKey = '',
    this.signerSignature = '',
  });

  Map<String, dynamic> toEncryptionJson() => {
    'mls_group_id': groupId,
    'mls_group_info': groupInfo,
    'mls_ratchet_tree': ratchetTree,
    'mls_epoch': epoch,
    if (signerPublicKey.isNotEmpty) 'mls_signer_public_key': signerPublicKey,
    if (signerSignature.isNotEmpty) 'mls_signer_signature': signerSignature,
  };

  Map<String, dynamic> toCommitJson() => {
    'mls_group_info': groupInfo,
    'mls_ratchet_tree': ratchetTree,
    'mls_epoch': epoch,
    if (signerPublicKey.isNotEmpty) 'mls_signer_public_key': signerPublicKey,
    if (signerSignature.isNotEmpty) 'mls_signer_signature': signerSignature,
  };
}

class ConversationMlsCommit {
  final String id;
  final String conversationId;
  final String senderId;
  final String commitPayload;
  final DateTime createdAt;

  const ConversationMlsCommit({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.commitPayload,
    required this.createdAt,
  });

  factory ConversationMlsCommit.fromJson(Map<String, dynamic> json) =>
      ConversationMlsCommit(
        id: json['id'] as String,
        conversationId: json['conversation_id'] as String,
        senderId: json['sender_id'] as String,
        commitPayload: json['commit_payload'] as String,
        createdAt: DateTime.parse(json['created_at'] as String),
      );
}

class ConversationMlsState {
  final String conversationId;
  final String groupId;
  final String groupInfo;
  final String ratchetTree;
  final int epoch;
  final String signerPublicKey;
  final String signerSignature;
  final List<ConversationMlsCommit> commits;

  const ConversationMlsState({
    required this.conversationId,
    required this.groupId,
    required this.groupInfo,
    required this.ratchetTree,
    required this.epoch,
    this.signerPublicKey = '',
    this.signerSignature = '',
    this.commits = const [],
  });

  factory ConversationMlsState.fromJson(Map<String, dynamic> json) =>
      ConversationMlsState(
        conversationId: json['conversation_id'] as String,
        groupId: json['group_id'] as String,
        groupInfo: json['group_info'] as String,
        ratchetTree: json['ratchet_tree'] as String,
        epoch: (json['epoch'] as num?)?.toInt() ?? 0,
        signerPublicKey: json['signer_public_key'] as String? ?? '',
        signerSignature: json['signer_signature'] as String? ?? '',
        commits: (json['commits'] as List? ?? const [])
            .map(
              (e) => ConversationMlsCommit.fromJson(e as Map<String, dynamic>),
            )
            .toList(),
      );
}
