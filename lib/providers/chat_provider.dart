import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:uuid/uuid.dart';
import '../crypto/pgp_service.dart';
import '../models/chat_folder.dart';
import '../models/conversation.dart';
import '../models/message.dart';
import '../models/user.dart';
import '../providers/settings_provider.dart';
import '../services/api_service.dart';
import '../services/attachment_service.dart';
import '../services/message_search_service.dart';
import '../services/mls_service.dart';
import '../services/notification_service.dart';
import '../services/offline_outbox_service.dart';
import '../services/secure_storage_service.dart';
import '../services/websocket_service.dart';
import '../utils/mention_utils.dart';

class ChatSendException implements Exception {
  final String message;
  const ChatSendException(this.message);

  @override
  String toString() => message;
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
  final SecureStorageService _storage;
  final WebSocketService _ws;
  final SettingsProvider _settings;
  final MlsService _mls;
  final MessageSearchService _search;
  final OfflineOutboxService _outbox;

  final Map<String, List<Message>> _messages = {};
  final Map<String, Conversation> _conversations = {};
  final List<ChatFolder> _chatFolders = [];
  final Map<String, Set<String>> _typingUsers = {};
  final Map<String, Map<String, String>> _readReceipts = {};
  final Map<String, _ActiveLiveLocationShare> _liveLocationShares = {};
  List<OfflineOutboxItem> _outboxItems = const [];
  String? _selfId;
  String? _selfUsername;
  Future<void>? _outboxLoadInFlight;
  bool _drainingOutbox = false;
  bool _outboxLoaded = false;

  List<Conversation> get conversations =>
      _conversations.values.toList()..sort((a, b) {
        final aTime = a.lastMessage?.createdAt ?? a.createdAt;
        final bTime = b.lastMessage?.createdAt ?? b.createdAt;
        return bTime.compareTo(aTime);
      });

  List<ChatFolder> get chatFolders => List.unmodifiable(_chatFolders);

  List<Message> messagesFor(String convID) =>
      List.unmodifiable(_messages[convID] ?? []);

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
    OfflineOutboxService? outboxService,
  }) : _search = searchService ?? MessageSearchService(_storage),
       _outbox = outboxService ?? OfflineOutboxService(_storage) {
    _wsSub = _ws.events.listen(_handleWsEvent);
    _ws.addListener(_onWsConnectionChanged);
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

  Future<void> connectWebSocket() => _ws.connect();

  void clearState() {
    _messages.clear();
    _conversations.clear();
    _chatFolders.clear();
    _typingUsers.clear();
    _readReceipts.clear();
    _outboxItems = const [];
    _selfUsername = null;
    _outboxLoaded = false;
    _wasWsMonitoring = false;
    unawaited(_search.clearAll());
    unawaited(_outbox.clearAll());
    unawaited(_stopAllLiveLocationShares());
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

  void _onWsConnectionChanged() {
    final monitoring = _ws.isMonitoring;
    if (monitoring && !_wasWsMonitoring) {
      unawaited(_catchUpAfterReconnect());
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

  Future<void> loadConversations() => _loadConversations(silent: false);

  Future<void> refreshConversationsSilently() {
    _conversationRefreshInFlight ??= _loadConversations(silent: true)
        .whenComplete(() {
          _conversationRefreshInFlight = null;
        });
    return _conversationRefreshInFlight!;
  }

  Future<void> _loadConversations({required bool silent}) async {
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
        var hydrated = c;
        final last = c.lastMessage;
        if (last != null) {
          await _promoteDeliveredSealedScheduledMessage(last);
          _hydrateMessageSender(last);
          final cached = _cachedDecryptedMessage(last);
          if (cached != null) {
            _hydrateMessageSender(cached, fresh: last);
            hydrated = c.copyWith(lastMessage: cached);
            await _syncLocalUnreadMentionFromConversation(hydrated);
            next[c.id] = hydrated;
            continue;
          }
          await _tryDecrypt(last, privateKey, conversation: c);
          hydrated = c.copyWith(lastMessage: last);
        }
        await _syncLocalUnreadMentionFromConversation(hydrated);
        next[c.id] = hydrated;
      }
      changed = hasConversationListChanges(
        current: _conversations,
        fresh: next.values,
      );
      if (changed || !silent) {
        _conversations
          ..clear()
          ..addAll(next);
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

  Future<void> loadChatFolders() async {
    final folders = await _settings.loadChatFolders();
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
          await _tryDecrypt(
            msg,
            privateKey,
            conversation: _conversations[convID],
          );
          await _syncLiveLocationShareFromMessage(msg);
          result.add(msg);
        }
      }

      _messages[convID] = _withOutboxOverlays(convID, result);
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
      await Future.wait(
        older.map(
          (msg) => _tryDecrypt(
            msg,
            privateKey,
            conversation: _conversations[convID],
          ),
        ),
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
  }) async {
    final payloadJson = jsonEncode(
      attachment.toPayloadJson(caption: caption, viewOnce: viewOnce),
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
    AttachmentUploadProgressCallback? onProgress,
  }) async {
    try {
      if (!_ws.isMonitoring) {
        await _queueAttachmentUpload(
          convID: convID,
          attachment: attachment,
          caption: caption,
          viewOnce: viewOnce,
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
      );
    } catch (e) {
      if (_shouldRetryOutboxError(e)) {
        await _queueAttachmentUpload(
          convID: convID,
          attachment: attachment,
          caption: caption,
          viewOnce: viewOnce,
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
  }) async {
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
      type: 'regular',
      isAnonymous: isAnonymous,
      allowsMultipleAnswers: allowsMultipleAnswers,
      allowsRevoting: true,
      isClosed: false,
      totalVoterCount: 0,
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
        'type': 'regular',
        'is_anonymous': isAnonymous,
        'allows_multiple_answers': allowsMultipleAnswers,
        'allows_revoting': true,
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
        allowsMultipleAnswers: allowsMultipleAnswers,
        allowsRevoting: true,
        silent: silent,
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

  Future<void> votePoll({
    required String convID,
    required String pollID,
    required List<String> optionIDs,
  }) async {
    final updatedPoll = await _api.votePoll(pollID, optionIDs);
    final list = _messages[convID];
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

    final privateKey = await _storage.getPrivateKeyIfUnlocked() ?? '';
    await _tryDecrypt(msg, privateKey);
    // If we can't decrypt the edit (e.g. our own message), keep the text we had.
    if (!msg.isDecrypted && old.isDecrypted) {
      final oldLocation = old.location;
      msg.setDecryptedContent(
        oldLocation != null
            ? jsonEncode(oldLocation.toJson())
            : (old.decryptedContent ?? ''),
      );
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
        await _api.scheduleSealedMessage(
          convID: convID,
          encryptedPayload: prepared.encryptedPayload,
          postToken: prepared.postToken ?? '',
          scheduledFor: scheduledFor,
          replyTo: null,
          attachmentId: attachmentId,
          topicId: null,
          silent: silent,
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
      final confirmed = conv.isEncrypted
          ? await _api.sendSealedMessage(
              convID: convID,
              encryptedPayload: prepared.encryptedPayload,
              postToken: prepared.postToken ?? '',
              replyTo: null,
              attachmentId: attachmentId,
              topicId: null,
              silent: silent,
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
    return jsonEncode({
      'openchat_message': 1,
      'type': messageType,
      'payload': plaintextPayload,
      'sender': {
        'id': senderId,
        'key_fingerprint': fingerprint,
        'signature': signature,
        'created_at': createdAt,
      },
    });
  }

  Future<String> _sealedPostToken(String convID, String privateKey) async {
    final encrypted = await _api.getEncryptedSealedPostToken(convID);
    return PgpService.decrypt(
      encryptedArmor: encrypted,
      privateKeyArmored: privateKey,
    );
  }

  Future<String?> _verifiedPgpSenderId(
    String raw,
    String convID,
    Conversation? conversation,
  ) async {
    final proof = Message.senderProofFromRaw(raw);
    if (proof == null) return null;
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
    if (user == null) return null;
    if (user.keyFingerprint.toUpperCase() !=
        proof.keyFingerprint.toUpperCase()) {
      return null;
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
      final next = await Geolocator.requestPermission();
      permission = next;
      if (permission != LocationPermission.always) {
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

      try {
        final freshKey = await _api.getFreshUserPublicKeyEntry(member.userId);
        if (freshKey != null && freshKey.publicKey.trim().isNotEmpty) {
          keysByUser[member.userId] = PgpRecipient(
            userId: member.userId,
            publicKeyArmored: freshKey.publicKey,
            keyFingerprint: freshKey.fingerprint,
          );
          continue;
        }
        continue;
      } catch (_) {
        final embeddedKey = member.user?.publicKey ?? '';
        final embeddedFingerprint = member.user?.keyFingerprint ?? '';
        if (embeddedKey.trim().isNotEmpty &&
            embeddedFingerprint.trim().isNotEmpty) {
          keysByUser[member.userId] = PgpRecipient(
            userId: member.userId,
            publicKeyArmored: embeddedKey,
            keyFingerprint: embeddedFingerprint,
          );
          continue;
        }
        throw const ChatSendException(
          'Could not load every recipient key. Refresh the chat and try again.',
        );
      }
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
  }) async {
    final conv = await _api.createGroup(
      name: name,
      description: description,
      memberIDs: memberIDs,
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
          _conversations.remove(convID);
          _messages.remove(convID);
          _typingUsers.remove(convID);
          unawaited(_settings.clearUnreadMention(convID));
          _deleteSearchConversation(convID);
          notifyListeners();
        }

      case WsEventType.messageEdited:
        _handleEditedMessage(Message.fromJson(event.data));

      case WsEventType.messageReaction:
        _handleMessageReactionUpdate(event.data);

      case WsEventType.pollUpdated:
        _handlePollUpdate(event.data);

      case WsEventType.paymentRequestUpdated:
        unawaited(_handlePaymentRequestUpdate(event.data));

      case WsEventType.conversationUpdated:
        // Name / description / avatar (and for channels, handle) changed. Pull
        // the fresh conversation + members so it updates without a manual refresh.
        final convID = event.data['conversation_id'] as String?;
        if (convID != null) {
          unawaited(refreshConversationsSilently());
          if (_conversations.containsKey(convID)) {
            loadConversationMembers(convID);
          }
        }

      case WsEventType.readReceipt:
        _handleReadReceipt(event.data);

      case WsEventType.memberJoined:
      case WsEventType.memberLeft:
        final convID = event.data['conversation_id'] as String?;
        if (convID != null) {
          if (_conversations.containsKey(convID)) {
            loadConversationMembers(convID);
          } else {
            // We were added to a new group — fetch the full list to surface it.
            unawaited(refreshConversationsSilently());
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

    final list = _messages[msg.conversationId] ?? [];
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
      // Message from a conversation we haven't seen yet (new DM or group).
      unawaited(refreshConversationsSilently());
    }

    _indexMessage(displayMsg);
    final mentionedForCurrentUser = await _recordLocalUnreadMention(displayMsg);

    if (_selfId != null &&
        msg.senderId != _selfId &&
        msg.type != MessageType.system) {
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
  }

  void _deleteSearchConversation(String conversationId) {
    unawaited(_search.deleteConversation(conversationId));
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
      final raw = await _mls.decryptPayload(
        api: _api,
        conversation: conv!,
        encryptedPayload: msg.encryptedPayload,
      );
      if (raw != null && raw.isNotEmpty) {
        final verifiedSenderId = await _verifiedPgpSenderId(
          raw,
          msg.conversationId,
          conv,
        );
        if (msg.sealedSender && verifiedSenderId == null) {
          msg.markDecryptionFailed();
          return;
        }
        msg.setDecryptedContent(raw, verifiedSenderId: verifiedSenderId);
        _applyArtifactState(msg);
        _hydrateMessageSender(msg);
        _indexMessage(msg);
      } else {
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
        final verifiedSenderId = await _verifiedPgpSenderId(
          raw,
          msg.conversationId,
          conv,
        );
        if (msg.sealedSender && verifiedSenderId == null) {
          msg.markDecryptionFailed();
          return;
        }
        msg.setDecryptedContent(raw, verifiedSenderId: verifiedSenderId);
        _applyArtifactState(msg);
        _hydrateMessageSender(msg);
        _indexMessage(msg);
      } else {
        msg.markDecryptionFailed();
      }
    } catch (_) {
      msg.markDecryptionFailed();
    }
  }

  Future<void> deleteMessage(String convID, String msgID) async {
    try {
      await _stopLiveLocationShare(msgID, shouldNotify: false);
      await _api.deleteMessage(convID, msgID);
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
    _wsSub?.cancel();
    NotificationService.setLiveLocationHandlers(onCancel: null);
    unawaited(_stopAllLiveLocationShares());
    _ws.removeListener(_onWsConnectionChanged);
    _ws.disconnect();
    super.dispose();
  }
}
