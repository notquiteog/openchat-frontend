import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// SQLite-backed local cache for remote users' public keys.
///
/// Reduces network round-trips when encrypting to large groups: key fetches
/// hit the server only on the first use and after the 24-hour TTL expires.
/// Invalidate manually after a key-rotation event.
class KeyCacheService {
  static const _ttl = Duration(hours: 24);
  static sqlite.Database? _db;
  static Future<sqlite.Database>? _opening;

  static Future<sqlite.Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;

    final inFlight = _opening;
    if (inFlight != null) return inFlight;

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

  static Future<sqlite.Database> _openDatabase() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    final db = sqlite.sqlite3.open(p.join(dir.path, 'key_cache.db'));
    _migrate(db);
    return db;
  }

  static void _migrate(sqlite.Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS key_cache (
        user_id        TEXT PRIMARY KEY,
        public_key     TEXT NOT NULL,
        fingerprint    TEXT NOT NULL,
        expires_at_ms  INTEGER,
        cached_at      INTEGER NOT NULL
      )
    ''');

    final columns = db
        .select('PRAGMA table_info(key_cache)')
        .map((row) => row['name'] as String)
        .toSet();
    if (!columns.contains('expires_at_ms')) {
      db.execute('ALTER TABLE key_cache ADD COLUMN expires_at_ms INTEGER');
    }
    db.execute('PRAGMA user_version = 2');
  }

  /// Returns the cached entry for [userId], or null if missing, expired by
  /// TTL, or — when [excludeExpiredKeys] is true — the cached key itself has
  /// passed its PGP expiry. Callers encrypting outbound messages should
  /// always pass excludeExpiredKeys: true so they never address a recipient
  /// who can't decrypt. Pass [maxAge] to additionally require the entry to
  /// have been fetched recently (used by the send path's freshness window).
  static Future<CachedKey?> get(
    String userId, {
    bool excludeExpiredKeys = true,
    Duration? maxAge,
  }) async {
    final db = await _open();
    final stmt = db.prepare('''
      SELECT public_key, fingerprint, expires_at_ms, cached_at
      FROM key_cache
      WHERE user_id = ?
      LIMIT 1
    ''');
    final rows = stmt.select([userId]);
    stmt.close();
    if (rows.isEmpty) return null;
    final row = rows.first;
    final cachedAt = DateTime.fromMillisecondsSinceEpoch(
      row['cached_at'] as int,
    );
    if (DateTime.now().difference(cachedAt) > _ttl) {
      _delete(db, userId);
      return null;
    }
    if (maxAge != null && DateTime.now().difference(cachedAt) > maxAge) {
      // Still valid by TTL but not fresh enough for this caller — keep it.
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

  static Future<void> put(
    String userId,
    String publicKey,
    String fingerprint, {
    DateTime? expiresAt,
  }) async {
    final db = await _open();
    final stmt = db.prepare('''
      INSERT INTO key_cache (
        user_id, public_key, fingerprint, expires_at_ms, cached_at
      ) VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(user_id) DO UPDATE SET
        public_key = excluded.public_key,
        fingerprint = excluded.fingerprint,
        expires_at_ms = excluded.expires_at_ms,
        cached_at = excluded.cached_at
    ''');
    stmt.execute([
      userId,
      publicKey,
      fingerprint,
      expiresAt?.millisecondsSinceEpoch,
      DateTime.now().millisecondsSinceEpoch,
    ]);
    stmt.close();
  }

  /// Remove a single entry — call after a contact's key rotation is detected.
  static Future<void> invalidate(String userId) async {
    final db = await _open();
    _delete(db, userId);
  }

  static Future<void> clear() async {
    final db = await _open();
    db.execute('DELETE FROM key_cache');
  }

  static void _delete(sqlite.Database db, String userId) {
    final stmt = db.prepare('DELETE FROM key_cache WHERE user_id = ?');
    stmt.execute([userId]);
    stmt.close();
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
