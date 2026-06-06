import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:openmls/openmls.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/conversation.dart';
import '../models/mls.dart';
import '../crypto/pgp_service.dart';
import 'api_service.dart';
import 'secure_storage_service.dart';

class MlsService {
  MlsService(this._storage);

  final SecureStorageService _storage;

  static Future<void>? _openmlsInit;
  MlsEngine? _engine;
  String? _engineUserID;
  Future<MlsEngine>? _engineFuture;
  final Set<String> _processedCommitIds = <String>{};

  static const defaultCiphersuite =
      MlsCiphersuite.mls256XwingChacha20Poly1305Sha256Ed25519;

  MlsGroupConfig get _config =>
      MlsGroupConfig.defaultConfig(ciphersuite: defaultCiphersuite);

  Future<void> ensureIdentityForCurrentUser() async {
    await _engineForCurrentUser();
    await _identityForCurrentUser();
  }

  Future<MlsBootstrap> createBootstrapForConversation(
    Conversation conversation,
  ) async {
    final engine = await _engineForCurrentUser();
    final identity = await _identityForCurrentUser();
    final result = await engine.createGroup(
      config: _config,
      signerBytes: identity.signerBytes,
      credentialIdentity: identity.credentialIdentity,
      signerPublicKey: identity.publicKey,
    );
    return _exportBootstrap(engine, result.groupId, identity);
  }

  Future<String> encryptPayload({
    required ApiService api,
    required Conversation conversation,
    required String plaintextPayload,
  }) async {
    final joined = await _ensureJoined(api, conversation);
    final paddedPlaintext = _padStructuredPlaintext(plaintextPayload);
    final encrypted = await joined.engine.createMessage(
      groupIdBytes: joined.groupId,
      signerBytes: joined.identity.signerBytes,
      message: Uint8List.fromList(utf8.encode(paddedPlaintext)),
    );
    return jsonEncode({
      'openchat_mls': 1,
      'ciphertext': base64Encode(encrypted.ciphertext),
    });
  }

  String _padStructuredPlaintext(String plaintext) {
    try {
      final decoded = jsonDecode(plaintext);
      if (decoded is! Map<String, dynamic>) return plaintext;
      if (decoded['openchat_message'] != 1 &&
          decoded['openchat_call_signal'] != 1) {
        return plaintext;
      }
      final currentSize = utf8.encode(plaintext).length;
      const buckets = [512, 1024, 2048, 4096, 8192, 16384, 32768, 65536];
      final target = buckets.firstWhere(
        (bucket) => bucket > currentSize + 48,
        orElse: () => 0,
      );
      if (target == 0) return plaintext;
      final random = Random.secure();
      final paddingBytes = max(16, ((target - currentSize) * 3 / 4).floor());
      decoded['_padding'] = base64Url.encode(
        List<int>.generate(paddingBytes, (_) => random.nextInt(256)),
      );
      return jsonEncode(decoded);
    } catch (_) {
      return plaintext;
    }
  }

  Future<String?> decryptPayload({
    required ApiService api,
    required Conversation conversation,
    required String encryptedPayload,
  }) async {
    final ciphertext = _ciphertextFromPayload(encryptedPayload);
    if (ciphertext == null) return null;
    final joined = await _ensureJoined(api, conversation);
    try {
      final processed = await joined.engine.processMessage(
        groupIdBytes: joined.groupId,
        messageBytes: ciphertext,
      );
      if (processed.messageType != ProcessedMessageType.application) {
        return null;
      }
      final bytes = processed.applicationMessage;
      if (bytes == null || bytes.isEmpty) return null;
      return utf8.decode(bytes);
    } catch (_) {
      return null;
    }
  }

  Future<_JoinedGroup> _ensureJoined(
    ApiService api,
    Conversation conversation,
  ) async {
    if (!conversation.usesMls) {
      throw StateError('Conversation is not using MLS.');
    }
    final engine = await _engineForCurrentUser();
    final identity = await _identityForCurrentUser();
    final state = await api.getConversationMlsState(conversation.id);
    final groupId = base64Decode(state.groupId);
    var active = await _isGroupActive(engine, groupId);
    if (!active) {
      final join = await engine.joinGroupExternalCommitV2(
        config: _config,
        groupInfoBytes: base64Decode(state.groupInfo),
        ratchetTreeBytes: Uint8List.fromList(base64Decode(state.ratchetTree)),
        signerBytes: identity.signerBytes,
        credentialIdentity: identity.credentialIdentity,
        signerPublicKey: identity.publicKey,
        aad: Uint8List.fromList(utf8.encode(conversation.id)),
        skipLifetimeValidation: true,
      );
      final nextState = await _exportBootstrap(engine, join.groupId, identity);
      await api.postConversationMlsCommit(
        conversation.id,
        base64Encode(join.commit),
        nextState: nextState,
      );
      _processedCommitIds.add(_commitDedupeKey(conversation.id, join.commit));
      active = true;
    }
    if (!active) {
      throw StateError('Could not join MLS group.');
    }
    await _processCommits(engine, groupId, state.commits, conversation.id);
    return _JoinedGroup(engine: engine, identity: identity, groupId: groupId);
  }

  Future<void> _processCommits(
    MlsEngine engine,
    List<int> groupId,
    List<ConversationMlsCommit> commits,
    String conversationId,
  ) async {
    for (final commit in commits) {
      final bytes = base64Decode(commit.commitPayload);
      final key = _commitDedupeKey(conversationId, bytes);
      if (_processedCommitIds.contains(key)) continue;
      try {
        final type = mlsMessageContentType(messageBytes: bytes);
        if (type != 'commit') {
          _processedCommitIds.add(key);
          continue;
        }
        await engine.processMessage(groupIdBytes: groupId, messageBytes: bytes);
        _processedCommitIds.add(key);
      } catch (_) {
        _processedCommitIds.add(key);
      }
    }
  }

  Future<MlsBootstrap> _exportBootstrap(
    MlsEngine engine,
    List<int> groupId,
    _MlsIdentity identity,
  ) async {
    final groupInfo = await engine.exportGroupInfo(
      groupIdBytes: groupId,
      signerBytes: identity.signerBytes,
    );
    final ratchetTree = await engine.exportRatchetTree(groupIdBytes: groupId);
    final epoch = await engine.groupEpoch(groupIdBytes: groupId);
    return MlsBootstrap(
      groupId: base64Encode(groupId),
      groupInfo: base64Encode(groupInfo),
      ratchetTree: base64Encode(ratchetTree),
      epoch: epoch.toInt(),
      signerPublicKey: base64Encode(identity.publicKey),
      signerSignature: identity.publicKeySignature,
    );
  }

  Uint8List? _ciphertextFromPayload(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['openchat_mls'] != 1) return null;
      final ciphertext = decoded['ciphertext'];
      if (ciphertext is! String || ciphertext.isEmpty) return null;
      return Uint8List.fromList(base64Decode(ciphertext));
    } catch (_) {
      return null;
    }
  }

  Future<MlsEngine> _engineForCurrentUser() async {
    final userID = await _storage.getUserID() ?? '';
    if (userID.isEmpty) {
      throw StateError('Your session is incomplete. Sign in again.');
    }
    if (_engine != null && _engineUserID == userID && !_engine!.isClosed()) {
      return _engine!;
    }
    final inFlight = _engineFuture;
    if (inFlight != null && _engineUserID == userID) return inFlight;
    if (_engine != null && !_engine!.isClosed()) {
      unawaited(_engine!.close());
      _engine = null;
      _processedCommitIds.clear();
    }
    _engineUserID = userID;
    _engineFuture = _createEngine(userID);
    try {
      _engine = await _engineFuture;
      return _engine!;
    } finally {
      _engineFuture = null;
    }
  }

  Future<MlsEngine> _createEngine(String userID) async {
    _openmlsInit ??= Openmls.init();
    await _openmlsInit;
    final key = base64Decode(await _storage.getOrCreateMlsEngineKey(userID));
    final dbPath = await _dbPathForUser(userID);
    return MlsEngine.create(dbPath: dbPath, encryptionKey: key);
  }

  Future<String> _dbPathForUser(String userID) async {
    final safeID = userID.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    if (kIsWeb) return 'openchat_mls_$safeID';
    final dir = await getApplicationSupportDirectory();
    return p.join(dir.path, 'openchat_mls_$safeID.db');
  }

  Future<_MlsIdentity> _identityForCurrentUser() async {
    final userID = await _storage.getUserID() ?? '';
    if (userID.isEmpty) {
      throw StateError('Your session is incomplete. Sign in again.');
    }
    final stored = await _storage.getMlsSigner(userID);
    if (stored != null) {
      final publicKey = Uint8List.fromList(base64Decode(stored.publicKey));
      var signature = stored.signature;
      if (signature.isEmpty) {
        signature = await _signMlsPublicKey(userID, publicKey);
        await _storage.saveMlsSigner(
          userID: userID,
          signerBytes: stored.signerBytes,
          publicKey: stored.publicKey,
          signature: signature,
        );
      }
      return _MlsIdentity(
        signerBytes: Uint8List.fromList(base64Decode(stored.signerBytes)),
        publicKey: publicKey,
        publicKeySignature: signature,
        credentialIdentity: Uint8List.fromList(
          base64Decode(await _storage.getOrCreateMlsCredentialIdentity(userID)),
        ),
      );
    }
    final keyPair = MlsSignatureKeyPair.generate(
      ciphersuite: defaultCiphersuite,
    );
    final publicKey = keyPair.publicKey();
    final privateKey = keyPair.privateKey();
    final signer = serializeSigner(
      ciphersuite: defaultCiphersuite,
      privateKey: privateKey,
      publicKey: publicKey,
    );
    final signature = await _signMlsPublicKey(userID, publicKey);
    await _storage.saveMlsSigner(
      userID: userID,
      signerBytes: base64Encode(signer),
      publicKey: base64Encode(publicKey),
      signature: signature,
    );
    return _MlsIdentity(
      signerBytes: signer,
      publicKey: publicKey,
      publicKeySignature: signature,
      credentialIdentity: Uint8List.fromList(
        base64Decode(await _storage.getOrCreateMlsCredentialIdentity(userID)),
      ),
    );
  }

  Future<String> _signMlsPublicKey(String userID, Uint8List publicKey) async {
    final privateKey = await _storage.getPrivateKey();
    if (privateKey == null || privateKey.isEmpty) return '';
    return PgpService.sign(
      data: PgpService.deviceKeySignatureData(
        userId: userID,
        deviceKey: base64Encode(publicKey),
      ),
      privateKeyArmored: privateKey,
    );
  }

  Future<bool> _isGroupActive(MlsEngine engine, List<int> groupId) async {
    try {
      return await engine.groupIsActive(groupIdBytes: groupId);
    } catch (_) {
      return false;
    }
  }

  String _commitDedupeKey(String conversationId, List<int> bytes) {
    var hash = 0xcbf29ce484222325;
    for (final b in bytes) {
      hash ^= b;
      hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
    }
    return '$conversationId:$hash:${bytes.length}';
  }
}

class _MlsIdentity {
  final Uint8List signerBytes;
  final Uint8List publicKey;
  final String publicKeySignature;
  final Uint8List credentialIdentity;

  const _MlsIdentity({
    required this.signerBytes,
    required this.publicKey,
    required this.publicKeySignature,
    required this.credentialIdentity,
  });
}

class _JoinedGroup {
  final MlsEngine engine;
  final _MlsIdentity identity;
  final List<int> groupId;

  const _JoinedGroup({
    required this.engine,
    required this.identity,
    required this.groupId,
  });
}
