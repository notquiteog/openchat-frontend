import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/providers/auth_provider.dart';
import 'package:openchat/providers/chat_provider.dart';
import 'package:openchat/providers/settings_provider.dart';
import 'package:openchat/services/api_service.dart';
import 'package:openchat/services/call_history_service.dart';
import 'package:openchat/services/local_private_state_service.dart';
import 'package:openchat/services/message_cache_service.dart';
import 'package:openchat/services/message_search_service.dart';
import 'package:openchat/services/mls_service.dart';
import 'package:openchat/services/network_service.dart';
import 'package:openchat/services/offline_outbox_service.dart';
import 'package:openchat/services/secure_storage_service.dart';
import 'package:openchat/services/websocket_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// Regression suite for cross-account plaintext residue at logout.
///
/// The message cache, call history DB, and encrypted private local state
/// (drafts, folders, private contacts) are device-global stores: none of
/// them is keyed by account, so logging out MUST wipe all three or the next
/// account logging in on this device inherits the previous account's
/// decrypted MLS plaintext, call log, and drafts.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<List<int>> testKey() async => List<int>.generate(32, (index) => index);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({
      'user_id': 'user-a',
      'username': 'alice',
      'access_token': 'token-a',
      'refresh_token': 'refresh-a',
    });
  });

  group('MessageCacheService.clearAll', () {
    test('wipes cached plaintext and rotates the at-rest key', () async {
      final storage = SecureStorageService();
      // No keyLoader: exercise the real key path so the wipe's key rotation
      // is observable through secure storage.
      final cache = MessageCacheService(storage, databasePath: ':memory:');

      await cache.put('msg-1', 'conv-1', 'cipher-1', 'previous secret', 'a');
      expect(
        (await cache.get('msg-1', 'cipher-1'))?.plaintext,
        'previous secret',
      );
      final keyBefore = await storage.getOrCreateMessageCacheKey();

      await cache.clearAll();

      expect(
        await cache.get('msg-1', 'cipher-1'),
        isNull,
        reason:
            'the next account must never get cache hits on the previous '
            "account's decrypted MLS plaintext",
      );
      final keyAfter = await storage.getOrCreateMessageCacheKey();
      expect(
        keyAfter,
        isNot(keyBefore),
        reason:
            'the at-rest key must be deleted so residual sqlite pages '
            'become undecryptable garbage',
      );

      // The cache must stay usable for the next account, under the new key.
      await cache.put('msg-2', 'conv-2', 'cipher-2', 'next account text', 'b');
      expect(
        (await cache.get('msg-2', 'cipher-2'))?.plaintext,
        'next account text',
      );
    });

    test(
      'a transient open failure does not disable the cache forever',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'openchat_cache_test_',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final dbPath = p.join(tempDir.path, 'missing', 'message_cache.db');
        final cache = MessageCacheService(
          SecureStorageService(),
          databasePath: dbPath,
          keyLoader: testKey,
        );

        // Parent directory missing: the open fails. Before the fix the failed
        // future stayed cached in _opening, poisoning every later call.
        await cache.put('msg-1', 'conv-1', 'cipher-1', 'text', null);
        expect(await cache.get('msg-1', 'cipher-1'), isNull);

        await Directory(p.dirname(dbPath)).create(recursive: true);

        await cache.put('msg-1', 'conv-1', 'cipher-1', 'text', null);
        expect(
          (await cache.get('msg-1', 'cipher-1'))?.plaintext,
          'text',
          reason:
              'the cache must recover once the transient failure clears, '
              'not stay broken until app restart',
        );
      },
    );
  });

  test(
    'AuthProvider.logout wipes call history and private local state',
    () async {
      final storage = SecureStorageService();
      final callHistory = CallHistoryService(
        storage,
        databasePath: ':memory:',
        keyLoader: testKey,
      );
      await callHistory.record(
        CallHistoryEntry(
          id: 'call-1',
          conversationId: 'conv-1',
          peerUserId: 'peer-1',
          peerUsername: 'bob',
          isVideo: false,
          direction: CallDirection.outgoing,
          outcome: CallOutcomeKind.answered,
          startedAt: DateTime.utc(2026, 6, 1),
          durationSecs: 42,
        ),
      );
      expect(await callHistory.list(), hasLength(1));

      final privateState = LocalPrivateStateService(
        storage: storage,
        keyLoader: testKey,
      );
      await privateState.writeState({
        privateStateMessageDraftsKey: {
          'conv-1': {'text': 'unsent draft'},
        },
      });
      expect(await privateState.hasState(), isTrue);

      final auth = AuthProvider(
        ApiService(storage),
        storage,
        callHistoryService: callHistory,
        localPrivateStateService: privateState,
      );
      await auth.logout();

      expect(
        await callHistory.list(),
        isEmpty,
        reason:
            'call log rows are not user-scoped — the next account must '
            'not inherit them',
      );
      expect(
        await privateState.hasState(),
        isFalse,
        reason:
            'drafts and private local state belong to the account that '
            'logged out',
      );
      expect(await storage.isLoggedIn(), isFalse);
      expect(auth.state, AuthState.unauthenticated);
    },
  );

  test('ChatProvider.clearState wipes the decrypted-message cache', () async {
    final storage = SecureStorageService();
    final cache = _WipeRecordingCache(storage);
    final provider = ChatProvider(
      _FakeApi(storage),
      storage,
      _FakeWs(storage),
      SettingsProvider(),
      MlsService(storage),
      NetworkService(),
      searchService: _NoopSearch(storage),
      cacheService: cache,
      outboxService: _NoopOutbox(storage),
    );
    addTearDown(provider.dispose);
    // Let the constructor's async identity load settle.
    await Future<void>.delayed(Duration.zero);

    provider.clearState();
    // clearState fires the wipe unawaited; let it land.
    await Future<void>.delayed(Duration.zero);

    expect(
      cache.cleared,
      isTrue,
      reason:
          'logout must wipe the device-global message_cache.db or the '
          "next account gets cache hits on this account's plaintext",
    );
  });
}

// ── Fakes ────────────────────────────────────────────────────────────────────

class _WipeRecordingCache extends MessageCacheService {
  _WipeRecordingCache(super.storage);

  bool cleared = false;

  @override
  Future<void> clearAll() async {
    cleared = true;
  }
}

class _FakeApi extends ApiService {
  _FakeApi(super.storage);
}

class _FakeWs extends WebSocketService {
  _FakeWs(super.storage);

  @override
  Future<void> connect() async {}

  @override
  void disconnect() {}
}

class _NoopSearch extends MessageSearchService {
  _NoopSearch(super.storage);

  @override
  Future<void> clearAll() => Future.value();
}

class _NoopOutbox extends OfflineOutboxService {
  _NoopOutbox(super.storage);

  @override
  Future<List<OfflineOutboxItem>> list() => Future.value(const []);

  @override
  Future<void> clearAll() => Future.value();
}
