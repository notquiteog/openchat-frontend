import 'dart:async';
import 'dart:math';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:uuid/uuid.dart';
import '../crypto/pgp_service.dart';
import '../crypto/smp_service.dart';
import '../models/chat_folder.dart';
import '../models/conversation.dart';
import '../models/key_transparency_event.dart';
import '../models/message.dart';
import '../models/user.dart';
import '../providers/settings_provider.dart';
import '../services/api_service.dart';
import '../services/attachment_service.dart';
import '../services/key_cache_service.dart';
import '../services/message_search_service.dart';
import '../services/message_cache_service.dart';
import '../services/mls_service.dart';
import '../services/notification_service.dart';
import '../services/mesh/mesh_outbox_drain.dart';
import '../services/offline_outbox_service.dart';
import '../services/push_notification_service.dart';
import '../services/app_lock_state.dart';
import '../services/kt_audit_service.dart';
import '../services/secure_storage_service.dart';
import '../services/social_recovery_service.dart';
import '../services/websocket_service.dart';
import '../utils/mention_utils.dart';

class ChatSendException implements Exception {
  final String message;
  const ChatSendException(this.message);

  @override
  String toString() => message;
}

/// A pre-fetched single-use sealed post token plus the time it was issued, so
/// stale tokens (near the server's TTL) can be discarded before use.
class _PooledPostToken {
  final String token;
  final DateTime fetchedAt;
  const _PooledPostToken(this.token, this.fetchedAt);

  bool isStale(Duration maxAge) =>
      DateTime.now().difference(fetchedAt) >= maxAge;
}

class _ActiveLiveLocationShare {
  _ActiveLiveLocationShare({
    required this.conversationId,
    required this.shareId,
    required this.expiresAt,
    required this.latitude,
    required this.longitude,
    required this.sharingWith,
    this.accuracy,
  });

  final String conversationId;
  final String shareId;
  final String sharingWith;
  DateTime expiresAt;
  double latitude;
  double longitude;
  double? accuracy;
  DateTime lastSentAt = DateTime.now();
  StreamSubscription<Position>? subscription;
  Timer? expiryTimer;

  bool get isActive => DateTime.now().isBefore(expiresAt);

  void cancel() {
    unawaited(subscription?.cancel());
    subscription = null;
    expiryTimer?.cancel();
    expiryTimer = null;
  }
}

class LiveLocationShareStatus {
  final String conversationId;
  final String messageId;
  final String sharingWith;
  final DateTime expiresAt;

  const LiveLocationShareStatus({
    required this.conversationId,
    required this.messageId,
    required this.sharingWith,
    required this.expiresAt,
  });
}

class _PreparedEncryptedPayload {
  final String encryptedPayload;
  final String signature;
  final String cleartextPayload;
  final bool isEncrypted;
  final int autoDeleteSeconds;
  final DateTime? autoDeleteExpiresAt;
  final String senderId;
  final String? postToken;

  const _PreparedEncryptedPayload({
    required this.encryptedPayload,
    required this.signature,
    required this.cleartextPayload,
    required this.isEncrypted,
    required this.autoDeleteSeconds,
    required this.autoDeleteExpiresAt,
    required this.senderId,
    this.postToken,
  });
}

class ChatProvider extends ChangeNotifier {
  final ApiService _api;
  bool _disposed = false;
  // Sealed-sender messages whose signature verification transiently fails
  // (openpgp fork PQC-verify bug) are re-verified a few times: msgId -> attempts.
  final Map<String, int> _verifyRetryCounts = {};
  final SecureStorageService _storage;
  final WebSocketService _ws;
  final SettingsProvider _settings;
  final MlsService _mls;
  final MessageSearchService _search;
  final MessageCacheService _cache;
  final OfflineOutboxService _outbox;

  final Map<String, List<Message>> _messages = {};
  final Map<String, Conversation> _conversations = {};
  final List<ChatFolder> _chatFolders = [];
  final Map<String, Set<String>> _typingUsers = {};
  final Map<String, Map<String, String>> _readReceipts = {};
  // Live provably-fair game rounds, keyed by round id (populated from the API
  // and game_updated WS events) so the in-chat game cards render reactively.
  final Map<String, Map<String, dynamic>> _gameRounds = {};
  final Map<String, _ActiveLiveLocationShare> _liveLocationShares = {};
  final Set<String> _mlsRefreshInFlight = {};
  List<OfflineOutboxItem> _outboxItems = const [];
  String? _selfId;
  String? _selfUsername;
  Future<void>? _outboxLoadInFlight;
  bool _drainingOutbox = false;
  bool _outboxLoaded = false;

  List<Conversation> get conversations =>
      _conversations.values.where(_visibleInCurrentVault).toList()
        ..sort((a, b) {
          final aTime = a.lastMessage?.createdAt ?? a.createdAt;
          final bTime = b.lastMessage?.createdAt ?? b.createdAt;
          return bTime.compareTo(aTime);
        });

  void _onVaultModeChanged() {
    if (!_disposed) notifyListeners();
  }

  /// Send jitter: random 200–1500ms before the wire send so an observer can't
  /// correlate typing/submit timing with ciphertext departure. The optimistic
  /// bubble is already on screen; only the network call waits.
  bool _sendJitterEnabled = false;
  final Random _sendJitterRandom = Random.secure();

  bool get sendJitterEnabled => _sendJitterEnabled;

  Future<void> setSendJitterEnabled(bool enabled) async {
    _sendJitterEnabled = enabled;
    await _storage.setSendJitterEnabled(enabled);
    notifyListeners();
  }

  Future<void> _applySendJitter() async {
    if (!_sendJitterEnabled) return;
    await Future<void>.delayed(
      Duration(milliseconds: 200 + _sendJitterRandom.nextInt(1300)),
    );
  }

  /// Vault filter: decoy (duress-PIN) sessions must not surface hidden
  /// conversations anywhere — list, search, badges, notifications. Real
  /// sessions see everything.
  bool _visibleInCurrentVault(Conversation conv) =>
      vaultModeListenable.value == VaultMode.real ||
      !_settings.isConversationHidden(conv.id);

  /// Public form of the vault filter for UI surfaces (badges, search results)
  /// that resolve conversations outside [conversations].
  bool isConversationVisibleInVault(String convID) =>
      vaultModeListenable.value == VaultMode.real ||
      !_settings.isConversationHidden(convID);

  Conversation? conversationById(String conversationId) =>
      _conversations[conversationId];

  Future<Conversation?> ensureConversationLoaded(String conversationId) async {
    final existing = _conversations[conversationId];
    if (existing != null) return existing;
    try {
      final conv = await _api.getConversation(conversationId);
      _conversations[conv.id] = conv;
      await loadConversationMembers(conv.id);
      notifyListeners();
      return _conversations[conv.id] ?? conv;
    } catch (_) {
      try {
        await refreshConversationsSilently();
      } catch (_) {
        return null;
      }
      return _conversations[conversationId];
    }
  }

  List<ChatFolder> get chatFolders => List.unmodifiable(_chatFolders);

  List<Message> messagesFor(String convID) => List.unmodifiable(
    (_messages[convID] ?? const <Message>[]).where((m) => !m.isHiddenControl),
  );

  /// In-band SMP control messages, routed to the SMP provider rather than shown.
  final StreamController<SmpInbound> _smpController =
      StreamController<SmpInbound>.broadcast();
  Stream<SmpInbound> get smpMessages => _smpController.stream;

  /// On-chain deposit confirmation progress for THIS user's deposits, straight
  /// off the user-scoped `deposit_progress` WS event. Payload keys:
  /// deposit_id, status, confirmations, required_confirmations.
  final StreamController<Map<String, dynamic>> _depositProgressController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get depositProgress =>
      _depositProgressController.stream;

  /// Pending join requests, delivered only to members who can approve them.
  /// Payload keys: conversation_id, user_id (the requester). The join-request
  /// review UI listens to live-refresh its list while open.
  final StreamController<Map<String, dynamic>> _joinRequestController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get joinRequests =>
      _joinRequestController.stream;

  /// Social-recovery ceremony events, tagged with `kind`:
  /// 'request' (a contact you guard opened a ceremony — Trust Center refreshes
  /// + banners) or 'share' (a guardian's share landed on YOUR ceremony — the
  /// recovery screen progresses live).
  final StreamController<Map<String, dynamic>> _recoveryEventsController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get recoveryEvents =>
      _recoveryEventsController.stream;

  /// Send one SMP step to [convID] as a hidden `system` control message.
  Future<void> sendSmpStep(String convID, Map<String, dynamic> payload) async {
    final body = jsonEncode({'openchat_smp': 1, ...payload});
    await _sendEncryptedPayload(
      convID: convID,
      plaintextPayload: body,
      messageType: 'system',
    );
  }

  /// Delivers one Shamir recovery share to a guardian as a hidden E2EE
  /// control message (same transport as SMP). [shareJson] is the full
  /// openchat_recovery_share payload from SocialRecoveryService.configure.
  Future<void> sendRecoveryShare(
    String guardianUserId,
    String shareJson,
  ) async {
    final conv = await openDM(guardianUserId);
    await _sendEncryptedPayload(
      convID: conv.id,
      plaintextPayload: shareJson,
      messageType: 'system',
    );
  }

  int get pendingOutboxCount => _outboxItems.length;

  Set<String> typingUsersFor(String convID) => _typingUsers[convID] ?? {};

  bool messageReadByOthers(
    String convID,
    Message message,
    String currentUserID,
  ) {
    final receipts = _readReceipts[convID];
    if (receipts == null || receipts.isEmpty) return false;
    final list = _messages[convID] ?? const <Message>[];
    final messageIndex = list.indexWhere((msg) => msg.id == message.id);
    for (final entry in receipts.entries) {
      if (entry.key == currentUserID) continue;
      if (entry.value == message.id) return true;
      if (messageIndex < 0) continue;
      final readIndex = list.indexWhere((msg) => msg.id == entry.value);
      if (readIndex >= 0 && readIndex >= messageIndex) return true;
    }
    return false;
  }

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  StreamSubscription<WsEvent>? _wsSub;
  static const Duration _liveLocationInterval = Duration(seconds: 30);
  Future<void>? _conversationRefreshInFlight;
  bool _wasWsMonitoring = false;

  ChatProvider(
    this._api,
    this._storage,
    this._ws,
    this._settings,
    this._mls, {
    MessageSearchService? searchService,
    MessageCacheService? cacheService,
    OfflineOutboxService? outboxService,
  }) : _search = searchService ?? MessageSearchService(_storage),
       _cache = cacheService ?? MessageCacheService(_storage),
       _outbox = outboxService ?? OfflineOutboxService(_storage) {
    _wsSub = _ws.events.listen(_handleWsEvent);
    _ws.addListener(_onWsConnectionChanged);
    // Vault mode changes what `conversations` returns (decoy sessions filter
    // hidden chats) — rebuild listeners when it flips.
    vaultModeListenable.addListener(_onVaultModeChanged);
    _storage.getSendJitterEnabled().then((v) => _sendJitterEnabled = v);
    NotificationService.setLiveLocationHandlers(
      onCancel: (_, messageId) async => stopLiveLocation(messageId),
    );
    _ws.connect();
    _storage.getUserID().then((id) => _selfId = id);
    _storage.getUsername().then((username) => _selfUsername = username);
    unawaited(_loadOutbox());
  }

  Future<List<MessageSearchResult>> searchMessages(
    String query, {
    String? conversationId,
    Set<MessageSearchCategory>? categories,
    int limit = 40,
  }) {
    return _search.search(
      query,
      conversationId: conversationId,
      categories: categories,
      limit: limit,
    );
  }

  void indexLoadedMessage(Message message) => _indexMessage(message);

  Future<void> connectWebSocket() {
    unawaited(_hydrateSelfIdentity());
    return _ws.connect();
  }

  void clearState() {
    _messages.clear();
    _conversations.clear();
    _chatFolders.clear();
    _typingUsers.clear();
    _readReceipts.clear();
    // Drop the in-memory vote marks on logout. The persisted entries are
    // device-local and keyed by poll id (the same model as the anonymous
    // vote tokens above them in secure storage).
    _myPollVotes.clear();
    _myPollVotesLoading.clear();
    _outboxItems = const [];
    // Reset identity too — the provider outlives a logout/login cycle, and a
    // stale _selfId misattributes own-message suppression, self-reactions, and
    // mention detection to the previous account.
    _selfId = null;
    _selfUsername = null;
    _outboxLoaded = false;
    _wasWsMonitoring = false;
    unawaited(_search.clearAll());
    unawaited(_outbox.clearAll());
    unawaited(_stopAllLiveLocationShares());
    // The resume position belongs to this account; the next login must not
    // try to resume another user's event stream.
    unawaited(_ws.resetSequence());
    _ws.disconnect();
    notifyListeners();
  }

  Future<void> _loadOutbox() {
    _outboxLoadInFlight ??= _outbox
        .list()
        .then((items) {
          _outboxItems = items;
          _outboxLoaded = true;
          _overlayOutboxOnLoadedMessages();
          notifyListeners();
        })
        .whenComplete(() {
          _outboxLoadInFlight = null;
        });
    return _outboxLoadInFlight!;
  }

  Future<void> _ensureOutboxLoaded() {
    final inFlight = _outboxLoadInFlight;
    if (inFlight != null) return inFlight;
    if (_outboxLoaded) return Future.value();
    return _loadOutbox();
  }

  Future<void> _stopAllLiveLocationShares() async {
    if (_liveLocationShares.isEmpty) return;
    final active = _liveLocationShares.entries.toList();
    _liveLocationShares.clear();
    for (final entry in active) {
      final share = entry.value;
      share.cancel();
      await NotificationService.cancelLiveLocationNotification(
        messageId: entry.key,
        conversationId: share.conversationId,
      );
    }
  }

  Future<void> _stopOtherLiveLocationShares(String messageID) async {
    final otherMessageIds = _liveLocationShares.keys
        .where((id) => id != messageID)
        .toList(growable: false);
    for (final id in otherMessageIds) {
      await _stopLiveLocationShare(id, shouldNotify: true);
    }
  }

  void _onWsConnectionChanged() {
    final monitoring = _ws.isMonitoring;
    if (monitoring && !_wasWsMonitoring) {
      if (_ws.lastSeq > 0) {
        // The socket resumed from its last sequence number — the server
        // replays the missed durable events (or sends resync_required, which
        // triggers the full catch-up below). Only the outbox needs draining.
        unawaited(drainOutbox());
      } else {
        unawaited(_catchUpAfterReconnect());
      }
    }
    _wasWsMonitoring = monitoring;
  }

  Future<void> _catchUpAfterReconnect() async {
    final token = await _storage.getAccessToken();
    if (token == null) return;
    await refreshConversationsSilently();
    await drainOutbox();
    final loadedConversationIds = _messages.keys.toList(growable: false);
    await Future.wait(loadedConversationIds.map(loadMessages));
  }

  Future<void> _hydrateSelfIdentity() async {
    if (_selfId == null || _selfId!.isEmpty) {
      _selfId = await _storage.getUserID();
    }
    if (_selfUsername == null || _selfUsername!.isEmpty) {
      _selfUsername = await _storage.getUsername();
    }
  }

  Future<void> loadConversations() => _loadConversations(silent: false);

  Future<void> refreshConversationsSilently() {
    _conversationRefreshInFlight ??= _loadConversations(silent: true)
        .whenComplete(() {
          _conversationRefreshInFlight = null;
        });
    return _conversationRefreshInFlight!;
  }

  Future<void> _loadConversations({required bool silent}) async {
    // Self-identity is hydrated once in the constructor — which on a fresh
    // install runs BEFORE login, and clearState() nulls it on logout. Without
    // re-hydration here (the first call after every login), everything keyed
    // on "is this me" silently broke until an app restart: own game seats
    // never matched (the join button never became "Ready up"), own messages
    // triggered notifications, mentions misattributed.
    await _hydrateSelfIdentity();
    // Audit the key-transparency log (throttled internally): pin/verify the
    // latest signed tree head and check append-only consistency.
    unawaited(KtAuditService(storage: _storage).syncSth(_api));
    if (!silent) {
      _isLoading = true;
      notifyListeners();
    }
    var changed = false;
    try {
      final convs = await _api.listConversations();
      final privateKey = await _storage.getPrivateKeyIfUnlocked() ?? '';
      final next = <String, Conversation>{};
      for (final c in convs) {
        next[c.id] = await _hydrateConversationPreview(c, privateKey);
      }
      changed = hasConversationListChanges(
        current: _conversations,
        fresh: next.values,
      );
      if (changed || !silent) {
        _conversations
          ..clear()
          ..addAll(next);
        // Keep the opaque push-routing map current so notifications for newly
        // joined conversations resolve to the right chat.
        if (PushNotificationService.isRegistered) {
          unawaited(PushNotificationService.refreshPushRoutes(_api));
        }
      }
    } finally {
      if (!silent) {
        _isLoading = false;
        notifyListeners();
      } else if (changed) {
        notifyListeners();
      }
    }
  }

  /// Decrypts/backfills a conversation's last-message preview — shared by the
  /// full list load and the incremental single-conversation refresh so both
  /// produce identical entries.
  Future<Conversation> _hydrateConversationPreview(
    Conversation c,
    String privateKey,
  ) async {
    var hydrated = c;
    final last = c.lastMessage;
    if (last != null) {
      await _promoteDeliveredSealedScheduledMessage(last);
      _hydrateMessageSender(last);
      final cached = _cachedDecryptedMessage(last);
      if (cached != null) {
        _hydrateMessageSender(cached, fresh: last);
        hydrated = c.copyWith(lastMessage: cached);
      } else {
        await _tryDecrypt(last, privateKey, conversation: c);
        hydrated = c.copyWith(lastMessage: last);
      }
    }
    await _syncLocalUnreadMentionFromConversation(hydrated);
    return hydrated;
  }

  /// Incrementally refreshes ONE conversation — the live-update path for WS
  /// metadata/membership events. A full list refetch per event does not scale
  /// (a busy account would re-pull thousands of conversations on every
  /// rename); this fetches, hydrates and upserts just the affected one.
  ///
  /// 403/404 means our access is gone (removed, expired, deleted) — the
  /// conversation is dropped locally. Transient errors keep current state;
  /// the next event or full load reconciles.
  Future<void> refreshConversation(String convID) async {
    if (convID.isEmpty) return;
    try {
      final conv = await _api.getConversation(convID);
      final privateKey = await _storage.getPrivateKeyIfUnlocked() ?? '';
      final hydrated = await _hydrateConversationPreview(conv, privateKey);
      final isNew = !_conversations.containsKey(convID);
      _conversations[convID] = hydrated;
      if (isNew && PushNotificationService.isRegistered) {
        // Newly visible conversation: keep the opaque push-routing map
        // current so its notifications resolve to the right chat.
        unawaited(PushNotificationService.refreshPushRoutes(_api));
      }
      notifyListeners();
    } on ApiException catch (e) {
      if (e.statusCode == 403 || e.statusCode == 404) {
        removeConversationLocally(convID);
      }
    } catch (_) {
      // Transient (offline, timeout) — leave the current entry alone.
    }
  }

  /// Drops a conversation from local state (lost access / revoked / deleted
  /// elsewhere). No server call — the server already considers us out.
  void removeConversationLocally(String convID) {
    if (_conversations.remove(convID) == null) return;
    _messages.remove(convID);
    _typingUsers.remove(convID);
    unawaited(_settings.clearUnreadMention(convID));
    _deleteSearchConversation(convID);
    notifyListeners();
  }

  Future<void> loadChatFolders() async {
    // SettingsProvider.loadChatFolders() returns an unmodifiable list, so copy
    // before sorting — sorting it in place throws and chat folders never load.
    final folders = (await _settings.loadChatFolders()).toList();
    folders.sort((a, b) {
      final position = a.position.compareTo(b.position);
      if (position != 0) return position;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    _chatFolders
      ..clear()
      ..addAll(folders);
    notifyListeners();
  }

  Future<ChatFolder> saveChatFolder(ChatFolder folder) async {
    final saved = await _settings.saveChatFolder(folder);
    final index = _chatFolders.indexWhere((item) => item.id == saved.id);
    if (index == -1) {
      _chatFolders.add(saved);
    } else {
      _chatFolders[index] = saved;
    }
    _chatFolders.sort((a, b) {
      final position = a.position.compareTo(b.position);
      if (position != 0) return position;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    notifyListeners();
    return saved;
  }

  Future<void> removeChatFolder(String folderId) async {
    await _settings.removeChatFolder(folderId);
    _chatFolders.removeWhere((folder) => folder.id == folderId);
    notifyListeners();
  }

  /// Test seams for the MLS plaintext-cache regression suite: sent/edited MLS
  /// messages can never be re-decrypted by their author (one-time sender
  /// ratchet keys), so these private paths MUST persist plaintext into the
  /// durable cache — a regression silently destroys message history on the
  /// next restart.
  @visibleForTesting
  void debugSeedConversation(Conversation conversation) {
    _conversations[conversation.id] = conversation;
  }

  @visibleForTesting
  void debugSeedMessages(String convID, List<Message> messages) {
    _messages[convID] = List.of(messages);
  }

  // ── On-device intelligence: transcripts + translations ────────────────────

  /// Voice-note transcripts live in the encrypted message cache under a
  /// synthetic id, so they're at rest with the same key as message plaintext
  /// and disappear with the cache on wipe/logout.
  String _transcriptKey(String msgID) => '$msgID#transcript';

  Future<String?> cachedTranscript(Message message) async {
    final entry = await _cache.get(
      _transcriptKey(message.id),
      message.encryptedPayload,
    );
    final text = entry?.plaintext;
    return (text == null || text.isEmpty) ? null : text;
  }

  Future<void> storeTranscript(Message message, String transcript) =>
      _cache.put(
        _transcriptKey(message.id),
        message.conversationId,
        message.encryptedPayload,
        transcript,
        null,
      );

  // ── Nearby mesh (BLE) integration ──────────────────────────────────────────

  /// The existing DM whose OTHER participant holds [fingerprint]. Mesh
  /// messaging deliberately requires a pre-existing DM: a new conversation
  /// can't be created server-side while offline, and a verified stranger can
  /// still exchange fingerprints to chat once online.
  String? dmConversationIdForFingerprint(String fingerprint) {
    final fp = fingerprint.toUpperCase();
    for (final conv in _conversations.values) {
      if (!conv.isDM) continue;
      for (final member in conv.members) {
        if (member.userId == _selfId) continue;
        final memberFp = member.user?.keyFingerprint.toUpperCase() ?? '';
        if (memberFp.isNotEmpty && memberFp == fp) return conv.id;
      }
    }
    return null;
  }

  /// Queued outbox envelopes deliverable to a verified nearby peer.
  Future<List<Map<String, dynamic>>> meshEnvelopesForFingerprint(
    String fingerprint,
  ) async {
    final convID = dmConversationIdForFingerprint(fingerprint);
    if (convID == null) return const [];
    await _ensureOutboxLoaded();
    return meshDeliverableItems(_outboxItems, convID)
        .map(meshEnvelopeForItem)
        .toList();
  }

  /// Ingests an envelope received over BLE from a peer whose key proof
  /// already verified. Runs through the exact same decrypt/dedup path as a
  /// WS message; the eventual server copy replaces the mesh copy by payload.
  Future<bool> ingestMeshMessage(
    Map<String, dynamic> envelope,
    String senderFingerprint,
  ) async {
    final convID = envelope['conversation_id']?.toString() ?? '';
    final payload = envelope['encrypted_payload']?.toString() ?? '';
    final nonce = envelope['client_nonce']?.toString() ?? '';
    if (convID.isEmpty || payload.isEmpty || nonce.isEmpty) return false;
    // The conversation must exist here, and it must be the DM with the
    // VERIFIED sender — a peer can't push envelopes into other chats.
    if (dmConversationIdForFingerprint(senderFingerprint) != convID) {
      return false;
    }
    final existing = _messages[convID] ?? const <Message>[];
    final meshId = 'mesh-$nonce';
    if (existing.any(
      (m) => m.id == meshId || m.encryptedPayload == payload,
    )) {
      return true; // duplicate retransmit — already have it
    }
    final msg = Message(
      id: meshId,
      conversationId: convID,
      senderId: '',
      type: Message.parseType(envelope['message_type']?.toString() ?? 'text'),
      encryptedPayload: payload,
      signature: envelope['signature']?.toString() ?? '',
      isEncrypted: true,
      createdAt:
          DateTime.tryParse(envelope['created_at']?.toString() ?? '') ??
              DateTime.now(),
    );
    await _handleIncomingMessage(msg);
    return true;
  }

  /// Ephemeral per-session translations (message id → translated text).
  /// Deliberately NOT persisted: a translation is a view, not message state.
  final Map<String, String> _messageTranslations = {};

  String? translationFor(String msgID) => _messageTranslations[msgID];

  void setMessageTranslation(String msgID, String? translated) {
    if (translated == null || translated.isEmpty) {
      if (_messageTranslations.remove(msgID) == null) return;
    } else {
      _messageTranslations[msgID] = translated;
    }
    notifyListeners();
  }

  @visibleForTesting
  void debugReplacePendingWithConfirmed({
    required String convID,
    required String? pendingID,
    required Message confirmed,
    required String plaintextPayload,
  }) {
    _replacePendingWithConfirmed(
      convID: convID,
      pendingID: pendingID,
      confirmed: confirmed,
      plaintextPayload: plaintextPayload,
    );
  }

  @visibleForTesting
  Future<void> debugHandleEditedMessage(Message message) =>
      _handleEditedMessage(message);

  @visibleForTesting
  Future<void> debugHandleIncomingMessage(Message message) =>
      _handleIncomingMessage(message);

  @visibleForTesting
  static bool hasConversationListChanges({
    required Map<String, Conversation> current,
    required Iterable<Conversation> fresh,
  }) {
    final freshById = {for (final conv in fresh) conv.id: conv};
    if (current.length != freshById.length) return true;
    for (final entry in freshById.entries) {
      final existing = current[entry.key];
      if (existing == null) return true;
      if (_conversationFingerprint(existing) !=
          _conversationFingerprint(entry.value)) {
        return true;
      }
    }
    return false;
  }

  static Object _conversationFingerprint(Conversation conv) => (
    conv.id,
    conv.type,
    conv.name,
    conv.description,
    conv.avatarUrl,
    conv.backgroundUrl,
    conv.archivedAt?.toIso8601String(),
    conv.ownerOnlyPost,
    conv.messageTtlSeconds,
    conv.encryptionMode,
    conv.unreadCount,
    conv.members.length,
    conv.lastMessage?.id,
    conv.lastMessage?.encryptedPayload,
    conv.lastMessage?.editedAt?.toIso8601String(),
  );

  Future<void> loadMessages(String convID) async {
    try {
      final msgs = await _api.getMessages(convID, limit: 20);
      final privateKey = await _storage.getPrivateKeyIfUnlocked() ?? '';

      // Reuse in-memory decrypted state for messages already decrypted this
      // session. Self-sent messages are kept from the in-memory copy rather than
      // re-decrypting from the server, since PGP signing doesn't guarantee the
      // sender's copy is decryptable without the corresponding private key.
      final cachedById = Map.fromEntries(
        (_messages[convID] ?? []).map((m) => MapEntry(m.id, m)),
      );

      final result = <Message>[];
      for (final msg in msgs.reversed) {
        await _promoteDeliveredSealedScheduledMessage(msg);
        final cached = cachedById[msg.id];
        if (cached != null &&
            cached.isDecrypted &&
            cached.encryptedPayload == msg.encryptedPayload) {
          final merged = cached.copyWith(
            encryptedPayload: msg.encryptedPayload,
            signature: msg.signature,
            reactions: msg.reactions,
            poll: msg.poll,
            editedAt: msg.editedAt,
          );
          _applyArtifactState(merged);
          _hydrateMessageSender(merged, fresh: msg);
          result.add(merged);
          await _syncLiveLocationShareFromMessage(merged);
          _indexMessage(merged);
        } else {
          _hydrateMessageSender(msg);
          // For MLS messages, check the persistent cache before attempting
          // decryption — MLS application keys are one-time-use (forward
          // secrecy) so re-decryption after a restart would always fail.
          final conv = _conversations[convID];
          MessageCacheEntry? cacheEntry;
          if (msg.isEncrypted && conv?.usesMls == true) {
            cacheEntry = await _cache.get(msg.id, msg.encryptedPayload);
          }
          if (cacheEntry != null) {
            msg.setDecryptedContent(
              cacheEntry.plaintext,
              verifiedSenderId: cacheEntry.senderId,
            );
            _applyArtifactState(msg);
            _indexMessage(msg);
          } else {
            await _tryDecrypt(msg, privateKey, conversation: conv);
          }
          await _syncLiveLocationShareFromMessage(msg);
          result.add(msg);
        }
      }

      // Preserve scrollback the user already paged in: reconnect catch-up
      // calls loadMessages for every loaded conversation, and replacing the
      // list wholesale truncated hundreds of loaded messages to the latest 20
      // on every WS blip.
      final existing = _messages[convID] ?? const <Message>[];
      var merged = result;
      if (result.isNotEmpty && existing.isNotEmpty) {
        final fetchedIds = result.map((m) => m.id).toSet();
        final oldestFetched = result.first.createdAt;
        final olderScrollback = existing
            .where(
              (m) =>
                  !fetchedIds.contains(m.id) &&
                  m.createdAt.isBefore(oldestFetched),
            )
            .toList();
        if (olderScrollback.isNotEmpty) {
          merged = [...olderScrollback, ...result];
        }
      }
      _messages[convID] = _withOutboxOverlays(convID, merged);
      notifyListeners();
    } catch (_) {}
  }

  Future<int?> loadMoreMessages(String convID) async {
    final existing = _messages[convID];
    if (existing == null || existing.isEmpty) return 0;
    final oldest = existing.first;
    try {
      final older = await _api.getMessages(
        convID,
        beforeID: oldest.id,
        limit: 20,
      );
      if (older.isEmpty) return 0;
      for (final msg in older) {
        await _promoteDeliveredSealedScheduledMessage(msg);
        _hydrateMessageSender(msg);
      }
      final privateKey = await _storage.getPrivateKeyIfUnlocked() ?? '';
      final conv = _conversations[convID];
      await Future.wait(
        older.map((msg) async {
          if (msg.isEncrypted && conv?.usesMls == true) {
            final entry = await _cache.get(msg.id, msg.encryptedPayload);
            if (entry != null) {
              msg.setDecryptedContent(
                entry.plaintext,
                verifiedSenderId: entry.senderId,
              );
              _applyArtifactState(msg);
              _indexMessage(msg);
              return;
            }
          }
          await _tryDecrypt(msg, privateKey, conversation: conv);
        }),
      );
      for (final msg in older) {
        await _syncLiveLocationShareFromMessage(msg);
      }
      _messages[convID] = _withOutboxOverlays(convID, [
        ...older.reversed,
        ...existing.where(
          (message) => message is! PendingMessage || message.outboxId == null,
        ),
      ]);
      notifyListeners();
      return older.length;
    } catch (_) {}
    return null;
  }

  void _overlayOutboxOnLoadedMessages() {
    if (_messages.isEmpty) return;
    for (final convID in _messages.keys.toList(growable: false)) {
      _messages[convID] = _withOutboxOverlays(convID, _messages[convID] ?? []);
    }
  }

  List<Message> _withOutboxOverlays(String convID, List<Message> base) {
    final items = _outboxItems
        .where((item) => item.conversationId == convID)
        .toList(growable: false);
    var next = base
        .where(
          (message) => message is! PendingMessage || message.outboxId == null,
        )
        .toList();
    if (items.isEmpty) return next;

    for (final item in items) {
      switch (item.action) {
        case OfflineOutboxAction.sendMessage ||
            OfflineOutboxAction.attachmentUpload:
          final pending = _pendingMessageFromOutbox(item);
          if (pending != null) {
            next.removeWhere((message) => message.id == pending.id);
            next.add(pending);
          }
        case OfflineOutboxAction.editMessage:
          final msgID = item.data['message_id'] as String?;
          final plaintext = item.data['plaintext_payload'] as String?;
          final encrypted = item.data['encrypted_payload'] as String?;
          final signature = item.data['signature'] as String? ?? '';
          if (msgID == null || plaintext == null || encrypted == null) break;
          final idx = next.indexWhere((message) => message.id == msgID);
          if (idx == -1) break;
          final edited = next[idx].copyWith(
            encryptedPayload: encrypted,
            signature: signature,
            editedAt: DateTime.now(),
          );
          edited.setDecryptedContent(plaintext);
          next[idx] = edited;
        case OfflineOutboxAction.reaction:
          final msgID = item.data['message_id'] as String?;
          final emoji = item.data['emoji'] as String?;
          final reacted = item.data['reacted'] as bool? ?? false;
          if (msgID == null || emoji == null) break;
          final idx = next.indexWhere((message) => message.id == msgID);
          if (idx == -1) break;
          next[idx] = next[idx].copyWith(
            reactions: _reactionsWithViewerState(
              next[idx].reactions,
              emoji: emoji,
              reacted: reacted,
            ),
          );
        case OfflineOutboxAction.channelPost ||
            OfflineOutboxAction.channelAttachmentUpload ||
            OfflineOutboxAction.channelReaction:
          break;
      }
    }
    next.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return next;
  }

  PendingMessage? _pendingMessageFromOutbox(OfflineOutboxItem item) {
    final data = item.data;
    final pendingID = data['pending_message_id'] as String?;
    final encrypted = data['encrypted_payload'] as String?;
    final signature = data['signature'] as String? ?? '';
    final plaintext = data['plaintext_payload'] as String?;
    final senderID = data['sender_id'] as String? ?? _selfId ?? '';
    final messageType =
        data['local_message_type'] as String? ??
        data['message_type'] as String? ??
        'text';
    if (pendingID == null ||
        pendingID.isEmpty ||
        plaintext == null ||
        senderID.isEmpty) {
      return null;
    }

    final createdAt =
        DateTime.tryParse(data['created_at'] as String? ?? '') ??
        item.createdAt;
    final pending = PendingMessage(
      id: pendingID,
      conversationId: item.conversationId,
      senderId: senderID,
      type: _messageTypeFromWire(messageType),
      encryptedPayload: encrypted ?? plaintext,
      signature: signature,
      isEncrypted: data['is_encrypted'] as bool? ?? true,
      autoDeleteSeconds: data['auto_delete_seconds'] as int? ?? 0,
      autoDeleteExpiresAt: data['auto_delete_expires_at'] != null
          ? DateTime.tryParse(data['auto_delete_expires_at'] as String)
          : null,
      attachmentId: data['attachment_id'] as String?,
      replyTo: data['reply_to'] as String?,
      topicId: data['topic_id'] as String?,
      silent: data['silent'] as bool? ?? false,
      createdAt: createdAt,
      plaintext: plaintext,
      outboxId: item.id,
      status: switch (item.status) {
        OfflineOutboxStatus.failed => PendingMessageStatus.failed,
        OfflineOutboxStatus.sending => PendingMessageStatus.sending,
        OfflineOutboxStatus.queued => PendingMessageStatus.queued,
      },
      lastError: item.lastError,
    );
    _hydrateMessageSender(pending);
    return pending;
  }

  String _newOutboxId() =>
      'outbox-${DateTime.now().microsecondsSinceEpoch}-${_outboxItems.length}';

  Future<void> _upsertOutboxItem(
    OfflineOutboxItem item, {
    bool coalesceReaction = false,
  }) async {
    await _ensureOutboxLoaded();
    final next = List<OfflineOutboxItem>.from(_outboxItems);
    if (coalesceReaction && item.action == OfflineOutboxAction.reaction) {
      final msgID = item.data['message_id'];
      final emoji = item.data['emoji'];
      next.removeWhere(
        (existing) =>
            existing.action == OfflineOutboxAction.reaction &&
            existing.data['message_id'] == msgID &&
            existing.data['emoji'] == emoji,
      );
    } else {
      next.removeWhere((existing) => existing.id == item.id);
    }
    next.add(item);
    next.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    _outboxItems = next;
    await _outbox.replaceAll(next);
    _overlayOutboxOnLoadedMessages();
    notifyListeners();
    if (_ws.isMonitoring && !_drainingOutbox) {
      unawaited(drainOutbox());
    } else {
      unawaited(_ws.connect());
    }
  }

  Future<void> _removeOutboxItem(String id) async {
    _outboxItems = _outboxItems
        .where((item) => item.id != id)
        .toList(growable: false);
    await _outbox.remove(id);
    _overlayOutboxOnLoadedMessages();
    notifyListeners();
  }

  Future<void> _updateOutboxItem(OfflineOutboxItem item) async {
    final next = List<OfflineOutboxItem>.from(_outboxItems);
    final index = next.indexWhere((existing) => existing.id == item.id);
    if (index == -1) {
      next.add(item);
    } else {
      next[index] = item;
    }
    next.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    _outboxItems = next;
    await _outbox.replaceAll(next);
    _overlayOutboxOnLoadedMessages();
    notifyListeners();
  }

  bool _shouldRetryOutboxError(Object error) {
    if (error is SocketException || error is TimeoutException) return true;
    if (error is ApiException) {
      return error.statusCode == 408 ||
          error.statusCode == 429 ||
          error.statusCode >= 500;
    }
    return true;
  }

  Future<void> drainOutbox() async {
    if (_drainingOutbox) return;
    _drainingOutbox = true;
    try {
      await _ensureOutboxLoaded();
      if (_outboxItems.isEmpty) return;
      for (final item in List<OfflineOutboxItem>.from(_outboxItems)) {
        if (!_outboxItems.any((current) => current.id == item.id)) continue;
        final sending = item.copyWith(
          status: OfflineOutboxStatus.sending,
          clearLastError: true,
        );
        await _updateOutboxItem(sending);
        try {
          switch (item.action) {
            case OfflineOutboxAction.sendMessage:
              await _deliverQueuedMessage(sending);
            case OfflineOutboxAction.attachmentUpload:
              await _deliverQueuedAttachment(sending);
            case OfflineOutboxAction.editMessage:
              await _deliverQueuedEdit(sending);
            case OfflineOutboxAction.reaction:
              await _deliverQueuedReaction(sending);
            case OfflineOutboxAction.channelPost ||
                OfflineOutboxAction.channelAttachmentUpload ||
                OfflineOutboxAction.channelReaction:
              continue;
          }
          await _removeOutboxItem(item.id);
        } catch (e) {
          final retry = _shouldRetryOutboxError(e);
          await _updateOutboxItem(
            sending.copyWith(
              attempts: sending.attempts + 1,
              status: retry
                  ? OfflineOutboxStatus.queued
                  : OfflineOutboxStatus.failed,
              lastError: e.toString(),
            ),
          );
          if (retry) return;
        }
      }
    } finally {
      _drainingOutbox = false;
    }
  }

  Future<void> _deliverQueuedMessage(OfflineOutboxItem item) async {
    final data = item.data;
    final plaintext = data['plaintext_payload'] as String? ?? '';
    final postToken = data['post_token'] as String?;
    final isEncrypted = data['is_encrypted'] as bool? ?? false;
    late final Message confirmed;
    if (postToken != null && postToken.isNotEmpty) {
      confirmed = await _api.sendSealedMessage(
        convID: item.conversationId,
        encryptedPayload: data['encrypted_payload'] as String? ?? '',
        postToken: postToken,
        replyTo: null,
        attachmentId: data['attachment_id'] as String?,
        topicId: null,
        silent: data['silent'] as bool? ?? false,
        // The pending message id doubles as the idempotency key (the same id
        // used by a direct send before it was queued): a retry after a
        // timed-out-but-committed POST returns the original message instead
        // of duplicating it for every recipient.
        clientNonce: data['pending_message_id'] as String? ?? item.id,
      );
    } else {
      if (isEncrypted) {
        throw const ChatSendException(
          'Queued encrypted message is missing its sealed posting token.',
        );
      }
      confirmed = await _api.sendMessage(
        convID: item.conversationId,
        encryptedPayload: data['encrypted_payload'] as String? ?? '',
        signature: data['signature'] as String? ?? '',
        messageType: data['message_type'] as String? ?? 'text',
        replyTo: data['reply_to'] as String?,
        attachmentId: data['attachment_id'] as String?,
        topicId: data['topic_id'] as String?,
        silent: data['silent'] as bool? ?? false,
        clientNonce: data['pending_message_id'] as String? ?? item.id,
      );
    }
    _replacePendingWithConfirmed(
      convID: item.conversationId,
      pendingID: data['pending_message_id'] as String?,
      confirmed: confirmed,
      plaintextPayload: plaintext,
    );
  }

  Future<void> _deliverQueuedAttachment(OfflineOutboxItem item) async {
    final data = item.data;
    final ciphertextPath = data['ciphertext_path'] as String?;
    if (ciphertextPath == null || ciphertextPath.isEmpty) {
      throw const ChatSendException('Queued attachment file is missing.');
    }
    final ciphertext = await _outbox.readAttachmentCiphertext(ciphertextPath);
    final encryptedAttachment = EncryptedAttachmentUpload.fromMetadataJson(
      Map<String, dynamic>.from(data['attachment'] as Map? ?? const {}),
      ciphertext: ciphertext,
    );
    final attachment = await AttachmentService(
      _api,
    ).uploadEncryptedAttachment(encryptedAttachment);
    final plaintext = jsonEncode(
      attachment.toPayloadJson(
        caption: data['caption'] as String? ?? '',
        viewOnce: data['view_once'] as bool? ?? false,
        hasSpoiler: data['has_spoiler'] as bool? ?? false,
      ),
    );
    final sent = await _prepareAndSendOutboxPayload(
      convID: item.conversationId,
      plaintextPayload: plaintext,
      messageType: attachment.messageType.name,
      pendingID: data['pending_message_id'] as String?,
      attachmentId: attachment.attachmentId,
      replyTo: data['reply_to'] as String?,
      topicId: data['topic_id'] as String?,
      silent: data['silent'] as bool? ?? false,
    );
    if (sent) {
      await _outbox.deleteAttachmentCiphertext(ciphertextPath);
    }
  }

  Future<void> _deliverQueuedEdit(OfflineOutboxItem item) async {
    final data = item.data;
    final msgID = data['message_id'] as String? ?? '';
    final plaintext = data['plaintext_payload'] as String? ?? '';
    final updated = await _api.editMessage(
      convID: item.conversationId,
      msgID: msgID,
      encryptedPayload: data['encrypted_payload'] as String? ?? '',
      signature: data['signature'] as String? ?? '',
    );
    updated.setDecryptedContent(plaintext);
    // Same as the live edit path: the author can't re-decrypt an MLS edit, so
    // the durable cache must carry the new ciphertext's plaintext.
    if (_conversations[item.conversationId]?.usesMls == true) {
      unawaited(
        _cache.put(
          updated.id,
          item.conversationId,
          updated.encryptedPayload,
          plaintext,
          updated.senderId.isNotEmpty ? updated.senderId : _selfId,
        ),
      );
    }
    _replaceMessage(item.conversationId, msgID, updated);
  }

  Future<void> _deliverQueuedReaction(OfflineOutboxItem item) async {
    final data = item.data;
    final msgID = data['message_id'] as String? ?? '';
    final emoji = data['emoji'] as String? ?? '';
    final reacted = data['reacted'] as bool? ?? false;
    if (reacted) {
      await _api.reactToMessage(msgID, emoji);
    } else {
      await _api.removeReaction(msgID, emoji);
    }
  }

  Future<bool> _prepareAndSendOutboxPayload({
    required String convID,
    required String plaintextPayload,
    required String messageType,
    required String? pendingID,
    String? replyTo,
    String? attachmentId,
    String? topicId,
    bool silent = false,
  }) async {
    final prepared = await _prepareEncryptedPayload(
      convID: convID,
      plaintextPayload: plaintextPayload,
      messageType: messageType,
      replyTo: replyTo,
      topicId: topicId,
    );
    final confirmed = await _api.sendMessage(
      convID: convID,
      encryptedPayload: prepared.encryptedPayload,
      signature: prepared.signature,
      messageType: messageType,
      replyTo: replyTo,
      attachmentId: attachmentId,
      topicId: topicId,
      silent: silent,
    );
    _replacePendingWithConfirmed(
      convID: convID,
      pendingID: pendingID,
      confirmed: confirmed,
      plaintextPayload: plaintextPayload,
    );
    return true;
  }

  Future<bool> ensureMessageLoaded(
    String convID,
    String msgID, {
    int maxPages = 12,
  }) async {
    await loadMessages(convID);
    for (var page = 0; page <= maxPages; page++) {
      final messages = _messages[convID] ?? const <Message>[];
      if (messages.any((message) => message.id == msgID)) return true;
      final added = await loadMoreMessages(convID);
      if (added == null || added == 0) break;
    }
    return false;
  }

  /// Send a plain text message, encrypted for all conversation members.
  Future<bool> sendMessage({
    required String convID,
    required String plaintext,
    String messageType = 'text',
    String? replyTo,
    bool silent = false,
    DateTime? scheduledFor,
    String? topicId,
  }) async {
    return _sendEncryptedPayload(
      convID: convID,
      plaintextPayload: plaintext,
      messageType: messageType,
      replyTo: replyTo,
      silent: silent,
      scheduledFor: scheduledFor,
      topicId: topicId,
    );
  }

  Future<bool> sendPaymentArtifact({
    required String convID,
    required String kind,
    required Map<String, dynamic> payload,
  }) {
    return _sendEncryptedPayload(
      convID: convID,
      plaintextPayload: jsonEncode(payload),
      messageType: kind,
    );
  }

  /// Encrypt a local file (via [AttachmentService]) and send as a media message.
  Future<bool> sendAttachment({
    required String convID,
    required PendingAttachment attachment,
    String caption = '',
    bool viewOnce = false,
    bool hasSpoiler = false,
  }) async {
    final payloadJson = jsonEncode(
      attachment.toPayloadJson(
        caption: caption,
        viewOnce: viewOnce,
        hasSpoiler: hasSpoiler,
      ),
    );
    return _sendEncryptedPayload(
      convID: convID,
      plaintextPayload: payloadJson,
      messageType: attachment.messageType.name,
      attachmentId: attachment.attachmentId,
    );
  }

  Future<bool> sendPreparedAttachment({
    required String convID,
    required EncryptedAttachmentUpload attachment,
    String caption = '',
    bool viewOnce = false,
    bool hasSpoiler = false,
    AttachmentUploadProgressCallback? onProgress,
  }) async {
    try {
      if (!_ws.isMonitoring) {
        await _queueAttachmentUpload(
          convID: convID,
          attachment: attachment,
          caption: caption,
          viewOnce: viewOnce,
          hasSpoiler: hasSpoiler,
        );
        return true;
      }
      final uploaded = await AttachmentService(
        _api,
      ).uploadEncryptedAttachment(attachment, onProgress: onProgress);
      return sendAttachment(
        convID: convID,
        attachment: uploaded,
        caption: caption,
        viewOnce: viewOnce,
        hasSpoiler: hasSpoiler,
      );
    } catch (e) {
      if (_shouldRetryOutboxError(e)) {
        await _queueAttachmentUpload(
          convID: convID,
          attachment: attachment,
          caption: caption,
          viewOnce: viewOnce,
          hasSpoiler: hasSpoiler,
        );
        return true;
      }
      rethrow;
    }
  }

  Future<void> _queueAttachmentUpload({
    required String convID,
    required EncryptedAttachmentUpload attachment,
    String caption = '',
    bool viewOnce = false,
    bool hasSpoiler = false,
  }) async {
    final conv = _conversations[convID];
    if (conv == null) {
      throw const ChatSendException(
        'Conversation is not ready. Reopen the chat and try again.',
      );
    }
    final userID = await _storage.getUserID() ?? '';
    if (userID.isEmpty) {
      throw const ChatSendException(
        'Your session is incomplete. Sign in again.',
      );
    }

    final itemID = _newOutboxId();
    final pendingAttachmentID = 'pending-attachment-$itemID';
    final pendingMessageID = 'pending-$itemID';
    final ciphertextPath = await _outbox.saveAttachmentCiphertext(
      itemID,
      attachment.ciphertext,
    );
    final plaintext = jsonEncode(
      attachment.toPayloadJson(
        attachmentId: pendingAttachmentID,
        caption: caption,
        viewOnce: viewOnce,
        hasSpoiler: hasSpoiler,
      ),
    );
    final now = DateTime.now();
    final pending = PendingMessage(
      id: pendingMessageID,
      conversationId: convID,
      senderId: userID,
      type: attachment.messageType,
      encryptedPayload: plaintext,
      signature: '',
      isEncrypted: conv.isEncrypted,
      autoDeleteSeconds: conv.messageTtlSeconds,
      autoDeleteExpiresAt: conv.messageTtlSeconds > 0
          ? now.add(Duration(seconds: conv.messageTtlSeconds))
          : null,
      attachmentId: pendingAttachmentID,
      createdAt: now,
      plaintext: plaintext,
      outboxId: itemID,
      status: PendingMessageStatus.queued,
    );
    _messages[convID] = [...?_messages[convID], pending];
    notifyListeners();

    await _upsertOutboxItem(
      OfflineOutboxItem(
        id: itemID,
        action: OfflineOutboxAction.attachmentUpload,
        conversationId: convID,
        createdAt: now,
        data: {
          'pending_message_id': pendingMessageID,
          'sender_id': userID,
          'plaintext_payload': plaintext,
          'message_type': attachment.messageType.name,
          'attachment_id': pendingAttachmentID,
          'attachment': attachment.toMetadataJson(),
          'ciphertext_path': ciphertextPath,
          'caption': caption,
          if (viewOnce) 'view_once': true,
          if (hasSpoiler) 'has_spoiler': true,
          'is_encrypted': conv.isEncrypted,
          'auto_delete_seconds': conv.messageTtlSeconds,
          if (pending.autoDeleteExpiresAt != null)
            'auto_delete_expires_at': pending.autoDeleteExpiresAt!
                .toUtc()
                .toIso8601String(),
          'created_at': now.toUtc().toIso8601String(),
        },
      ),
    );
  }

  Future<bool> sendOneTimeLocation({required String convID}) async {
    await _ensureLocationPermission(background: false);
    final pos = await _getCurrentPosition();
    final payload = MessageLocation(
      kind: LocationMessageKind.oneTime,
      latitude: pos.latitude,
      longitude: pos.longitude,
      accuracy: pos.accuracy,
      shareId: _newLiveLocationShareId(),
    );
    await _sendEncryptedPayload(
      convID: convID,
      plaintextPayload: jsonEncode(payload.toJson()),
      messageType: 'location',
    );
    return true;
  }

  Future<String?> sendLiveLocation({
    required String convID,
    required Duration duration,
  }) async {
    await _ensureLocationPermission(background: true);
    if (duration <= Duration.zero) {
      throw const ChatSendException(
        'Live location duration must be greater than 0',
      );
    }
    final now = DateTime.now();
    final expiresAt = now.add(duration);
    final pos = await _getCurrentPosition();
    final shareId = _newLiveLocationShareId();
    final payload = MessageLocation(
      kind: LocationMessageKind.live,
      latitude: pos.latitude,
      longitude: pos.longitude,
      accuracy: pos.accuracy,
      shareId: shareId,
      endsAt: expiresAt,
    );
    final msg = await _sendEncryptedPayloadWithResult(
      convID: convID,
      plaintextPayload: jsonEncode(payload.toJson()),
      messageType: 'location',
      allowOutbox: false,
    );
    if (msg == null) return null;
    await _beginLiveLocationShare(
      messageID: msg.id,
      conversationId: convID,
      shareId: shareId,
      latitude: pos.latitude,
      longitude: pos.longitude,
      accuracy: pos.accuracy,
      expiresAt: expiresAt,
    );
    return msg.id;
  }

  Future<void> stopLiveLocation(String messageID) async {
    await _stopLiveLocationShare(messageID, shouldNotify: true);
  }

  /// Re-emit live location notifications for all active shares.
  /// Called when the app moves to the background so the notification
  /// appears immediately rather than waiting for the next position update.
  Future<void> refreshLiveLocationNotifications() async {
    for (final entry in _liveLocationShares.entries) {
      final share = entry.value;
      if (!share.isActive) continue;
      await NotificationService.showLiveLocationNotification(
        messageId: entry.key,
        conversationId: share.conversationId,
        title: 'Sharing with ${share.sharingWith}',
        endsAt: share.expiresAt,
        live: true,
      );
    }
  }

  /// Height of the app-wide live-location bar (matches the call bar height).
  static const double liveLocationBarHeight = 48.0;

  bool isLiveLocationActive(String messageID) =>
      _liveLocationShares.containsKey(messageID);

  /// The first active live-location share across ALL conversations, or null.
  /// Used by the app-wide overlay so the bar persists when navigating away.
  LiveLocationShareStatus? get anyActiveLiveLocationShare {
    for (final entry in _liveLocationShares.entries) {
      if (entry.value.isActive) {
        return LiveLocationShareStatus(
          conversationId: entry.value.conversationId,
          messageId: entry.key,
          sharingWith: entry.value.sharingWith,
          expiresAt: entry.value.expiresAt,
        );
      }
    }
    return null;
  }

  /// Extra pixels that every screen must reserve at the top when the
  /// live-location bar is visible (mirrors [CallProvider.minimizedContentTopInset]).
  double get liveLocationTopInset =>
      anyActiveLiveLocationShare != null ? liveLocationBarHeight + 8.0 : 0.0;

  LiveLocationShareStatus? activeLiveLocationShareForConversation(
    String conversationId,
  ) {
    for (final entry in _liveLocationShares.entries) {
      final share = entry.value;
      if (share.conversationId == conversationId && share.isActive) {
        return LiveLocationShareStatus(
          conversationId: share.conversationId,
          messageId: entry.key,
          sharingWith: share.sharingWith,
          expiresAt: share.expiresAt,
        );
      }
    }
    return null;
  }

  Future<void> _syncLiveLocationShareFromMessage(Message msg) async {
    final location = msg.location;
    final selfId = _selfId ?? await _storage.getUserID() ?? '';
    if (selfId.isEmpty || location == null || msg.senderId != selfId) {
      await _stopLiveLocationShare(msg.id, shouldNotify: false);
      return;
    }
    if (!location.isLive || location.ended || !location.isActive) {
      await _stopLiveLocationShare(msg.id, shouldNotify: false);
      return;
    }

    final existing = _liveLocationShares[msg.id];
    if (existing == null) {
      await _beginLiveLocationShare(
        messageID: msg.id,
        conversationId: msg.conversationId,
        shareId: location.shareId,
        latitude: location.latitude,
        longitude: location.longitude,
        accuracy: location.accuracy,
        expiresAt: location.endsAt!,
      );
      return;
    }

    existing.latitude = location.latitude;
    existing.longitude = location.longitude;
    existing.accuracy = location.accuracy;
    existing.expiresAt = location.endsAt!;
    await NotificationService.showLiveLocationNotification(
      messageId: msg.id,
      conversationId: msg.conversationId,
      title: 'Sharing with ${existing.sharingWith}',
      endsAt: location.endsAt!,
      live: true,
    );
  }

  Future<bool> sendPoll({
    required String convID,
    required String question,
    required List<String> options,
    bool isAnonymous = true,
    bool allowsMultipleAnswers = false,
    bool silent = false,
    bool quiz = false,
    bool meeting = false,
    int? correctOptionId,
    String? explanation,
  }) async {
    final conv = _conversations[convID];
    if (conv?.isEncrypted == true) {
      return _sendEncryptedPoll(
        convID: convID,
        question: question,
        options: options,
        isAnonymous: isAnonymous,
        allowsMultipleAnswers: allowsMultipleAnswers,
        silent: silent,
        quiz: quiz,
        meeting: meeting,
        correctOptionId: correctOptionId,
        explanation: explanation,
      );
    }
    final userID = await _storage.getUserID() ?? '';
    if (userID.isEmpty) {
      throw const ChatSendException(
        'Your session is incomplete. Sign in again.',
      );
    }
    final msg = await _api.createPoll(
      convID: convID,
      question: question,
      options: options,
      isAnonymous: isAnonymous,
      allowsMultipleAnswers: allowsMultipleAnswers,
      silent: silent,
      quiz: quiz,
      meeting: meeting,
      correctOptionId: correctOptionId,
      explanation: explanation,
    );
    _hydrateMessageSender(msg);
    final list = _messages[convID] ?? [];
    _messages[convID] = [...list.where((m) => m.id != msg.id), msg];
    final existingConv = _conversations[convID];
    if (existingConv != null) {
      _conversations[convID] = existingConv.copyWith(lastMessage: msg);
    }
    _indexMessage(msg);
    notifyListeners();
    return true;
  }

  Future<bool> _sendEncryptedPoll({
    required String convID,
    required String question,
    required List<String> options,
    required bool isAnonymous,
    required bool allowsMultipleAnswers,
    required bool silent,
    bool quiz = false,
    bool meeting = false,
    int? correctOptionId,
    String? explanation,
  }) async {
    final pollEffectiveMultiple = meeting ? true : allowsMultipleAnswers;
    final pollType = quiz ? 'quiz' : (meeting ? 'meeting' : 'regular');
    final userID = await _storage.getUserID() ?? '';
    if (userID.isEmpty) {
      throw const ChatSendException(
        'Your session is incomplete. Sign in again.',
      );
    }
    final cleanQuestion = question.trim();
    final cleanOptions = options.map((option) => option.trim()).toList();
    if (cleanQuestion.isEmpty || cleanOptions.any((option) => option.isEmpty)) {
      throw const ChatSendException('Poll question and options are required.');
    }
    if (cleanOptions.isEmpty || cleanOptions.length > 10) {
      throw const ChatSendException('Polls must have 1 to 10 options.');
    }

    final uuid = const Uuid();
    final pollID = uuid.v4();
    final optionIDs = [for (final _ in cleanOptions) uuid.v4()];
    final localPoll = Poll(
      id: pollID,
      question: cleanQuestion,
      type: pollType,
      isAnonymous: isAnonymous,
      allowsMultipleAnswers: pollEffectiveMultiple,
      allowsRevoting: !quiz,
      isClosed: false,
      totalVoterCount: 0,
      correctOptionIds:
          quiz && correctOptionId != null ? [correctOptionId] : const [],
      explanation: quiz ? explanation : null,
      options: [
        for (var i = 0; i < cleanOptions.length; i++)
          PollOption(
            id: optionIDs[i],
            index: i,
            text: cleanOptions[i],
            voterCount: 0,
            persistentId: optionIDs[i],
          ),
      ],
    );
    final payload = jsonEncode({
      'poll': {
        'id': pollID,
        'question': cleanQuestion,
        'type': pollType,
        'is_anonymous': isAnonymous,
        'allows_multiple_answers': pollEffectiveMultiple,
        'allows_revoting': !quiz,
        'options': [
          for (var i = 0; i < cleanOptions.length; i++)
            {
              'id': optionIDs[i],
              'option_index': i,
              'text': cleanOptions[i],
              'persistent_id': optionIDs[i],
            },
        ],
      },
    });
    final prepared = await _prepareEncryptedPayload(
      convID: convID,
      plaintextPayload: payload,
      messageType: 'poll',
    );

    final pending = PendingMessage(
      id: 'pending-${DateTime.now().millisecondsSinceEpoch}',
      conversationId: convID,
      senderId: userID,
      type: MessageType.poll,
      encryptedPayload: prepared.encryptedPayload,
      signature: prepared.signature,
      isEncrypted: true,
      autoDeleteSeconds: prepared.autoDeleteSeconds,
      autoDeleteExpiresAt: prepared.autoDeleteExpiresAt,
      silent: silent,
      createdAt: DateTime.now(),
      plaintext: prepared.cleartextPayload,
      poll: localPoll,
    );
    _messages[convID] = [...?_messages[convID], pending];
    notifyListeners();

    try {
      final confirmed = await _api.createEncryptedPoll(
        convID: convID,
        pollID: pollID,
        optionIDs: optionIDs,
        encryptedPayload: prepared.encryptedPayload,
        postToken: prepared.postToken ?? '',
        isAnonymous: isAnonymous,
        allowsMultipleAnswers: pollEffectiveMultiple,
        allowsRevoting: !quiz,
        silent: silent,
        quiz: quiz,
        meeting: meeting,
        correctOptionId: correctOptionId,
        explanation: explanation,
      );
      _replacePendingWithConfirmed(
        convID: convID,
        pendingID: pending.id,
        confirmed: confirmed,
        plaintextPayload: prepared.cleartextPayload,
      );
      return true;
    } catch (e) {
      final list = _messages[convID] ?? [];
      final idx = list.indexWhere((m) => m.id == pending.id);
      if (idx != -1) {
        list[idx] = PendingMessage(
          id: pending.id,
          conversationId: pending.conversationId,
          senderId: pending.senderId,
          type: pending.type,
          encryptedPayload: pending.encryptedPayload,
          signature: pending.signature,
          isEncrypted: pending.isEncrypted,
          autoDeleteSeconds: pending.autoDeleteSeconds,
          autoDeleteExpiresAt: pending.autoDeleteExpiresAt,
          silent: pending.silent,
          createdAt: pending.createdAt,
          plaintext: prepared.cleartextPayload,
          poll: localPoll,
          status: PendingMessageStatus.failed,
          lastError: e.toString(),
        );
        _messages[convID] = List.from(list);
        notifyListeners();
      }
      rethrow;
    }
  }

  // The viewer's own poll selections, by poll id. Refetched poll payloads
  // don't echo the viewer's votes (anonymous ones can't, by design), so the
  // marked bubble would vanish on chat re-entry without this device-local
  // memory. Hydrated lazily per poll from secure storage.
  final Map<String, List<String>> _myPollVotes = {};
  final Set<String> _myPollVotesLoading = {};

  /// The option ids this device voted for in [pollID] (empty until known).
  /// Triggers a lazy storage read on first ask and notifies when it lands.
  List<String> myPollVotes(String pollID) {
    final cached = _myPollVotes[pollID];
    if (cached != null) return cached;
    if (_myPollVotesLoading.add(pollID)) {
      unawaited(
        _storage
            .getPollVoteSelections(pollID)
            .then((ids) {
              _myPollVotes[pollID] = ids;
              if (ids.isNotEmpty) notifyListeners();
            })
            .catchError((Object _) {
              _myPollVotes[pollID] = const <String>[];
            }),
      );
    }
    return const [];
  }

  void _rememberPollVote(String pollID, List<String> optionIDs) {
    _myPollVotes[pollID] = List.of(optionIDs);
    unawaited(
      _storage
          .savePollVoteSelections(pollID, optionIDs)
          .catchError((Object _) {}),
    );
  }

  Future<void> votePoll({
    required String convID,
    required String pollID,
    required List<String> optionIDs,
  }) async {
    final list = _messages[convID];
    final pollMessage = list?.where((m) => m.poll?.id == pollID).firstOrNull;
    final isAnonymous = pollMessage?.poll?.isAnonymous ?? false;

    final Poll updatedPoll;
    if (isAnonymous) {
      // Blind-token vote: the server stores the choice against the token's
      // hash, never this account. The raw token is issued once and cached so
      // revoting (and "you voted X") keep working on this device.
      var token = await _storage.getPollVoteToken(pollID);
      if (token == null || token.isEmpty) {
        token = await _api.requestPollVoteToken(pollID);
        await _storage.savePollVoteToken(pollID, token);
        // Decorrelate the (logged) issuance from the vote a little; the
        // anonymity model itself is "the server doesn't store who voted".
        await Future<void>.delayed(
          Duration(milliseconds: 200 + Random().nextInt(1300)),
        );
      }
      final voted = await _api.votePollAnonymous(pollID, token, optionIDs);
      // The server can't attribute the vote, so it can't echo our selection —
      // mark it locally for the "you voted X" UI state.
      updatedPoll = voted.copyWith(voterOptionIds: List.of(optionIDs));
    } else {
      updatedPoll = await _api.votePoll(pollID, optionIDs);
    }
    // Persist the selection so the marked bubble survives chat re-entry
    // (refetched polls don't echo the viewer's own votes).
    _rememberPollVote(pollID, optionIDs);

    if (list == null) return;
    final idx = list.indexWhere((m) => m.poll?.id == pollID);
    if (idx == -1) return;
    final updated = List<Message>.from(list);
    final current = updated[idx];
    updated[idx] = current.copyWith(
      poll: _pollWithArtifactLabels(
        updatedPoll,
        current.artifact,
        fallback: current.poll,
      ),
    );
    _messages[convID] = updated;
    notifyListeners();
  }

  /// Records a call outcome as a `system` message in the DM. The payload is
  /// E2E-encrypted like any other message and rendered as a centered chip
  /// (red for missed). Posted only by the caller's client to avoid duplicates.
  Future<void> postCallEvent({
    required String convID,
    required bool answered,
    required bool isVideo,
    int durationSecs = 0,
  }) async {
    final payload = jsonEncode({
      'call_event': answered ? 'answered' : 'missed',
      'video': isVideo,
      'duration': durationSecs,
    });
    await _sendEncryptedPayload(
      convID: convID,
      plaintextPayload: payload,
      messageType: 'system',
    );
  }

  /// Notify the conversation that the local user captured a screenshot of a
  /// view-once / disappearing attachment. Travels E2E as a `system` artifact —
  /// no server-readable metadata — and renders as a system note for everyone.
  Future<void> postScreenshotNotice({required String convID}) async {
    final payload = jsonEncode({'screenshot_notice': true});
    try {
      await _sendEncryptedPayload(
        convID: convID,
        plaintextPayload: payload,
        messageType: 'system',
      );
    } catch (_) {
      // Best-effort: never throw from a screenshot handler.
    }
  }

  /// Re-encrypt and replace the body of a message the user sent. Encryption is
  /// identical to sending; the server stamps edited_at and broadcasts the update.
  Future<void> editMessage({
    required String convID,
    required String msgID,
    required String newPlaintext,
  }) async {
    final conv = _conversations[convID];
    if (conv == null) return;
    final list = _messages[convID] ?? [];
    final idx = list.indexWhere((m) => m.id == msgID);
    Message? original = idx != -1 ? list[idx] : null;
    final editMessageType = _messageTypeWire(
      original?.type ?? MessageType.text,
    );
    final String encrypted;
    final String signature;
    final String cleartextPayload;
    if (conv.isEncrypted) {
      final prepared = await _prepareEncryptedPayload(
        convID: convID,
        plaintextPayload: newPlaintext,
        messageType: editMessageType,
        replyTo: original?.effectiveReplyTo,
        topicId: original?.effectiveTopicId,
        mediaGroupId: original?.effectiveMediaGroupId,
        includePostToken: false,
      );
      encrypted = prepared.encryptedPayload;
      signature = prepared.signature;
      cleartextPayload = prepared.cleartextPayload;
    } else {
      encrypted = newPlaintext;
      signature = '';
      cleartextPayload = newPlaintext;
    }

    if (idx != -1) {
      final optimistic = list[idx].copyWith(
        encryptedPayload: encrypted,
        signature: signature,
        editedAt: DateTime.now(),
      );
      optimistic.setDecryptedContent(cleartextPayload);
      list[idx] = optimistic;
      _messages[convID] = List.from(list);
      notifyListeners();
    }

    if (!_ws.isMonitoring) {
      await _upsertOutboxItem(
        OfflineOutboxItem(
          id: _newOutboxId(),
          action: OfflineOutboxAction.editMessage,
          conversationId: convID,
          createdAt: DateTime.now(),
          data: {
            'message_id': msgID,
            'plaintext_payload': cleartextPayload,
            'encrypted_payload': encrypted,
            'signature': signature,
          },
        ),
      );
      return;
    }

    try {
      final updated = await _api.editMessage(
        convID: convID,
        msgID: msgID,
        encryptedPayload: encrypted,
        signature: signature,
      );
      // We can't always re-decrypt our own message from the server, so set the
      // plaintext we already know directly.
      updated.setDecryptedContent(cleartextPayload);
      // An MLS edit mints a new ciphertext the author can never re-decrypt;
      // refresh the durable cache under the new fingerprint or the edit is
      // lost on the next restart.
      if (conv.usesMls) {
        unawaited(
          _cache.put(
            updated.id,
            convID,
            updated.encryptedPayload,
            cleartextPayload,
            updated.senderId.isNotEmpty ? updated.senderId : _selfId,
          ),
        );
      }
      _replaceMessage(convID, msgID, updated);
    } catch (e) {
      if (_shouldRetryOutboxError(e)) {
        await _upsertOutboxItem(
          OfflineOutboxItem(
            id: _newOutboxId(),
            action: OfflineOutboxAction.editMessage,
            conversationId: convID,
            createdAt: DateTime.now(),
            data: {
              'message_id': msgID,
              'plaintext_payload': cleartextPayload,
              'encrypted_payload': encrypted,
              'signature': signature,
            },
          ),
        );
        return;
      }
      if (original != null) {
        final current = _messages[convID] ?? [];
        final currentIdx = current.indexWhere((m) => m.id == msgID);
        if (currentIdx != -1) {
          current[currentIdx] = original;
          _messages[convID] = List.from(current);
          notifyListeners();
        }
      }
      rethrow;
    }
  }

  Future<void> _handleEditedMessage(Message msg) async {
    final list = _messages[msg.conversationId];
    if (list == null) return;
    final idx = list.indexWhere((m) => m.id == msg.id);
    if (idx == -1) return;
    final old = list[idx];

    // Drop the durable plaintext cache entry when the ciphertext actually
    // changed — otherwise a fingerprint false-match could keep rendering the
    // pre-edit plaintext after a restart. (_tryDecrypt re-caches the new
    // plaintext for MLS.)
    if (old.encryptedPayload != msg.encryptedPayload) {
      await _cache.delete(msg.id);
    }

    final privateKey = await _storage.getPrivateKeyIfUnlocked() ?? '';
    await _tryDecrypt(msg, privateKey);
    // If we can't decrypt the edit (e.g. our own message), keep the text we had.
    if (!msg.isDecrypted && old.isDecrypted) {
      final oldLocation = old.location;
      final keptPlaintext = oldLocation != null
          ? jsonEncode(oldLocation.toJson())
          : (old.decryptedContent ?? '');
      msg.setDecryptedContent(keptPlaintext);
      // Our own MLS edit echoed from another device: we can never decrypt our
      // own ciphertext, and the stale cache entry was just dropped above —
      // re-persist the kept plaintext under the new fingerprint so a restart
      // doesn't render the message undecryptable. Only for own messages: a
      // recipient's transient decrypt failure must stay uncached so nothing
      // masks the real content.
      if (old.senderId.isNotEmpty &&
          old.senderId == _selfId &&
          _conversations[msg.conversationId]?.usesMls == true) {
        unawaited(
          _cache.put(
            msg.id,
            msg.conversationId,
            msg.encryptedPayload,
            keptPlaintext,
            old.senderId,
          ),
        );
      }
    }
    if (msg.senderId.isEmpty) msg.senderId = old.senderId;
    msg.sender ??= old.sender;
    list[idx] = msg;
    await _syncLiveLocationShareFromMessage(msg);
    _messages[msg.conversationId] = List.from(list);
    notifyListeners();
  }

  Future<_PreparedEncryptedPayload> _prepareEncryptedPayload({
    required String convID,
    required String plaintextPayload,
    required String messageType,
    String? replyTo,
    String? topicId,
    String? mediaGroupId,
    bool includePostToken = true,
  }) async {
    final conv = _conversations[convID];
    if (conv == null) {
      throw const ChatSendException(
        'Conversation is not ready. Reopen the chat and try again.',
      );
    }

    final privateKey = await _storage.getPrivateKeyIfUnlocked() ?? '';
    final userID = await _storage.getUserID() ?? '';
    if (userID.isEmpty) {
      throw const ChatSendException(
        'Your session is incomplete. Sign in again.',
      );
    }
    if (conv.usesMls) {
      if (privateKey.isEmpty) {
        throw const ChatSendException(
          'Your PGP key is locked or missing. Unlock or import it in Settings to post sealed MLS messages.',
        );
      }
      final artifactPayload = _chatArtifactPayload(
        messageType,
        plaintextPayload,
        replyTo: replyTo,
        topicId: topicId,
        mediaGroupId: mediaGroupId,
      );
      final cleartextPayload = await _signedPgpCleartextPayload(
        convID: convID,
        plaintextPayload: artifactPayload,
        messageType: messageType,
        senderId: userID,
        privateKey: privateKey,
      );
      final encrypted = await _mls.encryptPayload(
        api: _api,
        conversation: conv,
        plaintextPayload: cleartextPayload,
      );
      return _PreparedEncryptedPayload(
        encryptedPayload: encrypted,
        signature: '',
        cleartextPayload: cleartextPayload,
        isEncrypted: true,
        autoDeleteSeconds: conv.messageTtlSeconds,
        autoDeleteExpiresAt: conv.messageTtlSeconds > 0
            ? DateTime.now().add(Duration(seconds: conv.messageTtlSeconds))
            : null,
        senderId: userID,
        postToken: includePostToken
            ? await _sealedPostToken(convID, privateKey)
            : null,
      );
    }
    if (conv.usesPgp && privateKey.isEmpty) {
      throw const ChatSendException(
        'Your PGP key is locked or missing. Unlock or import it in Settings.',
      );
    }
    if (!conv.isEncrypted) {
      return _PreparedEncryptedPayload(
        encryptedPayload: plaintextPayload,
        signature: '',
        cleartextPayload: plaintextPayload,
        isEncrypted: false,
        autoDeleteSeconds: conv.messageTtlSeconds,
        autoDeleteExpiresAt: conv.messageTtlSeconds > 0
            ? DateTime.now().add(Duration(seconds: conv.messageTtlSeconds))
            : null,
        senderId: userID,
      );
    }

    final recipients = await _freshRecipientKeys(convID, conv);
    if (recipients.isEmpty) {
      throw const ChatSendException(
        'Could not load recipient keys. Refresh the chat and try again.',
      );
    }
    final artifactPayload = _chatArtifactPayload(
      messageType,
      plaintextPayload,
      replyTo: replyTo,
      topicId: topicId,
      mediaGroupId: mediaGroupId,
    );
    final cleartextPayload = await _signedPgpCleartextPayload(
      convID: convID,
      plaintextPayload: artifactPayload,
      messageType: messageType,
      senderId: userID,
      privateKey: privateKey,
    );

    final String encrypted;
    try {
      encrypted = await PgpService.encrypt(
        plaintext: cleartextPayload,
        recipients: recipients,
        signingPrivateKeyArmored: privateKey,
      ).timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw const ChatSendException(
        'Encryption timed out. Your stored key may be corrupted — try rotating it in Settings → PGP Keys.',
      );
    } catch (e) {
      throw ChatSendException('Encryption failed: $e');
    }

    final postToken = includePostToken
        ? await _sealedPostToken(convID, privateKey)
        : null;

    return _PreparedEncryptedPayload(
      encryptedPayload: encrypted,
      signature: '',
      cleartextPayload: cleartextPayload,
      isEncrypted: true,
      autoDeleteSeconds: conv.messageTtlSeconds,
      autoDeleteExpiresAt: conv.messageTtlSeconds > 0
          ? DateTime.now().add(Duration(seconds: conv.messageTtlSeconds))
          : null,
      senderId: userID,
      postToken: postToken,
    );
  }

  Future<Message?> _sendEncryptedPayloadWithResult({
    required String convID,
    required String plaintextPayload,
    required String messageType,
    String? replyTo,
    String? attachmentId,
    String? topicId,
    bool silent = false,
    DateTime? scheduledFor,
    bool allowOutbox = true,
  }) async {
    final conv = _conversations[convID];
    if (conv == null) {
      throw const ChatSendException(
        'Conversation is not ready. Reopen the chat and try again.',
      );
    }

    final prepared = await _prepareEncryptedPayload(
      convID: convID,
      plaintextPayload: plaintextPayload,
      messageType: messageType,
      replyTo: replyTo,
      topicId: topicId,
    );
    final serverMessageType = prepared.isEncrypted ? 'text' : messageType;

    if (scheduledFor != null) {
      if (conv.isEncrypted) {
        final scheduled = await _api.scheduleSealedMessage(
          convID: convID,
          encryptedPayload: prepared.encryptedPayload,
          postToken: prepared.postToken ?? '',
          scheduledFor: scheduledFor,
          replyTo: null,
          attachmentId: attachmentId,
          topicId: null,
          silent: silent,
        );
        // Author-local copy of the composed plaintext so the schedule list can
        // show the intended message — the stored payload is ciphertext the
        // author can't decrypt back (sealed sender / forward-secret MLS).
        await _storage.saveScheduledPlaintext(
          convID,
          scheduled.id,
          plaintextPayload,
        );
      } else {
        await _api.sendMessage(
          convID: convID,
          encryptedPayload: prepared.encryptedPayload,
          signature: prepared.signature,
          messageType: serverMessageType,
          replyTo: replyTo,
          attachmentId: attachmentId,
          topicId: topicId,
          silent: silent,
          scheduledFor: scheduledFor,
        );
      }
      return null;
    }

    final pending = PendingMessage(
      id: 'pending-${DateTime.now().millisecondsSinceEpoch}',
      conversationId: convID,
      senderId: prepared.senderId,
      type: MessageType.values.firstWhere(
        (t) => t.name == messageType,
        orElse: () => MessageType.text,
      ),
      encryptedPayload: prepared.encryptedPayload,
      signature: prepared.signature,
      isEncrypted: prepared.isEncrypted,
      autoDeleteSeconds: prepared.autoDeleteSeconds,
      autoDeleteExpiresAt: prepared.autoDeleteExpiresAt,
      attachmentId: attachmentId,
      replyTo: replyTo,
      topicId: topicId,
      silent: silent,
      createdAt: DateTime.now(),
      plaintext: prepared.cleartextPayload,
    );

    _messages[convID] = [...?_messages[convID], pending];
    notifyListeners();

    if (allowOutbox && !_ws.isMonitoring) {
      await _queuePreparedMessageSend(
        convID: convID,
        pending: pending,
        plaintextPayload: prepared.cleartextPayload,
        messageType: serverMessageType,
        localMessageType: messageType,
        encryptedPayload: prepared.encryptedPayload,
        signature: prepared.signature,
        postToken: prepared.postToken,
        replyTo: replyTo,
        attachmentId: attachmentId,
        topicId: topicId,
        silent: silent,
        isEncrypted: prepared.isEncrypted,
        autoDeleteSeconds: prepared.autoDeleteSeconds,
        autoDeleteExpiresAt: prepared.autoDeleteExpiresAt,
      );
      return null;
    }

    try {
      await _applySendJitter();
      // pending.id doubles as the idempotency key — the same id rides along
      // if this send times out and is retried through the outbox, so the
      // server maps the retry onto the original row instead of duplicating.
      final confirmed = conv.isEncrypted
          ? await _api.sendSealedMessage(
              convID: convID,
              encryptedPayload: prepared.encryptedPayload,
              postToken: prepared.postToken ?? '',
              replyTo: null,
              attachmentId: attachmentId,
              topicId: null,
              silent: silent,
              clientNonce: pending.id,
            )
          : await _api.sendMessage(
              convID: convID,
              encryptedPayload: prepared.encryptedPayload,
              signature: prepared.signature,
              messageType: serverMessageType,
              replyTo: replyTo,
              attachmentId: attachmentId,
              topicId: topicId,
              silent: silent,
              clientNonce: pending.id,
            );
      _replacePendingWithConfirmed(
        convID: convID,
        pendingID: pending.id,
        confirmed: confirmed,
        plaintextPayload: prepared.cleartextPayload,
      );
      return confirmed;
    } catch (e) {
      if (allowOutbox && _shouldRetryOutboxError(e)) {
        await _queuePreparedMessageSend(
          convID: convID,
          pending: pending,
          plaintextPayload: prepared.cleartextPayload,
          messageType: serverMessageType,
          localMessageType: messageType,
          encryptedPayload: prepared.encryptedPayload,
          signature: prepared.signature,
          postToken: prepared.postToken,
          replyTo: replyTo,
          attachmentId: attachmentId,
          topicId: topicId,
          silent: silent,
          isEncrypted: prepared.isEncrypted,
          autoDeleteSeconds: prepared.autoDeleteSeconds,
          autoDeleteExpiresAt: prepared.autoDeleteExpiresAt,
        );
        return null;
      }
      final list = _messages[convID] ?? [];
      final idx = list.indexWhere((m) => m.id == pending.id);
      if (idx != -1) {
        list[idx] = PendingMessage(
          id: pending.id,
          conversationId: pending.conversationId,
          senderId: pending.senderId,
          type: pending.type,
          encryptedPayload: pending.encryptedPayload,
          signature: pending.signature,
          isEncrypted: pending.isEncrypted,
          autoDeleteSeconds: pending.autoDeleteSeconds,
          autoDeleteExpiresAt: pending.autoDeleteExpiresAt,
          attachmentId: pending.attachmentId,
          replyTo: pending.replyTo,
          topicId: pending.topicId,
          silent: pending.silent,
          createdAt: pending.createdAt,
          plaintext: prepared.cleartextPayload,
          status: PendingMessageStatus.failed,
          lastError: e.toString(),
        );
        _messages[convID] = List.from(list);
        notifyListeners();
      }
      rethrow;
    }
  }

  Future<void> _queuePreparedMessageSend({
    required String convID,
    required PendingMessage pending,
    required String plaintextPayload,
    required String messageType,
    required String localMessageType,
    required String encryptedPayload,
    required String signature,
    String? postToken,
    required bool isEncrypted,
    required int autoDeleteSeconds,
    required DateTime? autoDeleteExpiresAt,
    String? replyTo,
    String? attachmentId,
    String? topicId,
    bool silent = false,
  }) async {
    final item = OfflineOutboxItem(
      id: _newOutboxId(),
      action: OfflineOutboxAction.sendMessage,
      conversationId: convID,
      createdAt: DateTime.now(),
      data: {
        'pending_message_id': pending.id,
        'sender_id': pending.senderId,
        'plaintext_payload': plaintextPayload,
        'encrypted_payload': encryptedPayload,
        'signature': signature,
        'post_token': ?postToken,
        'message_type': messageType,
        'local_message_type': localMessageType,
        'is_encrypted': isEncrypted,
        'auto_delete_seconds': autoDeleteSeconds,
        if (autoDeleteExpiresAt != null)
          'auto_delete_expires_at': autoDeleteExpiresAt
              .toUtc()
              .toIso8601String(),
        'reply_to': ?replyTo,
        'attachment_id': ?attachmentId,
        'topic_id': ?topicId,
        if (silent) 'silent': true,
        'created_at': pending.createdAt.toUtc().toIso8601String(),
      },
    );
    await _upsertOutboxItem(item);
  }

  void _replacePendingWithConfirmed({
    required String convID,
    required String? pendingID,
    required Message confirmed,
    required String plaintextPayload,
  }) {
    // Sealed-sender messages come back from the server without sender_id.
    // Restore it from the local pending so isMe / avatar hydration still work.
    if (confirmed.senderId.isEmpty && pendingID != null) {
      final list = _messages[convID] ?? const <Message>[];
      final idx = list.indexWhere((m) => m.id == pendingID);
      if (idx != -1 && list[idx].senderId.isNotEmpty) {
        confirmed.senderId = list[idx].senderId;
      }
    }
    try {
      confirmed.setDecryptedContent(plaintextPayload);
      _applyArtifactState(confirmed);
    } catch (error, stackTrace) {
      confirmed.markDecryptionFailed();
      debugPrint('Failed to hydrate confirmed message plaintext: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
    // The author of an MLS message can never re-decrypt it — the sender
    // ratchet key is consumed at encrypt time. Persist the plaintext into the
    // durable cache NOW (under the server-assigned id) or every message this
    // user ever sent comes back as "Unable to decrypt" with an unknown sender
    // after the next app restart.
    if (confirmed.isDecrypted && _conversations[convID]?.usesMls == true) {
      unawaited(
        _cache.put(
          confirmed.id,
          convID,
          confirmed.encryptedPayload,
          plaintextPayload,
          confirmed.senderId.isNotEmpty ? confirmed.senderId : _selfId,
        ),
      );
    }
    try {
      _hydrateMessageSender(confirmed);
    } catch (error, stackTrace) {
      debugPrint('Failed to hydrate confirmed message sender: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
    try {
      _indexMessage(confirmed);
    } catch (error, stackTrace) {
      debugPrint('Failed to index confirmed message: $error');
      debugPrintStack(stackTrace: stackTrace);
    }

    final list = _messages[convID] ?? [];
    _messages[convID] = [
      ...list.where((m) => m.id != pendingID && m.id != confirmed.id),
      confirmed,
    ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    final existingConv = _conversations[convID];
    if (existingConv != null) {
      _conversations[convID] = existingConv.copyWith(lastMessage: confirmed);
    }

    notifyListeners();
  }

  void _replaceMessage(String convID, String msgID, Message updated) {
    _hydrateMessageSender(updated);
    _indexMessage(updated);
    final list = _messages[convID] ?? [];
    final idx = list.indexWhere((message) => message.id == msgID);
    if (idx != -1) {
      final next = List<Message>.from(list);
      next[idx] = updated;
      _messages[convID] = next;
    }
    final conv = _conversations[convID];
    if (conv?.lastMessage?.id == msgID) {
      _conversations[convID] = conv!.copyWith(lastMessage: updated);
    }
    notifyListeners();
  }

  MessageType _messageTypeFromWire(String value) {
    return switch (value) {
      'sticker' => MessageType.sticker,
      'file' => MessageType.file,
      'image' => MessageType.image,
      'video' => MessageType.video,
      'voice' => MessageType.voice,
      'audio' => MessageType.audio,
      'animation' => MessageType.animation,
      'video_note' => MessageType.videoNote,
      'live_photo' => MessageType.livePhoto,
      'poll' => MessageType.poll,
      'location' => MessageType.location,
      'venue' => MessageType.venue,
      'contact' => MessageType.contact,
      'dice' => MessageType.dice,
      'checklist' => MessageType.checklist,
      'invoice' => MessageType.invoice,
      'payment_request' => MessageType.paymentRequest,
      'payment_transfer' => MessageType.paymentTransfer,
      'system' => MessageType.system,
      _ => MessageType.text,
    };
  }

  String _messageTypeWire(MessageType type) {
    return switch (type) {
      MessageType.sticker => 'sticker',
      MessageType.file => 'file',
      MessageType.image => 'image',
      MessageType.video => 'video',
      MessageType.voice => 'voice',
      MessageType.audio => 'audio',
      MessageType.animation => 'animation',
      MessageType.videoNote => 'video_note',
      MessageType.livePhoto => 'live_photo',
      MessageType.poll => 'poll',
      MessageType.location => 'location',
      MessageType.venue => 'venue',
      MessageType.contact => 'contact',
      MessageType.dice => 'dice',
      MessageType.game => 'game',
      MessageType.checklist => 'checklist',
      MessageType.invoice => 'invoice',
      MessageType.paymentRequest => 'payment_request',
      MessageType.paymentTransfer => 'payment_transfer',
      MessageType.system => 'system',
      MessageType.text => 'text',
    };
  }

  String _chatArtifactPayload(
    String kind,
    String plaintextPayload, {
    String? replyTo,
    String? topicId,
    String? mediaGroupId,
  }) {
    if (ChatArtifact.tryParse(plaintextPayload) != null) {
      return plaintextPayload;
    }
    Object payload = plaintextPayload;
    try {
      final decoded = jsonDecode(plaintextPayload);
      if (decoded is Map || decoded is List) payload = decoded;
    } catch (_) {}
    final metadata = <String, dynamic>{
      if (replyTo != null && replyTo.isNotEmpty) 'reply_to': replyTo,
      if (topicId != null && topicId.isNotEmpty) 'topic_id': topicId,
      if (mediaGroupId != null && mediaGroupId.isNotEmpty)
        'media_group_id': mediaGroupId,
    };
    return ChatArtifact.encodePayload(
      kind: kind,
      payload: payload,
      metadata: metadata,
    );
  }

  Future<String> _signedPgpCleartextPayload({
    required String convID,
    required String plaintextPayload,
    required String messageType,
    required String senderId,
    required String privateKey,
  }) async {
    final fingerprint = await _storage.getFingerprint() ?? '';
    final createdAt = DateTime.now().toUtc().toIso8601String();
    final signature = await PgpService.sign(
      data: PgpService.senderProofData(
        conversationId: convID,
        messageType: messageType,
        payload: plaintextPayload,
        createdAt: createdAt,
      ),
      privateKeyArmored: privateKey,
    ).timeout(const Duration(seconds: 30));
    // STH gossip: piggyback our last VERIFIED key-transparency tree head
    // inside the encrypted envelope. Recipients compare it against their own
    // — two valid heads of equal size with different roots prove the server
    // equivocated, and the server can't strip what it can't read. ~150 bytes,
    // absorbed by the plaintext padding buckets.
    final sthGossip = await KtAuditService(storage: _storage).gossipPayload();
    return jsonEncode({
      'openchat_message': 1,
      'type': messageType,
      'payload': plaintextPayload,
      'kt_sth': ?sthGossip,
      'sender': {
        'id': senderId,
        'key_fingerprint': fingerprint,
        'signature': signature,
        'created_at': createdAt,
      },
    });
  }

  // Per-conversation pool of pre-fetched, single-use sealed post tokens, each
  // tagged with when it was issued. Pre-fetching (and refilling with jitter)
  // decouples the *authenticated* token issuance from the *anonymous* sealed
  // post that follows: without it the server sees an issuance for user X
  // immediately before a sealed message in the same conversation, which largely
  // defeats sealed-sender anonymity through timing correlation.
  final Map<String, List<_PooledPostToken>> _postTokenPool = {};
  final Set<String> _postTokenRefilling = {};
  static const int _postTokenPoolTarget = 3;
  // Stay well under the server's 15-minute token TTL.
  static const Duration _postTokenMaxAge = Duration(minutes: 10);

  Future<String> _sealedPostToken(String convID, String privateKey) async {
    final pool = _postTokenPool[convID];
    String? token;
    if (pool != null) {
      // Drop expired tokens, then take the freshest still-valid one.
      pool.removeWhere((t) => t.isStale(_postTokenMaxAge));
      if (pool.isNotEmpty) {
        token = pool.removeLast().token;
      }
    }
    token ??= await _fetchSealedPostToken(convID, privateKey);
    // Top the pool back up in the background, on a jittered schedule.
    unawaited(_refillPostTokenPool(convID, privateKey));
    return token;
  }

  Future<String> _fetchSealedPostToken(String convID, String privateKey) async {
    final encrypted = await _api.getEncryptedSealedPostToken(convID);
    return PgpService.decrypt(
      encryptedArmor: encrypted,
      privateKeyArmored: privateKey,
    );
  }

  Future<void> _refillPostTokenPool(String convID, String privateKey) async {
    if (_postTokenRefilling.contains(convID)) return;
    _postTokenRefilling.add(convID);
    final rng = Random.secure();
    try {
      while (true) {
        final pool = _postTokenPool[convID] ??= [];
        pool.removeWhere((t) => t.isStale(_postTokenMaxAge));
        if (pool.length >= _postTokenPoolTarget) break;
        // Jitter each fetch so issuances don't cluster around send time.
        await Future.delayed(Duration(milliseconds: 500 + rng.nextInt(2500)));
        try {
          final token = await _fetchSealedPostToken(convID, privateKey);
          (_postTokenPool[convID] ??= []).add(
            _PooledPostToken(token, DateTime.now()),
          );
        } catch (_) {
          break; // back off on error; the next send retries
        }
      }
    } finally {
      _postTokenRefilling.remove(convID);
    }
  }

  // Replay guard: a captured sealed envelope replayed by the server arrives
  // with the SAME sender-proof signature under a different message id. Keyed
  // per conversation; in-memory (a replay across restarts re-verifies, but the
  // durable plaintext cache already short-circuits known message ids).
  final Map<String, Map<String, String>> _seenProofSignatures = {};

  Future<String?> _verifiedPgpSenderId(
    String raw,
    String convID,
    Conversation? conversation, {
    String? messageId,
    DateTime? serverCreatedAt,
  }) async {
    final proof = Message.senderProofFromRaw(raw);
    if (proof == null) {
      return null;
    }
    // Replay detection — the v2 proof binds createdAt precisely so duplicates
    // are detectable; actually check it instead of only re-signing it.
    if (messageId != null && proof.signature.isNotEmpty) {
      final seen = _seenProofSignatures.putIfAbsent(
        convID,
        () => <String, String>{},
      );
      final priorMessageId = seen[proof.signature];
      if (priorMessageId != null && priorMessageId != messageId) {
        debugPrint(
          'ChatProvider: REPLAYED sender proof — signature already seen on '
          'message $priorMessageId, rejecting $messageId',
        );
        return null;
      }
      seen[proof.signature] = messageId;
    }
    // A proof "signed" meaningfully after the server accepted the message is
    // forged metadata (10 min allows client clock skew). The reverse — proof
    // older than server receipt — is legitimate (offline outbox, scheduled
    // sends), so it is deliberately not rejected.
    final proofCreatedAt = DateTime.tryParse(proof.createdAt ?? '');
    if (proofCreatedAt != null &&
        serverCreatedAt != null &&
        proofCreatedAt.isAfter(
          serverCreatedAt.add(const Duration(minutes: 10)),
        )) {
      debugPrint(
        'ChatProvider: sender proof timestamp ${proof.createdAt} is after '
        'server receipt $serverCreatedAt — rejecting',
      );
      return null;
    }

    var conv = conversation ?? _conversations[convID];
    var members = conv?.members ?? const <ConversationMember>[];
    if (members.isEmpty) {
      try {
        members = await _api.getConversationMembers(convID);
        if (conv != null) {
          _conversations[convID] = conv.copyWith(members: members);
        }
      } catch (_) {
        return null;
      }
    }
    ConversationMember? sender;
    for (final member in members) {
      if (member.userId == proof.senderId) {
        sender = member;
        break;
      }
    }
    final user = sender?.user;
    if (user == null ||
        user.keyFingerprint.toUpperCase() !=
            proof.keyFingerprint.toUpperCase()) {
      // The sender rotated their key or left the conversation. Their key
      // history (hash-chained transparency log) still proves which key was
      // theirs when the message was sent — verify against that instead of
      // permanently failing every pre-rotation message.
      return _verifyAgainstKeyHistory(
        proof: proof,
        convID: convID,
        currentFingerprint: user?.keyFingerprint,
      );
    }
    // v2 messages carry a createdAt timestamp in the signed data.  v1 messages
    // (sent before this scheme was introduced) omit it; fall back to v1 so
    // historical message history continues to verify correctly.
    final ok = await PgpService.verify(
      data: PgpService.senderProofData(
        conversationId: convID,
        messageType: proof.type,
        payload: proof.payload,
        createdAt: proof.createdAt,
      ),
      signatureArmor: proof.signature,
      signerPublicKeyArmored: user.publicKey,
    );
    return ok ? proof.senderId : null;
  }

  /// Verifies a sender proof against the signer's key-transparency history:
  /// the proof's fingerprint must appear in the sender's hash-chained log, the
  /// signature must verify against that historical public key, and — when the
  /// sender is still a member with a newer key — the rotation chain from the
  /// historical key to the current one must be cryptographically continuous.
  Future<String?> _verifyAgainstKeyHistory({
    required OpenChatSenderProof proof,
    required String convID,
    String? currentFingerprint,
  }) async {
    try {
      final events = await _api.getKeyTransparencyEvents(proof.senderId);
      final wantedFingerprint = proof.keyFingerprint.toUpperCase();
      KeyTransparencyEvent? match;
      for (final event in events) {
        if (event.newKeyFingerprint.toUpperCase() == wantedFingerprint) {
          match = event;
        }
      }
      if (match == null || match.newPublicKey.trim().isEmpty) return null;
      final ok = await PgpService.verify(
        data: PgpService.senderProofData(
          conversationId: convID,
          messageType: proof.type,
          payload: proof.payload,
          createdAt: proof.createdAt,
        ),
        signatureArmor: proof.signature,
        signerPublicKeyArmored: match.newPublicKey,
      );
      if (!ok) return null;
      if (currentFingerprint != null &&
          currentFingerprint.trim().isNotEmpty &&
          currentFingerprint.toUpperCase() != wantedFingerprint) {
        final continuous = await verifyRotationContinuity(
          events: events,
          userId: proof.senderId,
          oldFingerprint: proof.keyFingerprint,
          newFingerprint: currentFingerprint,
        );
        if (!continuous) {
          debugPrint(
            'ChatProvider: historical key ${proof.keyFingerprint} has no '
            'continuity proof to current $currentFingerprint',
          );
          return null;
        }
      }
      return proof.senderId;
    } catch (_) {
      return null;
    }
  }

  /// Re-runs sender verification on already-decrypted plaintext after a short,
  /// growing delay (bounded). The openpgp fork's PQC signature verification
  /// intermittently returns false for valid signatures and succeeds on a later
  /// attempt — the same reason manually reopening the chat fixes it. This
  /// re-verifies only (never re-decrypts), so it is safe for MLS one-time keys.
  void _scheduleVerifyRetry(Message msg, String raw, Conversation? conv) {
    final attempts = _verifyRetryCounts[msg.id] ?? 0;
    if (attempts >= 5) {
      _verifyRetryCounts.remove(msg.id);
      return;
    }
    _verifyRetryCounts[msg.id] = attempts + 1;
    Future.delayed(Duration(milliseconds: 500 * (attempts + 1)), () async {
      if (_disposed) return;
      final verifiedSenderId = await _verifiedPgpSenderId(
        raw,
        msg.conversationId,
        conv,
        messageId: msg.id,
        serverCreatedAt: msg.createdAt,
      );
      if (verifiedSenderId == null) {
        _scheduleVerifyRetry(msg, raw, conv);
        return;
      }
      _verifyRetryCounts.remove(msg.id);
      msg.setDecryptedContent(raw, verifiedSenderId: verifiedSenderId);
      // Backfill the now-verified sender id into the durable cache so a restart
      // shows the message correctly attributed. (MLS plaintext was cached at
      // decrypt time with a null sender; PGP can re-decrypt so it needs no cache.)
      if (conv?.usesMls == true) {
        await _cache.put(
          msg.id,
          msg.conversationId,
          msg.encryptedPayload,
          raw,
          verifiedSenderId,
        );
      }
      _applyArtifactState(msg);
      _hydrateMessageSender(msg);
      _indexMessage(msg);
      if (!_disposed) notifyListeners();
    });
  }

  Future<bool> _sendEncryptedPayload({
    required String convID,
    required String plaintextPayload,
    required String messageType,
    String? replyTo,
    String? attachmentId,
    String? topicId,
    bool silent = false,
    DateTime? scheduledFor,
  }) async {
    try {
      await _sendEncryptedPayloadWithResult(
        convID: convID,
        plaintextPayload: plaintextPayload,
        messageType: messageType,
        replyTo: replyTo,
        attachmentId: attachmentId,
        topicId: topicId,
        silent: silent,
        scheduledFor: scheduledFor,
      );
      return true;
    } catch (error) {
      if (error is ChatSendException || error is ApiException) rethrow;
      throw ChatSendException('Message send failed: $error');
    }
  }

  String _newLiveLocationShareId() =>
      'live_${DateTime.now().millisecondsSinceEpoch}';

  Future<bool> _ensureLocationPermission({required bool background}) async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw const ChatSendException('Location service is disabled.');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw const ChatSendException(
        'Location permission is required to share location.',
      );
    }
    if (!background) return true;

    if (permission != LocationPermission.always) {
      permission = await Geolocator.requestPermission();
      if (permission != LocationPermission.always) {
        // Android 11+ won't grant background ("Allow all the time") from an
        // in-app prompt — the user has to enable it in system settings. Route
        // them there instead of failing with no way forward.
        if (defaultTargetPlatform == TargetPlatform.android) {
          await Geolocator.openAppSettings();
          throw const ChatSendException(
            'Set location access to "Allow all the time" in Settings to share '
            'live location in the background.',
          );
        }
        throw const ChatSendException(
          'Enable Always location access for background live sharing.',
        );
      }
    }
    return true;
  }

  Future<Position> _getCurrentPosition() async {
    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.best),
    );
  }

  LocationSettings _liveLocationSettings(String sharingWith) {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 5,
          intervalDuration: _liveLocationInterval,
          foregroundNotificationConfig: ForegroundNotificationConfig(
            notificationTitle: 'OpenChat live location',
            notificationText: 'Sharing with $sharingWith',
            notificationChannelName: 'Live location sharing',
            enableWakeLock: true,
            setOngoing: true,
            notificationIcon: const AndroidResource(
              name: 'launcher_icon',
              defType: 'mipmap',
            ),
          ),
        );
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return AppleSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 5,
          allowBackgroundLocationUpdates: true,
          pauseLocationUpdatesAutomatically: false,
          showBackgroundLocationIndicator: true,
        );
      default:
        return const LocationSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 5,
        );
    }
  }

  MessageLocation _liveLocationPayload({
    required LocationMessageKind kind,
    required double latitude,
    required double longitude,
    required String shareId,
    DateTime? endsAt,
    double? accuracy,
    bool ended = false,
  }) => MessageLocation(
    kind: kind,
    latitude: latitude,
    longitude: longitude,
    shareId: shareId,
    endsAt: endsAt,
    accuracy: accuracy,
    ended: ended,
  );

  Future<void> _beginLiveLocationShare({
    required String messageID,
    required String conversationId,
    required String shareId,
    required double latitude,
    required double longitude,
    required double? accuracy,
    required DateTime expiresAt,
  }) async {
    await _stopOtherLiveLocationShares(messageID);
    _liveLocationShares.remove(messageID)?.cancel();
    final conv = _conversations[conversationId];
    final sharingWith = conv?.displayName(_selfId ?? '') ?? 'this chat';
    final share = _ActiveLiveLocationShare(
      conversationId: conversationId,
      shareId: shareId,
      expiresAt: expiresAt,
      latitude: latitude,
      longitude: longitude,
      accuracy: accuracy,
      sharingWith: sharingWith,
    );
    _liveLocationShares[messageID] = share;
    share.expiryTimer = Timer(expiresAt.difference(DateTime.now()), () {
      unawaited(_stopLiveLocationShare(messageID, shouldNotify: true));
    });
    share.subscription =
        Geolocator.getPositionStream(
          locationSettings: _liveLocationSettings(sharingWith),
        ).listen((pos) {
          final current = _liveLocationShares[messageID];
          if (current == null) return;
          if (!current.isActive) {
            unawaited(_stopLiveLocationShare(messageID, shouldNotify: true));
            return;
          }
          if (DateTime.now().difference(current.lastSentAt) <
              _liveLocationInterval) {
            return;
          }
          unawaited(_updateLiveLocationShare(messageID, position: pos));
        });

    await NotificationService.showLiveLocationNotification(
      messageId: messageID,
      conversationId: conversationId,
      title: 'Sharing with $sharingWith',
      endsAt: expiresAt,
      live: true,
    );
    notifyListeners();
  }

  Future<void> _updateLiveLocationShare(
    String messageID, {
    Position? position,
  }) async {
    final share = _liveLocationShares[messageID];
    if (share == null) return;
    if (!share.isActive) {
      await _stopLiveLocationShare(messageID, shouldNotify: true);
      return;
    }
    try {
      final pos = position ?? await _getCurrentPosition();
      share.latitude = pos.latitude;
      share.longitude = pos.longitude;
      share.accuracy = pos.accuracy;
      share.lastSentAt = DateTime.now();
      final payload = _liveLocationPayload(
        kind: LocationMessageKind.live,
        latitude: pos.latitude,
        longitude: pos.longitude,
        shareId: share.shareId,
        endsAt: share.expiresAt,
        accuracy: pos.accuracy,
      );
      await editMessage(
        convID: share.conversationId,
        msgID: messageID,
        newPlaintext: jsonEncode(payload.toJson()),
      );
      await NotificationService.showLiveLocationNotification(
        messageId: messageID,
        conversationId: share.conversationId,
        title: 'Sharing with ${share.sharingWith}',
        endsAt: share.expiresAt,
        live: false,
      );
    } catch (_) {}
  }

  Future<void> _stopLiveLocationShare(
    String messageID, {
    bool shouldNotify = false,
  }) async {
    final share = _liveLocationShares.remove(messageID);
    if (share == null) return;
    share.cancel();

    await NotificationService.cancelLiveLocationNotification(
      messageId: messageID,
      conversationId: share.conversationId,
    );
    notifyListeners();
    if (!shouldNotify) return;

    try {
      final payload = _liveLocationPayload(
        kind: LocationMessageKind.live,
        latitude: share.latitude,
        longitude: share.longitude,
        shareId: share.shareId,
        endsAt: share.expiresAt,
        accuracy: share.accuracy,
        ended: true,
      );
      await editMessage(
        convID: share.conversationId,
        msgID: messageID,
        newPlaintext: jsonEncode(payload.toJson()),
      );
    } catch (_) {}
  }

  /// Builds the recipient keyring from the server's latest membership and
  /// public-key rows. User IDs are used only locally for deterministic
  /// de-duplication; they are not written into the PGP envelope slots.
  ///
  /// Sending is strict: every non-expired member must have a key available, so
  /// we never create a sender-only envelope that other members can't decrypt.
  /// The sender's own key is always ensured via their local storage entry so
  /// they can re-decrypt their sent messages from the server after a fresh
  /// login.
  Future<List<PgpRecipient>> _freshRecipientKeys(
    String convID,
    Conversation fallback,
  ) async {
    final members = await _loadMembersForEncryption(convID, fallback);
    if (members.isEmpty) return const [];
    if (fallback.isDM &&
        members.where((m) => !(m.user?.isKeyExpired ?? false)).length < 2) {
      throw const ChatSendException(
        'Conversation members are not ready. Refresh the chat and try again.',
      );
    }

    // Collect keys by user ID — deduplication by identity, not by key string.
    final selfId = await _storage.getUserID() ?? '';
    final ownPublicKey = await _storage.getPublicKey() ?? '';
    final ownFingerprint = await _storage.getFingerprint() ?? '';
    final keysByUser = <String, PgpRecipient>{};

    for (final member in members) {
      if (member.user?.isKeyExpired ?? false) continue;

      if (member.userId == selfId) continue;

      PgpRecipient? recipient;
      try {
        // Freshness window instead of force-refresh on EVERY send — a
        // 100-member PGP group otherwise does ~200 network fetches per
        // message. Keys fetched within the window already passed trust
        // observation.
        final freshKey = await _api.getRecentUserPublicKeyEntry(member.userId);
        if (freshKey != null && freshKey.publicKey.trim().isNotEmpty) {
          recipient = PgpRecipient(
            userId: member.userId,
            publicKeyArmored: freshKey.publicKey,
            keyFingerprint: freshKey.fingerprint,
          );
        }
      } catch (_) {
        // Fresh fetch failed. Fall back to the most recent VERIFIED fetch
        // (key cache, 24h TTL) — NOT the key embedded in the conversation
        // payload, which may predate a rotation and whose trust pin was never
        // observed on this path. If there is no verified cache entry either,
        // fail the send rather than encrypt to a possibly-dead key.
        final cached = await KeyCacheService.get(member.userId);
        if (cached != null && cached.publicKey.trim().isNotEmpty) {
          recipient = PgpRecipient(
            userId: member.userId,
            publicKeyArmored: cached.publicKey,
            keyFingerprint: cached.fingerprint,
          );
        } else {
          throw const ChatSendException(
            'Could not load every recipient key. Refresh the chat and try again.',
          );
        }
      }
      if (recipient == null) continue;
      // Fail closed on an unexplained key replacement (active-MITM defense).
      // Done outside the catch above so the trust block can't be swallowed by
      // the network-fallback path. Fetching the fresh key already refreshed the
      // trust pin (TOFU + rotation continuity).
      await _assertRecipientKeyTrusted(member.userId);
      keysByUser[member.userId] = recipient;
    }

    if (selfId.isNotEmpty &&
        ownPublicKey.trim().isNotEmpty &&
        ownFingerprint.trim().isNotEmpty) {
      keysByUser[selfId] = PgpRecipient(
        userId: selfId,
        publicKeyArmored: ownPublicKey,
        keyFingerprint: ownFingerprint,
      );
    }

    final out = keysByUser.values.toList()
      ..sort((a, b) => a.userId.compareTo(b.userId));
    return out;
  }

  /// Throws when a recipient's pinned key carries an unexplained-replacement
  /// warning and has not been re-verified. This turns the (previously
  /// detect-only) key-transparency layer into a preventive gate: a malicious or
  /// compromised server that swaps a contact's public key can no longer get the
  /// client to silently encrypt the next message to the attacker's key — the
  /// user must re-verify the contact (e.g. via SMP in the Trust Center) first.
  Future<void> _assertRecipientKeyTrusted(String userID) async {
    final pin = await _storage.getKeyTrustPin(userID);
    if (pin != null && (pin.warning?.isNotEmpty ?? false) && !pin.isVerified) {
      throw const ChatSendException(
        'A recipient\'s encryption key changed unexpectedly. Open the Trust '
        'Center and re-verify them before sending — this protects you from a '
        'server swapping their key.',
      );
    }
  }

  Future<List<ConversationMember>> _loadMembersForEncryption(
    String convID,
    Conversation fallback,
  ) async {
    try {
      final members = await _api.getConversationMembers(convID);
      if (members.isEmpty) {
        throw const ChatSendException(
          'Conversation members are not ready. Refresh the chat and try again.',
        );
      }
      final conv = _conversations[convID] ?? fallback;
      _conversations[convID] = conv.copyWith(members: members);
      notifyListeners();
      return members;
    } on ChatSendException {
      rethrow;
    } catch (_) {
      throw const ChatSendException(
        'Could not load conversation members. Refresh the chat and try again.',
      );
    }
  }

  /// Delete a conversation. For a DM this removes it for both participants; for
  /// groups/channels the server enforces admin/owner permission (throws otherwise).
  Future<void> deleteConversation(String convID) async {
    await _api.deleteConversation(convID);
    _conversations.remove(convID);
    _messages.remove(convID);
    _typingUsers.remove(convID);
    _deleteSearchConversation(convID);
    notifyListeners();
  }

  Future<void> deleteOwnMessages(String convID) async {
    await _api.deleteOwnMessages(convID);
    _messages.remove(convID);
    _deleteSearchConversation(convID);
    notifyListeners();
  }

  Future<void> deleteAllConversationMessages(String convID) async {
    await _api.deleteAllConversationMessages(convID);
    _messages.remove(convID);
    _deleteSearchConversation(convID);
    notifyListeners();
  }

  Future<void> leaveConversation(
    String convID, {
    bool deleteOwnMessages = false,
  }) async {
    await _api.leaveConversation(convID, deleteOwnMessages: deleteOwnMessages);
    _conversations.remove(convID);
    _messages.remove(convID);
    _typingUsers.remove(convID);
    _deleteSearchConversation(convID);
    notifyListeners();
  }

  Future<Conversation> openDM(String userID) async {
    final conv = await _api.openDM(userID);
    _conversations[conv.id] = conv;
    await loadConversationMembers(conv.id);
    notifyListeners();
    return _conversations[conv.id] ?? conv;
  }

  Future<Conversation> createGroup({
    required String name,
    String? description,
    required List<String> memberIDs,
    int? expiresInSeconds,
  }) async {
    final conv = await _api.createGroup(
      name: name,
      description: description,
      memberIDs: memberIDs,
      expiresInSeconds: expiresInSeconds,
    );
    _conversations[conv.id] = conv;
    notifyListeners();
    return conv;
  }

  void sendTyping(String convID) {
    if (_settings.strictPrivacyMode) return;
    _ws.sendTyping(convID);
  }

  Future<void> sendReadReceipt(String convID, String messageID) async {
    await _settings.clearUnreadMention(convID);
    if (_settings.strictPrivacyMode) return;
    final userID = _selfId ?? await _storage.getUserID() ?? '';
    if (userID.isEmpty) return;
    _rememberReadReceipt(
      convID: convID,
      userID: userID,
      messageID: messageID,
      notify: false,
    );
    try {
      await _api.markRead(convID, messageID);
    } catch (_) {
      // Read receipts are best-effort metadata. Never surface failures in chat.
    }
  }

  void setLocalReaction({
    required String convID,
    required String msgID,
    required String emoji,
    required bool reacted,
  }) {
    _updateMessageInMemory(
      convID: convID,
      msgID: msgID,
      update: (msg) => msg.copyWith(
        reactions: _reactionsWithViewerState(
          msg.reactions,
          emoji: emoji,
          reacted: reacted,
        ),
      ),
    );
  }

  Future<void> setReaction({
    required String convID,
    required String msgID,
    required String emoji,
    required bool reacted,
  }) async {
    final list = _messages[convID] ?? const <Message>[];
    final current = list.firstWhere(
      (message) => message.id == msgID,
      orElse: () => Message(
        id: msgID,
        conversationId: convID,
        senderId: '',
        type: MessageType.text,
        encryptedPayload: '',
        signature: '',
        createdAt: DateTime.now(),
      ),
    );
    final alreadyReacted = current.reactions.any(
      (reaction) => reaction.emoji == emoji && reaction.reactedByMe,
    );
    setLocalReaction(
      convID: convID,
      msgID: msgID,
      emoji: emoji,
      reacted: reacted,
    );
    if (!_ws.isMonitoring) {
      await _upsertOutboxItem(
        OfflineOutboxItem(
          id: _newOutboxId(),
          action: OfflineOutboxAction.reaction,
          conversationId: convID,
          createdAt: DateTime.now(),
          data: {'message_id': msgID, 'emoji': emoji, 'reacted': reacted},
        ),
        coalesceReaction: true,
      );
      return;
    }
    try {
      if (reacted) {
        await _api.reactToMessage(msgID, emoji);
      } else {
        await _api.removeReaction(msgID, emoji);
      }
    } catch (e) {
      if (_shouldRetryOutboxError(e)) {
        await _upsertOutboxItem(
          OfflineOutboxItem(
            id: _newOutboxId(),
            action: OfflineOutboxAction.reaction,
            conversationId: convID,
            createdAt: DateTime.now(),
            data: {'message_id': msgID, 'emoji': emoji, 'reacted': reacted},
          ),
          coalesceReaction: true,
        );
        return;
      }
      setLocalReaction(
        convID: convID,
        msgID: msgID,
        emoji: emoji,
        reacted: alreadyReacted,
      );
      rethrow;
    }
  }

  void _handleWsEvent(WsEvent event) {
    switch (event.type) {
      case WsEventType.newMessage:
        final msg = Message.fromJson(event.data);
        _handleIncomingMessage(msg);

      case WsEventType.typing:
        final convID = event.data['conversation_id'] as String?;
        final userID = event.data['user_id'] as String?;
        if (convID != null && userID != null) {
          _typingUsers[convID] = {...?_typingUsers[convID], userID};
          notifyListeners();
          Future.delayed(const Duration(seconds: 3), () {
            _typingUsers[convID]?.remove(userID);
            notifyListeners();
          });
        }

      case WsEventType.messageDeleted:
        final convID = event.data['conversation_id'] as String?;
        final msgID = event.data['message_id'] as String?;
        if (convID != null && msgID != null) {
          unawaited(_stopLiveLocationShare(msgID, shouldNotify: false));
          _deleteSearchMessage(msgID);
          unawaited(_settings.clearUnreadMention(convID, messageID: msgID));
          final list = _messages[convID];
          if (list != null) {
            _messages[convID] = list.where((m) => m.id != msgID).toList();
            notifyListeners();
          }
        }

      case WsEventType.conversationDeleted:
        final convID = event.data['conversation_id'] as String?;
        if (convID != null) {
          removeConversationLocally(convID);
        }

      case WsEventType.messageEdited:
        _handleEditedMessage(Message.fromJson(event.data));

      case WsEventType.messageReaction:
        _handleMessageReactionUpdate(event.data);

      case WsEventType.messageTipped:
        _handleMessageTipped(event.data);

      case WsEventType.pollUpdated:
        _handlePollUpdate(event.data);

      case WsEventType.resyncRequired:
        // The server's replay buffer couldn't bridge our last_seq — fall back
        // to the full refetch (the pre-resume reconnect behavior).
        unawaited(_catchUpAfterReconnect());

      case WsEventType.convResyncRequired:
        // One broadcast conversation's replay window couldn't bridge our
        // conv_seq: refetch exactly that conversation, never the whole list.
        final convID = event.data['conversation_id'] as String?;
        if (convID != null && convID.isNotEmpty) {
          unawaited(refreshConversation(convID));
          if (_messages.containsKey(convID)) {
            unawaited(loadMessages(convID));
          }
        }

      case WsEventType.gameUpdated:
        _ingestGameRound(event.data);

      case WsEventType.paymentRequestUpdated:
        unawaited(_handlePaymentRequestUpdate(event.data));

      case WsEventType.depositProgress:
        // Owner-only confirmation progress; consumed by whichever payment UI
        // (paywall sheet, wallet) is currently watching this deposit.
        if (!_depositProgressController.isClosed) {
          _depositProgressController.add(event.data);
        }

      case WsEventType.conversationUpdated:
        // Name / description / avatar (and for channels, handle) changed. Pull
        // the fresh conversation + members so it updates without a manual
        // refresh — ONE conversation, not the whole list (at scale a busy
        // account would otherwise re-pull everything on every rename).
        final convID = event.data['conversation_id'] as String?;
        if (convID != null) {
          // A "burner" group/channel just expired: the server has locked it and
          // purged its messages. Mirror that locally — wipe the encrypted cache
          // and in-memory list so nothing lingers on-device.
          if (event.data['expired'] == true || event.data['locked'] == true) {
            unawaited(_cache.deleteConversation(convID));
            _messages.remove(convID);
          }
          unawaited(refreshConversation(convID));
          if (_conversations.containsKey(convID)) {
            loadConversationMembers(convID);
            // For MLS groups, process any pending commits (e.g. a new member's
            // external join commit).  This advances the local epoch so the next
            // outbound message uses the correct epoch that all members share,
            // rather than an epoch the newly-joined member cannot decrypt.
            final conv = _conversations[convID];
            if (conv != null &&
                conv.usesMls &&
                !_mlsRefreshInFlight.contains(convID)) {
              _mlsRefreshInFlight.add(convID);
              unawaited(
                _mls
                    .refreshGroupState(api: _api, conversation: conv)
                    .whenComplete(() => _mlsRefreshInFlight.remove(convID)),
              );
            }
          }
        }

      case WsEventType.readReceipt:
        _handleReadReceipt(event.data);

      case WsEventType.joinRequest:
        if (!_joinRequestController.isClosed) {
          _joinRequestController.add(event.data);
        }

      case WsEventType.deviceWipe:
        // Routed to the home shell, which verifies the PGP signature against
        // our OWN account key and the target session id before wiping — the
        // server (or anyone who can inject WS frames) cannot forge this.
        final wipeHandler = deviceWipeRequestHandler;
        if (wipeHandler != null) {
          unawaited(wipeHandler(event.data));
        }

      case WsEventType.recoveryRequest:
        if (!_recoveryEventsController.isClosed) {
          _recoveryEventsController.add({'kind': 'request', ...event.data});
        }

      case WsEventType.recoveryShare:
        if (!_recoveryEventsController.isClosed) {
          _recoveryEventsController.add({'kind': 'share', ...event.data});
        }

      case WsEventType.memberJoined:
      case WsEventType.memberLeft:
        final convID = event.data['conversation_id'] as String?;
        final userID = event.data['user_id'] as String?;
        if (convID != null) {
          if (userID != null &&
              userID == _selfId &&
              event.type == WsEventType.memberLeft) {
            // WE lost access (removed, left elsewhere, subscription
            // expired) — drop it locally, no fetch needed.
            removeConversationLocally(convID);
          } else if (_conversations.containsKey(convID)) {
            loadConversationMembers(convID);
          } else {
            // We were added/subscribed (or learned of a conversation we have
            // not loaded) — fetch just that one to surface it.
            unawaited(refreshConversation(convID));
          }
        }

      // Call events are handled by CallProvider — ignore here
      case WsEventType.callOffer:
      case WsEventType.callAnswer:
      case WsEventType.callIceCandidate:
      case WsEventType.callHangup:
      case WsEventType.callReject:
      case WsEventType.callRinging:
        break;

      default:
        break;
    }
  }

  void _handleMessageTipped(Map<String, dynamic> data) {
    final convID = data['conversation_id']?.toString();
    final msgID = data['message_id']?.toString();
    if (convID == null || msgID == null) return;
    applyMessageTips(
      convID: convID,
      msgID: msgID,
      tips: MessageTipTotal.listFrom(data['tips']),
    );
  }

  /// Replaces a message's anonymous tip aggregates in memory and notifies.
  /// Aggregates are ephemeral UI state (not part of message fetches), so a
  /// miss — message not loaded — is fine.
  void applyMessageTips({
    required String convID,
    required String msgID,
    required List<MessageTipTotal> tips,
  }) {
    _updateMessageInMemory(
      convID: convID,
      msgID: msgID,
      update: (msg) => msg.copyWith(tips: tips),
    );
  }

  /// Tips a message from the app wallet and applies the returned aggregates.
  Future<List<MessageTipTotal>> tipMessage({
    required String convID,
    required String msgID,
    required String provider,
    required double amount,
  }) async {
    final raw = await _api.tipMessage(
      convID,
      msgID,
      provider: provider,
      amount: amount,
      isChannel: _conversations[convID]?.isChannel ?? false,
    );
    final tips = MessageTipTotal.listFrom(raw);
    applyMessageTips(convID: convID, msgID: msgID, tips: tips);
    return tips;
  }

  /// Lazily hydrates a message's tip aggregates (e.g. when the tip sheet
  /// opens — the backend doesn't include them in message fetches).
  Future<List<MessageTipTotal>> loadMessageTips({
    required String convID,
    required String msgID,
  }) async {
    final raw = await _api.getMessageTips(
      convID,
      msgID,
      isChannel: _conversations[convID]?.isChannel ?? false,
    );
    final tips = MessageTipTotal.listFrom(raw);
    applyMessageTips(convID: convID, msgID: msgID, tips: tips);
    return tips;
  }

  void _handleMessageReactionUpdate(Map<String, dynamic> data) {
    final convID = data['conversation_id']?.toString();
    final msgID = data['message_id']?.toString();
    if (convID == null || msgID == null) return;

    final rawReactions = data['reactions'];
    final incoming = rawReactions is List
        ? rawReactions
              .whereType<Map>()
              .map(
                (raw) => MessageReactionSummary.fromJson(
                  Map<String, dynamic>.from(raw),
                ),
              )
              .toList(growable: false)
        : const <MessageReactionSummary>[];
    final actorID = data['actor_user_id']?.toString();
    final eventEmoji = data['emoji']?.toString();
    final removed = data['removed'] == true;
    _updateMessageInMemory(
      convID: convID,
      msgID: msgID,
      update: (msg) {
        final viewerState = {
          for (final reaction in msg.reactions)
            if (reaction.reactedByMe) reaction.emoji: true,
        };
        if (_selfId != null && actorID == _selfId && eventEmoji != null) {
          viewerState[eventEmoji] = !removed;
        }
        return msg.copyWith(
          reactions: incoming
              .map(
                (reaction) => reaction.copyWith(
                  reactedByMe:
                      reaction.reactedByMe ||
                      (viewerState[reaction.emoji] ?? false),
                ),
              )
              .toList(growable: false),
        );
      },
    );
  }

  List<MessageReactionSummary> _reactionsWithViewerState(
    List<MessageReactionSummary> reactions, {
    required String emoji,
    required bool reacted,
  }) {
    final next = List<MessageReactionSummary>.from(reactions);
    final idx = next.indexWhere((reaction) => reaction.emoji == emoji);
    if (reacted) {
      if (idx == -1) {
        next.add(
          MessageReactionSummary(emoji: emoji, count: 1, reactedByMe: true),
        );
      } else {
        final current = next[idx];
        next[idx] = current.copyWith(
          count: current.reactedByMe ? current.count : current.count + 1,
          reactedByMe: true,
        );
      }
    } else if (idx != -1) {
      final current = next[idx];
      final nextCount = current.reactedByMe ? current.count - 1 : current.count;
      if (nextCount <= 0) {
        next.removeAt(idx);
      } else {
        next[idx] = current.copyWith(count: nextCount, reactedByMe: false);
      }
    }
    next.sort((a, b) {
      final count = b.count.compareTo(a.count);
      if (count != 0) return count;
      return a.emoji.compareTo(b.emoji);
    });
    return next;
  }

  void _handlePollUpdate(Map<String, dynamic> data) {
    final convID = data['conversation_id']?.toString();
    var msgID = data['message_id']?.toString();
    final rawPoll = data['poll'];
    if (convID == null || rawPoll is! Map) return;

    final poll = Poll.fromJson(Map<String, dynamic>.from(rawPoll));
    msgID ??= poll.messageId;
    if (msgID == null) return;
    _updateMessageInMemory(
      convID: convID,
      msgID: msgID,
      update: (msg) {
        var nextPoll = poll;
        final currentPoll = msg.poll;
        if (currentPoll?.id == poll.id) {
          nextPoll = _pollWithArtifactLabels(
            poll,
            msg.artifact,
            fallback: currentPoll,
          );
          if (poll.voterOptionIds.isEmpty &&
              currentPoll!.voterOptionIds.isNotEmpty) {
            nextPoll = nextPoll.copyWith(
              voterOptionIds: currentPoll.voterOptionIds,
            );
          }
        }
        return msg.copyWith(poll: nextPoll);
      },
    );
  }

  void _handleReadReceipt(Map<String, dynamic> data) {
    final convID = data['conversation_id']?.toString();
    final userID = data['user_id']?.toString();
    final messageID = data['message_id']?.toString();
    if (convID == null || userID == null || messageID == null) return;
    // Our own read receipt from ANOTHER device — the chat was read there, so
    // clear the stale notification on this one.
    if (userID == _selfId) {
      unawaited(NotificationService.cancelMessageNotification(convID));
    }
    _rememberReadReceipt(convID: convID, userID: userID, messageID: messageID);
  }

  void _rememberReadReceipt({
    required String convID,
    required String userID,
    required String messageID,
    bool notify = true,
  }) {
    final byUser = _readReceipts.putIfAbsent(convID, () => <String, String>{});
    if (byUser[userID] == messageID) return;
    byUser[userID] = messageID;
    if (notify) notifyListeners();
  }

  bool _updateMessageInMemory({
    required String convID,
    required String msgID,
    required Message Function(Message msg) update,
  }) {
    final list = _messages[convID];
    if (list == null) return false;
    final idx = list.indexWhere((m) => m.id == msgID);
    if (idx == -1) return false;

    final updatedMessage = update(list[idx]);
    final updated = List<Message>.from(list);
    updated[idx] = updatedMessage;
    _messages[convID] = updated;

    final conv = _conversations[convID];
    if (conv?.lastMessage?.id == msgID) {
      _conversations[convID] = conv!.copyWith(lastMessage: updatedMessage);
    }

    notifyListeners();
    _indexMessage(updatedMessage);
    return true;
  }

  Future<void> _syncLocalUnreadMentionFromConversation(
    Conversation conversation,
  ) async {
    if (conversation.unreadCount <= 0) {
      await _settings.clearUnreadMention(conversation.id);
      return;
    }
    final last = conversation.lastMessage;
    if (last == null) return;
    await _recordLocalUnreadMention(last);
  }

  Future<bool> _recordLocalUnreadMention(Message message) async {
    if (!message.isDecrypted || message.type == MessageType.system) {
      return false;
    }
    final selfId = _selfId ?? await _storage.getUserID() ?? '';
    _selfId ??= selfId.isEmpty ? null : selfId;
    if (selfId.isNotEmpty && message.senderId == selfId) return false;
    final username = _selfUsername ?? await _storage.getUsername() ?? '';
    _selfUsername ??= username.isEmpty ? null : username;
    if (!textMentionsUsername(message.listPreview, username)) return false;
    await _settings.setUnreadMentionMessage(message.conversationId, message.id);
    return true;
  }

  Future<void> _handleIncomingMessage(Message msg) async {
    await _promoteDeliveredSealedScheduledMessage(msg);
    final privateKey = await _storage.getPrivateKeyIfUnlocked() ?? '';
    await _tryDecrypt(msg, privateKey);

    // SMP verification traffic is consumed by the SMP provider, never shown.
    final smp = msg.smpControl;
    if (smp != null) {
      if (msg.senderId != _selfId) {
        _smpController.add(
          SmpInbound(
            conversationId: msg.conversationId,
            senderId: msg.senderId,
            payload: smp,
          ),
        );
      }
      return;
    }

    // A guardian share arriving in-band: persist it (it must survive
    // restarts and ride this device's backups) and never render it.
    final recoveryShare = msg.recoveryShareControl;
    if (recoveryShare != null) {
      if (msg.senderId != _selfId) {
        unawaited(
          SocialRecoveryService(
            storage: _storage,
          ).storeIncomingShare(recoveryShare),
        );
      }
      return;
    }

    // Realtime events don't carry sender profile info, so backfill from the
    // loaded members before the message reaches the bubble/avatar UI.
    _hydrateMessageSender(msg);

    final cached = _cachedDecryptedMessage(msg);
    final displayMsg = (!msg.isDecrypted && cached != null) ? cached : msg;
    await _syncLiveLocationShareFromMessage(displayMsg);
    if (displayMsg != msg) {
      _hydrateMessageSender(displayMsg, fresh: msg);
    }

    _applyPaymentTransferUpdate(displayMsg);

    var list = _messages[msg.conversationId] ?? [];
    // A message that already arrived over the BLE mesh is superseded by its
    // server copy (same encrypted payload, real id) — replace, don't double.
    if (!msg.id.startsWith('mesh-') && msg.encryptedPayload.isNotEmpty) {
      final meshIdx = list.indexWhere(
        (m) =>
            m.id.startsWith('mesh-') &&
            m.encryptedPayload == msg.encryptedPayload,
      );
      if (meshIdx != -1) {
        list = List<Message>.from(list)..removeAt(meshIdx);
        _messages[msg.conversationId] = list;
      }
    }
    final idx = list.indexWhere((m) => m.id == msg.id);
    if (idx == -1) {
      _messages[msg.conversationId] = [...list, displayMsg];
    } else if (!list[idx].isDecrypted && displayMsg.isDecrypted) {
      final updated = List<Message>.from(list);
      updated[idx] = displayMsg;
      _messages[msg.conversationId] = updated;
    }

    final conv = _conversations[msg.conversationId];
    if (conv != null) {
      _conversations[msg.conversationId] = conv.copyWith(
        lastMessage: displayMsg,
      );
    } else if (!_isLoading) {
      // Message from a conversation we haven't seen yet (new DM or group) —
      // fetch just that one rather than re-pulling the whole list.
      unawaited(refreshConversation(msg.conversationId));
    }

    _indexMessage(displayMsg);
    final mentionedForCurrentUser = await _recordLocalUnreadMention(displayMsg);

    if (_selfId != null &&
        msg.senderId != _selfId &&
        msg.type != MessageType.system &&
        // Decoy sessions: a hidden conversation must not buzz or banner.
        isConversationVisibleInVault(msg.conversationId)) {
      final senderName = msg.sender?.username != null
          ? '@${msg.sender!.username}'
          : 'Someone';
      final String title;
      final String body;
      if (conv != null && (conv.isGroup || conv.isChannel)) {
        title = conv.name ?? 'Group';
        body =
            '$senderName: ${displayMsg.isDecrypted ? (displayMsg.decryptedContent ?? 'New message') : 'New message'}';
      } else {
        title = senderName;
        body = displayMsg.isDecrypted
            ? (displayMsg.decryptedContent ?? 'New message')
            : 'New message';
      }
      NotificationService.showMessage(
        conversationId: msg.conversationId,
        title: title,
        body: body,
        showSensitive: _settings.notificationSensitiveContent,
        mentionedForCurrentUser: mentionedForCurrentUser,
        notificationText: body,
      );
    }

    notifyListeners();
  }

  Future<void> _promoteDeliveredSealedScheduledMessage(Message msg) async {
    if (!msg.sealedSender) return;
    await _api.promoteSealedScheduledControlToMessage(
      msg.conversationId,
      msg.id,
    );
  }

  Future<void> _handlePaymentRequestUpdate(Map<String, dynamic> data) async {
    final convID = data['conversation_id']?.toString();
    if (convID == null || convID.isEmpty) return;

    final rawRequest = data['request'];
    final request = rawRequest is Map
        ? Map<String, dynamic>.from(rawRequest)
        : null;
    final requestID =
        data['request_id']?.toString() ?? request?['id']?.toString();
    final status = data['status']?.toString() ?? request?['status']?.toString();

    if (requestID != null && requestID.isNotEmpty) {
      _applyPaymentRequestUpdate(
        convID: convID,
        requestID: requestID,
        request: request,
        status: status,
      );
    }

    unawaited(refreshConversationsSilently());
    if (_messages.containsKey(convID)) {
      await loadMessages(convID);
      if (requestID != null && requestID.isNotEmpty) {
        _applyPaymentRequestUpdate(
          convID: convID,
          requestID: requestID,
          request: request,
          status: status,
        );
      }
    }
  }

  void _applyPaymentTransferUpdate(Message msg) {
    if (msg.type != MessageType.paymentTransfer) return;
    try {
      final raw = _paymentPayloadMap(msg);
      if (raw == null) return;
      final transfer = raw['transfer'];
      final request = raw['request'];
      final requestID =
          (transfer is Map ? transfer['request_id']?.toString() : null) ??
          (request is Map ? request['id']?.toString() : null);
      if (requestID == null || requestID.isEmpty) return;
      _applyPaymentRequestUpdate(
        convID: msg.conversationId,
        requestID: requestID,
        request: request is Map ? Map<String, dynamic>.from(request) : null,
        status: 'confirmed',
      );
    } catch (_) {}
  }

  bool _applyPaymentRequestUpdate({
    required String convID,
    required String requestID,
    Map<String, dynamic>? request,
    String? status,
  }) {
    var changed = false;
    final list = _messages[convID];
    if (list != null) {
      final updated = <Message>[];
      for (final msg in list) {
        final next = _updatedPaymentRequestMessage(
          msg: msg,
          requestID: requestID,
          request: request,
          status: status,
        );
        updated.add(next ?? msg);
        changed = changed || next != null;
      }
      if (changed) {
        _messages[convID] = updated;
        for (final message in updated) {
          _indexMessage(message);
        }
      }
    }

    final conv = _conversations[convID];
    final last = conv?.lastMessage;
    if (conv != null && last != null) {
      final nextLast = _updatedPaymentRequestMessage(
        msg: last,
        requestID: requestID,
        request: request,
        status: status,
      );
      if (nextLast != null) {
        _conversations[convID] = conv.copyWith(lastMessage: nextLast);
        changed = true;
      }
    }

    if (changed) notifyListeners();
    return changed;
  }

  Message? _updatedPaymentRequestMessage({
    required Message msg,
    required String requestID,
    Map<String, dynamic>? request,
    String? status,
  }) {
    if (msg.type != MessageType.paymentRequest) return null;
    try {
      final raw = _paymentPayloadMap(msg);
      if (raw == null) return null;
      final currentRequestRaw = raw['request'];
      if (currentRequestRaw is! Map) return null;
      final currentRequest = Map<String, dynamic>.from(currentRequestRaw);
      if (currentRequest['id']?.toString() != requestID) return null;

      final nextRequest = Map<String, dynamic>.from(currentRequest);
      if (request != null) nextRequest.addAll(request);
      if (status != null && status.isNotEmpty) {
        nextRequest['status'] = status;
      }
      final nextPayload = Map<String, dynamic>.from(raw);
      nextPayload['request'] = nextRequest;
      final encoded = jsonEncode(nextPayload);
      if (encoded == (msg.decryptedPayload ?? msg.encryptedPayload)) {
        return null;
      }
      if (msg.artifact != null || msg.isEncrypted) {
        final next = msg.copyWith();
        next.setDecryptedContent(
          ChatArtifact.encodePayload(
            kind: 'payment_request',
            payload: nextPayload,
          ),
          verifiedSenderId: msg.senderId,
        );
        return next;
      }
      return msg.copyWith(encryptedPayload: encoded);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic>? _paymentPayloadMap(Message msg) {
    final artifact = msg.artifact?.payloadMap;
    if (artifact != null) return artifact;
    final raw = msg.decryptedPayload ?? msg.encryptedPayload;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (_) {}
    return null;
  }

  Message? _cachedDecryptedMessage(Message msg) {
    final list = _messages[msg.conversationId] ?? const <Message>[];
    for (final cached in list) {
      if (cached.id == msg.id && cached.isDecrypted) return cached;
    }
    final last = _conversations[msg.conversationId]?.lastMessage;
    if (last != null && last.id == msg.id && last.isDecrypted) return last;
    return null;
  }

  void _hydrateMessageSender(Message msg, {Message? fresh}) {
    final freshSender = fresh?.sender;
    if (freshSender != null && _shouldReplaceSender(msg.sender, freshSender)) {
      msg.sender = freshSender;
    }

    final conv = _conversations[msg.conversationId];
    if (conv == null) return;
    hydrateMessageSenderFromConversation(msg, conv);
  }

  void _indexMessage(Message msg) {
    if (!msg.isDecrypted && msg.poll == null) return;
    final conv = _conversations[msg.conversationId];
    final conversationTitle = conv?.displayName(_selfId ?? '');
    unawaited(_search.indexMessage(msg, conversationTitle: conversationTitle));
  }

  void _applyArtifactState(Message msg) {
    if (msg.poll != null) {
      msg.poll = _pollWithArtifactLabels(msg.poll!, msg.artifact);
    }
  }

  Poll _pollWithArtifactLabels(
    Poll poll,
    ChatArtifact? artifact, {
    Poll? fallback,
  }) {
    final raw = artifact?.payloadMap?['poll'];
    final pollPayload = raw is Map ? Map<String, dynamic>.from(raw) : null;
    final fallbackById = {
      for (final option in fallback?.options ?? const <PollOption>[])
        option.id: option,
    };
    final payloadById = <String, Map<String, dynamic>>{};
    final payloadByIndex = <int, Map<String, dynamic>>{};
    final rawOptions = pollPayload?['options'];
    if (rawOptions is List) {
      for (final rawOption in rawOptions.whereType<Map>()) {
        final option = Map<String, dynamic>.from(rawOption);
        final id = option['id']?.toString();
        final indexRaw = option['option_index'];
        if (id != null && id.isNotEmpty) payloadById[id] = option;
        if (indexRaw is num) payloadByIndex[indexRaw.toInt()] = option;
      }
    }
    final options = [
      for (final option in poll.options)
        option.copyWith(
          text:
              payloadById[option.id]?['text']?.toString() ??
              payloadByIndex[option.index]?['text']?.toString() ??
              fallbackById[option.id]?.text,
        ),
    ];
    return poll.copyWith(
      question:
          pollPayload?['question']?.toString() ??
          (poll.question.isEmpty ? fallback?.question : null),
      description:
          pollPayload?['description']?.toString() ??
          (poll.description == null || poll.description!.isEmpty
              ? fallback?.description
              : null),
      options: options,
      voterOptionIds: poll.voterOptionIds.isNotEmpty
          ? poll.voterOptionIds
          : fallback?.voterOptionIds,
    );
  }

  void _deleteSearchMessage(String messageId) {
    unawaited(_search.deleteMessage(messageId));
    unawaited(_cache.delete(messageId));
  }

  void _deleteSearchConversation(String conversationId) {
    unawaited(_search.deleteConversation(conversationId));
    unawaited(_cache.deleteConversation(conversationId));
  }

  static void hydrateMessageSenderFromConversation(
    Message msg,
    Conversation conv,
  ) {
    final members = conv.members;
    for (final m in members) {
      if (m.userId == msg.senderId &&
          m.user != null &&
          _shouldReplaceSender(msg.sender, m.user!)) {
        msg.sender = m.user;
        break;
      }
    }
  }

  static bool _shouldReplaceSender(User? current, User candidate) {
    if (current == null) return true;
    return (current.avatarUrl == null && candidate.avatarUrl != null) ||
        (current.bio == null && candidate.bio != null) ||
        current.bubbleColor != candidate.bubbleColor ||
        (current.publicKey.isEmpty && candidate.publicKey.isNotEmpty) ||
        (current.keyFingerprint.isEmpty && candidate.keyFingerprint.isNotEmpty);
  }

  /// Picks up a key-transparency head gossiped inside a decrypted envelope
  /// and feeds it to the auditor. Cheap string guard first — most messages
  /// carry no gossip and never pay the JSON parse.
  void _ingestSthGossip(String raw) {
    if (!raw.contains('"kt_sth"')) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['openchat_message'] != 1) return;
      final gossip = decoded['kt_sth'];
      if (gossip is! Map) return;
      unawaited(
        KtAuditService(storage: _storage).ingestGossipedHead(
          _api,
          Map<String, dynamic>.from(gossip),
        ),
      );
    } catch (_) {}
  }

  Future<void> _tryDecrypt(
    Message msg,
    String privateKey, {
    Conversation? conversation,
  }) async {
    if (msg.type == MessageType.poll) {
      msg.setDecryptedContent(msg.encryptedPayload);
      _applyArtifactState(msg);
      _indexMessage(msg);
      return;
    }
    if (!msg.isEncrypted) {
      msg.setDecryptedContent(msg.encryptedPayload);
      _applyArtifactState(msg);
      _indexMessage(msg);
      return;
    }
    final conv = conversation ?? _conversations[msg.conversationId];
    if (conv?.usesMls == true) {
      // MLS application keys are one-time-use (forward secrecy).  Check the
      // persistent plaintext cache first so that app restarts and re-loads of
      // already-decrypted messages don't fail because the sender ratchet has
      // moved on.
      final cacheEntry = await _cache.get(msg.id, msg.encryptedPayload);
      if (cacheEntry != null) {
        msg.setDecryptedContent(
          cacheEntry.plaintext,
          verifiedSenderId: cacheEntry.senderId,
        );
        _applyArtifactState(msg);
        _hydrateMessageSender(msg);
        _indexMessage(msg);
        return;
      }
      final raw = await _mls.decryptPayload(
        api: _api,
        conversation: conv!,
        encryptedPayload: msg.encryptedPayload,
      );
      if (raw != null && raw.isNotEmpty) {
        _ingestSthGossip(raw);
        final verifiedSenderId = await _verifiedPgpSenderId(
          raw,
          msg.conversationId,
          conv,
          messageId: msg.id,
          serverCreatedAt: msg.createdAt,
        );
        // The MLS ratchet key for this message is consumed by the decrypt above
        // and cannot be replayed after a restart. Persist the plaintext NOW,
        // before the sender-verification gate — otherwise a message whose sender
        // can't be verified yet (a transient PQC-verify failure) is shown on
        // screen but never cached, and is permanently lost on the next launch.
        // _scheduleVerifyRetry backfills the verified sender id into the cache.
        await _cache.put(
          msg.id,
          msg.conversationId,
          msg.encryptedPayload,
          raw,
          verifiedSenderId,
        );
        if (verifiedSenderId == null) {
          // Fail closed on the in-payload sender proof for EVERY encrypted
          // message, not just those the server flagged sealed_sender. Encrypted
          // conversations always post through the sealed endpoint, so a real
          // message always carries a verifiable proof; a server that sets
          // sealed_sender:false with a chosen sender_id must not be able to
          // spoof attribution. A transient PQC-verify failure self-heals via
          // the retry below instead of showing an unverified sender.
          _scheduleVerifyRetry(msg, raw, conv);
          msg.markDecryptionFailed();
          return;
        }
        msg.setDecryptedContent(raw, verifiedSenderId: verifiedSenderId);
        _applyArtifactState(msg);
        _hydrateMessageSender(msg);
        _indexMessage(msg);
      } else {
        debugPrint('ChatProvider: decrypt FAILED (MLS returned empty — sender '
            'ratchet/epoch mismatch?) msg=${msg.id} conv=${msg.conversationId}');
        msg.markDecryptionFailed();
      }
      return;
    }
    if (privateKey.isEmpty) return;
    try {
      final raw = await PgpService.decrypt(
        encryptedArmor: msg.encryptedPayload,
        privateKeyArmored: privateKey,
      );
      if (raw.isNotEmpty) {
        _ingestSthGossip(raw);
        final verifiedSenderId = await _verifiedPgpSenderId(
          raw,
          msg.conversationId,
          conv,
          messageId: msg.id,
          serverCreatedAt: msg.createdAt,
        );
        if (verifiedSenderId == null) {
          // Fail closed on the in-payload sender proof for EVERY encrypted
          // message, not just those the server flagged sealed_sender. Encrypted
          // conversations always post through the sealed endpoint, so a real
          // message always carries a verifiable proof; a server that sets
          // sealed_sender:false with a chosen sender_id must not be able to
          // spoof attribution. A transient PQC-verify failure self-heals via
          // the retry below instead of showing an unverified sender.
          _scheduleVerifyRetry(msg, raw, conv);
          msg.markDecryptionFailed();
          return;
        }
        msg.setDecryptedContent(raw, verifiedSenderId: verifiedSenderId);
        _applyArtifactState(msg);
        _hydrateMessageSender(msg);
        _indexMessage(msg);
      }
      // Empty-string result without an exception can be a transient PGP
      // service state issue (e.g. library internal buffer race on concurrent
      // calls).  Don't permanently mark failed — the next loadMessages call
      // will retry with a fresh PgpService invocation.
    } catch (e) {
      debugPrint('ChatProvider: decrypt FAILED (PGP threw) msg=${msg.id} '
          'conv=${msg.conversationId} sealed=${msg.sealedSender}: $e');
      msg.markDecryptionFailed();
    }
  }

  // ── Provably-fair games ────────────────────────────────────────────────────

  /// The current user's id (used by game cards to find the viewer's own bet).
  String? get selfId => _selfId;

  /// Live round state for an in-chat game card, or null until loaded.
  Map<String, dynamic>? gameRound(String roundId) => _gameRounds[roundId];

  void _ingestGameRound(Map<String, dynamic> round) {
    final id = round['id'] as String?;
    if (id == null || id.isEmpty) return;
    _gameRounds[id] = round;
    notifyListeners();
  }

  /// Rolls a server-authoritative animated dice (Telegram behavior for a
  /// bare 🎲 message). The server picks the value, posts the public dice
  /// message and broadcasts it; the response is ingested directly so the
  /// roller sees it instantly (the WS copy dedupes by id).
  Future<void> rollDice(
    String convID, {
    String emoji = '🎲',
    bool isChannel = false,
  }) async {
    final msg = Message.fromJson(
      await _api.rollDice(convID, emoji: emoji, isChannel: isChannel),
    );
    await _handleIncomingMessage(msg);
    notifyListeners();
  }

  /// Opens a skill-game lobby ('🎲' dice or '🎯' darts). provider: 'fun' |
  /// 'btc' | 'xmr'; stake is the per-player ante for real money. isChannel
  /// routes to the /channels surface when the round lives in a channel.
  Future<Map<String, dynamic>> createGame(
    String convID, {
    required String gameType,
    required String provider,
    double? stake,
    int maxPlayers = 8,
    bool isChannel = false,
  }) async {
    final round = await _api.createGameRound(
      convID,
      gameType: gameType,
      provider: provider,
      stake: stake,
      maxPlayers: maxPlayers,
      isChannel: isChannel,
    );
    _ingestGameRound(round);
    return round;
  }

  Future<void> joinGame(
    String convID,
    String roundID, {
    bool isChannel = false,
  }) async {
    _ingestGameRound(
      await _api.joinGameRound(convID, roundID, isChannel: isChannel),
    );
  }

  Future<void> leaveGame(
    String convID,
    String roundID, {
    bool isChannel = false,
  }) async {
    _ingestGameRound(
      await _api.leaveGameRound(convID, roundID, isChannel: isChannel),
    );
  }

  Future<void> readyGame(
    String convID,
    String roundID, {
    bool ready = true,
    bool isChannel = false,
  }) async {
    _ingestGameRound(
      await _api.readyGameRound(
        convID,
        roundID,
        ready: ready,
        isChannel: isChannel,
      ),
    );
  }

  /// Submits the player's marker stops; the returned round carries the final
  /// state (and, mid-game, my_patterns for the caller only — not cached, the
  /// play sheet refetches per play session anyway).
  Future<Map<String, dynamic>> playGame(
    String convID,
    String roundID,
    List<int> taps, {
    bool isChannel = false,
  }) async {
    final round = await _api.playGameRound(
      convID,
      roundID,
      taps,
      isChannel: isChannel,
    );
    _ingestGameRound(round);
    return round;
  }

  /// Fetches the freshest round state INCLUDING the caller's my_patterns
  /// (needed to open the play sheet — the WS broadcast never carries them).
  Future<Map<String, dynamic>> fetchGameRound(
    String convID,
    String roundID, {
    bool isChannel = false,
  }) async {
    final round = await _api.getGameRound(convID, roundID, isChannel: isChannel);
    _ingestGameRound(round);
    return round;
  }

  Future<void> placeGameBet(
    String convID,
    String roundID,
    int selection, {
    bool isChannel = false,
  }) async {
    _ingestGameRound(
      await _api.placeGameBet(convID, roundID, selection, isChannel: isChannel),
    );
  }

  Future<void> revealGame(
    String convID,
    String roundID, {
    bool isChannel = false,
  }) async {
    _ingestGameRound(
      await _api.revealGameRound(convID, roundID, isChannel: isChannel),
    );
  }

  /// Fetches a round the client hasn't seen yet (e.g. a card scrolled into view).
  Future<void> loadGameRound(
    String convID,
    String roundID, {
    bool isChannel = false,
  }) async {
    if (_gameRounds.containsKey(roundID)) return;
    try {
      _ingestGameRound(
        await _api.getGameRound(convID, roundID, isChannel: isChannel),
      );
    } catch (_) {}
  }

  Future<void> deleteMessage(String convID, String msgID) async {
    try {
      await _stopLiveLocationShare(msgID, shouldNotify: false);
      // For a sealed message the author proves ownership with its control token.
      String? controlToken;
      for (final m in _messages[convID] ?? const <Message>[]) {
        if (m.id == msgID) {
          controlToken = m.controlToken;
          break;
        }
      }
      await _api.deleteMessage(convID, msgID, controlToken: controlToken);
      final list = _messages[convID] ?? [];
      _messages[convID] = list.where((m) => m.id != msgID).toList();
      _deleteSearchMessage(msgID);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> loadConversationMembers(String convID) async {
    try {
      final members = await _api.getConversationMembers(convID);
      final conv = _conversations[convID];
      if (conv != null) {
        _conversations[convID] = conv.copyWith(members: members);
        notifyListeners();
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    _wsSub?.cancel();
    vaultModeListenable.removeListener(_onVaultModeChanged);
    _depositProgressController.close();
    _joinRequestController.close();
    _recoveryEventsController.close();
    NotificationService.setLiveLocationHandlers(onCancel: null);
    unawaited(_stopAllLiveLocationShares());
    _ws.removeListener(_onWsConnectionChanged);
    _ws.disconnect();
    super.dispose();
  }
}
