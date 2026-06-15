import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/conversation.dart';
import 'package:openchat/models/key_transparency_event.dart';
import 'package:openchat/models/user.dart';
import 'package:openchat/providers/auth_provider.dart';
import 'package:openchat/providers/chat_provider.dart';
import 'package:openchat/providers/key_provider.dart';
import 'package:openchat/providers/settings_provider.dart';
import 'package:openchat/screens/settings/trust_center_screen.dart';
import 'package:openchat/services/api_service.dart';
import 'package:openchat/services/app_lock_state.dart';
import 'package:openchat/services/message_cache_service.dart';
import 'package:openchat/services/message_search_service.dart';
import 'package:openchat/services/mls_service.dart';
import 'package:openchat/services/network_service.dart';
import 'package:openchat/services/offline_outbox_service.dart';
import 'package:openchat/services/secure_storage_service.dart';
import 'package:openchat/services/websocket_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    vaultModeListenable.value = VaultMode.real;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/local_auth'),
          (call) async => switch (call.method) {
            'getAvailableBiometrics' => <String>[],
            'isDeviceSupported' => false,
            _ => null,
          },
        );
  });

  tearDown(() {
    vaultModeListenable.value = VaultMode.real;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/local_auth'),
          null,
        );
  });

  testWidgets('dead-man and PIN status rows are hidden in decoy mode', (
    tester,
  ) async {
    final storage = SecureStorageService();
    final api = _FakeApi(storage);
    final settings = SettingsProvider();
    final chat = ChatProvider(
      api,
      storage,
      _FakeWs(storage),
      settings,
      MlsService(storage),
      NetworkService(),
      searchService: _NoopSearch(storage),
      cacheService: _NoopCache(storage),
      outboxService: _NoopOutbox(storage),
    );
    addTearDown(chat.dispose);

    await storage.setAppLockPin('123456');
    await storage.setDuressPin('999999');
    await storage.setDuressAction('wipe');
    expect(await storage.hasAppLockPin(), isTrue);
    expect(await storage.hasDuressPin(), isTrue);
    await const FlutterSecureStorage().write(
      key: 'deadman_days_v1',
      value: '7',
    );
    await const FlutterSecureStorage().write(
      key: 'last_real_unlock_at_v1',
      value: DateTime.now()
          .toUtc()
          .subtract(const Duration(days: 2))
          .millisecondsSinceEpoch
          .toString(),
    );

    tester.view.physicalSize = const Size(900, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<SecureStorageService>.value(value: storage),
          Provider<ApiService>.value(value: api),
          ChangeNotifierProvider<AuthProvider>.value(
            value: _FakeAuthProvider(_user(), api, storage),
          ),
          ChangeNotifierProvider<KeyProvider>.value(
            value: KeyProvider(storage),
          ),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<ChatProvider>.value(value: chat),
        ],
        child: const MaterialApp(home: TrustCenterScreen()),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    await tester.dragUntilVisible(
      find.text('Auto-wipe'),
      find.byType(ListView),
      const Offset(0, -500),
    );
    await tester.pump();

    expect(find.text('Auto-wipe'), findsOneWidget);
    expect(find.textContaining('Local data wipes'), findsOneWidget);
    expect(find.text('App lock PIN'), findsOneWidget);
    expect(find.text('Duress PIN'), findsOneWidget);

    vaultModeListenable.value = VaultMode.decoy;
    await tester.pump();

    expect(find.text('Auto-wipe'), findsNothing);
    expect(find.text('App lock PIN'), findsNothing);
    expect(find.text('Duress PIN'), findsNothing);
  });
}

class _FakeApi extends ApiService {
  _FakeApi(super.storage);

  @override
  Future<List<Conversation>> listConversations() async => const [];

  @override
  Future<Map<String, dynamic>> getSecuritySettings() async => {
    'two_factor_enabled': false,
    'account_self_destruct_days': 0,
  };

  @override
  Future<List<Map<String, dynamic>>> listSessions() async => const [];

  @override
  Future<Map<String, dynamic>?> getLatestBackup() async => null;

  @override
  Future<List<KeyTransparencyEvent>> getKeyTransparencyEvents(
    String userId,
  ) async => const [];
}

class _FakeAuthProvider extends AuthProvider {
  _FakeAuthProvider(this._user, ApiService api, SecureStorageService storage)
    : super(api, storage);

  final User _user;

  @override
  User? get currentUser => _user;
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
  ) => Future.value();
}

class _NoopOutbox extends OfflineOutboxService {
  _NoopOutbox(super.storage);

  @override
  Future<List<OfflineOutboxItem>> list() => Future.value(const []);
}

User _user() => User(
  id: 'self-user',
  username: 'maya',
  publicKey: 'PUBLIC',
  keyFingerprint: 'FINGERPRINT',
  createdAt: DateTime.utc(2026, 6, 1),
);
