import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import '../crypto/pgp_service.dart';

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

  /// Signed by the NEW key, binding it to the old key (continuity proof).
  final String? crossoverSignature;
  final String? crossoverScheme;
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
    this.crossoverSignature,
    this.crossoverScheme,
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
      crossoverSignature: json['crossover_signature'] as String?,
      crossoverScheme: json['crossover_scheme'] as String?,
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

/// Cryptographically verifies that a contact's rotation from [oldFingerprint]
/// to [newFingerprint] is continuous, using only the transparency [events] (no
/// server trust): the OLD key must have signed the rotation, AND — when present
/// — the NEW key must have signed the crossover statement binding it to the old
/// key. The crossover is tolerated as absent during rollout. Returns true only
/// when continuity is proven.
Future<bool> verifyRotationContinuity({
  required List<KeyTransparencyEvent> events,
  required String userId,
  required String oldFingerprint,
  required String newFingerprint,
}) async {
  final oldFp = oldFingerprint.trim().toUpperCase();
  final newFp = newFingerprint.trim().toUpperCase();

  KeyTransparencyEvent? rotation;
  String? oldPublicKey;
  for (final e in events) {
    if (e.newKeyFingerprint.toUpperCase() == oldFp) {
      oldPublicKey = e.newPublicKey; // chain's record of the old key
    }
    if (e.eventType == 'rotate' &&
        e.newKeyFingerprint.toUpperCase() == newFp &&
        e.oldKeyFingerprint?.toUpperCase() == oldFp) {
      rotation = e;
    }
  }
  if (rotation == null || oldPublicKey == null) return false;
  final sig = rotation.signature;
  if (sig == null || sig.isEmpty) return false;

  // 1) The OLD key signed the rotation statement.
  final rotationOk = await PgpService.verify(
    data: keyRotationSignatureData(
      userId: userId,
      oldFingerprint: oldFp,
      newFingerprint: newFp,
      newPublicKey: rotation.newPublicKey,
    ),
    signatureArmor: sig,
    signerPublicKeyArmored: oldPublicKey,
  );
  if (!rotationOk) return false;

  // 2) The NEW key signed the crossover statement (tolerated absent in rollout).
  final crossover = rotation.crossoverSignature;
  if (crossover == null || crossover.isEmpty) return true;
  return PgpService.verify(
    data: keyCrossoverSignatureData(
      userId: userId,
      newFingerprint: newFp,
      oldFingerprint: oldFp,
      oldPublicKey: oldPublicKey,
    ),
    signatureArmor: crossover,
    signerPublicKeyArmored: rotation.newPublicKey,
  );
}

const keyCrossoverScheme = 'openchat-key-crossover-v1';

/// The statement the NEW key signs to prove continuity with the OLD key. Must
/// match the backend's `keyCrossoverSignatureData` byte-for-byte.
String keyCrossoverSignatureData({
  required String userId,
  required String newFingerprint,
  required String oldFingerprint,
  required String oldPublicKey,
}) {
  final oldKeyHash = crypto.sha256
      .convert(utf8.encode(oldPublicKey.trim()))
      .toString()
      .toUpperCase();
  return '$keyCrossoverScheme:${userId.trim()}:'
      '${newFingerprint.trim().toUpperCase()}:'
      '${oldFingerprint.trim().toUpperCase()}:$oldKeyHash';
}
