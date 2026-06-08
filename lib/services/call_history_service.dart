import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'secure_storage_service.dart';

enum CallDirection { incoming, outgoing }

enum CallOutcomeKind { answered, missed, declined }

class CallHistoryEntry {
  final String id; // the call id (used as PK so a call is logged once)
  final String? conversationId;
  final String? peerUserId;
  final String? peerUsername;
  final bool isVideo;
  final CallDirection direction;
  final CallOutcomeKind outcome;
  final bool sfu;
  final DateTime startedAt;
  final int durationSecs;

  const CallHistoryEntry({
    required this.id,
    required this.conversationId,
    required this.peerUserId,
    required this.peerUsername,
    required this.isVideo,
    required this.direction,
    required this.outcome,
    required this.startedAt,
    this.sfu = false,
    this.durationSecs = 0,
  });

  bool get isMissed => outcome == CallOutcomeKind.missed;
}

/// Persists a per-device call log (who, direction, outcome, duration, time)
/// encrypted at rest — the server keeps no plaintext call log, matching the
/// app's metadata-minimisation model. Mirrors [MessageCacheService].
class CallHistoryService {
  final SecureStorageService _storage;
  final String? _databasePath;
  final Future<List<int>> Function()? _keyLoader;
  final _aes = AesGcm.with256bits();

  sqlite.Database? _db;
  Future<sqlite.Database>? _opening;
  SecretKey? _secretKey;
  List<int>? _keyBytes;

  CallHistoryService(
    SecureStorageService storage, {
    String? databasePath,
    Future<List<int>> Function()? keyLoader,
  }) : this._(storage, databasePath: databasePath, keyLoader: keyLoader);

  CallHistoryService._(this._storage, {this._databasePath, this._keyLoader});

  Future<void> record(CallHistoryEntry e) async {
    if (kIsWeb) return;
    try {
      final db = await _open();
      final data = await _encrypt({
        'peer_user_id': e.peerUserId ?? '',
        'peer_username': e.peerUsername ?? '',
        'is_video': e.isVideo,
        'direction': e.direction.name,
        'outcome': e.outcome.name,
        'sfu': e.sfu,
        'duration_secs': e.durationSecs,
      });
      final stmt = db.prepare('''
        INSERT INTO call_history (id, conversation_id, data, started_at_ms)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          conversation_id = excluded.conversation_id,
          data            = excluded.data,
          started_at_ms   = excluded.started_at_ms
      ''');
      try {
        stmt.execute([
          e.id,
          e.conversationId ?? '',
          data,
          e.startedAt.toUtc().millisecondsSinceEpoch,
        ]);
      } finally {
        stmt.close();
      }
    } catch (_) {}
  }

  Future<List<CallHistoryEntry>> list({int limit = 200}) async {
    if (kIsWeb) return const [];
    try {
      final db = await _open();
      final rows = db.select(
        'SELECT id, conversation_id, data, started_at_ms '
        'FROM call_history ORDER BY started_at_ms DESC LIMIT ?',
        [limit],
      );
      final out = <CallHistoryEntry>[];
      for (final row in rows) {
        final data = await _decrypt(row['data'] as String);
        if (data == null) continue;
        final convId = row['conversation_id'] as String? ?? '';
        out.add(CallHistoryEntry(
          id: row['id'] as String,
          conversationId: convId.isEmpty ? null : convId,
          peerUserId: _nullable(data['peer_user_id']),
          peerUsername: _nullable(data['peer_username']),
          isVideo: data['is_video'] == true,
          direction: _direction(data['direction']),
          outcome: _outcome(data['outcome']),
          sfu: data['sfu'] == true,
          startedAt: DateTime.fromMillisecondsSinceEpoch(
            row['started_at_ms'] as int,
            isUtc: true,
          ).toLocal(),
          durationSecs: (data['duration_secs'] as num?)?.toInt() ?? 0,
        ));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<void> clear() async {
    if (kIsWeb) return;
    try {
      final db = await _open();
      db.execute('DELETE FROM call_history');
    } catch (_) {}
  }

  static String? _nullable(Object? v) {
    final s = v as String?;
    return (s == null || s.isEmpty) ? null : s;
  }

  static CallDirection _direction(Object? v) =>
      v == 'incoming' ? CallDirection.incoming : CallDirection.outgoing;

  static CallOutcomeKind _outcome(Object? v) => switch (v) {
        'answered' => CallOutcomeKind.answered,
        'declined' => CallOutcomeKind.declined,
        _ => CallOutcomeKind.missed,
      };

  Future<sqlite.Database> _open() {
    final existing = _db;
    if (existing != null) return Future.value(existing);
    return _opening ??= _openDatabase();
  }

  Future<sqlite.Database> _openDatabase() async {
    final path = _databasePath ?? await _defaultDatabasePath();
    final db = sqlite.sqlite3.open(path);
    db.execute('''
      CREATE TABLE IF NOT EXISTS call_history (
        id              TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL,
        data            TEXT NOT NULL,
        started_at_ms   INTEGER NOT NULL
      )
    ''');
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_call_history_time ON call_history (started_at_ms DESC)',
    );
    _db = db;
    return db;
  }

  Future<String> _defaultDatabasePath() async {
    final dir = await getApplicationSupportDirectory();
    return p.join(dir.path, 'call_history.db');
  }

  Future<String> _encrypt(Map<String, Object?> json) async {
    final key = await _secret();
    final box = await _aes.encrypt(utf8.encode(jsonEncode(json)), secretKey: key);
    return base64Encode(box.concatenation());
  }

  Future<Map<String, dynamic>?> _decrypt(String encoded) async {
    try {
      final key = await _secret();
      final box = SecretBox.fromConcatenation(
        base64Decode(encoded),
        nonceLength: _aes.nonceLength,
        macLength: _aes.macAlgorithm.macLength,
      );
      final bytes = await _aes.decrypt(box, secretKey: key);
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return decoded.map((k, v) => MapEntry(k.toString(), v));
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
      throw StateError('call history key must be 32 bytes');
    }
    _keyBytes = List<int>.unmodifiable(bytes);
    return _keyBytes!;
  }
}
