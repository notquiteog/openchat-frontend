import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/recent_nearby_peer.dart';
import 'package:openchat/services/mesh/mesh_session.dart';
import 'package:openchat/services/mesh/nearby_mesh_service.dart';
import 'package:openchat/services/secure_storage_service.dart';

NearbyMeshService _service(SecureStorageService storage) => NearbyMeshService(
  storage: storage,
  onEnvelope: (envelope, fingerprint) async => true,
  envelopesForPeer: (fingerprint) async => const [],
  contactNameForFingerprint: (fingerprint) => null,
);

MeshPeer _peer(
  String fingerprint, {
  String displayName = 'Peer',
  String userId = '',
  String publicKeyArmored = 'PUBLIC-KEY',
}) {
  return MeshPeer(
    sessionId: 'session-$fingerprint',
    fingerprint: fingerprint,
    publicKeyArmored: publicKeyArmored,
    displayName: displayName,
    userId: userId,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test(
    'remembering is opt-in and upserts verified peers by fingerprint',
    () async {
      final storage = SecureStorageService();
      final service = _service(storage);

      await service.debugRememberRecentPeer(
        _peer('aa bb', displayName: 'Alice', userId: 'user-a'),
        isLan: true,
      );
      expect(await service.recentPeers(), isEmpty);

      service.historyEnabled = true;
      await service.debugRememberRecentPeer(
        _peer('aa bb', displayName: 'Alice', userId: 'user-a'),
        isLan: true,
      );

      var peers = await service.recentPeers();
      expect(peers, hasLength(1));
      expect(peers.single.fingerprint, 'AABB');
      expect(peers.single.transport, recentNearbyTransportLan);
      expect(peers.single.userId, 'user-a');

      await service.debugRememberRecentPeer(
        _peer('AABB', displayName: 'Alice nearby', publicKeyArmored: ''),
        isLan: false,
      );

      peers = await service.recentPeers();
      expect(peers, hasLength(1));
      expect(peers.single.displayName, 'Alice nearby');
      expect(peers.single.transport, recentNearbyTransportBle);
      expect(peers.single.userId, 'user-a');
      expect(peers.single.publicKeyArmored, 'PUBLIC-KEY');
    },
  );

  test(
    'history is capped, forgettable, clearable, and not cleared by stop',
    () async {
      final storage = SecureStorageService();
      final service = _service(storage)..historyEnabled = true;

      for (var i = 0; i < 55; i++) {
        await service.debugRememberRecentPeer(
          _peer(
            'fp-${i.toString().padLeft(2, '0')}',
            displayName: 'Peer $i',
            userId: 'user-$i',
          ),
          isLan: i.isEven,
        );
      }

      var peers = await service.recentPeers();
      expect(peers, hasLength(50));

      await service.stop();
      peers = await service.recentPeers();
      expect(peers, hasLength(50));

      await service.forgetRecentPeer(peers.first.fingerprint);
      peers = await service.recentPeers();
      expect(peers, hasLength(49));

      await service.clearRecentPeers();
      expect(await service.recentPeers(), isEmpty);
    },
  );
}
