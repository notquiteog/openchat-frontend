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
  final String? callerUsername;
  final String? callerAvatarUrl;
  final bool? isVideo;

  /// Marks a renegotiation offer that ADDS video to a connected voice call.
  /// Explicit flag (not SDP sniffing) so a pure ICE-restart renegotiation can
  /// never be mistaken for a camera turn-on.
  final bool videoUpgrade;
  // SDP offer or answer for P2P WebRTC signaling.
  final String? sdp;
  final List<String> participantUserIds;

  /// SFU media frame-encryption key (base64). SECRET: deliberately absent
  /// from [toPlainOuter] — it may only travel inside the encrypted inner
  /// JSON, so in a plaintext conversation (where encode falls back to the
  /// plain outer shape) it is structurally dropped rather than leaked.
  final String? e2eeKey;

  const CallSignalPayload({
    required this.kind,
    required this.targetUserId,
    required this.callId,
    this.conversationId,
    this.callerId,
    this.callerUsername,
    this.callerAvatarUrl,
    this.isVideo,
    this.videoUpgrade = false,
    this.sdp,
    this.participantUserIds = const [],
    this.e2eeKey,
  });

  Map<String, dynamic> toPlainOuter() => {
    'target_user_id': targetUserId,
    'call_id': callId,
    'conversation_id': ?conversationId,
    'sdp': ?sdp,
    'is_video': ?isVideo,
    if (videoUpgrade) 'video_upgrade': true,
    'caller_username': ?callerUsername,
    'caller_avatar': ?callerAvatarUrl,
    if (participantUserIds.isNotEmpty)
      'participant_user_ids': participantUserIds,
  };
}

abstract class CallSignalCodec {
  Future<Map<String, dynamic>> encode(CallSignalPayload payload);

  Future<Map<String, dynamic>?> decode(Map<String, dynamic> data);

  /// Whether signals for this conversation are sealed (PGP/MLS). SFU media
  /// E2EE keys may only be distributed when this is true — otherwise the key
  /// would transit the server readable.
  Future<bool> isConversationEncrypted(String conversationId);
}

class PlainCallSignalCodec implements CallSignalCodec {
  const PlainCallSignalCodec();

  @override
  Future<Map<String, dynamic>> encode(CallSignalPayload payload) async =>
      payload.toPlainOuter();

  @override
  Future<Map<String, dynamic>?> decode(Map<String, dynamic> data) async =>
      // `encryption_mode` is the receivers' proof that a signal came out of a
      // sealed envelope (it drives the call UI's E2EE chip) — strip it from
      // plain payloads so a sender can't spoof it.
      Map<String, dynamic>.from(data)..remove('encryption_mode');

  @override
  Future<bool> isConversationEncrypted(String conversationId) async => false;
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
    final callerProfile = await _currentCallerProfile(conversation, callerId);
    final plaintext = jsonEncode({
      'openchat_call_signal': 1,
      'kind': payload.kind,
      'call_id': payload.callId,
      'conversation_id': conversationId,
      'caller_id': callerId,
      'caller_username': ?(payload.callerUsername ?? callerProfile.username),
      'caller_avatar': ?(payload.callerAvatarUrl ?? callerProfile.avatarUrl),
      'is_video': payload.isVideo,
      if (payload.videoUpgrade) 'video_upgrade': true,
      'sdp': ?payload.sdp,
      if (payload.participantUserIds.isNotEmpty)
        'participant_user_ids': payload.participantUserIds,
      // Sealed-only: the SFU frame key never appears in the plain outer shape.
      'e2ee_key': ?payload.e2eeKey,
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
      // Same anti-spoof rule as the plain codec: only a successful sealed
      // decryption below may assert `encryption_mode` to the caller.
      return Map<String, dynamic>.from(data)..remove('encryption_mode');
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

    final callerId = payload['caller_id']?.toString() ?? '';
    final callerProfile = _decodedCallerProfile(
      payload,
      conversation,
      callerId,
    );

    final out = <String, dynamic>{
      'call_id': callId,
      'conversation_id':
          payload['conversation_id']?.toString() ?? conversationId,
      'caller_id': callerId,
      'caller_username': ?callerProfile.username,
      'caller_avatar': ?callerProfile.avatarUrl,
      'is_video': payload['is_video'],
      if (payload['video_upgrade'] == true) 'video_upgrade': true,
      'encryption_mode': mode.apiValue,
    };
    // Sealed sender timestamp — the replay guard in CallService rejects
    // offers older than its window (a server can't forge this: it rides
    // inside the ciphertext).
    final createdAt = payload['created_at'];
    if (createdAt is String && createdAt.isNotEmpty) {
      out['created_at'] = createdAt;
    }
    final e2eeKey = payload['e2ee_key'];
    if (e2eeKey is String && e2eeKey.isNotEmpty) out['e2ee_key'] = e2eeKey;
    final sdp = payload['sdp'];
    if (sdp is String && sdp.isNotEmpty) out['sdp'] = sdp;
    final participantUserIds = payload['participant_user_ids'];
    if (participantUserIds is List) {
      out['participant_user_ids'] = participantUserIds
          .whereType<String>()
          .where((id) => id.trim().isNotEmpty)
          .toList(growable: false);
    }
    return out;
  }

  @override
  Future<bool> isConversationEncrypted(String conversationId) async {
    if (conversationId.trim().isEmpty) return false;
    final conversation = await _conversationFor(conversationId);
    return conversation?.isEncrypted ?? false;
  }

  Future<_CallCallerProfile> _currentCallerProfile(
    Conversation conversation,
    String callerId,
  ) async {
    final fromConversation = _callerProfileFromConversation(
      conversation,
      callerId,
    );
    if (fromConversation.username != null ||
        fromConversation.avatarUrl != null) {
      return fromConversation;
    }

    final username = _trimmedString(await _storage.getUsername());
    return _CallCallerProfile(username: username);
  }

  _CallCallerProfile _decodedCallerProfile(
    Map<String, dynamic> payload,
    Conversation conversation,
    String callerId,
  ) {
    final fromPayload = _CallCallerProfile(
      username: _trimmedString(payload['caller_username']),
      avatarUrl: _trimmedString(payload['caller_avatar']),
    );
    if (fromPayload.username != null || fromPayload.avatarUrl != null) {
      return fromPayload;
    }
    return _callerProfileFromConversation(conversation, callerId);
  }

  _CallCallerProfile _callerProfileFromConversation(
    Conversation conversation,
    String userId,
  ) {
    if (userId.isEmpty || conversation.members.isEmpty) {
      return const _CallCallerProfile();
    }
    for (final member in conversation.members) {
      if (member.userId != userId) continue;
      final user = member.user;
      if (user == null) return const _CallCallerProfile();
      return _CallCallerProfile(
        username: _trimmedString(user.username),
        avatarUrl: _trimmedString(user.avatarUrl),
      );
    }
    return const _CallCallerProfile();
  }

  Future<Conversation?> _conversationFor(String conversationId) async {
    final cached = _conversationCache[conversationId];
    if (cached != null && (!cached.isEncrypted || cached.members.isNotEmpty)) {
      return cached;
    }
    try {
      var conversation = await _api.getConversation(conversationId);
      if (conversation.usesPgp) {
        final members = await _api.getConversationMembers(conversationId);
        conversation = conversation.copyWith(members: members);
      } else if (conversation.isEncrypted && conversation.members.isEmpty) {
        try {
          final members = await _api.getConversationMembers(conversationId);
          conversation = conversation.copyWith(members: members);
        } catch (_) {}
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

class _CallCallerProfile {
  final String? username;
  final String? avatarUrl;

  const _CallCallerProfile({this.username, this.avatarUrl});
}

String? _trimmedString(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}
