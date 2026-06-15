import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/recent_nearby_peer.dart';
import 'package:openchat/services/mesh/mesh_session.dart';
import 'package:openchat/services/secure_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('model normalizes, round-trips, and builds contact bundle', () {
    final lastSeen = DateTime.utc(2026, 6, 15, 12, 30);
    final peer = RecentNearbyPeer.fromMeshPeer(
      const MeshPeer(
        sessionId: 'session-1',
        fingerprint: 'aa bb cc dd',
        publicKeyArmored: 'PUBLIC-KEY',
        displayName: ' Alice ',
        userId: 'user-a',
      ),
      transport: recentNearbyTransportLan,
      lastSeenAt: lastSeen,
    );

    expect(peer.fingerprint, 'AABBCCDD');
    expect(peer.displayName, 'Alice');
    expect(peer.transport, recentNearbyTransportLan);
    expect(peer.canSaveAsContact, isTrue);

    final decoded = RecentNearbyPeer.fromJson(peer.toJson());
    expect(decoded.fingerprint, peer.fingerprint);
    expect(decoded.transport, peer.transport);
    expect(
      decoded.lastSeenAt.toUtc().millisecondsSinceEpoch,
      lastSeen.millisecondsSinceEpoch,
    );

    final contact = peer.toContactBundle();
    expect(contact.userId, 'user-a');
    expect(contact.displayName, 'Alice');
    expect(contact.publicKey, 'PUBLIC-KEY');
    expect(contact.keyFingerprint, 'AABBCCDD');
    expect(
      contact.mailboxBootstrap['public_key_endpoint'],
      '/api/v1/users/user-a/public-key',
    );
  });

  test('storage persists opt-in and sorted peer list', () async {
    final storage = SecureStorageService();
    expect(await storage.getRecentNearbyEnabled(), isFalse);

    await storage.setRecentNearbyEnabled(true);
    expect(await storage.getRecentNearbyEnabled(), isTrue);

    await storage.saveRecentNearbyPeers([
      RecentNearbyPeer(
        fingerprint: 'OLDER',
        displayName: 'Older',
        transport: recentNearbyTransportBle,
        lastSeenAt: DateTime.utc(2026, 6, 14),
      ),
      RecentNearbyPeer(
        fingerprint: 'NEWER',
        displayName: 'Newer',
        transport: recentNearbyTransportLan,
        lastSeenAt: DateTime.utc(2026, 6, 15),
      ),
    ]);

    final peers = await storage.getRecentNearbyPeers();
    expect(peers.map((peer) => peer.fingerprint), ['NEWER', 'OLDER']);

    await storage.clearRecentNearbyPeers();
    expect(await storage.getRecentNearbyPeers(), isEmpty);
  });

  test(
    'recent nearby keys never travel in recovery import or export',
    () async {
      final storage = SecureStorageService();
      await storage.setRecentNearbyEnabled(true);
      await storage.saveRecentNearbyPeers([
        RecentNearbyPeer(
          fingerprint: 'LOCALONLY',
          displayName: 'Local only',
          transport: recentNearbyTransportBle,
          lastSeenAt: DateTime.utc(2026, 6, 15),
        ),
      ]);

      final exported = await storage.exportRecoverySecrets();
      expect(exported.keys, isNot(contains('recent_nearby_peers_v1')));
      expect(
        exported.keys,
        isNot(contains('recent_nearby_history_enabled_v1')),
      );

      FlutterSecureStorage.setMockInitialValues({});
      final restored = SecureStorageService();
      await restored.importRecoverySecrets({
        'pgp_fingerprint': 'RECOVERED',
        'recent_nearby_history_enabled_v1': 'true',
        'recent_nearby_peers_v1': '[{"fingerprint":"IMPORTED"}]',
      });

      expect(await restored.getFingerprint(), 'RECOVERED');
      expect(await restored.getRecentNearbyEnabled(), isFalse);
      expect(await restored.getRecentNearbyPeers(), isEmpty);
    },
  );
}
