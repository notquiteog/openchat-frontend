import 'dart:convert';

import '../crypto/pgp_service.dart';
import '../models/conversation.dart';
import 'api_service.dart';
import 'mls_service.dart';
import 'secure_storage_service.dart';

class CallSignalCodecException implements Exception {
  final String message;

  const CallSignalCodecException(this.message);

  @override
  String toString() => message;
}

class CallSignalPayload {
  final String kind;
  final String targetUserId;
  final String callId;
  final String? conversationId;
  final String? callerId;
  final bool? isVideo;
  final String? sdp;
  final Map<String, dynamic>? candidate;

  const CallSignalPayload({
    required this.kind,
    required this.targetUserId,
    required this.callId,
    this.conversationId,
    this.callerId,
    this.isVideo,
    this.sdp,
    this.candidate,
  });

  Map<String, dynamic> toPlainOuter() => {
    'target_user_id': targetUserId,
    'call_id': callId,
    'conversation_id': ?conversationId,
    'sdp': ?sdp,
    'candidate': ?candidate,
    'is_video': ?isVideo,
  };
}

abstract class CallSignalCodec {
  Future<Map<String, dynamic>> encode(CallSignalPayload payload);

  Future<Map<String, dynamic>?> decode(Map<String, dynamic> data);
}

class PlainCallSignalCodec implements CallSignalCodec {
  const PlainCallSignalCodec();

  @override
  Future<Map<String, dynamic>> encode(CallSignalPayload payload) async =>
      payload.toPlainOuter();

  @override
  Future<Map<String, dynamic>?> decode(Map<String, dynamic> data) async =>
      Map<String, dynamic>.from(data);
}

class PrivacyCallSignalCodec implements CallSignalCodec {
  final ApiService _api;
  final SecureStorageService _storage;
  final MlsService _mls;
  final Map<String, Conversation> _conversationCache = {};

  PrivacyCallSignalCodec(this._api, this._storage, this._mls);

  @override
  Future<Map<String, dynamic>> encode(CallSignalPayload payload) async {
    final conversationId = payload.conversationId;
    if (conversationId == null || conversationId.isEmpty) {
      return payload.toPlainOuter();
    }

    final conversation = await _conversationFor(conversationId);
    if (conversation == null || !conversation.isEncrypted) {
      return payload.toPlainOuter();
    }

    final privateKey = await _storage.getPrivateKeyIfUnlocked() ?? '';
    if (privateKey.trim().isEmpty) {
      throw const CallSignalCodecException(
        'Your PGP key is locked or missing. Unlock it in Settings to place encrypted calls.',
      );
    }

    final callerId = payload.callerId ?? await _currentUserId();
    final plaintext = jsonEncode({
      'openchat_call_signal': 1,
      'kind': payload.kind,
      'call_id': payload.callId,
      'conversation_id': conversationId,
      'caller_id': callerId,
      'is_video': payload.isVideo,
      'sdp': ?payload.sdp,
      'candidate': ?payload.candidate,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });

    final encrypted = conversation.usesMls
        ? await _mls.encryptPayload(
            api: _api,
            conversation: conversation,
            plaintextPayload: plaintext,
          )
        : await PgpService.encrypt(
            plaintext: plaintext,
            recipients: _pgpRecipients(conversation),
            signingPrivateKeyArmored: privateKey,
          );

    return {
      'target_user_id': payload.targetUserId,
      'conversation_id': conversationId,
      'call_id': payload.callId,
      'encrypted_signal': encrypted,
      'encryption_mode': conversation.encryptionMode.apiValue,
    };
  }

  @override
  Future<Map<String, dynamic>?> decode(Map<String, dynamic> data) async {
    final encryptedSignal = data['encrypted_signal'] as String?;
    if (encryptedSignal == null || encryptedSignal.trim().isEmpty) {
      return Map<String, dynamic>.from(data);
    }

    final conversationId = data['conversation_id']?.toString() ?? '';
    if (conversationId.isEmpty) return null;
    final conversation = await _conversationFor(conversationId);
    if (conversation == null || !conversation.isEncrypted) return null;

    final privateKey = await _storage.getPrivateKeyIfUnlocked() ?? '';
    if (privateKey.trim().isEmpty) {
      // Key is locked; return a minimal result so a ring notification fires.
      // Caller identity and SDP are inside the ciphertext and stay hidden —
      // the call rings but cannot be answered until the key is unlocked.
      final outerCallId = data['call_id']?.toString() ?? '';
      if (outerCallId.isEmpty) return null;
      return {'call_id': outerCallId, 'conversation_id': conversationId};
    }

    final mode = encryptionModeFromJson(
      data['encryption_mode'] ?? conversation.encryptionMode.apiValue,
    );
    final raw = mode == EncryptionMode.mls
        ? await _mls.decryptPayload(
            api: _api,
            conversation: conversation.copyWith(encryptionMode: mode),
            encryptedPayload: encryptedSignal,
          )
        : await PgpService.decrypt(
            encryptedArmor: encryptedSignal,
            privateKeyArmored: privateKey,
          );
    if (raw == null || raw.isEmpty) return null;

    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    final payload = Map<String, dynamic>.from(decoded);
    if (payload['openchat_call_signal'] != 1) return null;

    final outerCallId = data['call_id']?.toString() ?? '';
    final callId = payload['call_id']?.toString() ?? '';
    if (callId.isEmpty || (outerCallId.isNotEmpty && outerCallId != callId)) {
      return null;
    }

    final out = <String, dynamic>{
      'call_id': callId,
      'conversation_id':
          payload['conversation_id']?.toString() ?? conversationId,
      'caller_id': payload['caller_id']?.toString() ?? '',
      'is_video': payload['is_video'],
      'encryption_mode': mode.apiValue,
    };
    final sdp = payload['sdp'];
    if (sdp is String && sdp.isNotEmpty) out['sdp'] = sdp;
    final candidate = payload['candidate'];
    if (candidate is Map) {
      out['candidate'] = Map<String, dynamic>.from(candidate);
    }
    return out;
  }

  Future<Conversation?> _conversationFor(String conversationId) async {
    final cached = _conversationCache[conversationId];
    if (cached != null && (!cached.usesPgp || cached.members.isNotEmpty)) {
      return cached;
    }
    try {
      var conversation = await _api.getConversation(conversationId);
      if (conversation.usesPgp) {
        final members = await _api.getConversationMembers(conversationId);
        conversation = conversation.copyWith(members: members);
      }
      _conversationCache[conversationId] = conversation;
      return conversation;
    } catch (_) {
      return cached;
    }
  }

  List<PgpRecipient> _pgpRecipients(Conversation conversation) {
    final recipients = <PgpRecipient>[];
    for (final member in conversation.members) {
      final user = member.user;
      if (user == null || user.isKeyExpired) continue;
      if (user.publicKey.trim().isEmpty || user.keyFingerprint.trim().isEmpty) {
        continue;
      }
      recipients.add(
        PgpRecipient(
          userId: member.userId,
          publicKeyArmored: user.publicKey,
          keyFingerprint: user.keyFingerprint,
        ),
      );
    }
    if (recipients.isEmpty) {
      throw const CallSignalCodecException(
        'Could not load recipient keys for this encrypted call. Refresh the chat and try again.',
      );
    }
    return recipients;
  }

  Future<String> _currentUserId() async {
    final userId = await _storage.getUserID() ?? '';
    if (userId.isEmpty) {
      throw const CallSignalCodecException(
        'Your session is incomplete. Sign in again before placing a call.',
      );
    }
    return userId;
  }
}
