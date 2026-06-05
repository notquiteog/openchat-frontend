class KeyTrustPin {
  final String userId;
  final String fingerprint;
  final String publicKeyHash;
  final String? eventHash;
  final String? warning;
  final DateTime pinnedAt;

  const KeyTrustPin({
    required this.userId,
    required this.fingerprint,
    required this.publicKeyHash,
    this.eventHash,
    this.warning,
    required this.pinnedAt,
  });

  factory KeyTrustPin.fromJson(Map<String, dynamic> json) {
    final pinnedAtMs = json['pinned_at_ms'] as int?;
    return KeyTrustPin(
      userId: json['user_id']?.toString() ?? '',
      fingerprint: json['fingerprint']?.toString() ?? '',
      publicKeyHash: json['public_key_hash']?.toString() ?? '',
      eventHash: json['event_hash'] as String?,
      warning: json['warning'] as String?,
      pinnedAt: pinnedAtMs == null
          ? DateTime.now()
          : DateTime.fromMillisecondsSinceEpoch(
              pinnedAtMs,
              isUtc: true,
            ).toLocal(),
    );
  }

  Map<String, dynamic> toJson() => {
    'user_id': userId,
    'fingerprint': fingerprint,
    'public_key_hash': publicKeyHash,
    if (eventHash != null) 'event_hash': eventHash,
    if (warning != null) 'warning': warning,
    'pinned_at_ms': pinnedAt.toUtc().millisecondsSinceEpoch,
  };
}
