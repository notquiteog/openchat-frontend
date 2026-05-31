import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

/// SQLite-backed local cache for remote users' public keys.
///
/// Reduces network round-trips when encrypting to large groups: key fetches
/// hit the server only on the first use and after the 24-hour TTL expires.
/// Invalidate manually after a key-rotation event.
class KeyCacheService {
  static const _ttl = Duration(hours: 24);
  static Database? _db;

  static Future<Database> _open() async {
    _db ??= await openDatabase(
      p.join(await getDatabasesPath(), 'key_cache.db'),
      version: 2,
      onCreate: (db, _) => db.execute('''
        CREATE TABLE key_cache (
          user_id        TEXT PRIMARY KEY,
          public_key     TEXT NOT NULL,
          fingerprint    TEXT NOT NULL,
          expires_at_ms  INTEGER,
          cached_at      INTEGER NOT NULL
        )
      '''),
      onUpgrade: (db, oldVersion, _) async {
        if (oldVersion < 2) {
          await db.execute(
              'ALTER TABLE key_cache ADD COLUMN expires_at_ms INTEGER');
        }
      },
    );
    return _db!;
  }

  /// Returns the cached entry for [userId], or null if missing, expired by
  /// TTL, or — when [excludeExpiredKeys] is true — the cached key itself has
  /// passed its PGP expiry. Callers encrypting outbound messages should
  /// always pass excludeExpiredKeys: true so they never address a recipient
  /// who can't decrypt.
  static Future<CachedKey?> get(String userId,
      {bool excludeExpiredKeys = true}) async {
    final db = await _open();
    final rows = await db.query(
      'key_cache',
      columns: ['public_key', 'fingerprint', 'expires_at_ms', 'cached_at'],
      where: 'user_id = ?',
      whereArgs: [userId],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final cachedAt = DateTime.fromMillisecondsSinceEpoch(row['cached_at'] as int);
    if (DateTime.now().difference(cachedAt) > _ttl) {
      await db.delete('key_cache', where: 'user_id = ?', whereArgs: [userId]);
      return null;
    }
    DateTime? expiresAt;
    final expMs = row['expires_at_ms'] as int?;
    if (expMs != null) {
      expiresAt = DateTime.fromMillisecondsSinceEpoch(expMs);
      if (excludeExpiredKeys && !DateTime.now().isBefore(expiresAt)) {
        // Key is expired — surface a null so the caller drops this recipient.
        return null;
      }
    }
    return CachedKey(
      publicKey: row['public_key'] as String,
      fingerprint: row['fingerprint'] as String,
      expiresAt: expiresAt,
    );
  }

  /// Back-compat: legacy callers that want just the armored key bytes.
  static Future<String?> getPublicKey(String userId) async {
    final entry = await get(userId);
    return entry?.publicKey;
  }

  static Future<void> put(
    String userId,
    String publicKey,
    String fingerprint, {
    DateTime? expiresAt,
  }) async {
    final db = await _open();
    await db.insert(
      'key_cache',
      {
        'user_id': userId,
        'public_key': publicKey,
        'fingerprint': fingerprint,
        'expires_at_ms': expiresAt?.millisecondsSinceEpoch,
        'cached_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Remove a single entry — call after a contact's key rotation is detected.
  static Future<void> invalidate(String userId) async {
    final db = await _open();
    await db.delete('key_cache', where: 'user_id = ?', whereArgs: [userId]);
  }

  static Future<void> clear() async {
    final db = await _open();
    await db.delete('key_cache');
  }
}

class CachedKey {
  final String publicKey;
  final String fingerprint;
  final DateTime? expiresAt;

  const CachedKey({
    required this.publicKey,
    required this.fingerprint,
    this.expiresAt,
  });

  bool get isExpired =>
      expiresAt != null && !DateTime.now().isBefore(expiresAt!);
}
