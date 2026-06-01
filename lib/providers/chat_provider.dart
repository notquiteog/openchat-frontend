import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../crypto/pgp_service.dart';
import '../models/conversation.dart';
import '../models/message.dart';
import '../models/user.dart';
import '../providers/settings_provider.dart';
import '../services/api_service.dart';
import '../services/attachment_service.dart';
import '../services/notification_service.dart';
import '../services/secure_storage_service.dart';
import '../services/websocket_service.dart';

class ChatSendException implements Exception {
  final String message;
  const ChatSendException(this.message);

  @override
  String toString() => message;
}

class ChatProvider extends ChangeNotifier {
  final ApiService _api;
  final SecureStorageService _storage;
  final WebSocketService _ws;
  final SettingsProvider _settings;

  final Map<String, List<Message>> _messages = {};
  final Map<String, Conversation> _conversations = {};
  final Map<String, Set<String>> _typingUsers = {};
  String? _selfId;

  List<Conversation> get conversations => _conversations.values.toList()
    ..sort((a, b) {
      final aTime = a.lastMessage?.createdAt ?? a.createdAt;
      final bTime = b.lastMessage?.createdAt ?? b.createdAt;
      return bTime.compareTo(aTime);
    });

  List<Message> messagesFor(String convID) =>
      List.unmodifiable(_messages[convID] ?? []);

  Set<String> typingUsersFor(String convID) => _typingUsers[convID] ?? {};

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  StreamSubscription<WsEvent>? _wsSub;

  ChatProvider(this._api, this._storage, this._ws, this._settings) {
    _wsSub = _ws.events.listen(_handleWsEvent);
    _ws.connect();
    _storage.getUserID().then((id) => _selfId = id);
  }

  Future<void> connectWebSocket() => _ws.connect();

  void clearState() {
    _messages.clear();
    _conversations.clear();
    _typingUsers.clear();
    _ws.disconnect();
    notifyListeners();
  }

  Future<void> loadConversations() async {
    _isLoading = true;
    notifyListeners();
    try {
      final convs = await _api.listConversations();
      final privateKey = await _storage.getPrivateKeyIfUnlocked() ?? '';
      for (final c in convs) {
        final last = c.lastMessage;
        if (last != null) {
          _hydrateMessageSender(last);
          final cached = _cachedDecryptedMessage(last);
          if (cached != null) {
            _hydrateMessageSender(cached, fresh: last);
            _conversations[c.id] = c.copyWith(lastMessage: cached);
            continue;
          }
          await _tryDecrypt(last, privateKey);
        }
        _conversations[c.id] = c;
      }
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadMessages(String convID) async {
    try {
      final msgs = await _api.getMessages(convID, limit: 50);
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
        final cached = cachedById[msg.id];
        if (cached != null && cached.isDecrypted) {
          _hydrateMessageSender(cached, fresh: msg);
          result.add(cached);
        } else {
          _hydrateMessageSender(msg);
          await _tryDecrypt(msg, privateKey);
          result.add(msg);
        }
      }

      _messages[convID] = result;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> loadMoreMessages(String convID) async {
    final existing = _messages[convID];
    if (existing == null || existing.isEmpty) return;
    final oldest = existing.first;
    try {
      final older = await _api.getMessages(
        convID,
        beforeID: oldest.id,
        limit: 50,
      );
      for (final msg in older) {
        _hydrateMessageSender(msg);
      }
      final privateKey = await _storage.getPrivateKeyIfUnlocked() ?? '';
      await Future.wait(older.map((msg) => _tryDecrypt(msg, privateKey)));
      _messages[convID] = [...older.reversed, ...existing];
      notifyListeners();
    } catch (_) {}
  }

  /// Send a plain text message, encrypted for all conversation members.
  Future<bool> sendMessage({
    required String convID,
    required String plaintext,
    String messageType = 'text',
    String? replyTo,
  }) async {
    return _sendEncryptedPayload(
      convID: convID,
      plaintextPayload: plaintext,
      messageType: messageType,
      replyTo: replyTo,
    );
  }

  /// Encrypt a local file (via [AttachmentService]) and send as a media message.
  Future<bool> sendAttachment({
    required String convID,
    required PendingAttachment attachment,
    String caption = '',
  }) async {
    final payloadJson = jsonEncode(attachment.toPayloadJson(caption: caption));
    return _sendEncryptedPayload(
      convID: convID,
      plaintextPayload: payloadJson,
      messageType: attachment.messageType.name,
      attachmentId: attachment.attachmentId,
    );
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
    final privateKey = await _storage.getPrivateKeyIfUnlocked() ?? '';
    final String encrypted;
    final String signature;
    if (conv.encryptionEnabled) {
      if (privateKey.isEmpty) return;
      final recipientKeys = await _freshRecipientKeys(convID, conv);
      if (recipientKeys.isEmpty) return;

      encrypted = await PgpService.encrypt(
        plaintext: newPlaintext,
        recipientPublicKeys: recipientKeys,
        signingPrivateKeyArmored: privateKey,
      );
      signature = await PgpService.sign(
        data: '$convID:$encrypted',
        privateKeyArmored: privateKey,
      );
    } else {
      encrypted = newPlaintext;
      signature = '';
    }

    final updated = await _api.editMessage(
      convID: convID,
      msgID: msgID,
      encryptedPayload: encrypted,
      signature: signature,
    );
    // We can't always re-decrypt our own message from the server, so set the
    // plaintext we already know directly.
    updated.setDecryptedContent(newPlaintext);

    final list = _messages[convID] ?? [];
    final idx = list.indexWhere((m) => m.id == msgID);
    if (idx != -1) {
      updated.sender ??= list[idx].sender;
      list[idx] = updated;
      _messages[convID] = List.from(list);
      notifyListeners();
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
      msg.setDecryptedContent(old.decryptedContent ?? '');
    }
    msg.sender ??= old.sender;
    list[idx] = msg;
    _messages[msg.conversationId] = List.from(list);
    notifyListeners();
  }

  Future<bool> _sendEncryptedPayload({
    required String convID,
    required String plaintextPayload,
    required String messageType,
    String? replyTo,
    String? attachmentId,
  }) async {
    final conv = _conversations[convID];
    if (conv == null) {
      throw const ChatSendException(
        'Conversation is not ready. Reopen the chat and try again.',
      );
    }

    final privateKey = await _storage.getPrivateKeyIfUnlocked() ?? '';
    final userID = await _storage.getUserID() ?? '';
    if (conv.encryptionEnabled && privateKey.isEmpty) {
      throw const ChatSendException(
        'Your PGP key is locked or missing. Unlock or import it in Settings.',
      );
    }
    if (userID.isEmpty) {
      throw const ChatSendException(
        'Your session is incomplete. Sign in again.',
      );
    }

    final String encrypted;
    final String signature;
    if (conv.encryptionEnabled) {
      final recipientKeys = await _freshRecipientKeys(convID, conv);
      if (recipientKeys.isEmpty) {
        throw const ChatSendException(
          'Could not load recipient keys. Refresh the chat and try again.',
        );
      }

      try {
        encrypted = await PgpService.encrypt(
          plaintext: plaintextPayload,
          recipientPublicKeys: recipientKeys,
          signingPrivateKeyArmored: privateKey,
        ).timeout(const Duration(seconds: 30));
      } on TimeoutException {
        throw const ChatSendException(
          'Encryption timed out. Your stored key may be corrupted — try rotating it in Settings → PGP Keys.',
        );
      } catch (e) {
        throw ChatSendException('Encryption failed: $e');
      }

      final sigData = '$convID:$encrypted';
      try {
        signature = await PgpService.sign(
          data: sigData,
          privateKeyArmored: privateKey,
        ).timeout(const Duration(seconds: 30));
      } on TimeoutException {
        throw const ChatSendException(
          'Signing timed out. Your stored key may be corrupted — try rotating it in Settings → PGP Keys.',
        );
      } catch (e) {
        throw ChatSendException('Signing failed: $e');
      }
    } else {
      encrypted = plaintextPayload;
      signature = '';
    }

    final pending = PendingMessage(
      id: 'pending-${DateTime.now().millisecondsSinceEpoch}',
      conversationId: convID,
      senderId: userID,
      type: MessageType.values.firstWhere(
        (t) => t.name == messageType,
        orElse: () => MessageType.text,
      ),
      encryptedPayload: encrypted,
      signature: signature,
      isEncrypted: conv.encryptionEnabled,
      autoDeleteSeconds: conv.messageTtlSeconds,
      autoDeleteExpiresAt: conv.messageTtlSeconds > 0
          ? DateTime.now().add(Duration(seconds: conv.messageTtlSeconds))
          : null,
      attachmentId: attachmentId,
      replyTo: replyTo,
      createdAt: DateTime.now(),
      plaintext: plaintextPayload,
    );

    _messages[convID] = [...?_messages[convID], pending];
    notifyListeners();

    try {
      final confirmed = await _api.sendMessage(
        convID: convID,
        encryptedPayload: encrypted,
        signature: signature,
        messageType: messageType,
        replyTo: replyTo,
        attachmentId: attachmentId,
      );
      confirmed.setDecryptedContent(plaintextPayload);

      // Remove the pending placeholder and any WS-delivered copy of the same
      // real message ID. The WS new_message event can race the API response:
      // when it arrives first it lands as a separate, undecryptable entry
      // (the PGP library can't decrypt sender's own messages from the server).
      // Filtering both IDs then appending confirmed leaves exactly one copy.
      final list = _messages[convID] ?? [];
      _messages[convID] = [
        ...list.where((m) => m.id != pending.id && m.id != confirmed.id),
        confirmed,
      ];

      // Keep the conversation preview pointing at our decryptable copy so the
      // home screen never shows "🔒 Encrypted" for messages we just sent.
      final existingConv = _conversations[convID];
      if (existingConv != null) {
        _conversations[convID] = existingConv.copyWith(lastMessage: confirmed);
      }

      notifyListeners();
      return true;
    } catch (_) {
      final list = _messages[convID] ?? [];
      final idx = list.indexWhere((m) => m.id == pending.id);
      if (idx != -1) {
        list[idx].markDecryptionFailed();
        _messages[convID] = List.from(list);
        notifyListeners();
      }
      return false;
    }
  }

  /// Builds the recipient keyring from the server's latest membership and
  /// public-key rows, keyed by user ID so two members with different keys that
  /// happen to share the same key string don't silently merge into one PKESK.
  ///
  /// Sending is strict: every non-expired member must have a key available, so
  /// we never create a sender-only envelope that other members can't decrypt.
  /// The sender's own key is always ensured via their local storage entry so
  /// they can re-decrypt their sent messages from the server after a fresh
  /// login.
  Future<List<String>> _freshRecipientKeys(
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
    final keysByUser = <String, String>{};

    for (final member in members) {
      if (member.user?.isKeyExpired ?? false) continue;

      if (member.userId == selfId) continue;

      try {
        final freshKey = await _api.getFreshUserPublicKey(member.userId);
        if (freshKey != null && freshKey.trim().isNotEmpty) {
          keysByUser[member.userId] = freshKey;
          continue;
        }
      } catch (_) {
        final embeddedKey = member.user?.publicKey ?? '';
        if (embeddedKey.trim().isNotEmpty) {
          keysByUser[member.userId] = embeddedKey;
          continue;
        }
        throw const ChatSendException(
          'Could not load every recipient key. Refresh the chat and try again.',
        );
      }

      throw const ChatSendException(
        'Could not load every recipient key. Refresh the chat and try again.',
      );
    }

    if (selfId.isNotEmpty && ownPublicKey.isNotEmpty) {
      keysByUser[selfId] = ownPublicKey;
    }

    return keysByUser.values.where((k) => k.trim().isNotEmpty).toList();
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
    notifyListeners();
  }

  Future<void> leaveConversation(String convID,
      {bool deleteOwnMessages = false}) async {
    await _api.leaveConversation(
      convID,
      deleteOwnMessages: deleteOwnMessages,
    );
    _conversations.remove(convID);
    _messages.remove(convID);
    _typingUsers.remove(convID);
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

  void sendTyping(String convID) => _ws.sendTyping(convID);

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
          notifyListeners();
        }

      case WsEventType.messageEdited:
        _handleEditedMessage(Message.fromJson(event.data));

      case WsEventType.conversationUpdated:
        // Name / description / avatar (and for channels, handle) changed. Pull
        // the fresh conversation + members so it updates without a manual refresh.
        final convID = event.data['conversation_id'] as String?;
        if (convID != null) {
          loadConversations();
          if (_conversations.containsKey(convID)) {
            loadConversationMembers(convID);
          }
        }

      case WsEventType.readReceipt:
        break;

      case WsEventType.memberJoined:
      case WsEventType.memberLeft:
        final convID = event.data['conversation_id'] as String?;
        if (convID != null) {
          if (_conversations.containsKey(convID)) {
            loadConversationMembers(convID);
          } else {
            // We were added to a new group — fetch the full list to surface it.
            loadConversations();
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

  Future<void> _handleIncomingMessage(Message msg) async {
    final privateKey = await _storage.getPrivateKeyIfUnlocked() ?? '';
    await _tryDecrypt(msg, privateKey);

    // Realtime events don't carry sender profile info, so backfill from the
    // loaded members before the message reaches the bubble/avatar UI.
    _hydrateMessageSender(msg);

    final cached = _cachedDecryptedMessage(msg);
    final displayMsg = (!msg.isDecrypted && cached != null) ? cached : msg;
    if (displayMsg != msg) {
      _hydrateMessageSender(displayMsg, fresh: msg);
    }

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
      loadConversations();
    }

    if (_selfId != null &&
        msg.senderId != _selfId &&
        msg.type != MessageType.system) {
      final senderName =
          msg.sender?.username != null ? '@${msg.sender!.username}' : 'Someone';
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
      );
    }

    notifyListeners();
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
    hydrateMessageSenderFromConversationForTesting(msg, conv);
  }

  @visibleForTesting
  static void hydrateMessageSenderFromConversationForTesting(
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
        (current.bubbleColor == null && candidate.bubbleColor != null) ||
        (current.publicKey.isEmpty && candidate.publicKey.isNotEmpty) ||
        (current.keyFingerprint.isEmpty && candidate.keyFingerprint.isNotEmpty);
  }

  Future<void> _tryDecrypt(Message msg, String privateKey) async {
    if (!msg.isEncrypted) {
      msg.setDecryptedContent(msg.encryptedPayload);
      return;
    }
    if (privateKey.isEmpty) return;
    try {
      final raw = await PgpService.decrypt(
        encryptedArmor: msg.encryptedPayload,
        privateKeyArmored: privateKey,
      );
      if (raw.isNotEmpty) {
        msg.setDecryptedContent(raw);
      } else {
        msg.markDecryptionFailed();
      }
    } catch (_) {
      msg.markDecryptionFailed();
    }
  }

  Future<void> deleteMessage(String convID, String msgID) async {
    try {
      await _api.deleteMessage(convID, msgID);
      final list = _messages[convID] ?? [];
      _messages[convID] = list.where((m) => m.id != msgID).toList();
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
    _ws.disconnect();
    super.dispose();
  }
}
