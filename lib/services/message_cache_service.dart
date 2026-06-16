import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
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
      final rows = db.select(
        'SELECT payload_prefix, data FROM message_cache WHERE message_id = ?',
        [messageId],
      );
      if (rows.isEmpty) return null;
      final row = rows.first;
      final stored = row['payload_prefix'] as String;
      if (stored != _payloadFingerprint(encryptedPayload) &&
          stored != _legacyPayloadPrefix(encryptedPayload)) {
        return null;
      }
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
      final prefix = _payloadFingerprint(encryptedPayload);
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
      final stmt = db.prepare('DELETE FROM message_cache WHERE message_id = ?');
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

  /// Logout wipe: the cache DB is device-global, so without this the next
  /// account logging in on this device gets cache hits on the previous
  /// account's decrypted MLS plaintext. Deletes every row AND the at-rest key
  /// so residual ciphertext in sqlite free pages / WAL is garbage too. The
  /// next account mints a fresh key on its first cache write.
  Future<void> clearAll() async {
    if (kIsWeb) return;
    try {
      final db = await _open();
      db.execute('DELETE FROM message_cache');
    } catch (_) {}
    // Drop cached key material so the next put() picks up the fresh key
    // rather than encrypting new rows with the deleted one.
    _secretKey = null;
    _keyBytes = null;
    try {
      await _storage.deleteMessageCacheKey();
    } catch (_) {}
  }

  Future<sqlite.Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;

    final inFlight = _opening;
    if (inFlight != null) return inFlight;

    // Clear _opening in `finally` (mirrors KeyCacheService): caching a FAILED
    // open future forever would turn one transient failure (locked keyring,
    // slow disk at launch) into a cache disabled until app restart.
    final opening = _openDatabase();
    _opening = opening;
    try {
      final db = await opening;
      _db = db;
      return db;
    } finally {
      _opening = null;
    }
  }

  Future<sqlite.Database> _openDatabase() async {
    final path = _databasePath ?? await _defaultDatabasePath();
    final db = sqlite.sqlite3.open(path);
    _migrate(db);
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

  /// Full-payload fingerprint used to detect edits. A 48-char prefix was used
  /// before, but the first ~36 decoded bytes of an MLS ciphertext are
  /// structural (version/wire-format/group_id/epoch — constant within an
  /// epoch), so an edited MLS message could match the stale entry and keep
  /// rendering the pre-edit plaintext.
  static String _payloadFingerprint(String encryptedPayload) =>
      crypto.sha256.convert(utf8.encode(encryptedPayload)).toString();

  /// Legacy prefix kept for matching rows written before the fingerprint
  /// scheme; MLS plaintexts cannot be re-derived (one-time keys), so old
  /// entries must keep matching rather than be invalidated wholesale.
  static String _legacyPayloadPrefix(String encryptedPayload) =>
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
