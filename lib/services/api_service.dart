import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import '../config/api_config.dart' show ApiConfig, IceServer;
import '../crypto/pgp_service.dart';
import '../models/admin_audit_event.dart';
import '../models/channel_analytics.dart';
import '../models/channel_pinned_message.dart';
import '../models/contact_bundle.dart';
import '../models/key_transparency_event.dart';
import '../models/key_trust_pin.dart';
import '../models/user.dart';
import '../models/message.dart';
import '../models/conversation.dart';
import '../models/conversation_invite.dart';
import '../models/moderation_report.dart';
import '../models/mls.dart';
import '../models/scheduled_message.dart';
import '../models/story.dart';
import '../services/secure_storage_service.dart';
import '../services/key_cache_service.dart';
import '../utils/device_label.dart';

class ApiException implements Exception {
  final int statusCode;
  final String code;
  final String message;
  ApiException(this.statusCode, this.code, this.message);
  @override
  String toString() => 'ApiException($statusCode): $code - $message';
}

/// Thrown by [ApiService.postConversationMlsCommit] when the server rejects an
/// MLS commit because the group epoch already advanced (HTTP 409
/// MLS_EPOCH_CONFLICT) — i.e. a concurrent external-commit join won the race.
/// Callers should discard their local fork, refetch the canonical group state,
/// and rebuild their commit against it.
class MlsEpochConflictException implements Exception {
  const MlsEpochConflictException();
  @override
  String toString() => 'MlsEpochConflictException';
}

class AuthResponse {
  final String accessToken;
  final String refreshToken;
  final User user;

  AuthResponse({
    required this.accessToken,
    required this.refreshToken,
    required this.user,
  });

  factory AuthResponse.fromJson(Map<String, dynamic> json) => AuthResponse(
    accessToken: json['access_token'] as String,
    refreshToken: json['refresh_token'] as String,
    user: User.fromJson(json['user'] as Map<String, dynamic>),
  );
}

class UploadRequest {
  final String attachmentId;
  final String uploadUrl;
  final String uploadToken;
  final int expiresIn;

  UploadRequest({
    required this.attachmentId,
    required this.uploadUrl,
    required this.uploadToken,
    required this.expiresIn,
  });

  factory UploadRequest.fromJson(Map<String, dynamic> json) => UploadRequest(
    attachmentId: json['attachment_id'] as String,
    uploadUrl: json['upload_url'] as String,
    uploadToken: json['upload_token'] as String,
    expiresIn: json['expires_in'] as int,
  );
}

class DownloadInfo {
  final String downloadUrl;
  final String fileName;
  final int fileSize;
  final String mimeType;

  DownloadInfo({
    required this.downloadUrl,
    required this.fileName,
    required this.fileSize,
    required this.mimeType,
  });

  factory DownloadInfo.fromJson(Map<String, dynamic> json) => DownloadInfo(
    downloadUrl: json['download_url'] as String,
    fileName: json['file_name'] as String,
    fileSize: json['file_size'] as int,
    mimeType: json['mime_type'] as String,
  );
}

class SharedContentPage {
  final List<Message> items;
  final String? nextCursor;

  const SharedContentPage({required this.items, required this.nextCursor});
}

class SelfStateEvent {
  final String id;
  final int sequence;
  final String encryptedPayload;
  final DateTime createdAt;

  const SelfStateEvent({
    required this.id,
    required this.sequence,
    required this.encryptedPayload,
    required this.createdAt,
  });

  factory SelfStateEvent.fromJson(Map<String, dynamic> json) {
    return SelfStateEvent(
      id: json['id'] as String,
      sequence: (json['sequence'] as num).toInt(),
      encryptedPayload: json['encrypted_payload'] as String? ?? '',
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}

typedef UploadProgressCallback = void Function(int sentBytes, int totalBytes);


class ApiService {
  final SecureStorageService _storage;
  final http.Client _httpClient;
  Future<void>? _refreshInFlight;

  /// Called when a token refresh fails (expired/revoked session). Wire this
  /// to AuthProvider.logout so the user is returned to the login screen.
  void Function()? onAuthFailed;

  ApiService(this._storage) : _httpClient = http.Client();

  // ---- Auth ----

  Future<AuthResponse> register({
    required String username,
    String? displayName,
    required String password,
    required String publicKey,
    bool publicDiscovery = true,
  }) async {
    final resp = await _post('/api/v1/auth/register', {
      'username': username,
      if (displayName != null && displayName.trim().isNotEmpty)
        'display_name': displayName.trim(),
      'password': password,
      'public_key': publicKey,
      'public_discovery': publicDiscovery,
      'device_name': openChatDeviceName(),
    }, authenticated: false);
    return AuthResponse.fromJson(resp['data'] as Map<String, dynamic>);
  }

  Future<AuthResponse> login({
    required String identifier,
    required String password,
    String? twoFactorPassword,
  }) async {
    final resp = await _post('/api/v1/auth/login', {
      'identifier': identifier,
      'password': password,
      if (twoFactorPassword != null && twoFactorPassword.isNotEmpty)
        'two_factor_password': twoFactorPassword,
      'device_name': openChatDeviceName(),
    }, authenticated: false);
    return AuthResponse.fromJson(resp['data'] as Map<String, dynamic>);
  }

  Future<void> refreshTokens() async {
    final refreshToken = await _storage.getRefreshToken();
    if (refreshToken == null) {
      throw ApiException(401, 'NO_TOKEN', 'no refresh token');
    }
    final resp = await _post('/api/v1/auth/refresh', {
      'refresh_token': refreshToken,
      'device_name': openChatDeviceName(),
    }, authenticated: false);
    final data = resp['data'] as Map<String, dynamic>;
    await _storage.updateTokens(
      accessToken: data['access_token'] as String,
      refreshToken: data['refresh_token'] as String,
    );
  }

  // ---- Users ----

  Future<User> getMe() async {
    final resp = await _get('/api/v1/users/me');
    return User.fromJson(resp['data'] as Map<String, dynamic>);
  }

  Future<User> getUserByUsername(String username) async {
    final resp = await _get('/api/v1/users/@$username');
    return User.fromJson(resp['data'] as Map<String, dynamic>);
  }

  Future<User> getUserByFingerprint(String fingerprint) async {
    final encoded = Uri.encodeComponent(fingerprint);
    final resp = await _get('/api/v1/users/fingerprint/$encoded');
    return User.fromJson(resp['data'] as Map<String, dynamic>);
  }

  /// Fetch a user's public key, honouring expiry. Returns null for users
  /// whose key has expired — callers building a multi-recipient envelope
  /// should drop those recipients so the resulting PGP message is decodable
  /// only by people who still have a valid key.
  Future<CachedKey?> getUserPublicKeyEntry(String userID) async {
    final cached = await KeyCacheService.get(userID);
    if (cached != null) return cached;

    final resp = await _get('/api/v1/users/$userID/public-key');
    final data = resp['data'] as Map<String, dynamic>;
    final isExpired = data['is_key_expired'] as bool? ?? false;
    if (isExpired) return null;

    final publicKey = data['public_key'] as String;
    final fingerprint = data['key_fingerprint'] as String? ?? '';
    final expiresAt = data['public_key_expires_at'] != null
        ? DateTime.parse(data['public_key_expires_at'] as String)
        : null;
    final events = await getKeyTransparencyEvents(
      userID,
    ).catchError((_) => <KeyTransparencyEvent>[]);
    await _observeKeyTrust(
      userID: userID,
      publicKey: publicKey,
      fingerprint: fingerprint,
      events: events,
    );
    await KeyCacheService.put(
      userID,
      publicKey,
      fingerprint,
      expiresAt: expiresAt,
    );
    return CachedKey(
      publicKey: publicKey,
      fingerprint: fingerprint,
      expiresAt: expiresAt,
    );
  }

  Future<String?> getUserPublicKey(String userID) async {
    final entry = await getUserPublicKeyEntry(userID);
    return entry?.publicKey;
  }

  /// Fetch a user's public key directly from the server, bypassing the local
  /// cache. Use this for outbound encryption so key rotations and newly-added
  /// members are reflected immediately.
  Future<String?> getFreshUserPublicKey(String userID) async {
    await KeyCacheService.invalidate(userID);
    return getUserPublicKey(userID);
  }

  Future<CachedKey?> getFreshUserPublicKeyEntry(String userID) async {
    await KeyCacheService.invalidate(userID);
    return getUserPublicKeyEntry(userID);
  }

  /// Send-path key lookup with a freshness window: returns the cached entry
  /// when it was fetched within [maxAge], otherwise force-refreshes from the
  /// server (which also re-observes key trust). Without this, every send to a
  /// 100-member PGP group performed ~100 key fetches + transparency reads —
  /// the documented "subsequent sends skip the network" behaviour.
  Future<CachedKey?> getRecentUserPublicKeyEntry(
    String userID, {
    Duration maxAge = const Duration(minutes: 5),
  }) async {
    final cached = await KeyCacheService.get(userID, maxAge: maxAge);
    if (cached != null) return cached;
    return getFreshUserPublicKeyEntry(userID);
  }

  Future<List<KeyTransparencyEvent>> getKeyTransparencyEvents(
    String userID,
  ) async {
    final encoded = Uri.encodeComponent(userID);
    final resp = await _get('/api/v1/users/$encoded/key-transparency');
    return (resp['data'] as List? ?? const [])
        .map((e) => KeyTransparencyEvent.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> _observeKeyTrust({
    required String userID,
    required String publicKey,
    required String fingerprint,
    required List<KeyTransparencyEvent> events,
  }) async {
    final normalizedFingerprint = fingerprint.trim().toUpperCase();
    if (userID.isEmpty || normalizedFingerprint.isEmpty) return;
    final publicKeyHash = crypto.sha256
        .convert(utf8.encode(publicKey.trim()))
        .toString()
        .toUpperCase();
    final matchingEvents = events
        .where(
          (event) =>
              event.newKeyFingerprint.toUpperCase() == normalizedFingerprint,
        )
        .toList();
    final latestEventHash = matchingEvents.isEmpty
        ? null
        : matchingEvents.last.eventHash;
    final pin = await _storage.getKeyTrustPin(userID);
    if (pin == null || pin.fingerprint.trim().isEmpty) {
      await _storage.saveKeyTrustPin(
        KeyTrustPin(
          userId: userID,
          fingerprint: normalizedFingerprint,
          publicKeyHash: publicKeyHash,
          eventHash: latestEventHash,
          pinnedAt: DateTime.now(),
        ),
      );
      return;
    }
    if (pin.fingerprint.toUpperCase() == normalizedFingerprint) {
      if (pin.publicKeyHash == publicKeyHash &&
          pin.eventHash == latestEventHash) {
        return;
      }
      await _storage.saveKeyTrustPin(
        KeyTrustPin(
          userId: userID,
          fingerprint: normalizedFingerprint,
          publicKeyHash: publicKeyHash,
          eventHash: latestEventHash ?? pin.eventHash,
          warning: pin.warning,
          pinnedAt: pin.pinnedAt,
        ),
      );
      return;
    }

    // Cryptographically verify continuity (old key signed the rotation + new
    // key signed the crossover) rather than merely trusting that the server
    // returned a matching event.
    final explained = await verifyRotationContinuity(
      events: events,
      userId: userID,
      oldFingerprint: pin.fingerprint,
      newFingerprint: normalizedFingerprint,
    );
    await _storage.saveKeyTrustPin(
      KeyTrustPin(
        userId: userID,
        fingerprint: normalizedFingerprint,
        publicKeyHash: publicKeyHash,
        eventHash: latestEventHash,
        warning: explained
            ? null
            : 'Unexplained key replacement: ${pin.fingerprint} -> $normalizedFingerprint',
        pinnedAt: DateTime.now(),
      ),
    );
  }

  /// Change the account login password. Verified against the current password
  /// server-side; does not affect the PGP key.
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    await _put('/api/v1/users/me/password', {
      'current_password': currentPassword,
      'new_password': newPassword,
    });
  }

  Future<void> rotatePublicKey({
    required String publicKey,
    required String fingerprint,
    required String signature,
    String? crossoverSignature,
  }) async {
    await _put('/api/v1/users/me/public-key', {
      'public_key': publicKey,
      'key_fingerprint': fingerprint,
      'signature': signature,
      if (crossoverSignature != null && crossoverSignature.isNotEmpty)
        'crossover_signature': crossoverSignature,
    });
  }

  /// Fetch many users' public keys. Users with expired keys are silently
  /// omitted from the returned map — the caller's encryption layer simply
  /// won't include them as recipients, which is the correct behaviour
  /// (expired-key users can't decrypt anyway).
  Future<Map<String, String>> getBulkPublicKeys(List<String> userIDs) async {
    final keys = await Future.wait(userIDs.map(getUserPublicKey));
    final out = <String, String>{};
    for (var i = 0; i < userIDs.length; i++) {
      final k = keys[i];
      if (k != null) out[userIDs[i]] = k;
    }
    return out;
  }

  Future<Map<String, String>> getFreshBulkPublicKeys(
    List<String> userIDs,
  ) async {
    // Catch per-user failures so a single bad fetch doesn't drop every key.
    final entries = await Future.wait(
      userIDs.map((id) async {
        try {
          final k = await getFreshUserPublicKey(id);
          return k != null ? MapEntry(id, k) : null;
        } catch (_) {
          return null;
        }
      }),
    );
    return Map.fromEntries(entries.whereType<MapEntry<String, String>>());
  }

  Future<List<User>> searchUsers(String query) async {
    final resp = await _get(
      '/api/v1/users/search?q=${Uri.encodeComponent(query)}',
    );
    return (resp['data'] as List)
        .map((e) => User.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<ContactBundle> getMyContactBundle() async {
    final resp = await _get('/api/v1/users/me/contact-bundle');
    return ContactBundle.fromJson(resp['data'] as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> createContactLink({
    int expiresInSeconds = 24 * 60 * 60,
  }) async {
    final resp = await _post('/api/v1/users/me/contact-links', {
      'expires_in_seconds': expiresInSeconds,
    });
    return resp['data'] as Map<String, dynamic>;
  }

  Future<ContactBundle> claimContactLink(String token) async {
    final encoded = Uri.encodeComponent(token);
    final resp = await _post('/api/v1/users/contact-links/$encoded/claim', {});
    return ContactBundle.fromJson(resp['data'] as Map<String, dynamic>);
  }

  Future<List<Conversation>> getSharedConversations(
    String userID, {
    int limit = 20,
  }) async {
    final resp = await _get(
      '/api/v1/users/$userID/shared-conversations?limit=$limit',
    );
    final list = resp['data'] as List? ?? [];
    return list
        .map((e) => Conversation.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ---- Conversations ----

  Future<List<Conversation>> listConversations() async {
    final resp = await _get('/api/v1/conversations');
    final list = resp['data'] as List? ?? [];
    return list
        .map((e) => Conversation.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Conversation> openDM(String userID) async {
    final resp = await _post('/api/v1/conversations/dm', {'user_id': userID});
    return Conversation.fromJson(resp['data'] as Map<String, dynamic>);
  }

  Future<Conversation> createGroup({
    required String name,
    String? description,
    required List<String> memberIDs,
    int? expiresInSeconds,
  }) async {
    final resp = await _post('/api/v1/conversations', {
      'name': name,
      'description': ?description,
      'member_ids': memberIDs,
      if (expiresInSeconds != null && expiresInSeconds > 0)
        'expires_in_seconds': expiresInSeconds,
    });
    return Conversation.fromJson(resp['data'] as Map<String, dynamic>);
  }

  Future<Conversation> getConversation(String id) async {
    final resp = await _get('/api/v1/conversations/$id');
    return Conversation.fromJson(resp['data'] as Map<String, dynamic>);
  }

  Future<List<ConversationMember>> getConversationMembers(String convID) async {
    final resp = await _get('/api/v1/conversations/$convID/members');
    return (resp['data'] as List)
        .map((e) => ConversationMember.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> addMember(String convID, String userID) async {
    await _post('/api/v1/conversations/$convID/members', {'user_id': userID});
  }

  /// Web-of-trust: set a group's join policy ('open' or 'web_of_trust').
  Future<void> setMembershipPolicy(String convID, String policy) async {
    await _put('/api/v1/conversations/$convID/membership-policy', {
      'policy': policy,
    });
  }

  /// Web-of-trust: submit a vouch (PGP signature over the candidate's key).
  Future<void> vouchForMember(
    String convID,
    String candidateUserID,
    String signature,
  ) async {
    await _post('/api/v1/conversations/$convID/vouch', {
      'candidate_user_id': candidateUserID,
      'signature': signature,
    });
  }

  /// Roll a server-authoritative dice/randomiser. The server picks the value.
  Future<void> rollDice(String convID, String emoji) async {
    await _post('/api/v1/conversations/$convID/dice', {'emoji': emoji});
  }

  // ── Provably-fair games (fun + real-money pari-mutuel) ─────────────────────
  // mode: 'quick' (instant fun roll) | 'betting'. provider: 'fun' | 'btc' | 'xmr'.
  // Channels expose the same surface under /channels instead of /conversations.
  String _gameBase(String convID, bool isChannel) =>
      '/api/v1/${isChannel ? 'channels' : 'conversations'}/$convID/games';

  Future<Map<String, dynamic>> createGameRound(
    String convID, {
    String gameType = '🎲',
    String mode = 'quick',
    String provider = 'fun',
    double? stake,
    bool isChannel = false,
  }) async {
    final resp = await _post(_gameBase(convID, isChannel), {
      'game_type': gameType,
      'mode': mode,
      'provider': provider,
      'stake': ?stake,
    });
    return resp['data'] as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getGameRound(
    String convID,
    String roundID, {
    bool isChannel = false,
  }) async {
    final resp = await _get('${_gameBase(convID, isChannel)}/$roundID');
    return resp['data'] as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> placeGameBet(
    String convID,
    String roundID,
    int selection, {
    bool isChannel = false,
  }) async {
    // Contribute fresh client-side entropy so neither the server (which committed
    // to its seed before this bet) nor any player can grind the provably-fair
    // outcome: it's HMAC(server_seed, combined client seeds).
    final resp = await _post(
      '${_gameBase(convID, isChannel)}/$roundID/bets',
      {'selection': selection, 'client_seed': _randomClientSeed()},
    );
    return resp['data'] as Map<String, dynamic>;
  }

  String _randomClientSeed() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<Map<String, dynamic>> revealGameRound(
    String convID,
    String roundID, {
    bool isChannel = false,
  }) async {
    final resp = await _post(
      '${_gameBase(convID, isChannel)}/$roundID/reveal',
      {},
    );
    return resp['data'] as Map<String, dynamic>;
  }

  // ── Voice Stage Rooms ──────────────────────────────────────────────────────
  Future<Map<String, dynamic>> joinStage(String convID) async {
    final resp = await _post('/api/v1/conversations/$convID/stage/join', {});
    return resp['data'] as Map<String, dynamic>;
  }

  Future<void> leaveStage(String convID) async {
    await _post('/api/v1/conversations/$convID/stage/leave', {});
  }

  Future<void> raiseStageHand(String convID) async {
    await _post('/api/v1/conversations/$convID/stage/raise-hand', {});
  }

  Future<void> lowerStageHand(String convID) async {
    await _post('/api/v1/conversations/$convID/stage/lower-hand', {});
  }

  Future<void> inviteStageSpeaker(String convID, String userID) async {
    await _post('/api/v1/conversations/$convID/stage/speakers', {
      'user_id': userID,
    });
  }

  Future<void> removeStageSpeaker(String convID, String userID) async {
    await _delete('/api/v1/conversations/$convID/stage/speakers/$userID');
  }

  Future<Map<String, dynamic>> getStageState(String convID) async {
    final resp = await _get('/api/v1/conversations/$convID/stage');
    return resp['data'] as Map<String, dynamic>;
  }

  Future<void> removeMember(String convID, String userID) async {
    await _delete('/api/v1/conversations/$convID/members/$userID');
  }

  Future<void> setConversationMemberRole(
    String convID,
    String userID,
    String role, {
    Map<String, bool>? adminPermissions,
  }) async {
    await _put('/api/v1/conversations/$convID/members/$userID/role', {
      'role': role,
      'admin_permissions': ?adminPermissions,
    });
  }

  // ---- Channels ----

  Future<List<Conversation>> searchChannels(String query) async {
    final resp = await _get('/api/v1/channels?q=${Uri.encodeComponent(query)}');
    return (resp['data'] as List)
        .map((e) => Conversation.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Conversation> createChannel({
    required String name,
    String? handle,
    String? description,
    bool isPublic = true,
  }) async {
    final resp = await _post('/api/v1/channels', {
      'name': name,
      if (handle != null && handle.isNotEmpty) 'handle': handle,
      'description': ?description,
      'is_public': isPublic,
    });
    return Conversation.fromJson(resp['data'] as Map<String, dynamic>);
  }

  Future<Conversation> getChannelByHandle(String handle) async {
    final resp = await _get('/api/v1/channels/@$handle');
    return Conversation.fromJson(resp['data'] as Map<String, dynamic>);
  }

  Future<void> archiveChannel(String chanID) async {
    await _post('/api/v1/channels/$chanID/archive', {});
  }

  Future<void> unarchiveChannel(String chanID) async {
    await _delete('/api/v1/channels/$chanID/archive');
  }

  /// Set a channel member's role: 'admin', 'moderator', or 'member' (admins only).
  Future<void> setChannelMemberRole(
    String chanID,
    String userID,
    String role, {
    Map<String, bool>? adminPermissions,
  }) async {
    await _put('/api/v1/channels/$chanID/members/$userID/role', {
      'role': role,
      'admin_permissions': ?adminPermissions,
    });
  }

  /// Ban a user from a channel (admins/moderators). Removes their membership.
  Future<void> banChannelUser(
    String chanID,
    String userID, {
    String? reason,
  }) async {
    await _post('/api/v1/channels/$chanID/bans', {
      'user_id': userID,
      'reason': ?reason,
    });
  }

  Future<void> unbanChannelUser(String chanID, String userID) async {
    await _delete('/api/v1/channels/$chanID/bans/$userID');
  }

  Future<Conversation> getChannel(String chanID) async {
    final resp = await _get('/api/v1/channels/$chanID');
    return Conversation.fromJson(resp['data'] as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> subscribeChannel(String chanID) async {
    final resp = await _post('/api/v1/channels/$chanID/subscribe', {});
    return resp['data'] as Map<String, dynamic>;
  }

  Future<void> unsubscribeChannel(String chanID) async {
    await _delete('/api/v1/channels/$chanID/subscribe');
  }

  // ---- Paid channel access (subscription plans + ledger) ----

  /// Returns {plans, subscriber_count, is_owner, subscription?, periods?}.
  Future<Map<String, dynamic>> getChannelSubscription(String chanID) async {
    final resp = await _get('/api/v1/channels/$chanID/subscription');
    return resp['data'] as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> setChannelSubscriptionPlan(
    String chanID, {
    required String provider,
    required double price,
    required int periodDays,
    bool isActive = true,
  }) async {
    final resp = await _post('/api/v1/channels/$chanID/subscription-plan', {
      'provider': provider,
      'price': price,
      'period_days': periodDays,
      'is_active': isActive,
    });
    return resp['data'] as Map<String, dynamic>;
  }

  /// [source] is 'wallet' (instant) or 'external' (returns a deposit address).
  Future<Map<String, dynamic>> subscribePaidChannel(
    String chanID, {
    required String provider,
    required String source,
  }) async {
    final resp = await _post('/api/v1/channels/$chanID/subscribe-paid', {
      'provider': provider,
      'source': source,
    });
    return resp['data'] as Map<String, dynamic>;
  }

  Future<void> setChannelSubscriptionAutoRenew(
    String chanID,
    bool autoRenew,
  ) async {
    await _post('/api/v1/channels/$chanID/subscription/auto-renew', {
      'auto_renew': autoRenew,
    });
  }

  Future<List<Message>> getChannelPosts(
    String chanID, {
    String? beforeID,
    int limit = 50,
  }) async {
    var path = '/api/v1/channels/$chanID/posts?limit=$limit';
    if (beforeID != null) path += '&before=$beforeID';
    final resp = await _get(path);
    return (resp['data'] as List)
        .map((e) => Message.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<ChannelPinnedMessage>> getChannelPinnedPosts(
    String chanID,
  ) async {
    final resp = await _get('/api/v1/channels/$chanID/pinned-posts');
    return (resp['data'] as List)
        .map((e) => ChannelPinnedMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> pinChannelPost(String chanID, String msgID) async {
    await _put('/api/v1/channels/$chanID/posts/$msgID/pin', {});
  }

  Future<void> unpinChannelPost(String chanID, String msgID) async {
    await _delete('/api/v1/channels/$chanID/posts/$msgID/pin');
  }

  Future<Message> postToChannel({
    required String chanID,
    required String encryptedPayload,
    required String signature,
    String? postToken,
    String messageType = 'text',
    String? attachmentId,
    bool silent = false,
    DateTime? scheduledFor,
  }) async {
    final resp = await _post('/api/v1/channels/$chanID/posts', {
      'encrypted_payload': encryptedPayload,
      'signature': signature,
      'post_token': ?postToken,
      'message_type': messageType,
      'attachment_id': ?attachmentId,
      if (silent) 'silent': true,
      if (scheduledFor != null)
        'scheduled_for': scheduledFor.toUtc().toIso8601String(),
    });
    return Message.fromJson(resp['data'] as Map<String, dynamic>);
  }

  // ---- Messages ----

  Future<List<Message>> getMessages(
    String convID, {
    String? beforeID,
    int limit = 50,
  }) async {
    var path = '/api/v1/conversations/$convID/messages?limit=$limit';
    if (beforeID != null) path += '&before=$beforeID';
    final resp = await _get(path);
    return (resp['data'] as List)
        .map((e) => Message.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<SharedContentPage> getSharedContent(
    String convID, {
    required String section,
    bool channel = false,
    String? beforeID,
    int limit = 50,
  }) async {
    final base = channel ? '/api/v1/channels' : '/api/v1/conversations';
    final encodedSection = Uri.encodeQueryComponent(section);
    var path =
        '$base/$convID/shared-content?section=$encodedSection&limit=$limit';
    if (beforeID != null) path += '&before=$beforeID';
    final resp = await _get(path);
    final items = (resp['data'] as List? ?? const [])
        .map((e) => Message.fromJson(e as Map<String, dynamic>))
        .toList();
    final meta = resp['meta'] as Map<String, dynamic>?;
    final nextCursor = meta?['next_cursor'] as String?;
    return SharedContentPage(
      items: items,
      nextCursor: nextCursor?.isEmpty == true ? null : nextCursor,
    );
  }

  Future<Message> sendMessage({
    required String convID,
    required String encryptedPayload,
    required String signature,
    String? postToken,
    String messageType = 'text',
    String? replyTo,
    String? attachmentId,
    String? topicId,
    bool silent = false,
    DateTime? scheduledFor,
    String? clientNonce,
  }) async {
    final resp = await _post('/api/v1/conversations/$convID/messages', {
      'encrypted_payload': encryptedPayload,
      'signature': signature,
      'post_token': ?postToken,
      'message_type': messageType,
      'reply_to': ?replyTo,
      'attachment_id': ?attachmentId,
      'topic_id': ?topicId,
      if (silent) 'silent': true,
      if (scheduledFor != null)
        'scheduled_for': scheduledFor.toUtc().toIso8601String(),
      // Idempotency key: a retried send maps onto the original message
      // server-side instead of duplicating it.
      'client_nonce': ?clientNonce,
    });
    return Message.fromJson(resp['data'] as Map<String, dynamic>);
  }

  Future<Message> sendSealedMessage({
    required String convID,
    required String encryptedPayload,
    required String postToken,
    String? replyTo,
    String? attachmentId,
    String? topicId,
    bool silent = false,
    String? clientNonce,
  }) async {
    final resp = await _post('/api/v1/conversations/$convID/sealed-messages', {
      'encrypted_payload': encryptedPayload,
      'post_token': postToken,
      'reply_to': ?replyTo,
      'attachment_id': ?attachmentId,
      'topic_id': ?topicId,
      if (silent) 'silent': true,
      'client_nonce': ?clientNonce,
    }, authenticated: false);
    final message = Message.fromJson(resp['data'] as Map<String, dynamic>);
    await _saveSealedMessageControlFromMessage(convID, message);
    return message;
  }

  Future<ScheduledMessage> scheduleSealedMessage({
    required String convID,
    required String encryptedPayload,
    required String postToken,
    required DateTime scheduledFor,
    String? replyTo,
    String? attachmentId,
    String? topicId,
    bool silent = false,
  }) async {
    final resp = await _post('/api/v1/conversations/$convID/sealed-messages', {
      'encrypted_payload': encryptedPayload,
      'post_token': postToken,
      'reply_to': ?replyTo,
      'attachment_id': ?attachmentId,
      'topic_id': ?topicId,
      'scheduled_for': scheduledFor.toUtc().toIso8601String(),
      if (silent) 'silent': true,
    }, authenticated: false);
    final scheduled = ScheduledMessage.fromJson(
      resp['data'] as Map<String, dynamic>,
    );
    final controlToken = scheduled.controlToken;
    if (controlToken != null && controlToken.isNotEmpty) {
      await _storage.saveSealedScheduleControlToken(
        convID,
        scheduled.id,
        controlToken,
      );
      await _appendSealedScheduleControlEvent(
        operation: 'upsert',
        conversationId: convID,
        scheduledId: scheduled.id,
        controlToken: controlToken,
      );
    }
    return scheduled;
  }

  Future<Message> sendSealedPgpMessage({
    required String convID,
    required String encryptedPayload,
    required String postToken,
    String? replyTo,
    String? attachmentId,
    String? topicId,
    bool silent = false,
  }) {
    return sendSealedMessage(
      convID: convID,
      encryptedPayload: encryptedPayload,
      postToken: postToken,
      replyTo: replyTo,
      attachmentId: attachmentId,
      topicId: topicId,
      silent: silent,
    );
  }

  Future<String> getEncryptedSealedPostToken(String convID) async {
    final resp = await _get('/api/v1/conversations/$convID/sealed-post-token');
    final data = resp['data'] as Map<String, dynamic>;
    return data['encrypted_post_token'] as String;
  }

  Future<String> getEncryptedPgpPostToken(String convID) =>
      getEncryptedSealedPostToken(convID);

  Future<List<ScheduledMessage>> listScheduledMessages(
    String convID, {
    bool channel = false,
  }) async {
    await syncSelfStateLog();
    final base = channel
        ? '/api/v1/channels/$convID/scheduled-posts'
        : '/api/v1/conversations/$convID/scheduled-messages';
    final resp = await _get(base);
    final authenticatedItems = (resp['data'] as List? ?? const [])
        .map((e) => ScheduledMessage.fromJson(e as Map<String, dynamic>))
        .toList();
    final controlTokens = await _storage.getSealedScheduleControlTokens(convID);
    if (controlTokens.isEmpty) return authenticatedItems;

    final sealedItems = <ScheduledMessage>[];
    final tokenValues = controlTokens.values.toList();
    for (var i = 0; i < tokenValues.length; i += 100) {
      final batch = tokenValues.skip(i).take(100).toList();
      final sealedResp = await _post(
        '/api/v1/conversations/$convID/sealed-scheduled-messages/list',
        {'control_tokens': batch},
        authenticated: false,
      );
      sealedItems.addAll(
        (sealedResp['data'] as List? ?? const [])
            .map((e) => ScheduledMessage.fromJson(e as Map<String, dynamic>))
            .map((item) {
              final token = item.controlToken ?? controlTokens[item.id];
              return token == null ? item : item.copyWith(controlToken: token);
            }),
      );
    }
    final returnedSealedIds = sealedItems.map((item) => item.id).toSet();
    for (final scheduledID in controlTokens.keys) {
      if (!returnedSealedIds.contains(scheduledID)) {
        await _storage.deleteSealedScheduleControlToken(convID, scheduledID);
      }
    }
    final merged = <String, ScheduledMessage>{
      for (final item in authenticatedItems) item.id: item,
      for (final item in sealedItems) item.id: item,
    }.values.toList()..sort((a, b) => a.scheduledFor.compareTo(b.scheduledFor));
    return merged;
  }

  Future<void> cancelScheduledMessage(
    String convID,
    String scheduledID, {
    bool channel = false,
  }) async {
    final controlToken = await _storage.getSealedScheduleControlToken(
      convID,
      scheduledID,
    );
    if (controlToken != null && controlToken.isNotEmpty) {
      await _post(
        '/api/v1/conversations/$convID/sealed-scheduled-messages/$scheduledID/cancel',
        {'control_token': controlToken},
        authenticated: false,
      );
      await _storage.deleteSealedScheduleControlToken(convID, scheduledID);
      await _appendSealedScheduleControlEvent(
        operation: 'delete',
        conversationId: convID,
        scheduledId: scheduledID,
      );
      return;
    }
    final base = channel
        ? '/api/v1/channels/$convID/scheduled-posts'
        : '/api/v1/conversations/$convID/scheduled-messages';
    await _delete('$base/$scheduledID');
  }

  Future<void> rescheduleScheduledMessage(
    String convID,
    String scheduledID, {
    required DateTime scheduledFor,
    bool channel = false,
  }) async {
    final controlToken = await _storage.getSealedScheduleControlToken(
      convID,
      scheduledID,
    );
    if (controlToken != null && controlToken.isNotEmpty) {
      await _put(
        '/api/v1/conversations/$convID/sealed-scheduled-messages/$scheduledID',
        {
          'control_token': controlToken,
          'scheduled_for': scheduledFor.toUtc().toIso8601String(),
        },
        authenticated: false,
      );
      return;
    }
    final base = channel
        ? '/api/v1/channels/$convID/scheduled-posts'
        : '/api/v1/conversations/$convID/scheduled-messages';
    await _put('$base/$scheduledID', {
      'scheduled_for': scheduledFor.toUtc().toIso8601String(),
    });
  }

  Future<Message> sendScheduledMessageNow(
    String convID,
    String scheduledID, {
    bool channel = false,
  }) async {
    final controlToken = await _storage.getSealedScheduleControlToken(
      convID,
      scheduledID,
    );
    if (controlToken != null && controlToken.isNotEmpty) {
      final resp = await _post(
        '/api/v1/conversations/$convID/sealed-scheduled-messages/$scheduledID/send-now',
        {'control_token': controlToken},
        authenticated: false,
      );
      await _storage.deleteSealedScheduleControlToken(convID, scheduledID);
      await _appendSealedScheduleControlEvent(
        operation: 'delete',
        conversationId: convID,
        scheduledId: scheduledID,
      );
      final message = Message.fromJson(resp['data'] as Map<String, dynamic>);
      await _saveSealedMessageControlFromMessage(convID, message);
      return message;
    }
    final base = channel
        ? '/api/v1/channels/$convID/scheduled-posts'
        : '/api/v1/conversations/$convID/scheduled-messages';
    final resp = await _post('$base/$scheduledID/send-now', {});
    return Message.fromJson(resp['data'] as Map<String, dynamic>);
  }

  Future<List<SelfStateEvent>> listSelfStateLog({
    int after = 0,
    int limit = 200,
  }) async {
    final resp = await _get(
      '/api/v1/users/me/self-state-log?after=$after&limit=$limit',
    );
    return (resp['data'] as List? ?? const [])
        .map((e) => SelfStateEvent.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<SelfStateEvent> appendSelfStateLog(String encryptedPayload) async {
    final resp = await _post('/api/v1/users/me/self-state-log', {
      'encrypted_payload': encryptedPayload,
    });
    return SelfStateEvent.fromJson(resp['data'] as Map<String, dynamic>);
  }

  Future<void> syncSelfStateLog() async {
    try {
      final privateKey = await _storage.getPrivateKeyIfUnlocked() ?? '';
      if (privateKey.isEmpty) return;

      var after = await _storage.getSelfStateLogSequence();
      var maxSequence = after;
      while (true) {
        final events = await listSelfStateLog(after: after, limit: 200);
        if (events.isEmpty) break;

        for (final event in events) {
          if (event.sequence > maxSequence) maxSequence = event.sequence;
          await _applySelfStateEvent(event, privateKey);
        }
        after = maxSequence;
        if (events.length < 200) break;
      }

      if (maxSequence > await _storage.getSelfStateLogSequence()) {
        await _storage.saveSelfStateLogSequence(maxSequence);
      }
    } catch (_) {
      return;
    }
  }

  Future<void> _applySelfStateEvent(
    SelfStateEvent event,
    String privateKey,
  ) async {
    try {
      final raw = await PgpService.decrypt(
        encryptedArmor: event.encryptedPayload,
        privateKeyArmored: privateKey,
      );
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final payload = Map<String, dynamic>.from(decoded);
      if (payload['openchat_self_state'] != 1) return;
      final kind = payload['kind'];

      final conversationId = payload['conversation_id'] as String? ?? '';
      if (conversationId.isEmpty) return;

      if (kind == 'sealed_schedule_control') {
        final scheduledId = payload['scheduled_id'] as String? ?? '';
        if (scheduledId.isEmpty) return;
        switch (payload['operation']) {
          case 'upsert':
            final controlToken = payload['control_token'] as String? ?? '';
            if (controlToken.isNotEmpty) {
              await _storage.saveSealedScheduleControlToken(
                conversationId,
                scheduledId,
                controlToken,
              );
            }
            break;
          case 'delete':
            await _storage.deleteSealedScheduleControlToken(
              conversationId,
              scheduledId,
            );
            break;
        }
      } else if (kind == 'sealed_message_control') {
        final messageId = payload['message_id'] as String? ?? '';
        if (messageId.isEmpty) return;
        switch (payload['operation']) {
          case 'upsert':
            final controlToken = payload['control_token'] as String? ?? '';
            if (controlToken.isNotEmpty) {
              await _storage.saveSealedMessageControlToken(
                conversationId,
                messageId,
                controlToken,
              );
            }
            break;
          case 'delete':
            await _storage.deleteSealedMessageControlToken(
              conversationId,
              messageId,
            );
            break;
        }
      }
    } catch (_) {
      return;
    }
  }

  Future<void> _appendSealedScheduleControlEvent({
    required String operation,
    required String conversationId,
    required String scheduledId,
    String? controlToken,
  }) async {
    final payload = <String, dynamic>{
      'openchat_self_state': 1,
      'kind': 'sealed_schedule_control',
      'operation': operation,
      'conversation_id': conversationId,
      'scheduled_id': scheduledId,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      if (controlToken != null && controlToken.isNotEmpty)
        'control_token': controlToken,
    };
    final encrypted = await _encryptSelfStatePayload(payload);
    if (encrypted == null) return;
    try {
      await appendSelfStateLog(encrypted);
    } catch (_) {
      return;
    }
  }

  Future<void> _saveSealedMessageControlFromMessage(
    String conversationId,
    Message message,
  ) async {
    final controlToken = message.controlToken;
    if (controlToken == null || controlToken.isEmpty) return;
    await _storage.saveSealedMessageControlToken(
      conversationId,
      message.id,
      controlToken,
    );
    await _appendSealedMessageControlEvent(
      operation: 'upsert',
      conversationId: conversationId,
      messageId: message.id,
      controlToken: controlToken,
    );
  }

  Future<void> promoteSealedScheduledControlToMessage(
    String conversationId,
    String messageId,
  ) async {
    final scheduleToken = await _storage.getSealedScheduleControlToken(
      conversationId,
      messageId,
    );
    if (scheduleToken == null || scheduleToken.isEmpty) return;

    final existingMessageToken = await _storage.getSealedMessageControlToken(
      conversationId,
      messageId,
    );
    if (existingMessageToken != scheduleToken) {
      await _storage.saveSealedMessageControlToken(
        conversationId,
        messageId,
        scheduleToken,
      );
      await _appendSealedMessageControlEvent(
        operation: 'upsert',
        conversationId: conversationId,
        messageId: messageId,
        controlToken: scheduleToken,
      );
    }

    await _storage.deleteSealedScheduleControlToken(conversationId, messageId);
    await _appendSealedScheduleControlEvent(
      operation: 'delete',
      conversationId: conversationId,
      scheduledId: messageId,
    );
  }

  Future<void> _appendSealedMessageControlEvent({
    required String operation,
    required String conversationId,
    required String messageId,
    String? controlToken,
  }) async {
    final payload = <String, dynamic>{
      'openchat_self_state': 1,
      'kind': 'sealed_message_control',
      'operation': operation,
      'conversation_id': conversationId,
      'message_id': messageId,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      if (controlToken != null && controlToken.isNotEmpty)
        'control_token': controlToken,
    };
    final encrypted = await _encryptSelfStatePayload(payload);
    if (encrypted == null) return;
    try {
      await appendSelfStateLog(encrypted);
    } catch (_) {
      return;
    }
  }

  Future<String?> _encryptSelfStatePayload(Map<String, dynamic> payload) async {
    final userId = await _storage.getUserID() ?? '';
    final publicKey = await _storage.getPublicKey() ?? '';
    final fingerprint = await _storage.getFingerprint() ?? '';
    final privateKey = await _storage.getPrivateKeyIfUnlocked() ?? '';
    if (userId.isEmpty ||
        publicKey.trim().isEmpty ||
        fingerprint.trim().isEmpty ||
        privateKey.trim().isEmpty) {
      return null;
    }
    return PgpService.encrypt(
      plaintext: jsonEncode(payload),
      recipients: [
        PgpRecipient(
          userId: userId,
          publicKeyArmored: publicKey,
          keyFingerprint: fingerprint,
        ),
      ],
      signingPrivateKeyArmored: privateKey,
    );
  }

  Future<Message> createPoll({
    required String convID,
    required String question,
    required List<String> options,
    bool isAnonymous = true,
    bool allowsMultipleAnswers = false,
    bool allowsRevoting = true,
    bool silent = false,
    bool quiz = false,
    bool meeting = false,
    int? correctOptionId,
    String? explanation,
  }) async {
    final resp = await _post('/api/v1/conversations/$convID/polls', {
      'question': question,
      'options': options,
      'is_anonymous': isAnonymous,
      // Quiz mode is single-answer with no revoting (reveal after voting);
      // meeting mode is multi-answer (pick all times that work).
      'allows_multiple_answers':
          meeting ? true : (quiz ? false : allowsMultipleAnswers),
      'allows_revoting': quiz ? false : allowsRevoting,
      if (quiz) 'type': 'quiz' else if (meeting) 'type': 'meeting',
      if (quiz && correctOptionId != null)
        'correct_option_ids': [correctOptionId],
      if (quiz && explanation != null && explanation.trim().isNotEmpty)
        'explanation': explanation.trim(),
      if (silent) 'silent': true,
    });
    final message = Message.fromJson(resp['data'] as Map<String, dynamic>);
    await _saveSealedMessageControlFromMessage(convID, message);
    return message;
  }

  Future<Message> createEncryptedPoll({
    required String convID,
    required String pollID,
    required List<String> optionIDs,
    required String encryptedPayload,
    required String postToken,
    bool isAnonymous = true,
    bool allowsMultipleAnswers = false,
    bool allowsRevoting = true,
    bool silent = false,
    bool quiz = false,
    bool meeting = false,
    int? correctOptionId,
    String? explanation,
  }) async {
    final resp = await _post('/api/v1/conversations/$convID/polls', {
      'poll_id': pollID,
      'option_ids': optionIDs,
      'encrypted_payload': encryptedPayload,
      'post_token': postToken,
      'is_anonymous': isAnonymous,
      'allows_multiple_answers': allowsMultipleAnswers,
      'allows_revoting': allowsRevoting,
      if (quiz) 'type': 'quiz' else if (meeting) 'type': 'meeting',
      if (quiz && correctOptionId != null)
        'correct_option_ids': [correctOptionId],
      if (quiz && explanation != null && explanation.trim().isNotEmpty)
        'explanation': explanation.trim(),
      if (silent) 'silent': true,
    });
    final message = Message.fromJson(resp['data'] as Map<String, dynamic>);
    await _saveSealedMessageControlFromMessage(convID, message);
    return message;
  }

  Future<Poll> votePoll(String pollID, List<String> optionIDs) async {
    final resp = await _post('/api/v1/polls/$pollID/votes', {
      'option_ids': optionIDs,
    });
    return Poll.fromJson(resp['data'] as Map<String, dynamic>);
  }

  /// Issues this member's single blind vote token for an anonymous poll. The
  /// raw token is returned exactly once — keep it to be able to revote.
  Future<String> requestPollVoteToken(String pollID) async {
    final resp = await _post('/api/v1/polls/$pollID/vote-token', {});
    return (resp['data'] as Map<String, dynamic>)['vote_token'] as String;
  }

  /// Votes on an anonymous poll with a blind token — the server stores the
  /// choice against the token's hash, never against this account.
  Future<Poll> votePollAnonymous(
    String pollID,
    String token,
    List<String> optionIDs,
  ) async {
    final resp = await _post('/api/v1/polls/$pollID/vote-anonymous', {
      'token': token,
      'option_ids': optionIDs,
    });
    return Poll.fromJson(resp['data'] as Map<String, dynamic>);
  }

  Future<Poll> stopPoll(
    String pollID, {
    String? convID,
    String? messageID,
  }) async {
    String? controlToken;
    if (convID != null && messageID != null) {
      controlToken = await _storage.getSealedMessageControlToken(
        convID,
        messageID,
      );
    }
    final resp = await _post('/api/v1/polls/$pollID/stop', {
      if (controlToken != null && controlToken.isNotEmpty)
        'control_token': controlToken,
    });
    return Poll.fromJson(resp['data'] as Map<String, dynamic>);
  }

  Future<void> reactToMessage(String msgID, String emoji) async {
    await _post('/api/v1/messages/$msgID/reactions', {'emoji': emoji});
  }

  Future<void> removeReaction(String msgID, String emoji) async {
    await _delete(
      '/api/v1/messages/$msgID/reactions?emoji=${Uri.encodeComponent(emoji)}',
    );
  }

  /// Who reacted to a message: list of {user_id, username, display_name?,
  /// avatar_url?, emoji}.
  Future<List<Map<String, dynamic>>> getMessageReactors(String msgID) async {
    final resp = await _get('/api/v1/messages/$msgID/reactions');
    return ((resp['data'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
  }

  Future<void> sendBotCallback({
    required String convID,
    required String msgID,
    required String data,
  }) async {
    await _post('/api/v1/conversations/$convID/messages/$msgID/callback', {
      'data': data,
    });
  }

  Future<Conversation> getSavedMessages() async {
    final resp = await _get('/api/v1/conversations/saved-messages');
    return Conversation.fromJson(resp['data'] as Map<String, dynamic>);
  }

  Future<void> deleteMessage(
    String convID,
    String msgID, {
    String? controlToken,
  }) async {
    var path = '/api/v1/conversations/$convID/messages/$msgID';
    // Sealed-sender messages have no recorded author, so deletion is authorized
    // by the per-message control token (same capability used for edits).
    if (controlToken != null && controlToken.isNotEmpty) {
      path += '?control_token=${Uri.encodeQueryComponent(controlToken)}';
    }
    await _delete(path);
  }

  Future<void> deleteOwnMessages(String convID) async {
    await _delete('/api/v1/conversations/$convID/messages?scope=mine');
  }

  Future<void> deleteAllConversationMessages(String convID) async {
    await _delete('/api/v1/conversations/$convID/messages?scope=all');
  }

  Future<void> deleteChannelUserMessages(String chanID, String userID) async {
    await _delete('/api/v1/channels/$chanID/posts?scope=user&user_id=$userID');
  }

  Future<void> deleteOwnChannelMessages(String chanID) async {
    await _delete('/api/v1/channels/$chanID/posts?scope=mine');
  }

  /// Set the disappearing-messages timer (seconds; 0 = off).
  Future<void> setMessageTtl(String convID, int seconds) async {
    await _put('/api/v1/conversations/$convID/message-ttl', {
      'seconds': seconds,
    });
  }

  Future<void> setSlowMode(
    String convID,
    int seconds, {
    bool channel = false,
  }) async {
    final base = channel ? '/api/v1/channels' : '/api/v1/conversations';
    await _put('$base/$convID/slow-mode', {'seconds': seconds});
  }

  Future<void> setJoinApproval(
    String convID,
    bool required, {
    bool channel = false,
  }) async {
    final base = channel ? '/api/v1/channels' : '/api/v1/conversations';
    await _put('$base/$convID/join-approval', {'required': required});
  }

  Future<List<ConversationInviteLink>> listConversationInviteLinks(
    String convID, {
    bool channel = false,
  }) async {
    final base = channel ? '/api/v1/channels' : '/api/v1/conversations';
    final resp = await _get('$base/$convID/invite-links');
    return (resp['data'] as List? ?? const [])
        .map((e) => ConversationInviteLink.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<ConversationInviteLink> createConversationInviteLink(
    String convID, {
    bool channel = false,
    bool approvalRequired = false,
    bool revokeExisting = false,
    int expiresInSeconds = 0,
    int? usageLimit,
  }) async {
    final base = channel ? '/api/v1/channels' : '/api/v1/conversations';
    final resp = await _post('$base/$convID/invite-links', {
      'approval_required': approvalRequired,
      'revoke_existing': revokeExisting,
      'expires_in_seconds': expiresInSeconds,
      'usage_limit': ?usageLimit,
    });
    return ConversationInviteLink.fromJson(
      resp['data'] as Map<String, dynamic>,
    );
  }

  Future<void> revokeConversationInviteLink(
    String convID,
    String linkID, {
    bool channel = false,
  }) async {
    final base = channel ? '/api/v1/channels' : '/api/v1/conversations';
    await _delete('$base/$convID/invite-links/$linkID');
  }

  Future<List<ConversationJoinRequest>> listJoinRequests(
    String convID, {
    bool channel = false,
  }) async {
    final base = channel ? '/api/v1/channels' : '/api/v1/conversations';
    final resp = await _get('$base/$convID/join-requests');
    return (resp['data'] as List? ?? const [])
        .map((e) => ConversationJoinRequest.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> approveJoinRequest(
    String convID,
    String userID, {
    bool channel = false,
  }) async {
    final base = channel ? '/api/v1/channels' : '/api/v1/conversations';
    await _post('$base/$convID/join-requests/$userID/approve', {});
  }

  Future<void> rejectJoinRequest(
    String convID,
    String userID, {
    bool channel = false,
  }) async {
    final base = channel ? '/api/v1/channels' : '/api/v1/conversations';
    await _delete('$base/$convID/join-requests/$userID');
  }

  Future<InvitePreview> getInvite(String token) async {
    final resp = await _get('/api/v1/invites/${Uri.encodeComponent(token)}');
    return InvitePreview.fromJson(resp['data'] as Map<String, dynamic>);
  }

  Future<InviteJoinResult> joinInvite(String token) async {
    final resp = await _post(
      '/api/v1/invites/${Uri.encodeComponent(token)}/join',
      {},
    );
    return InviteJoinResult.fromJson(resp['data'] as Map<String, dynamic>);
  }

  Future<void> setTopicsEnabled(
    String convID,
    bool enabled, {
    bool channel = false,
  }) async {
    final base = channel ? '/api/v1/channels' : '/api/v1/conversations';
    await _put('$base/$convID/topics-enabled', {'enabled': enabled});
  }

  Future<ChannelAnalytics> getChannelStats(String chanID) async {
    final resp = await _get('/api/v1/channels/$chanID/stats');
    return ChannelAnalytics.fromJson(resp['data'] as Map<String, dynamic>);
  }

  Future<void> setEncryptionMode(
    String convID,
    String mode, {
    MlsBootstrap? mlsBootstrap,
  }) async {
    await _put('/api/v1/conversations/$convID/encryption', {
      'mode': mode,
      ...?mlsBootstrap?.toEncryptionJson(),
    });
  }

  Future<ConversationMlsState> getConversationMlsState(String convID) async {
    final resp = await _get('/api/v1/conversations/$convID/mls');
    return ConversationMlsState.fromJson(resp['data'] as Map<String, dynamic>);
  }

  Future<ConversationMlsCommit> postConversationMlsCommit(
    String convID,
    String commitPayload, {
    MlsBootstrap? nextState,
  }) async {
    try {
      final resp = await _post('/api/v1/conversations/$convID/mls/commits', {
        'commit_payload': commitPayload,
        ...?nextState?.toCommitJson(),
      });
      return ConversationMlsCommit.fromJson(
        resp['data'] as Map<String, dynamic>,
      );
    } on ApiException catch (e) {
      if (e.statusCode == 409 && e.code == 'MLS_EPOCH_CONFLICT') {
        throw const MlsEpochConflictException();
      }
      rethrow;
    }
  }

  Future<Message> editMessage({
    required String convID,
    required String msgID,
    required String encryptedPayload,
    required String signature,
  }) async {
    var controlToken = await _storage.getSealedMessageControlToken(
      convID,
      msgID,
    );
    controlToken ??= await _storage.getSealedScheduleControlToken(
      convID,
      msgID,
    );
    final resp = await _put('/api/v1/conversations/$convID/messages/$msgID', {
      'encrypted_payload': encryptedPayload,
      'signature': signature,
      if (controlToken != null && controlToken.isNotEmpty)
        'control_token': controlToken,
    });
    return Message.fromJson(resp['data'] as Map<String, dynamic>);
  }

  Future<void> markRead(String convID, String messageID) async {
    await _post('/api/v1/conversations/$convID/read', {
      'message_id': messageID,
    });
  }

  // ---- Stories ----

  Future<List<Story>> getStories({
    bool archive = false,
    bool pinned = false,
    String? userId,
    String? conversationId,
    int limit = 100,
  }) async {
    final params = <String>[
      'limit=$limit',
      if (archive) 'archive=true',
      if (pinned) 'pinned=true',
      if (userId != null) 'user_id=${Uri.encodeComponent(userId)}',
      if (conversationId != null)
        'conversation_id=${Uri.encodeComponent(conversationId)}',
    ];
    final resp = await _get('/api/v1/stories?${params.join('&')}');
    return (resp['data'] as List? ?? [])
        .map((e) => Story.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Creates a story. For private audiences (contacts / selected) pass
  /// [encryptedPayload] — a PGP envelope holding the media key, nonce,
  /// caption, filename, and MIME type — and leave the plaintext fields null:
  /// the server must NOT be able to decrypt story media. Public and channel
  /// stories have no fixed audience to encrypt to, so they use the plaintext
  /// fields.
  Future<Story> createStory({
    required String attachmentId,
    required int fileSize,
    required String mediaType,
    String? fileName,
    String? mimeType,
    String? fileKey,
    String? fileNonce,
    String? encryptedPayload,
    String caption = '',
    String privacy = 'contacts',
    List<String> allowUserIds = const [],
    String? conversationId,
    int expiresInSeconds = 24 * 60 * 60,
    bool pinned = false,
    bool noForwards = false,
    List<Map<String, dynamic>> entities = const [],
  }) async {
    final resp = await _post('/api/v1/stories', {
      'attachment_id': attachmentId,
      'file_name': ?fileName,
      'file_size': fileSize,
      'mime_type': ?mimeType,
      'file_key': ?fileKey,
      'file_nonce': ?fileNonce,
      'encrypted_payload': ?encryptedPayload,
      'media_type': mediaType,
      'caption': caption,
      'entities': entities,
      'privacy': privacy,
      if (allowUserIds.isNotEmpty) 'allow_user_ids': allowUserIds,
      'conversation_id': ?conversationId,
      'expires_in_seconds': expiresInSeconds,
      if (pinned) 'pinned': true,
      if (noForwards) 'no_forwards': true,
    });
    return Story.fromJson(resp['data'] as Map<String, dynamic>);
  }

  Future<Story> getStory(String storyId) async {
    final resp = await _get('/api/v1/stories/$storyId');
    return Story.fromJson(resp['data'] as Map<String, dynamic>);
  }

  Future<Story> viewStory(String storyId) async {
    final resp = await _post('/api/v1/stories/$storyId/view', {});
    return Story.fromJson(resp['data'] as Map<String, dynamic>);
  }

  Future<Story> reactToStory(String storyId, String emoji) async {
    final resp = await _post('/api/v1/stories/$storyId/reactions', {
      'emoji': emoji,
    });
    return Story.fromJson(resp['data'] as Map<String, dynamic>);
  }

  Future<Story> deleteStoryReaction(String storyId) async {
    await _delete('/api/v1/stories/$storyId/reactions');
    return getStory(storyId);
  }

  Future<void> deleteStory(String storyId) async {
    await _delete('/api/v1/stories/$storyId');
  }

  Future<Story> pinStory(String storyId, bool pinned) async {
    final resp = await _put('/api/v1/stories/$storyId/pin', {'pinned': pinned});
    return Story.fromJson(resp['data'] as Map<String, dynamic>);
  }

  Future<Story> archiveStory(String storyId, bool archived) async {
    final resp = await _put('/api/v1/stories/$storyId/archive', {
      'archived': archived,
    });
    return Story.fromJson(resp['data'] as Map<String, dynamic>);
  }

  // ---- Attachments ----

  // ── Zero-knowledge encrypted backups ────────────────────────────────────
  // One opaque, client-side-encrypted blob per user. The server never sees
  // plaintext or keys — only size, hash, and timing.

  Future<Map<String, dynamic>> requestBackupUpload({
    required int size,
    required String sha256,
  }) async {
    final resp = await _post('/api/v1/backups/request-upload', {
      'size': size,
      'sha256': sha256,
    });
    return resp['data'] as Map<String, dynamic>;
  }

  Future<void> confirmBackupUpload(String objectKey) async {
    await _post('/api/v1/backups/confirm', {'object_key': objectKey});
  }

  /// Metadata + presigned download URL for the stored backup, or null when
  /// none exists.
  Future<Map<String, dynamic>?> getLatestBackup() async {
    try {
      final resp = await _get('/api/v1/backups/latest');
      return resp['data'] as Map<String, dynamic>;
    } on ApiException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<void> deleteServerBackup() async {
    await _delete('/api/v1/backups');
  }

  /// Downloads raw bytes from a presigned object-storage URL.
  Future<Uint8List> downloadBytes(String url) async {
    final response = await _httpClient.get(Uri.parse(url));
    if (response.statusCode >= 400) {
      throw ApiException(
        response.statusCode,
        'DOWNLOAD_FAILED',
        'object storage download failed',
      );
    }
    return response.bodyBytes;
  }

  /// Request a presigned PUT URL and create an attachment record.
  Future<UploadRequest> requestUpload({
    required String fileName,
    required int fileSize,
    required String mimeType,
  }) async {
    final resp = await _post('/api/v1/attachments', {
      'file_name': fileName,
      'file_size': fileSize,
      'mime_type': mimeType,
    });
    return UploadRequest.fromJson(resp['data'] as Map<String, dynamic>);
  }

  /// Upload raw bytes (already encrypted by client) directly to MinIO via presigned PUT URL.
  Future<void> uploadBytes(
    String uploadUrl,
    Uint8List bytes,
    String mimeType, {
    UploadProgressCallback? onProgress,
  }) async {
    if (onProgress != null) {
      await _uploadBytesWithProgress(uploadUrl, bytes, mimeType, onProgress);
      return;
    }

    final response = await _httpClient.put(
      Uri.parse(uploadUrl),
      headers: {'Content-Type': mimeType},
      body: bytes,
    );
    if (response.statusCode >= 400) {
      throw ApiException(
        response.statusCode,
        'UPLOAD_FAILED',
        'object storage upload failed',
      );
    }
  }

  Future<void> _uploadBytesWithProgress(
    String uploadUrl,
    Uint8List bytes,
    String mimeType,
    UploadProgressCallback onProgress,
  ) async {
    final total = bytes.length;
    final request = http.StreamedRequest('PUT', Uri.parse(uploadUrl));
    request.headers['Content-Type'] = mimeType;
    request.contentLength = total;

    final responseFuture = _httpClient.send(request);
    const chunkSize = 64 * 1024;
    var sent = 0;
    var closed = false;
    onProgress(0, total);

    try {
      for (var offset = 0; offset < total; offset += chunkSize) {
        final end = (offset + chunkSize).clamp(0, total).toInt();
        request.sink.add(bytes.sublist(offset, end));
        sent = end;
        onProgress(sent, total);
        await Future<void>.delayed(Duration.zero);
      }
      unawaited(request.sink.close());
      closed = true;

      final streamedResponse = await responseFuture;
      final response = await http.Response.fromStream(streamedResponse);
      if (response.statusCode >= 400) {
        throw ApiException(
          response.statusCode,
          'UPLOAD_FAILED',
          'object storage upload failed',
        );
      }
    } finally {
      if (!closed) {
        unawaited(request.sink.close());
      }
    }
  }

  /// Confirm that an attachment was successfully uploaded.
  Future<void> confirmUpload(String attachmentId, String uploadToken) async {
    await _post('/api/v1/attachments/$attachmentId/confirm', {
      'upload_token': uploadToken,
    });
  }

  /// Get a short-lived presigned download URL for an attachment.
  Future<DownloadInfo> getDownloadUrl(String attachmentId) async {
    final resp = await _get('/api/v1/attachments/$attachmentId/url');
    return DownloadInfo.fromJson(resp['data'] as Map<String, dynamic>);
  }

  // ---- Admin / Moderation ----

  Future<void> banUser(String userID) async {
    await _post('/api/v1/admin/users/$userID/ban', {});
  }

  Future<void> unbanUser(String userID) async {
    await _delete('/api/v1/admin/users/$userID/ban');
  }

  Future<void> flagScammer(String userID) async {
    await _post('/api/v1/admin/users/$userID/flag-scammer', {});
  }

  Future<void> unflagScammer(String userID) async {
    await _delete('/api/v1/admin/users/$userID/flag-scammer');
  }

  Future<void> grantPremiumMonth(String userID) async {
    await _post('/api/v1/admin/users/$userID/premium/month', {});
  }

  Future<void> updateProfile({
    String? username,
    String? displayName,
    bool? publicDiscovery,
    String? bio,
    String? avatarUrl,
    int? bubbleColor,
    bool clearBubbleColor = false,
  }) async {
    await _put('/api/v1/users/me', {
      'username': ?username,
      'display_name': ?displayName,
      'public_discovery': ?publicDiscovery,
      'bio': ?bio,
      'avatar_url': ?avatarUrl,
      if (clearBubbleColor)
        'bubble_color': ''
      else if (bubbleColor != null)
        'bubble_color': User.bubbleColorToJson(bubbleColor),
    });
  }

  Future<void> updatePreferences({bool? allowGroupAdd}) async {
    await _put('/api/v1/users/me/preferences', {
      'allow_group_add': ?allowGroupAdd,
    });
  }

  Future<void> deleteAccount({
    required String currentPassword,
    String? twoFactorPassword,
  }) async {
    final sealedMessageTokens = await _storage
        .getAllSealedMessageControlTokens();
    final sealedScheduleTokens = await _storage
        .getAllSealedScheduleControlTokens();
    await _deleteJson('/api/v1/users/me', {
      'current_password': currentPassword,
      if (twoFactorPassword != null && twoFactorPassword.trim().isNotEmpty)
        'two_factor_password': twoFactorPassword.trim(),
      'sealed_message_control_tokens': sealedMessageTokens,
      'sealed_schedule_control_tokens': sealedScheduleTokens,
    });
  }

  Future<Map<String, dynamic>> getSecuritySettings() async {
    final resp = await _get('/api/v1/me/security');
    return resp['data'] as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateSecuritySettings({
    String? twoFactorPassword,
    bool disableTwoFactor = false,
    int? accountSelfDestructDays,
  }) async {
    final resp = await _put('/api/v1/me/security', {
      'two_factor_password': ?twoFactorPassword,
      if (disableTwoFactor) 'disable_two_factor': true,
      'account_self_destruct_days': ?accountSelfDestructDays,
    });
    return resp['data'] as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> listSessions() async {
    final resp = await _get('/api/v1/me/sessions');
    return (resp['data'] as List)
        .map((e) => e as Map<String, dynamic>)
        .toList();
  }

  Future<void> revokeSession(String sessionId) async {
    await _delete('/api/v1/me/sessions/$sessionId');
  }

  Future<Map<String, dynamic>> getBusinessProfile() async {
    final resp = await _get('/api/v1/me/business');
    return resp['data'] as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateBusinessProfile({
    String? displayName,
    String? greetingMessage,
    String? awayMessage,
    List<Map<String, dynamic>> quickReplies = const [],
    Map<String, dynamic> openingHours = const {},
    bool enabled = false,
  }) async {
    final resp = await _put('/api/v1/me/business', {
      'display_name': displayName,
      'greeting_message': greetingMessage,
      'away_message': awayMessage,
      'quick_replies': quickReplies,
      'opening_hours': openingHours,
      'enabled': enabled,
    });
    return resp['data'] as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> listMiniApps({String query = ''}) async {
    final q = query.trim();
    final path = q.isEmpty
        ? '/api/v1/mini-apps'
        : '/api/v1/mini-apps?q=${Uri.encodeQueryComponent(q)}';
    final resp = await _get(path);
    return (resp['data'] as List? ?? const [])
        .map((item) => item as Map<String, dynamic>)
        .toList(growable: false);
  }

  Future<DateTime?> createDevicePairingBundle({
    required String tokenHash,
    required String encryptedPayload,
  }) async {
    final resp = await _post('/api/v1/me/device-pairing-bundles', {
      'token_hash': tokenHash,
      'encrypted_payload': encryptedPayload,
    });
    final data = resp['data'] as Map<String, dynamic>? ?? const {};
    final expiresAt = data['expires_at'] as String?;
    return expiresAt == null ? null : DateTime.tryParse(expiresAt);
  }

  Future<String> claimDevicePairingBundle({required String tokenHash}) async {
    final resp = await _post('/api/v1/device-pairing/claim', {
      'token_hash': tokenHash,
    }, authenticated: false);
    final data = resp['data'] as Map<String, dynamic>? ?? const {};
    return data['encrypted_payload'] as String? ?? '';
  }

  Future<void> deleteConversation(String convID) async {
    await _delete('/api/v1/conversations/$convID');
  }

  Future<void> leaveConversation(
    String convID, {
    bool deleteOwnMessages = false,
  }) async {
    await _delete(
      '/api/v1/conversations/$convID?leave=true&delete_own_messages=$deleteOwnMessages',
    );
  }

  /// Update a group conversation's name, description, and/or avatar (admin only).
  Future<void> updateConversation(
    String convID, {
    String? name,
    String? description,
    String? avatarUrl,
  }) async {
    await _put('/api/v1/conversations/$convID', {
      'name': ?name,
      'description': ?description,
      'avatar_url': ?avatarUrl,
    });
  }

  /// Set (or clear, with url=null) a group/bot-chat conversation-wide
  /// background. Premium-gated server-side. url must be an already-uploaded,
  /// metadata-stripped WEBP (see [uploadAvatar]).
  Future<void> setConversationBackground(String convID, String? url) async {
    await _put('/api/v1/conversations/$convID/background', {
      'background_url': url ?? '',
    });
  }

  /// Set (or clear) a channel's conversation-wide background. Premium + admin.
  Future<void> setChannelBackground(String chanID, String? url) async {
    await _put('/api/v1/channels/$chanID/background', {
      'background_url': url ?? '',
    });
  }

  // ---- Client config ----

  /// Premium/group/member-gated LiveKit room-join token for "Call with SFU".
  /// Returns {url, room, token}.
  Future<Map<String, dynamic>> getLiveKitToken(String conversationId) async {
    final resp = await _post('/api/v1/calls/livekit-token', {
      'conversation_id': conversationId,
    });
    return resp['data'] as Map<String, dynamic>;
  }

  /// Active SFU group call in a conversation (for the join banner). Returns
  /// {active, mode, participant_ids}.
  Future<Map<String, dynamic>> getActiveCall(String conversationId) async {
    final resp =
        await _get('/api/v1/conversations/$conversationId/active-call');
    return resp['data'] as Map<String, dynamic>;
  }

  Future<List<IceServer>> getIceServers() async {
    final resp = await _get('/api/v1/config', authenticated: false);
    final data = resp['data'];
    final list =
        (data is Map<String, dynamic> ? data['ice_servers'] : null) as List? ??
        const [];
    final servers = <IceServer>[];
    for (final entry in list) {
      if (entry is! Map<String, dynamic>) continue;
      final raw = entry['url'] ?? entry['urls'];
      final url = raw is List
          ? (raw.isEmpty ? null : raw.first?.toString())
          : raw?.toString();
      if (url == null || url.isEmpty) continue;
      servers.add(
        IceServer(
          url: url,
          username: entry['username']?.toString(),
          credential: entry['credential']?.toString(),
        ),
      );
    }
    return servers;
  }


  // ---- Stickers ----

  Future<List<dynamic>> getStickerPacks() async {
    final resp = await _get('/api/v1/stickers/packs');
    return resp['data'] as List;
  }

  Future<Map<String, dynamic>> getStickerPack(String packID) async {
    final resp = await _get('/api/v1/stickers/packs/$packID');
    return resp['data'] as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getSticker(String stickerID) async {
    final resp = await _get('/api/v1/stickers/$stickerID');
    return resp['data'] as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> createStickerPack({
    required String name,
    String? description,
    bool isDiscoverable = false,
  }) async {
    final resp = await _post('/api/v1/stickers/packs', {
      'name': name,
      'description': ?description,
      'is_discoverable': isDiscoverable,
    });
    return resp['data'] as Map<String, dynamic>;
  }

  /// Search publicly discoverable sticker packs.
  Future<List<dynamic>> discoverStickerPacks(String query) async {
    final resp = await _get('/api/v1/discover/stickers?q=${Uri.encodeQueryComponent(query)}');
    return resp['data'] as List? ?? const [];
  }

  /// Search publicly discoverable custom-emoji packs.
  Future<List<dynamic>> discoverCustomEmojiPacks(String query) async {
    final resp = await _get('/api/v1/discover/custom-emoji?q=${Uri.encodeQueryComponent(query)}');
    return resp['data'] as List? ?? const [];
  }

  Future<Map<String, dynamic>> addStickerToPack({
    required String packID,
    required Uint8List fileBytes,
    required String filename,
    required String name,
    String emoji = '',
  }) async {
    return await _multipartPost(
      '/api/v1/stickers/packs/$packID/stickers',
      fileField: 'file',
      fileBytes: fileBytes,
      filename: filename,
      fields: {'name': name, if (emoji.isNotEmpty) 'emoji': emoji},
    );
  }

  Future<void> deleteStickerFromPack(String packID, String stickerID) async {
    await _delete('/api/v1/stickers/packs/$packID/stickers/$stickerID');
  }

  Future<void> updateStickerPack(
    String packID, {
    String? name,
    String? description,
    String? coverUrl,
    bool? isDiscoverable,
  }) async {
    await _put('/api/v1/stickers/packs/$packID', {
      'name': ?name,
      'description': ?description,
      'cover_url': ?coverUrl,
      'is_discoverable': ?isDiscoverable,
    });
  }

  Future<void> addStickerPackToLibrary(String packID) async {
    await _post('/api/v1/stickers/packs/$packID/library', {});
  }

  Future<void> removeStickerPackFromLibrary(String packID) async {
    await _delete('/api/v1/stickers/packs/$packID/library');
  }

  // ---- Custom emoji ----

  Future<List<dynamic>> getCustomEmojiPacks() async {
    final resp = await _get('/api/v1/custom-emoji/packs');
    return resp['data'] as List;
  }

  Future<Map<String, dynamic>> getCustomEmojiPack(String packID) async {
    final resp = await _get('/api/v1/custom-emoji/packs/$packID');
    return resp['data'] as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getCustomEmoji(String emojiID) async {
    final resp = await _get('/api/v1/custom-emoji/$emojiID');
    return resp['data'] as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> createCustomEmojiPack({
    required String name,
    String? description,
    bool isDiscoverable = false,
  }) async {
    final resp = await _post('/api/v1/custom-emoji/packs', {
      'name': name,
      'description': ?description,
      'is_discoverable': isDiscoverable,
    });
    return resp['data'] as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> addCustomEmojiToPack({
    required String packID,
    required Uint8List fileBytes,
    required String filename,
    required String name,
    required String emoji,
  }) async {
    return await _multipartPost(
      '/api/v1/custom-emoji/packs/$packID/emojis',
      fileField: 'file',
      fileBytes: fileBytes,
      filename: filename,
      fields: {'name': name, 'emoji': emoji},
    );
  }

  Future<void> deleteCustomEmojiFromPack(String packID, String emojiID) async {
    await _delete('/api/v1/custom-emoji/packs/$packID/emojis/$emojiID');
  }

  Future<void> updateCustomEmojiPack(
    String packID, {
    String? name,
    String? description,
    String? coverUrl,
    bool? isDiscoverable,
  }) async {
    await _put('/api/v1/custom-emoji/packs/$packID', {
      'name': ?name,
      'description': ?description,
      'cover_url': ?coverUrl,
      'is_discoverable': ?isDiscoverable,
    });
  }

  Future<void> addCustomEmojiPackToLibrary(String packID) async {
    await _post('/api/v1/custom-emoji/packs/$packID/library', {});
  }

  Future<void> removeCustomEmojiPackFromLibrary(String packID) async {
    await _delete('/api/v1/custom-emoji/packs/$packID/library');
  }

  /// Uploads an image and returns the public URL for use as an avatar.
  Future<String> uploadAvatar({
    required Uint8List fileBytes,
    required String filename,
  }) async {
    final data = await _multipartPost(
      '/api/v1/upload/avatar',
      fileField: 'file',
      fileBytes: fileBytes,
      filename: filename,
      fields: {},
    );
    return (data['data'] as Map<String, dynamic>)['url'] as String;
  }

  // ---- Channel management ----

  Future<void> updateChannel(
    String channelID, {
    String? name,
    String? description,
    String? avatarUrl,
    String? handle,
    bool? isPublic,
  }) async {
    await _put('/api/v1/channels/$channelID', {
      'name': ?name,
      'description': ?description,
      'avatar_url': ?avatarUrl,
      // Empty string is meaningful here: it tells the server to clear the
      // handle. Only omit the field entirely when handle is null (no change).
      'handle': ?handle,
      'is_public': ?isPublic,
    });
  }

  // ---- Bot management ----

  Future<List<dynamic>> listBots() async {
    final resp = await _get('/api/v1/bots');
    return resp['data'] as List;
  }

  Future<Map<String, dynamic>> createBot({
    required String username,
    required String publicKey,
    String? description,
    String? avatarUrl,
  }) async {
    final resp = await _post('/api/v1/bots', {
      'username': username,
      'public_key': publicKey,
      'description': ?description,
      'avatar_url': ?avatarUrl,
    });
    return resp['data'] as Map<String, dynamic>;
  }

  Future<void> updateBot(
    String botID, {
    String? description,
    String? avatarUrl,
    String? webhookUrl,
  }) async {
    await _put('/api/v1/bots/$botID', {
      'description': ?description,
      'avatar_url': ?avatarUrl,
      'webhook_url': ?webhookUrl,
    });
  }

  Future<void> deleteBot(String botID) async {
    await _delete('/api/v1/bots/$botID');
  }

  /// Issues a fresh API token for a bot, invalidating the old one. The raw
  /// token is only returned by this call — store it immediately.
  Future<String> regenerateBotToken(String botID) async {
    final resp = await _post('/api/v1/bots/$botID/token', {});
    return (resp['data'] as Map<String, dynamic>)['api_token'] as String;
  }

  // ---- Billing / Premium ----

  /// GET /api/v1/billing/status — returns enabled providers and plan prices.
  Future<Map<String, dynamic>> getBillingStatus() async {
    final resp = await _get('/api/v1/billing/status');
    return resp['data'] as Map<String, dynamic>;
  }

  /// POST /api/v1/billing/checkout — opens a new invoice with the given
  /// provider+plan. For Stripe the response includes a `redirect_url`.
  Future<Map<String, dynamic>> createCheckout({
    required String plan,
    required String provider,
    String source = 'external',
  }) async {
    final resp = await _post('/api/v1/billing/checkout', {
      'plan': plan,
      'provider': provider,
      'source': source,
    });
    return resp['data'] as Map<String, dynamic>;
  }

  /// GET /api/v1/billing/invoices/:id — polled while a crypto invoice is open.
  Future<Map<String, dynamic>> getInvoice(String invoiceID) async {
    final resp = await _get('/api/v1/billing/invoices/$invoiceID');
    return resp['data'] as Map<String, dynamic>;
  }

  Future<List<dynamic>> listInvoices() async {
    final resp = await _get('/api/v1/billing/invoices');
    return resp['data'] as List;
  }

  Future<void> cancelInvoice(String invoiceID) async {
    await _delete('/api/v1/billing/invoices/$invoiceID');
  }

  Future<List<dynamic>> getPaymentBalances() async {
    final resp = await _get('/api/v1/billing/balances');
    return (resp['data'] as List?) ?? const [];
  }

  Future<Map<String, dynamic>> createPaymentDeposit({
    required String provider,
  }) async {
    final resp = await _post('/api/v1/billing/deposits', {
      'provider': provider,
    });
    return resp['data'] as Map<String, dynamic>;
  }

  Future<List<dynamic>> listPaymentDeposits() async {
    final resp = await _get('/api/v1/billing/deposits');
    return (resp['data'] as List?) ?? const [];
  }

  Future<Map<String, dynamic>> getPaymentDeposit(String depositID) async {
    final resp = await _get('/api/v1/billing/deposits/$depositID');
    return resp['data'] as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> sendPaymentTransfer({
    required String toUserID,
    required String provider,
    double? amount,
    double? fiatAmount,
    String? fiatCurrency,
    String? conversationID,
    String? note,
  }) async {
    final resp = await _post('/api/v1/billing/transfers', {
      'to_user_id': toUserID,
      'provider': provider,
      ..._paymentAmountPayload(
        amount: amount,
        fiatAmount: fiatAmount,
        fiatCurrency: fiatCurrency,
      ),
      'conversation_id': ?conversationID,
      if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
    });
    return resp['data'] as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> createExternalPaymentTransfer({
    required String toUserID,
    required String provider,
    double? amount,
    double? fiatAmount,
    String? fiatCurrency,
    String? conversationID,
    String? note,
  }) async {
    final resp = await _post('/api/v1/billing/transfers/external', {
      'to_user_id': toUserID,
      'provider': provider,
      ..._paymentAmountPayload(
        amount: amount,
        fiatAmount: fiatAmount,
        fiatCurrency: fiatCurrency,
      ),
      'conversation_id': ?conversationID,
      if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
    });
    return resp['data'] as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> createPaymentRequest({
    String? payerID,
    String? conversationID,
    required String provider,
    double? amount,
    double? fiatAmount,
    String? fiatCurrency,
    String? title,
    String? note,
  }) async {
    final resp = await _post('/api/v1/billing/payment-requests', {
      'provider': provider,
      ..._paymentAmountPayload(
        amount: amount,
        fiatAmount: fiatAmount,
        fiatCurrency: fiatCurrency,
      ),
      'payer_id': ?payerID,
      'conversation_id': ?conversationID,
      if (title != null && title.trim().isNotEmpty) 'title': title.trim(),
      if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
    });
    return resp['data'] as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> payPaymentRequest(String requestID) async {
    final resp = await _post(
      '/api/v1/billing/payment-requests/$requestID/pay',
      {},
    );
    return resp['data'] as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> payPaymentRequestAmount({
    required String requestID,
    double? amount,
    double? fiatAmount,
    String? fiatCurrency,
  }) async {
    final resp = await _post(
      '/api/v1/billing/payment-requests/$requestID/pay',
      _paymentAmountPayload(
        amount: amount,
        fiatAmount: fiatAmount,
        fiatCurrency: fiatCurrency,
      ),
    );
    return resp['data'] as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> payPaymentRequestExternally({
    required String requestID,
    double? amount,
    double? fiatAmount,
    String? fiatCurrency,
  }) async {
    final resp = await _post(
      '/api/v1/billing/payment-requests/$requestID/pay-external',
      _paymentAmountPayload(
        amount: amount,
        fiatAmount: fiatAmount,
        fiatCurrency: fiatCurrency,
      ),
    );
    return resp['data'] as Map<String, dynamic>;
  }

  Map<String, dynamic> _paymentAmountPayload({
    double? amount,
    double? fiatAmount,
    String? fiatCurrency,
  }) {
    final normalizedFiatCurrency = fiatCurrency?.trim().toUpperCase();
    return {
      'amount': ?amount,
      'fiat_amount': ?fiatAmount,
      if (normalizedFiatCurrency != null && normalizedFiatCurrency.isNotEmpty)
        'fiat_currency': normalizedFiatCurrency,
    };
  }

  Future<List<dynamic>> listPaymentTransfers() async {
    final resp = await _get('/api/v1/billing/transfers');
    return (resp['data'] as List?) ?? const [];
  }

  Future<List<dynamic>> listPaymentRequests() async {
    final resp = await _get('/api/v1/billing/payment-requests');
    return (resp['data'] as List?) ?? const [];
  }

  Future<void> cancelPaymentRequest(String requestID) async {
    await _delete('/api/v1/billing/payment-requests/$requestID');
  }

  Future<void> declinePaymentRequest(String requestID) async {
    await _post('/api/v1/billing/payment-requests/$requestID/decline', {});
  }

  Future<Map<String, dynamic>> withdrawPaymentFunds({
    required String provider,
    required String address,
    required double amount,
  }) async {
    final resp = await _post('/api/v1/billing/withdrawals', {
      'provider': provider,
      'address': address,
      'amount': amount,
    });
    return resp['data'] as Map<String, dynamic>;
  }

  Future<List<dynamic>> listPaymentWithdrawals() async {
    final resp = await _get('/api/v1/billing/withdrawals');
    return (resp['data'] as List?) ?? const [];
  }

  // ---- Channel / conversation moderation ----

  /// Mute a user in [convID]. durationMinutes=0 (default) is indefinite.
  Future<void> muteUser({
    required String convID,
    required String userID,
    int durationMinutes = 0,
    String? reason,
  }) async {
    await _post('/api/v1/conversations/$convID/mutes', {
      'user_id': userID,
      'duration_minutes': durationMinutes,
      'reason': ?reason,
    });
  }

  Future<void> unmuteUser({
    required String convID,
    required String userID,
  }) async {
    await _delete('/api/v1/conversations/$convID/mutes/$userID');
  }

  Future<List<dynamic>> listMutes(String convID) async {
    final resp = await _get('/api/v1/conversations/$convID/mutes');
    return (resp['data'] as List?) ?? const [];
  }

  Future<List<AdminAuditEvent>> listAdminAuditEvents(
    String convID, {
    bool channel = false,
    int limit = 100,
  }) async {
    final base = channel ? '/api/v1/channels' : '/api/v1/conversations';
    final resp = await _get('$base/$convID/audit-events?limit=$limit');
    return (resp['data'] as List? ?? const [])
        .map((e) => AdminAuditEvent.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> setAntiSpamControls(
    String convID, {
    bool channel = false,
    required int newMemberCooldownSeconds,
    required bool blockLinks,
    required bool blockMedia,
    required int mentionLimit,
  }) async {
    final base = channel ? '/api/v1/channels' : '/api/v1/conversations';
    await _put('$base/$convID/anti-spam', {
      'new_member_cooldown_seconds': newMemberCooldownSeconds,
      'block_links': blockLinks,
      'block_media': blockMedia,
      'mention_limit': mentionLimit,
    });
  }

  Future<List<ModerationReport>> listModerationReports(
    String convID, {
    bool channel = false,
    String status = 'open',
    int limit = 100,
  }) async {
    final base = channel ? '/api/v1/channels' : '/api/v1/conversations';
    final resp = await _get(
      '$base/$convID/reports?status=${Uri.encodeComponent(status)}&limit=$limit',
    );
    return (resp['data'] as List? ?? const [])
        .map((e) => ModerationReport.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<ModerationReport> createModerationReport(
    String convID, {
    bool channel = false,
    String? messageID,
    String? reportedUserID,
    String reason = '',
  }) async {
    final base = channel ? '/api/v1/channels' : '/api/v1/conversations';
    final resp = await _post('$base/$convID/reports', {
      'message_id': ?messageID,
      'reported_user_id': ?reportedUserID,
      'reason': reason,
    });
    return ModerationReport.fromJson(resp['data'] as Map<String, dynamic>);
  }

  Future<void> resolveModerationReport(
    String convID,
    String reportID, {
    bool channel = false,
    required String status,
  }) async {
    final base = channel ? '/api/v1/channels' : '/api/v1/conversations';
    await _put('$base/$convID/reports/$reportID', {'status': status});
  }

  /// Flip the channel/group into broadcast mode (only admins can post).
  Future<void> setOwnerOnlyPost(String convID, bool enabled) async {
    await _put('/api/v1/conversations/$convID/owner-only-post', {
      'enabled': enabled,
    });
  }

  // ---- Device tokens (push notifications) ----

  Future<void> registerDeviceToken({
    required String token,
    required String platform,
  }) async {
    await _put('/api/v1/users/me/device-token', {
      'token': token,
      'platform': platform,
    });
  }

  Future<void> removeDeviceToken() async {
    await _delete('/api/v1/users/me/device-token');
  }

  /// Returns the caller's opaque push routing map: each entry is
  /// {conversation_id, route}. Push payloads carry only the `route`, so the
  /// client uses this to resolve a notification back to its conversation
  /// without the real id ever passing through FCM/APNs.
  /// Replaces the server-side set of muted push routes (opaque tokens from
  /// /me/push-routes). The server skips FCM pushes for these — a client-side
  /// mute alone can't suppress the OS-displayed Notification block.
  Future<void> setPushRouteMutes(List<String> routes) async {
    await _put('/api/v1/me/push-route-mutes', {'routes': routes});
  }

  Future<Map<String, String>> getPushRoutes() async {
    final resp = await _get('/api/v1/me/push-routes');
    final data = resp['data'] as Map<String, dynamic>?;
    final routes = (data?['routes'] as List?) ?? const [];
    final map = <String, String>{};
    for (final entry in routes) {
      if (entry is Map) {
        final route = entry['route']?.toString();
        final convID = entry['conversation_id']?.toString();
        if (route != null && route.isNotEmpty && convID != null && convID.isNotEmpty) {
          map[route] = convID;
        }
      }
    }
    return map;
  }

  // ---- HTTP helpers ----

  /// Sends a multipart/form-data POST. Returns the parsed response body.
  Future<Map<String, dynamic>> _multipartPost(
    String path, {
    required String fileField,
    required Uint8List fileBytes,
    required String filename,
    required Map<String, String> fields,
  }) async {
    Future<http.Response> send() async {
      final token = await _storage.getAccessToken();
      final uri = Uri.parse('${ApiConfig.baseUrl}$path');
      final req = http.MultipartRequest('POST', uri)
        ..headers.addAll({
          if (token != null) 'Authorization': 'Bearer $token',
          'X-OpenChat-Device': openChatDeviceName(),
        })
        ..fields.addAll(fields)
        ..files.add(
          http.MultipartFile.fromBytes(
            fileField,
            fileBytes,
            filename: filename,
          ),
        );
      final streamed = await req.send();
      return http.Response.fromStream(streamed);
    }

    final response = await _requestWithRetry(send);
    return _parse(response);
  }

  Future<Map<String, dynamic>> _get(
    String path, {
    bool authenticated = true,
  }) async {
    final response = await _requestWithRetry(() async {
      final token = authenticated ? await _storage.getAccessToken() : null;
      return _httpClient.get(
        Uri.parse('${ApiConfig.baseUrl}$path'),
        headers: _headers(token),
      );
    }, authenticated: authenticated);
    return _parse(response);
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body, {
    bool authenticated = true,
  }) async {
    final response = await _requestWithRetry(() async {
      final token = authenticated ? await _storage.getAccessToken() : null;
      return _httpClient.post(
        Uri.parse('${ApiConfig.baseUrl}$path'),
        headers: _headers(token),
        body: jsonEncode(body),
      );
    }, authenticated: authenticated);
    return _parse(response);
  }

  Future<Map<String, dynamic>> _put(
    String path,
    Map<String, dynamic> body, {
    bool authenticated = true,
  }) async {
    final response = await _requestWithRetry(() async {
      final token = authenticated ? await _storage.getAccessToken() : null;
      return _httpClient.put(
        Uri.parse('${ApiConfig.baseUrl}$path'),
        headers: _headers(token),
        body: jsonEncode(body),
      );
    }, authenticated: authenticated);
    return _parse(response);
  }

  Future<void> _delete(String path) async {
    await _requestWithRetry(() async {
      final token = await _storage.getAccessToken();
      return _httpClient.delete(
        Uri.parse('${ApiConfig.baseUrl}$path'),
        headers: _headers(token),
      );
    });
  }

  Future<void> _deleteJson(String path, Map<String, dynamic> body) async {
    final response = await _requestWithRetry(() async {
      final token = await _storage.getAccessToken();
      return _httpClient.delete(
        Uri.parse('${ApiConfig.baseUrl}$path'),
        headers: _headers(token),
        body: jsonEncode(body),
      );
    });
    _parse(response);
  }

  Map<String, String> _headers(String? token) => {
    'Content-Type': 'application/json',
    'X-OpenChat-Device': openChatDeviceName(),
    if (token != null) 'Authorization': 'Bearer $token',
  };

  Future<http.Response> _requestWithRetry(
    Future<http.Response> Function() fn, {
    bool authenticated = true,
  }) async {
    var response = await fn();
    if (response.statusCode == 401 && authenticated) {
      try {
        _refreshInFlight ??= refreshTokens().whenComplete(() {
          _refreshInFlight = null;
        });
        await _refreshInFlight;
      } on ApiException {
        await _storage.clearSession();
        onAuthFailed?.call();
        rethrow;
      }
      response = await fn();
    }
    return response;
  }

  Map<String, dynamic> _parse(http.Response response) {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } on FormatException {
      throw ApiException(
        response.statusCode,
        'SERVER_ERROR',
        'Server returned an unexpected response (HTTP ${response.statusCode}). '
            'Check that the server is running and reachable.',
      );
    }
    if (response.statusCode >= 400) {
      final error = body['error'] as Map<String, dynamic>? ?? {};
      throw ApiException(
        response.statusCode,
        error['code'] as String? ?? 'UNKNOWN',
        error['message'] as String? ?? 'Unknown error',
      );
    }
    return body;
  }
}
