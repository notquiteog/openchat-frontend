import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/crypto/pgp_service.dart';
import 'package:openchat/models/conversation.dart';
import 'package:openchat/providers/chat_provider.dart';
import 'package:openchat/providers/settings_provider.dart';
import 'package:openchat/services/api_service.dart';
import 'package:openchat/services/app_lock_state.dart';
import 'package:openchat/services/message_cache_service.dart';
import 'package:openchat/services/message_search_service.dart';
import 'package:openchat/services/mls_service.dart';
import 'package:openchat/services/offline_outbox_service.dart';
import 'package:openchat/services/secure_storage_service.dart';
import 'package:openchat/services/websocket_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Lock & wipe cluster: PIN classification (real vs duress, never
/// distinguishable by error), dead-man bookkeeping, backup exclusion of lock
/// policy, vault filtering of hidden conversations in decoy sessions, and the
/// remote-wipe canonical signing string.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    vaultModeListenable.value = VaultMode.real;
  });

  tearDown(() {
    vaultModeListenable.value = VaultMode.real;
  });

  group('app-lock PIN classification', () {
    test('classifies real, duress, and wrong PINs', () async {
      final storage = SecureStorageService();
      await storage.setAppLockPin('123456');
      await storage.setDuressPin('999999');

      expect(await storage.classifyAppLockPin('123456'), AppLockPinKind.real);
      expect(await storage.classifyAppLockPin('999999'), AppLockPinKind.duress);
      expect(
        await storage.classifyAppLockPin('000000'),
        AppLockPinKind.invalid,
      );
    });

    test('no duress PIN configured → only real and invalid', () async {
      final storage = SecureStorageService();
      await storage.setAppLockPin('123456');

      expect(await storage.classifyAppLockPin('123456'), AppLockPinKind.real);
      expect(
        await storage.classifyAppLockPin('999999'),
        AppLockPinKind.invalid,
      );
    });

    test('duress action defaults to decoy and round-trips', () async {
      final storage = SecureStorageService();
      expect(await storage.getDuressAction(), 'decoy');
      await storage.setDuressAction('wipe');
      expect(await storage.getDuressAction(), 'wipe');
    });

    test('PINs are stored salted-hashed, never plaintext', () async {
      final storage = SecureStorageService();
      await storage.setAppLockPin('123456');
      final all = await const FlutterSecureStorage().readAll();
      final record = all['app_lock_pin_v1']!;
      expect(record, isNot(contains('123456')));
      expect(record, contains(':')); // salt:hash shape
    });
  });

  group('dead-man bookkeeping', () {
    test('days setting and unlock timestamp round-trip', () async {
      final storage = SecureStorageService();
      expect(await storage.getDeadmanDays(), 0);
      await storage.setDeadmanDays(30);
      expect(await storage.getDeadmanDays(), 30);

      expect(await storage.getLastRealUnlockAt(), isNull);
      await storage.recordRealUnlock();
      final recorded = await storage.getLastRealUnlockAt();
      expect(recorded, isNotNull);
      expect(
        DateTime.now().toUtc().difference(recorded!).inSeconds.abs() < 10,
        isTrue,
      );
    });
  });

  group('backup exclusion of device-local lock policy', () {
    test('recovery export never carries PINs, duress config, or timers',
        () async {
      final storage = SecureStorageService();
      await storage.setAppLockPin('123456');
      await storage.setDuressPin('999999');
      await storage.setDuressAction('wipe');
      await storage.setDeadmanDays(30);
      await storage.recordRealUnlock();

      final exported = await storage.exportRecoverySecrets();
      expect(exported.keys, isNot(contains('app_lock_pin_v1')));
      expect(exported.keys, isNot(contains('app_lock_duress_pin_v1')));
      expect(exported.keys, isNot(contains('app_lock_duress_action_v1')));
      expect(exported.keys, isNot(contains('deadman_days_v1')));
      expect(exported.keys, isNot(contains('last_real_unlock_at_v1')));
    });
  });

  group('remote wipe canonical data', () {
    test('is stable and case-normalises the session id', () {
      expect(
        PgpService.deviceWipeSignedData(
          sessionId: 'ABC-123',
          issuedAt: '2026-06-10T12:00:00Z',
        ),
        'openchat-device-wipe:v1:abc-123:2026-06-10T12:00:00Z',
      );
    });
  });

  group('vault filtering', () {
    late ChatProvider provider;
    late SettingsProvider settings;

    Conversation conv(String id) => Conversation(
      id: id,
      type: ConversationType.dm,
      createdAt: DateTime.utc(2026, 6, 1),
      createdBy: 'self',
    );

    setUp(() async {
      final storage = SecureStorageService();
      settings = SettingsProvider();
      provider = ChatProvider(
        _FakeApi(storage),
        storage,
        _FakeWs(storage),
        settings,
        MlsService(storage),
        searchService: _NoopSearch(storage),
        cacheService: _NoopCache(storage),
        outboxService: _NoopOutbox(storage),
      );
      await Future<void>.delayed(Duration.zero);
      provider.debugSeedConversation(conv('visible-1'));
      provider.debugSeedConversation(conv('secret-1'));
      await settings.setConversationHidden('secret-1', true);
    });

    tearDown(() => provider.dispose());

    test('real sessions see hidden conversations', () {
      vaultModeListenable.value = VaultMode.real;
      expect(
        provider.conversations.map((c) => c.id),
        containsAll(['visible-1', 'secret-1']),
      );
      expect(provider.isConversationVisibleInVault('secret-1'), isTrue);
    });

    test('decoy sessions filter hidden conversations everywhere', () {
      vaultModeListenable.value = VaultMode.decoy;
      final ids = provider.conversations.map((c) => c.id).toList();
      expect(ids, contains('visible-1'));
      expect(ids, isNot(contains('secret-1')));
      expect(provider.isConversationVisibleInVault('secret-1'), isFalse);
      expect(
        provider.isConversationVisibleInVault('visible-1'),
        isTrue,
      );
    });

    test('flipping vault mode notifies listeners', () {
      var notified = 0;
      provider.addListener(() => notified++);
      vaultModeListenable.value = VaultMode.decoy;
      expect(notified, greaterThan(0));
    });
  });
}

// ── Fakes (mirroring test/mls_sent_message_cache_test.dart) ─────────────────

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
  Future<void> indexMessage(message, {String? conversationTitle}) =>
      Future.value();
}

class _NoopCache extends MessageCacheService {
  _NoopCache(super.storage);

  @override
  Future<MessageCacheEntry?> get(String messageId, String encryptedPayload) =>
      Future.value(null);

  @override
  Future<void> put(
    String messageId,
    String conversationId,
    String encryptedPayload,
    String plaintext,
    String? senderId,
  ) =>
      Future.value();
}

class _NoopOutbox extends OfflineOutboxService {
  _NoopOutbox(super.storage);

  @override
  Future<List<OfflineOutboxItem>> list() => Future.value(const []);
}
