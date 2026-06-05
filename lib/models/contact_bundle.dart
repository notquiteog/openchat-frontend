import 'user.dart';

class ContactBundle {
  final int version;
  final String userId;
  final String username;
  final String displayName;
  final String publicKey;
  final String keyFingerprint;
  final String safetyNumber;
  final Map<String, dynamic> mailboxBootstrap;
  final DateTime addedAt;

  const ContactBundle({
    this.version = 1,
    required this.userId,
    this.username = '',
    required this.displayName,
    required this.publicKey,
    required this.keyFingerprint,
    required this.safetyNumber,
    this.mailboxBootstrap = const {},
    required this.addedAt,
  });

  factory ContactBundle.fromUser(User user) {
    return ContactBundle(
      userId: user.id,
      username: user.username,
      displayName: user.displayName,
      publicKey: user.publicKey,
      keyFingerprint: user.keyFingerprint,
      safetyNumber: user.keyFingerprint,
      mailboxBootstrap: {
        'type': 'openchat_user',
        'user_id': user.id,
        'public_key_endpoint': '/api/v1/users/${user.id}/public-key',
      },
      addedAt: DateTime.now(),
    );
  }

  factory ContactBundle.fromJson(Map<String, dynamic> json) {
    final userId = json['user_id']?.toString() ?? '';
    final username = json['username']?.toString() ?? '';
    final fingerprint = json['key_fingerprint']?.toString() ?? '';
    final rawDisplayName = json['display_name']?.toString();
    final displayName = rawDisplayName?.trim();
    final addedAtMs = json['added_at_ms'] as int?;
    return ContactBundle(
      version: json['version'] as int? ?? 1,
      userId: userId,
      username: username,
      displayName: displayName == null || displayName.isEmpty
          ? (username.isNotEmpty
                ? '@$username'
                : 'User ${userId.length >= 8 ? userId.substring(0, 8) : userId}')
          : displayName,
      publicKey: json['public_key']?.toString() ?? '',
      keyFingerprint: fingerprint,
      safetyNumber: json['safety_number']?.toString() ?? fingerprint,
      mailboxBootstrap: Map<String, dynamic>.from(
        json['mailbox_bootstrap'] as Map? ?? const {},
      ),
      addedAt: addedAtMs == null
          ? DateTime.now()
          : DateTime.fromMillisecondsSinceEpoch(
              addedAtMs,
              isUtc: true,
            ).toLocal(),
    );
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'user_id': userId,
    if (username.isNotEmpty) 'username': username,
    'display_name': displayName,
    'public_key': publicKey,
    'key_fingerprint': keyFingerprint,
    'safety_number': safetyNumber,
    if (mailboxBootstrap.isNotEmpty) 'mailbox_bootstrap': mailboxBootstrap,
    'added_at_ms': addedAt.toUtc().millisecondsSinceEpoch,
  };

  bool get isUsable =>
      userId.isNotEmpty && publicKey.isNotEmpty && keyFingerprint.isNotEmpty;

  String get title => displayName.isNotEmpty
      ? displayName
      : (username.isNotEmpty ? '@$username' : userId);
}
