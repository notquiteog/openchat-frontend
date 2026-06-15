import '../services/mesh/mesh_session.dart';
import 'contact_bundle.dart';

const recentNearbyTransportLan = 'lan';
const recentNearbyTransportBle = 'ble';

String normalizeRecentNearbyFingerprint(String fingerprint) =>
    fingerprint.replaceAll(RegExp(r'\s+'), '').toUpperCase();

class RecentNearbyPeer {
  final String fingerprint;
  final String displayName;
  final String transport;
  final DateTime lastSeenAt;
  final String userId;
  final String publicKeyArmored;

  const RecentNearbyPeer({
    required this.fingerprint,
    required this.displayName,
    required this.transport,
    required this.lastSeenAt,
    this.userId = '',
    this.publicKeyArmored = '',
  });

  factory RecentNearbyPeer.fromMeshPeer(
    MeshPeer peer, {
    required String transport,
    DateTime? lastSeenAt,
  }) {
    return RecentNearbyPeer(
      fingerprint: normalizeRecentNearbyFingerprint(peer.fingerprint),
      displayName: peer.displayName.trim().isNotEmpty
          ? peer.displayName.trim()
          : 'Nearby contact',
      transport: transport == recentNearbyTransportLan
          ? recentNearbyTransportLan
          : recentNearbyTransportBle,
      lastSeenAt: lastSeenAt ?? DateTime.now(),
      userId: peer.userId.trim(),
      publicKeyArmored: peer.publicKeyArmored,
    );
  }

  factory RecentNearbyPeer.fromJson(Map<String, dynamic> json) {
    final rawTransport = json['transport']?.toString();
    final lastSeenMs = json['last_seen_at_ms'];
    return RecentNearbyPeer(
      fingerprint: normalizeRecentNearbyFingerprint(
        json['fingerprint']?.toString() ?? '',
      ),
      displayName: (json['display_name']?.toString() ?? '').trim(),
      transport: rawTransport == recentNearbyTransportLan
          ? recentNearbyTransportLan
          : recentNearbyTransportBle,
      lastSeenAt: lastSeenMs is int
          ? DateTime.fromMillisecondsSinceEpoch(
              lastSeenMs,
              isUtc: true,
            ).toLocal()
          : DateTime.now(),
      userId: (json['user_id']?.toString() ?? '').trim(),
      publicKeyArmored: json['public_key_armored']?.toString() ?? '',
    );
  }

  bool get canSaveAsContact =>
      fingerprint.isNotEmpty &&
      userId.isNotEmpty &&
      publicKeyArmored.isNotEmpty;

  ContactBundle toContactBundle() {
    if (!canSaveAsContact) {
      throw StateError('Recent Nearby peer is missing contact details');
    }
    return ContactBundle(
      userId: userId,
      displayName: displayName.isNotEmpty ? displayName : 'Nearby contact',
      publicKey: publicKeyArmored,
      keyFingerprint: fingerprint,
      safetyNumber: fingerprint,
      mailboxBootstrap: {
        'type': 'openchat_user',
        'user_id': userId,
        'public_key_endpoint': '/api/v1/users/$userId/public-key',
      },
      addedAt: DateTime.now(),
    );
  }

  RecentNearbyPeer copyWith({
    String? fingerprint,
    String? displayName,
    String? transport,
    DateTime? lastSeenAt,
    String? userId,
    String? publicKeyArmored,
  }) {
    return RecentNearbyPeer(
      fingerprint: fingerprint ?? this.fingerprint,
      displayName: displayName ?? this.displayName,
      transport: transport ?? this.transport,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      userId: userId ?? this.userId,
      publicKeyArmored: publicKeyArmored ?? this.publicKeyArmored,
    );
  }

  Map<String, dynamic> toJson() => {
    'fingerprint': fingerprint,
    'display_name': displayName,
    'transport': transport,
    'last_seen_at_ms': lastSeenAt.toUtc().millisecondsSinceEpoch,
    if (userId.isNotEmpty) 'user_id': userId,
    if (publicKeyArmored.isNotEmpty) 'public_key_armored': publicKeyArmored,
  };
}
