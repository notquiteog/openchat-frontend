import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../models/message.dart';
import 'secure_storage_service.dart';

enum MessageSearchCategory {
  messages,
  media,
  files,
  links,
  voice,
  polls,
  payments,
  checklists,
}

class MessageSearchResult {
  final String messageId;
  final String conversationId;
  final String senderId;
  final MessageType messageType;
  final MessageSearchCategory category;
  final DateTime createdAt;
  final String title;
  final String snippet;

  const MessageSearchResult({
    required this.messageId,
    required this.conversationId,
    required this.senderId,
    required this.messageType,
    required this.category,
    required this.createdAt,
    required this.title,
    required this.snippet,
  });
}

class MessageSearchService {
  final SecureStorageService _storage;
  final String? _databasePath;
  final Future<List<int>> Function()? _keyLoader;
  final _aes = AesGcm.with256bits();
  final _hmac = Hmac.sha256();

  sqlite.Database? _db;
  Future<sqlite.Database>? _opening;
  SecretKey? _secretKey;
  List<int>? _keyBytes;

  MessageSearchService(
    SecureStorageService storage, {
    String? databasePath,
    Future<List<int>> Function()? keyLoader,
  }) : this._(storage, databasePath: databasePath, keyLoader: keyLoader);

  MessageSearchService._(this._storage, {this._databasePath, this._keyLoader});

  Future<void> indexMessage(
    Message message, {
    String? conversationTitle,
  }) async {
    if (message.id.startsWith('pending-')) return;
    final document = _SearchDocument.fromMessage(
      message,
      conversationTitle: conversationTitle,
    );
    if (document == null) {
      await deleteMessage(message.id);
      return;
    }

    final db = await _open();
    final encryptedPayload = await _encryptJson({
      'title': document.title,
      'snippet': document.snippet,
    });
    final tokenHashes = <String>{};
    for (final token in _tokensForIndex(document.indexText)) {
      tokenHashes.add(await _hashToken(token));
    }

    db.execute('BEGIN IMMEDIATE');
    try {
      final upsert = db.prepare('''
        INSERT INTO message_search_messages (
          message_id, conversation_id, sender_id, message_type, category,
          created_at_ms, encrypted_payload
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(message_id) DO UPDATE SET
          conversation_id = excluded.conversation_id,
          sender_id = excluded.sender_id,
          message_type = excluded.message_type,
          category = excluded.category,
          created_at_ms = excluded.created_at_ms,
          encrypted_payload = excluded.encrypted_payload
      ''');
      try {
        upsert.execute([
          message.id,
          message.conversationId,
          message.senderId,
          _messageTypeWire(message.type),
          document.category.name,
          message.createdAt.toUtc().millisecondsSinceEpoch,
          encryptedPayload,
        ]);
      } finally {
        upsert.close();
      }

      final deleteTokens = db.prepare(
        'DELETE FROM message_search_tokens WHERE message_id = ?',
      );
      try {
        deleteTokens.execute([message.id]);
      } finally {
        deleteTokens.close();
      }

      final insertToken = db.prepare('''
        INSERT OR IGNORE INTO message_search_tokens (
          token_hash, message_id, conversation_id, created_at_ms
        ) VALUES (?, ?, ?, ?)
      ''');
      try {
        for (final hash in tokenHashes) {
          insertToken.execute([
            hash,
            message.id,
            message.conversationId,
            message.createdAt.toUtc().millisecondsSinceEpoch,
          ]);
        }
      } finally {
        insertToken.close();
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<List<MessageSearchResult>> search(
    String query, {
    String? conversationId,
    String? senderId,
    DateTime? from,
    DateTime? to,
    Set<MessageSearchCategory>? categories,
    int limit = 40,
  }) async {
    // Dedupe: a repeated word ("had had") would demand COUNT(DISTINCT) equal
    // to the duplicated length, which no message can satisfy.
    final queryTokens = _tokensForQuery(query).toSet();
    if (queryTokens.isEmpty) return const [];
    final hashes = <String>[];
    for (final token in queryTokens) {
      hashes.add(await _hashToken(token));
    }

    final db = await _open();
    final tokenPlaceholders = List.filled(hashes.length, '?').join(',');
    final where = <String>['t.token_hash IN ($tokenPlaceholders)'];
    final args = <Object?>[...hashes];
    if (conversationId != null) {
      where.add('m.conversation_id = ?');
      args.add(conversationId);
    }
    if (senderId != null && senderId.trim().isNotEmpty) {
      where.add('m.sender_id = ?');
      args.add(senderId.trim());
    }
    if (categories != null && categories.isNotEmpty) {
      where.add(
        'm.category IN (${List.filled(categories.length, '?').join(',')})',
      );
      args.addAll(categories.map((category) => category.name));
    }
    if (from != null) {
      where.add('m.created_at_ms >= ?');
      args.add(from.toUtc().millisecondsSinceEpoch);
    }
    if (to != null) {
      where.add('m.created_at_ms < ?');
      args.add(_exclusiveEndOfLocalDayMs(to));
    }
    args
      ..add(hashes.length)
      ..add(limit);

    final rows = db.select('''
      SELECT m.message_id, m.conversation_id, m.sender_id, m.message_type,
             m.category, m.created_at_ms, m.encrypted_payload,
             COUNT(DISTINCT t.token_hash) AS matched_tokens
      FROM message_search_messages m
      JOIN message_search_tokens t ON t.message_id = m.message_id
      WHERE ${where.join(' AND ')}
      GROUP BY m.message_id
      HAVING matched_tokens = ?
      ORDER BY m.created_at_ms DESC
      LIMIT ?
    ''', args);

    final results = <MessageSearchResult>[];
    for (final row in rows) {
      final decrypted = await _decryptJson(row['encrypted_payload'] as String);
      if (decrypted == null) continue;
      results.add(
        MessageSearchResult(
          messageId: row['message_id'] as String,
          conversationId: row['conversation_id'] as String,
          senderId: row['sender_id'] as String,
          messageType: _parseMessageType(row['message_type'] as String),
          category: _parseCategory(row['category'] as String),
          createdAt: DateTime.fromMillisecondsSinceEpoch(
            row['created_at_ms'] as int,
            isUtc: true,
          ).toLocal(),
          title: decrypted['title'] as String? ?? 'Message',
          snippet: decrypted['snippet'] as String? ?? '',
        ),
      );
    }
    return results;
  }

  int _exclusiveEndOfLocalDayMs(DateTime day) {
    final local = day.toLocal();
    return DateTime(
      local.year,
      local.month,
      local.day + 1,
    ).toUtc().millisecondsSinceEpoch;
  }

  Future<void> deleteMessage(String messageId) async {
    final db = await _open();
    final stmt = db.prepare(
      'DELETE FROM message_search_messages WHERE message_id = ?',
    );
    try {
      stmt.execute([messageId]);
    } finally {
      stmt.close();
    }
  }

  Future<void> deleteConversation(String conversationId) async {
    final db = await _open();
    final stmt = db.prepare(
      'DELETE FROM message_search_messages WHERE conversation_id = ?',
    );
    try {
      stmt.execute([conversationId]);
    } finally {
      stmt.close();
    }
  }

  Future<void> clearAll() async {
    final db = await _open();
    db.execute('DELETE FROM message_search_messages');
  }

  Future<sqlite.Database> _open() {
    final existing = _db;
    if (existing != null) return Future.value(existing);
    final opening = _opening;
    if (opening != null) return opening;
    _opening = _openDatabase();
    return _opening!;
  }

  Future<sqlite.Database> _openDatabase() async {
    final path = _databasePath ?? await _defaultDatabasePath();
    final db = sqlite.sqlite3.open(path);
    _migrate(db);
    _db = db;
    return db;
  }

  Future<String> _defaultDatabasePath() async {
    final dir = await getApplicationSupportDirectory();
    return p.join(dir.path, 'message_search.db');
  }

  void _migrate(sqlite.Database db) {
    db
      ..execute('PRAGMA foreign_keys = ON')
      ..execute('''
        CREATE TABLE IF NOT EXISTS message_search_messages (
          message_id        TEXT PRIMARY KEY,
          conversation_id   TEXT NOT NULL,
          sender_id         TEXT NOT NULL,
          message_type      TEXT NOT NULL,
          category          TEXT NOT NULL,
          created_at_ms     INTEGER NOT NULL,
          encrypted_payload TEXT NOT NULL
        )
      ''')
      ..execute('''
        CREATE TABLE IF NOT EXISTS message_search_tokens (
          token_hash      TEXT NOT NULL,
          message_id      TEXT NOT NULL REFERENCES message_search_messages(message_id)
                          ON DELETE CASCADE,
          conversation_id TEXT NOT NULL,
          created_at_ms   INTEGER NOT NULL,
          PRIMARY KEY (token_hash, message_id)
        )
      ''')
      ..execute('''
        CREATE INDEX IF NOT EXISTS idx_message_search_tokens_hash
        ON message_search_tokens (token_hash, created_at_ms DESC)
      ''')
      ..execute('''
        CREATE INDEX IF NOT EXISTS idx_message_search_messages_conversation
        ON message_search_messages (conversation_id, created_at_ms DESC)
      ''');
  }

  Future<String> _encryptJson(Map<String, Object?> json) async {
    final key = await _secret();
    final secretBox = await _aes.encrypt(
      utf8.encode(jsonEncode(json)),
      secretKey: key,
    );
    return base64Encode(secretBox.concatenation());
  }

  Future<Map<String, dynamic>?> _decryptJson(String encoded) async {
    try {
      final key = await _secret();
      final secretBox = SecretBox.fromConcatenation(
        base64Decode(encoded),
        nonceLength: _aes.nonceLength,
        macLength: _aes.macAlgorithm.macLength,
      );
      final bytes = await _aes.decrypt(secretBox, secretKey: key);
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (_) {}
    return null;
  }

  Future<String> _hashToken(String token) async {
    final mac = await _hmac.calculateMac(
      utf8.encode(token),
      secretKey: await _secret(),
    );
    return base64UrlEncode(mac.bytes);
  }

  Future<SecretKey> _secret() async {
    final existing = _secretKey;
    if (existing != null) return existing;
    final bytes = await _loadKeyBytes();
    final key = SecretKey(bytes);
    _secretKey = key;
    return key;
  }

  Future<List<int>> _loadKeyBytes() async {
    final existing = _keyBytes;
    if (existing != null) return existing;
    final loader = _keyLoader;
    final bytes = loader != null
        ? await loader()
        : base64Decode(await _storage.getOrCreateSearchIndexKey());
    if (bytes.length != 32) {
      throw StateError('search index key must be 32 bytes');
    }
    _keyBytes = List<int>.unmodifiable(bytes);
    return _keyBytes!;
  }
}

class _SearchDocument {
  final MessageSearchCategory category;
  final String title;
  final String snippet;
  final String indexText;

  const _SearchDocument({
    required this.category,
    required this.title,
    required this.snippet,
    required this.indexText,
  });

  static _SearchDocument? fromMessage(
    Message message, {
    String? conversationTitle,
  }) {
    if (message.decryptionFailed) return null;
    final content = message.content;
    final text = content?.text.trim() ?? '';
    final fileName = content?.fileName?.trim() ?? '';
    final mimeType = content?.mimeType?.trim() ?? '';
    final sender = message.sender?.username ?? '';
    final poll = message.poll;
    final pollText = poll == null
        ? ''
        : [
            poll.question,
            poll.description ?? '',
            ...poll.options.map((option) => option.text),
          ].where((value) => value.trim().isNotEmpty).join(' ');
    final preview = message.listPreview.trim();
    final linkText = _linksIn(text).join(' ');
    final parts = [
      conversationTitle ?? '',
      sender,
      text,
      fileName,
      mimeType,
      pollText,
      preview,
      linkText,
    ].where((value) => value.trim().isNotEmpty).toList();
    if (parts.isEmpty) return null;

    final category = _categoryFor(message, text: text);
    final title = _titleFor(message, text: text, fileName: fileName);
    final snippet = _snippetFor(message, text: text, preview: preview);
    return _SearchDocument(
      category: category,
      title: title,
      snippet: snippet,
      indexText: parts.join(' '),
    );
  }
}

MessageSearchCategory _categoryFor(Message message, {required String text}) {
  return switch (message.type) {
    MessageType.image ||
    MessageType.video ||
    MessageType.animation ||
    MessageType.videoNote ||
    MessageType.livePhoto => MessageSearchCategory.media,
    MessageType.file => MessageSearchCategory.files,
    MessageType.voice || MessageType.audio => MessageSearchCategory.voice,
    MessageType.poll => MessageSearchCategory.polls,
    MessageType.invoice ||
    MessageType.paymentRequest ||
    MessageType.paymentTransfer => MessageSearchCategory.payments,
    MessageType.checklist => MessageSearchCategory.checklists,
    _ =>
      _linksIn(text).isNotEmpty
          ? MessageSearchCategory.links
          : MessageSearchCategory.messages,
  };
}

String _titleFor(
  Message message, {
  required String text,
  required String fileName,
}) {
  if (message.type == MessageType.poll && message.poll != null) {
    return message.poll!.question.isEmpty ? 'Poll' : message.poll!.question;
  }
  if (fileName.isNotEmpty) return fileName;
  if (text.isNotEmpty) return _ellipsize(text, 72);
  return switch (message.type) {
    MessageType.image => 'Image',
    MessageType.video => 'Video',
    MessageType.voice => 'Voice note',
    MessageType.audio => 'Audio',
    MessageType.paymentRequest => 'Payment request',
    MessageType.paymentTransfer => 'Payment sent',
    MessageType.invoice => 'Invoice',
    MessageType.checklist => 'Checklist',
    _ => 'Message',
  };
}

String _snippetFor(
  Message message, {
  required String text,
  required String preview,
}) {
  if (text.isNotEmpty) return _ellipsize(text, 160);
  if (preview.isNotEmpty) return _ellipsize(preview, 160);
  return _titleFor(
    message,
    text: text,
    fileName: message.content?.fileName ?? '',
  );
}

List<String> _tokensForQuery(String query) {
  return _baseTokens(query).where((token) => token.length >= 2).toList();
}

Set<String> _tokensForIndex(String text) {
  final out = <String>{};
  for (final token in _baseTokens(text)) {
    if (token.length < 2) continue;
    out.add(token);
    final maxPrefix = token.length.clamp(2, 24);
    for (var i = 2; i <= maxPrefix; i++) {
      out.add(token.substring(0, i));
    }
    if (out.length >= 180) break;
  }
  return out;
}

List<String> _baseTokens(String text) {
  final normalized = text.toLowerCase();
  final matches = RegExp(r"[a-z0-9@._:/#-]+").allMatches(normalized);
  final tokens = <String>[];
  for (final match in matches) {
    final token = match
        .group(0)!
        .replaceAll(RegExp(r"^[._:/#-]+|[._:/#-]+$"), '');
    if (token.isNotEmpty) tokens.add(token);
  }
  return tokens;
}

List<String> _linksIn(String text) {
  if (text.isEmpty) return const [];
  return RegExp(
    r'https?://[^\s<>()]+',
    caseSensitive: false,
  ).allMatches(text).map((match) => match.group(0)!).toList();
}

String _ellipsize(String text, int max) {
  final collapsed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (collapsed.length <= max) return collapsed;
  return '${collapsed.substring(0, max - 3)}...';
}

String _messageTypeWire(MessageType type) {
  return switch (type) {
    MessageType.videoNote => 'video_note',
    MessageType.livePhoto => 'live_photo',
    MessageType.paymentRequest => 'payment_request',
    MessageType.paymentTransfer => 'payment_transfer',
    _ => type.name,
  };
}

MessageType _parseMessageType(String value) {
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

MessageSearchCategory _parseCategory(String value) {
  return MessageSearchCategory.values.firstWhere(
    (category) => category.name == value,
    orElse: () => MessageSearchCategory.messages,
  );
}
