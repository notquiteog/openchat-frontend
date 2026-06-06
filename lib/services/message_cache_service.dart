import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'secure_storage_service.dart';

class MessageCacheEntry {
  final String plaintext;
  final String? senderId;

  const MessageCacheEntry({required this.plaintext, this.senderId});
}

/// Persists successfully-decrypted message content across app restarts.
///
/// MLS application-message key material is one-time-use (forward secrecy):
/// once consumed by the OpenMLS engine it cannot be replayed. Without this
/// cache, every app restart causes all MLS messages to show "Unable to
/// decrypt".  The plaintext is AES-256-GCM encrypted at rest using a key
/// kept in secure storage.
class MessageCacheService {
  final SecureStorageService _storage;
  final String? _databasePath;
  final Future<List<int>> Function()? _keyLoader;
  final _aes = AesGcm.with256bits();

  sqlite.Database? _db;
  Future<sqlite.Database>? _opening;
  SecretKey? _secretKey;
  List<int>? _keyBytes;

  MessageCacheService(
    SecureStorageService storage, {
    String? databasePath,
    Future<List<int>> Function()? keyLoader,
  }) : this._(storage, databasePath: databasePath, keyLoader: keyLoader);

  MessageCacheService._(this._storage, {this._databasePath, this._keyLoader});

  /// Returns the cached plaintext for [messageId] if present and the stored
  /// [encryptedPayload] prefix still matches (detects edits).
  Future<MessageCacheEntry?> get(
    String messageId,
    String encryptedPayload,
  ) async {
    if (kIsWeb) return null;
    try {
      final db = await _open();
      final prefix = _payloadPrefix(encryptedPayload);
      final rows = db.select(
        'SELECT payload_prefix, data FROM message_cache WHERE message_id = ?',
        [messageId],
      );
      if (rows.isEmpty) return null;
      final row = rows.first;
      if (row['payload_prefix'] as String != prefix) return null;
      final data = await _decrypt(row['data'] as String);
      if (data == null) return null;
      final senderIdStr = data['sender_id'] as String? ?? '';
      return MessageCacheEntry(
        plaintext: data['plaintext'] as String? ?? '',
        senderId: senderIdStr.isEmpty ? null : senderIdStr,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> put(
    String messageId,
    String conversationId,
    String encryptedPayload,
    String plaintext,
    String? senderId,
  ) async {
    if (kIsWeb) return;
    try {
      final db = await _open();
      final prefix = _payloadPrefix(encryptedPayload);
      final encrypted = await _encrypt({
        'plaintext': plaintext,
        'sender_id': senderId ?? '',
      });
      final stmt = db.prepare('''
        INSERT INTO message_cache (
          message_id, conversation_id, payload_prefix, data, created_at_ms
        ) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(message_id) DO UPDATE SET
          conversation_id = excluded.conversation_id,
          payload_prefix  = excluded.payload_prefix,
          data            = excluded.data,
          created_at_ms   = excluded.created_at_ms
      ''');
      try {
        stmt.execute([
          messageId,
          conversationId,
          prefix,
          encrypted,
          DateTime.now().toUtc().millisecondsSinceEpoch,
        ]);
      } finally {
        stmt.close();
      }
    } catch (_) {}
  }

  Future<void> delete(String messageId) async {
    if (kIsWeb) return;
    try {
      final db = await _open();
      final stmt = db.prepare(
        'DELETE FROM message_cache WHERE message_id = ?',
      );
      try {
        stmt.execute([messageId]);
      } finally {
        stmt.close();
      }
    } catch (_) {}
  }

  Future<void> deleteConversation(String conversationId) async {
    if (kIsWeb) return;
    try {
      final db = await _open();
      final stmt = db.prepare(
        'DELETE FROM message_cache WHERE conversation_id = ?',
      );
      try {
        stmt.execute([conversationId]);
      } finally {
        stmt.close();
      }
    } catch (_) {}
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
    return p.join(dir.path, 'message_cache.db');
  }

  void _migrate(sqlite.Database db) {
    db
      ..execute('PRAGMA foreign_keys = ON')
      ..execute('''
        CREATE TABLE IF NOT EXISTS message_cache (
          message_id      TEXT PRIMARY KEY,
          conversation_id TEXT NOT NULL,
          payload_prefix  TEXT NOT NULL,
          data            TEXT NOT NULL,
          created_at_ms   INTEGER NOT NULL
        )
      ''')
      ..execute('''
        CREATE INDEX IF NOT EXISTS idx_message_cache_conversation
        ON message_cache (conversation_id)
      ''');
  }

  static String _payloadPrefix(String encryptedPayload) =>
      encryptedPayload.length > 48
          ? encryptedPayload.substring(0, 48)
          : encryptedPayload;

  Future<String> _encrypt(Map<String, Object?> json) async {
    final key = await _secret();
    final secretBox = await _aes.encrypt(
      utf8.encode(jsonEncode(json)),
      secretKey: key,
    );
    return base64Encode(secretBox.concatenation());
  }

  Future<Map<String, dynamic>?> _decrypt(String encoded) async {
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
        return decoded.map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (_) {}
    return null;
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
        : base64Decode(await _storage.getOrCreateMessageCacheKey());
    if (bytes.length != 32) {
      throw StateError('message cache key must be 32 bytes');
    }
    _keyBytes = List<int>.unmodifiable(bytes);
    return _keyBytes!;
  }
}
