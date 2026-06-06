import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/crypto/pgp_service.dart';
import 'package:openchat/models/conversation.dart';
import 'package:openchat/models/user.dart';
import 'package:openchat/services/api_service.dart';
import 'package:openchat/services/call_signal_codec.dart';
import 'package:openchat/services/mls_service.dart';
import 'package:openchat/services/secure_storage_service.dart';

void main() {
  setUpAll(_ensureOpenPgpBridgeForUnitTests);

  test(
    'PGP call signal encrypts LiveKit room details outside ciphertext',
    () async {
      final keyPair = await PgpService.generateKeyPair(username: 'alice');
      final storage = _FakeSecureStorage(
        userId: 'alice-id',
        privateKey: keyPair.privateKeyArmored,
        publicKey: keyPair.publicKeyArmored,
        fingerprint: keyPair.fingerprint,
      );
      final member = _member(
        userId: 'alice-id',
        username: 'alice',
        publicKey: keyPair.publicKeyArmored,
        fingerprint: keyPair.fingerprint,
        avatarUrl: 'https://example.test/alice.png',
      );
      final conversation = _conversation(
        encryptionMode: EncryptionMode.pgp,
        members: [member],
      );
      final codec = PrivacyCallSignalCodec(
        _FakeApiService(storage, conversation: conversation, members: [member]),
        storage,
        _FakeMlsService(storage),
      );

      final encoded = await codec.encode(
        CallSignalPayload(
          kind: 'offer',
          targetUserId: 'bob-id',
          callId: 'call-1',
          conversationId: conversation.id,
          callerId: 'alice-id',
          isVideo: true,
          roomName: 'call_11111111-1111-4111-8111-111111111111',
          participantUserIds: const ['bob-id', 'carol-id'],
        ),
      );

      expect(encoded['encrypted_signal'], isA<String>());
      for (final key in [
        'room_name',
        'participant_user_ids',
        'is_video',
        'caller_id',
      ]) {
        expect(encoded.containsKey(key), isFalse);
      }

      final decoded = await codec.decode(encoded);
      expect(decoded?['call_id'], 'call-1');
      expect(decoded?['caller_id'], 'alice-id');
      expect(decoded?['caller_username'], 'alice');
      expect(decoded?['caller_avatar'], 'https://example.test/alice.png');
      expect(decoded?['is_video'], isTrue);
      expect(
        decoded?['room_name'],
        'call_11111111-1111-4111-8111-111111111111',
      );
      expect(decoded?['participant_user_ids'], ['bob-id', 'carol-id']);
    },
  );

  test(
    'locked key returns partial result so a ring notification still fires',
    () async {
      final storage = _FakeSecureStorage(
        userId: 'bob-id',
        privateKey: '', // locked
        publicKey: 'public-key',
        fingerprint: 'fingerprint',
      );
      final conversation = _conversation(encryptionMode: EncryptionMode.pgp);
      final codec = PrivacyCallSignalCodec(
        _FakeApiService(storage, conversation: conversation),
        storage,
        _FakeMlsService(storage),
      );

      // Simulate an encrypted call offer arriving while the key is locked.
      final incomingEnvelope = {
        'call_id': 'call-99',
        'conversation_id': conversation.id,
        'encrypted_signal': 'opaque-ciphertext',
        'encryption_mode': 'pgp',
      };

      final decoded = await codec.decode(incomingEnvelope);
      // Must be non-null so handleIncomingCallPayload fires a notification.
      expect(decoded, isNotNull);
      expect(decoded!['call_id'], 'call-99');
      // Privacy: caller identity and room details must stay hidden.
      expect(decoded.containsKey('caller_id'), isFalse);
      expect(decoded.containsKey('room_name'), isFalse);
      expect(decoded.containsKey('is_video'), isFalse);
    },
  );

  test(
    'MLS call signal encrypts LiveKit room details and keeps outer payload generic',
    () async {
      final storage = _FakeSecureStorage(
        userId: 'alice-id',
        username: 'alice',
        privateKey: 'unlocked-pgp-key',
        publicKey: 'public-key',
        fingerprint: 'fingerprint',
      );
      final conversation = _conversation(encryptionMode: EncryptionMode.mls);
      final codec = PrivacyCallSignalCodec(
        _FakeApiService(storage, conversation: conversation),
        storage,
        _FakeMlsService(storage),
      );

      final encoded = await codec.encode(
        CallSignalPayload(
          kind: 'offer',
          targetUserId: 'bob-id',
          callId: 'call-2',
          conversationId: conversation.id,
          callerId: 'alice-id',
          isVideo: false,
          roomName: 'call_22222222-2222-4222-8222-222222222222',
          participantUserIds: const ['bob-id'],
        ),
      );

      expect(encoded['encryption_mode'], 'mls');
      expect(encoded['encrypted_signal'], isA<String>());
      for (final key in [
        'room_name',
        'participant_user_ids',
        'is_video',
        'caller_id',
      ]) {
        expect(encoded.containsKey(key), isFalse);
      }

      final decoded = await codec.decode(encoded);
      expect(decoded?['call_id'], 'call-2');
      expect(decoded?['caller_username'], 'alice');
      expect(
        decoded?['room_name'],
        'call_22222222-2222-4222-8222-222222222222',
      );
      expect(decoded?['participant_user_ids'], ['bob-id']);
    },
  );
}

Future<void> _ensureOpenPgpBridgeForUnitTests() async {
  final target = _openPgpBridgeTestTarget();
  if (target == null || target.existsSync()) return;

  final source = await _bundledOpenPgpBridge();
  if (source == null || !source.existsSync()) return;

  await target.parent.create(recursive: true);
  await source.copy(target.path);
}

File? _openPgpBridgeTestTarget() {
  if (Platform.isLinux) {
    final arch = Platform.resolvedExecutable.contains('x64') ? 'x64' : 'arm64';
    return File('build/linux/$arch/debug/bundle/lib/libopenpgp_bridge.so');
  }
  if (Platform.isWindows) {
    final arch = Platform.resolvedExecutable.contains('x64') ? 'x64' : 'arm64';
    return File('build/windows/$arch/runner/Debug/libopenpgp_bridge.dll');
  }
  if (Platform.isMacOS) {
    return File(
      'build/macos/Build/Products/Debug/Contents/Frameworks/'
      'libopenpgp_bridge.dylib',
    );
  }
  return null;
}

Future<File?> _bundledOpenPgpBridge() async {
  final packageRoot = await _packageRoot('openpgp');
  if (packageRoot == null) return null;

  if (Platform.isLinux) {
    final arch = Platform.resolvedExecutable.contains('x64')
        ? 'x86_64'
        : 'aarch64';
    return File('${packageRoot.path}/linux/shared/$arch/libopenpgp_bridge.so');
  }
  if (Platform.isWindows) {
    return File('${packageRoot.path}/windows/shared/libopenpgp_bridge.dll');
  }
  if (Platform.isMacOS) {
    return File('${packageRoot.path}/macos/libopenpgp_bridge.dylib');
  }
  return null;
}

Future<Directory?> _packageRoot(String packageName) async {
  final config = File('.dart_tool/package_config.json');
  if (!config.existsSync()) return null;
  final decoded =
      jsonDecode(await config.readAsString()) as Map<String, dynamic>;
  final packages = (decoded['packages'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>();
  final package = packages
      .where((pkg) => pkg['name'] == packageName)
      .firstOrNull;
  if (package == null) return null;
  final rootUri = package['rootUri'] as String?;
  if (rootUri == null) return null;
  final packageConfigUri = config.absolute.parent.uri;
  return Directory.fromUri(packageConfigUri.resolve(rootUri));
}

Conversation _conversation({
  required EncryptionMode encryptionMode,
  List<ConversationMember> members = const [],
}) => Conversation(
  id: 'conv-1',
  type: ConversationType.dm,
  encryptionMode: encryptionMode,
  createdAt: DateTime.utc(2026),
  createdBy: 'alice-id',
  members: members,
);

ConversationMember _member({
  required String userId,
  required String username,
  required String publicKey,
  required String fingerprint,
  String? avatarUrl,
}) => ConversationMember(
  conversationId: 'conv-1',
  userId: userId,
  role: MemberRole.member,
  joinedAt: DateTime.utc(2026),
  user: User(
    id: userId,
    username: username,
    publicKey: publicKey,
    keyFingerprint: fingerprint,
    avatarUrl: avatarUrl,
    createdAt: DateTime.utc(2026),
  ),
);

class _FakeSecureStorage extends SecureStorageService {
  final String userId;
  final String? username;
  final String privateKey;
  final String publicKey;
  final String fingerprint;

  _FakeSecureStorage({
    required this.userId,
    this.username,
    required this.privateKey,
    required this.publicKey,
    required this.fingerprint,
  });

  @override
  Future<String?> getUserID() async => userId;

  @override
  Future<String?> getUsername() async => username;

  @override
  Future<String?> getPrivateKeyIfUnlocked() async => privateKey;

  @override
  Future<String?> getPublicKey() async => publicKey;

  @override
  Future<String?> getFingerprint() async => fingerprint;
}

class _FakeApiService extends ApiService {
  final Conversation conversation;
  final List<ConversationMember> members;

  _FakeApiService(
    super.storage, {
    required this.conversation,
    this.members = const [],
  });

  @override
  Future<Conversation> getConversation(String id) async => conversation;

  @override
  Future<List<ConversationMember>> getConversationMembers(
    String convID,
  ) async => members;
}

class _FakeMlsService extends MlsService {
  _FakeMlsService(super.storage);

  @override
  Future<String> encryptPayload({
    required ApiService api,
    required Conversation conversation,
    required String plaintextPayload,
  }) async =>
      jsonEncode({'openchat_test_mls': 1, 'plaintext': plaintextPayload});

  @override
  Future<String?> decryptPayload({
    required ApiService api,
    required Conversation conversation,
    required String encryptedPayload,
  }) async {
    final decoded = jsonDecode(encryptedPayload) as Map<String, dynamic>;
    return decoded['plaintext'] as String?;
  }
}
