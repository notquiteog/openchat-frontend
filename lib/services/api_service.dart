import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../config/api_config.dart' show ApiConfig, IceServer;
import '../models/user.dart';
import '../models/message.dart';
import '../models/conversation.dart';
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
  final int expiresIn;

  UploadRequest({
    required this.attachmentId,
    required this.uploadUrl,
    required this.expiresIn,
  });

  factory UploadRequest.fromJson(Map<String, dynamic> json) => UploadRequest(
    attachmentId: json['attachment_id'] as String,
    uploadUrl: json['upload_url'] as String,
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
    required String password,
    required String publicKey,
  }) async {
    final resp = await _post('/api/v1/auth/register', {
      'username': username,
      'password': password,
      'public_key': publicKey,
      'device_name': openChatDeviceName(),
    }, authenticated: false);
    return AuthResponse.fromJson(resp['data'] as Map<String, dynamic>);
  }

  Future<AuthResponse> login({
    required String username,
    required String password,
    String? twoFactorPassword,
  }) async {
    final resp = await _post('/api/v1/auth/login', {
      'username': username,
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
  Future<String?> getUserPublicKey(String userID) async {
    final cached = await KeyCacheService.get(userID);
    if (cached != null) return cached.publicKey;

    final resp = await _get('/api/v1/users/$userID/public-key');
    final data = resp['data'] as Map<String, dynamic>;
    final isExpired = data['is_key_expired'] as bool? ?? false;
    if (isExpired) return null;

    final publicKey = data['public_key'] as String;
    final fingerprint = data['key_fingerprint'] as String? ?? '';
    final expiresAt = data['public_key_expires_at'] != null
        ? DateTime.parse(data['public_key_expires_at'] as String)
        : null;
    await KeyCacheService.put(
      userID,
      publicKey,
      fingerprint,
      expiresAt: expiresAt,
    );
    return publicKey;
  }

  /// Fetch a user's public key directly from the server, bypassing the local
  /// cache. Use this for outbound encryption so key rotations and newly-added
  /// members are reflected immediately.
  Future<String?> getFreshUserPublicKey(String userID) async {
    await KeyCacheService.invalidate(userID);
    return getUserPublicKey(userID);
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
  }) async {
    await _put('/api/v1/users/me/public-key', {
      'public_key': publicKey,
      'key_fingerprint': fingerprint,
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
  }) async {
    final resp = await _post('/api/v1/conversations', {
      'name': name,
      'description': ?description,
      'member_ids': memberIDs,
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

  Future<void> removeMember(String convID, String userID) async {
    await _delete('/api/v1/conversations/$convID/members/$userID');
  }

  Future<void> setConversationMemberRole(
    String convID,
    String userID,
    String role,
  ) async {
    await _put('/api/v1/conversations/$convID/members/$userID/role', {
      'role': role,
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
    String role,
  ) async {
    await _put('/api/v1/channels/$chanID/members/$userID/role', {'role': role});
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

  Future<Message> postToChannel({
    required String chanID,
    required String encryptedPayload,
    required String signature,
    String messageType = 'text',
    String? attachmentId,
    bool silent = false,
    DateTime? scheduledFor,
  }) async {
    final resp = await _post('/api/v1/channels/$chanID/posts', {
      'encrypted_payload': encryptedPayload,
      'signature': signature,
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

  Future<Message> sendMessage({
    required String convID,
    required String encryptedPayload,
    required String signature,
    String messageType = 'text',
    String? replyTo,
    String? attachmentId,
    String? topicId,
    bool silent = false,
    DateTime? scheduledFor,
  }) async {
    final resp = await _post('/api/v1/conversations/$convID/messages', {
      'encrypted_payload': encryptedPayload,
      'signature': signature,
      'message_type': messageType,
      'reply_to': ?replyTo,
      'attachment_id': ?attachmentId,
      'topic_id': ?topicId,
      if (silent) 'silent': true,
      if (scheduledFor != null)
        'scheduled_for': scheduledFor.toUtc().toIso8601String(),
    });
    return Message.fromJson(resp['data'] as Map<String, dynamic>);
  }

  Future<Message> createPoll({
    required String convID,
    required String question,
    required List<String> options,
    bool isAnonymous = true,
    bool allowsMultipleAnswers = false,
    bool allowsRevoting = true,
    bool silent = false,
  }) async {
    final resp = await _post('/api/v1/conversations/$convID/polls', {
      'question': question,
      'options': options,
      'is_anonymous': isAnonymous,
      'allows_multiple_answers': allowsMultipleAnswers,
      'allows_revoting': allowsRevoting,
      if (silent) 'silent': true,
    });
    return Message.fromJson(resp['data'] as Map<String, dynamic>);
  }

  Future<Poll> votePoll(String pollID, List<String> optionIDs) async {
    final resp = await _post('/api/v1/polls/$pollID/votes', {
      'option_ids': optionIDs,
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

  Future<Conversation> getSavedMessages() async {
    final resp = await _get('/api/v1/conversations/saved-messages');
    return Conversation.fromJson(resp['data'] as Map<String, dynamic>);
  }

  Future<void> deleteMessage(String convID, String msgID) async {
    await _delete('/api/v1/conversations/$convID/messages/$msgID');
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

  Future<void> setTopicsEnabled(
    String convID,
    bool enabled, {
    bool channel = false,
  }) async {
    final base = channel ? '/api/v1/channels' : '/api/v1/conversations';
    await _put('$base/$convID/topics-enabled', {'enabled': enabled});
  }

  Future<Map<String, dynamic>> getChannelStats(String chanID) async {
    final resp = await _get('/api/v1/channels/$chanID/stats');
    return resp['data'] as Map<String, dynamic>;
  }

  Future<void> setEncryptionEnabled(String convID, bool enabled) async {
    await _put('/api/v1/conversations/$convID/encryption', {
      'enabled': enabled,
    });
  }

  Future<Message> editMessage({
    required String convID,
    required String msgID,
    required String encryptedPayload,
    required String signature,
  }) async {
    final resp = await _put('/api/v1/conversations/$convID/messages/$msgID', {
      'encrypted_payload': encryptedPayload,
      'signature': signature,
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

  Future<Story> createStory({
    required String attachmentId,
    required String fileName,
    required int fileSize,
    required String mimeType,
    required String fileKey,
    required String fileNonce,
    required String mediaType,
    String caption = '',
    String privacy = 'contacts',
    String? conversationId,
    int expiresInSeconds = 24 * 60 * 60,
    bool pinned = false,
    bool noForwards = false,
    List<Map<String, dynamic>> entities = const [],
  }) async {
    final resp = await _post('/api/v1/stories', {
      'attachment_id': attachmentId,
      'file_name': fileName,
      'file_size': fileSize,
      'mime_type': mimeType,
      'file_key': fileKey,
      'file_nonce': fileNonce,
      'media_type': mediaType,
      'caption': caption,
      'entities': entities,
      'privacy': privacy,
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
    String mimeType,
  ) async {
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

  /// Confirm that an attachment was successfully uploaded.
  Future<void> confirmUpload(String attachmentId) async {
    await _post('/api/v1/attachments/$attachmentId/confirm', {});
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
    String? bio,
    String? avatarUrl,
    int? bubbleColor,
    bool clearBubbleColor = false,
  }) async {
    await _put('/api/v1/users/me', {
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

  Future<List<IceServer>> getIceServers() async {
    final resp = await _get('/api/v1/config', authenticated: false);
    final list = (resp['data']['ice_servers'] as List? ?? []);
    return list
        .map((e) => IceServer.fromJson(e as Map<String, dynamic>))
        .toList();
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
  }) async {
    final resp = await _post('/api/v1/stickers/packs', {
      'name': name,
      'description': ?description,
    });
    return resp['data'] as Map<String, dynamic>;
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
  }) async {
    await _put('/api/v1/stickers/packs/$packID', {
      'name': ?name,
      'description': ?description,
      'cover_url': ?coverUrl,
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
  }) async {
    final resp = await _post('/api/v1/custom-emoji/packs', {
      'name': name,
      'description': ?description,
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
  }) async {
    await _put('/api/v1/custom-emoji/packs/$packID', {
      'name': ?name,
      'description': ?description,
      'cover_url': ?coverUrl,
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
    Map<String, dynamic> body,
  ) async {
    final response = await _requestWithRetry(() async {
      final token = await _storage.getAccessToken();
      return _httpClient.put(
        Uri.parse('${ApiConfig.baseUrl}$path'),
        headers: _headers(token),
        body: jsonEncode(body),
      );
    });
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
    final body = jsonDecode(response.body) as Map<String, dynamic>;
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
