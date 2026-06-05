import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

class KeyTransparencyEvent {
  final String id;
  final String userId;
  final int sequence;
  final String eventType;
  final String? oldKeyFingerprint;
  final String newKeyFingerprint;
  final String newPublicKey;
  final String? previousEventHash;
  final String eventHash;
  final String? signature;
  final DateTime createdAt;

  const KeyTransparencyEvent({
    required this.id,
    required this.userId,
    required this.sequence,
    required this.eventType,
    this.oldKeyFingerprint,
    required this.newKeyFingerprint,
    required this.newPublicKey,
    this.previousEventHash,
    required this.eventHash,
    this.signature,
    required this.createdAt,
  });

  factory KeyTransparencyEvent.fromJson(Map<String, dynamic> json) {
    return KeyTransparencyEvent(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      sequence: (json['sequence'] as num).toInt(),
      eventType: json['event_type'] as String,
      oldKeyFingerprint: json['old_key_fingerprint'] as String?,
      newKeyFingerprint: json['new_key_fingerprint'] as String,
      newPublicKey: json['new_public_key'] as String,
      previousEventHash: json['previous_event_hash'] as String?,
      eventHash: json['event_hash'] as String,
      signature: json['signature'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  bool explainsRotation({
    required String oldFingerprint,
    required String newFingerprint,
  }) {
    return eventType == 'rotate' &&
        oldKeyFingerprint?.toUpperCase() == oldFingerprint.toUpperCase() &&
        newKeyFingerprint.toUpperCase() == newFingerprint.toUpperCase() &&
        signature != null &&
        signature!.isNotEmpty;
  }
}

String keyRotationSignatureData({
  required String userId,
  required String oldFingerprint,
  required String newFingerprint,
  required String newPublicKey,
}) {
  final publicKeyHash = crypto.sha256
      .convert(utf8.encode(newPublicKey.trim()))
      .toString()
      .toUpperCase();
  return 'openchat-key-rotation-v1:${userId.trim()}:'
      '${oldFingerprint.trim().toUpperCase()}:'
      '${newFingerprint.trim().toUpperCase()}:$publicKeyHash';
}
