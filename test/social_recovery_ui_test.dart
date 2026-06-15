import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/conversation.dart';
import 'package:openchat/models/message.dart';
import 'package:openchat/providers/chat_provider.dart';
import 'package:openchat/providers/settings_provider.dart';
import 'package:openchat/screens/settings/social_recovery_screen.dart';
import 'package:openchat/screens/settings/trust_center_screen.dart';
import 'package:openchat/services/api_service.dart';
import 'package:openchat/services/app_lock_state.dart';
import 'package:openchat/services/message_cache_service.dart';
import 'package:openchat/services/message_search_service.dart';
import 'package:openchat/services/mls_service.dart';
import 'package:openchat/services/network_service.dart';
import 'package:openchat/services/offline_outbox_service.dart';
import 'package:openchat/services/secure_storage_service.dart';
import 'package:openchat/services/social_recovery_service.dart';
import 'package:openchat/services/websocket_service.dart';
import 'package:openchat/widgets/glass.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Social-recovery Trust Center UX: the guardian approve sheet must show the
/// verification code derived from the request's ephemeral pubkey (injectable
/// — PgpService cannot run in tests) and wire Approve to the service seam;
/// the whole recovery section must be invisible in a duress (decoy) session;
/// and the ceremony screen must progress live when a recovery 'share' event
/// arrives. Hermetic: every ApiService method touched is overridden, and no
/// bare Future.delayed runs inside testWidgets (FakeAsync would hang it).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const selfId = 'self-user';

  late SecureStorageService storage;
  late _FakeApi api;
  late WebSocketService ws;
  late ChatProvider provider;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'user_id': selfId});
    vaultModeListenable.value = VaultMode.real;
    storage = SecureStorageService();
    api = _FakeApi(storage);
  });

  tearDown(() {
    vaultModeListenable.value = VaultMode.real;
  });

  // ChatProvider (and its WS fake) must be constructed INSIDE the testWidgets
  // body: stream subscriptions capture the zone they are created in, and a
  // provider built in setUp delivers its events on the real event loop —
  // after the FakeAsync test body has already completed.
  void buildProvider() {
    ws = _FakeWs(storage);
    provider = ChatProvider(
      api,
      storage,
      ws,
      SettingsProvider(),
      MlsService(storage),
      NetworkService(),
      searchService: _NoopSearch(storage),
      cacheService: _NoopCache(storage),
      outboxService: _NoopOutbox(storage),
    );
    addTearDown(provider.dispose);
  }

  Widget wrap(Widget child) {
    return MaterialApp(
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider<ChatProvider>.value(value: provider),
          Provider<ApiService>.value(value: api),
          Provider<SecureStorageService>.value(value: storage),
        ],
        child: child,
      ),
    );
  }

  Future<void> pumpSection(WidgetTester tester) async {
    buildProvider();
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      wrap(
        const Scaffold(
          body: SingleChildScrollView(child: SocialRecoverySection()),
        ),
      ),
    );
    await tester.pump(); // post-frame -> _load
    await tester.pump(); // fake-api futures resolve
  }

  // ── (a) Guardian approve sheet ─────────────────────────────────────────────

  testWidgets('approve sheet shows the code from the request pubkey, the '
      'warning copy, and wires Approve to the service seam', (tester) async {
    var approveCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GuardianApproveSheet(
            requesterName: '@maya',
            ephemeralPubkeyArmored: 'EPHEMERAL-ARMOR',
            // PgpService cannot run in tests; the loader is injectable. This
            // fake still derives the code from the pubkey it was handed, so
            // the wiring (request pubkey -> code on screen) is what's tested.
            codeLoader: (armored) async => 'CODE:${armored.substring(0, 9)}',
            wordsLoader: (_) async => const [
              'aardvark',
              'adviser',
              'accrue',
              'aggregate',
              'adrift',
              'almighty',
            ],
            onApprove: () async {
              approveCalls++;
            },
          ),
        ),
      ),
    );
    await tester.pump(); // resolve the code future

    for (final word in const [
      'aardvark',
      'adviser',
      'accrue',
      'aggregate',
      'adrift',
      'almighty',
    ]) {
      expect(find.text(word), findsOneWidget);
    }
    expect(
      find.text('CODE:EPHEMERAL'),
      findsOneWidget,
      reason: 'the code shown must derive from the request ephemeral key',
    );
    expect(
      find.textContaining(
        'Only approve if you have verified these words or this code',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('Anyone with their password could be impersonating'),
      findsOneWidget,
    );
    expect(
      find.text(
        'I verified these words or this code with @maya over a call or in person',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('@maya'), findsWidgets);

    await tester.tap(find.text('Approve and send share'));
    await tester.pump();
    expect(
      approveCalls,
      0,
      reason: 'Approve must be gated until out-of-band verification is checked',
    );

    await tester.tap(find.byKey(const Key('guardian-verified-switch')));
    await tester.pump();
    await tester.tap(find.text('Approve and send share'));
    await tester.pump();
    expect(approveCalls, 1, reason: 'Approve must invoke the service call');
  });

  testWidgets('approve sheet starts with the verification gate off', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GuardianApproveSheet(
            requesterName: '@maya',
            ephemeralPubkeyArmored: 'EPHEMERAL-ARMOR',
            codeLoader: (_) async => 'AAAA-BBBB-CCCC',
            wordsLoader: (_) async => const [
              'aardvark',
              'adviser',
              'accrue',
              'aggregate',
              'adrift',
              'almighty',
            ],
            onApprove: () async {},
          ),
        ),
      ),
    );
    await tester.pump();

    final switchWidget = tester.widget<GlassSwitch>(
      find.byKey(const Key('guardian-verified-switch')),
    );
    expect(switchWidget.value, isFalse);
    expect(
      find.text(
        'I verified these words or this code with @maya over a call or in person',
      ),
      findsOneWidget,
    );
  });

  testWidgets('approve sheet warns on repeated recent recovery requests', (
    tester,
  ) async {
    Widget sheet({int recentRequestCount = 1}) => MaterialApp(
      home: Scaffold(
        body: GuardianApproveSheet(
          requesterName: '@maya',
          ephemeralPubkeyArmored: 'EPHEMERAL-ARMOR',
          recentRequestCount: recentRequestCount,
          codeLoader: (_) async => 'AAAA-BBBB-CCCC',
          wordsLoader: (_) async => const [
            'aardvark',
            'adviser',
            'accrue',
            'aggregate',
            'adrift',
            'almighty',
          ],
          onApprove: () async {},
        ),
      ),
    );

    await tester.pumpWidget(sheet(recentRequestCount: 3));
    await tester.pump();

    expect(
      find.textContaining(
        'This account has requested recovery 3 times in the last 24 hours',
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(sheet());
    await tester.pump();

    expect(
      find.byKey(const Key('guardian-recent-requests-warning')),
      findsNothing,
    );
  });

  testWidgets('approve sheet surfaces a StateError message verbatim and '
      'stays open', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GuardianApproveSheet(
            requesterName: '@maya',
            ephemeralPubkeyArmored: 'EPHEMERAL-ARMOR',
            codeLoader: (_) async => 'AAAA-BBBB-CCCC',
            wordsLoader: (_) async => const [
              'aardvark',
              'adviser',
              'accrue',
              'aggregate',
              'adrift',
              'almighty',
            ],
            onApprove: () async => throw StateError(
              'You hold no recovery share for this account on this device.',
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('guardian-verified-switch')));
    await tester.pump();
    await tester.tap(find.text('Approve and send share'));
    await tester.pump(); // submitting spinner
    await tester.pump(); // error lands

    expect(
      find.text('You hold no recovery share for this account on this device.'),
      findsOneWidget,
    );
    expect(
      find.text('Approve and send share'),
      findsOneWidget,
      reason: 'a failed approval must not dismiss the sheet',
    );
  });

  // ── (b) Decoy invisibility ─────────────────────────────────────────────────

  testWidgets('recovery section is invisible in a duress (decoy) session', (
    tester,
  ) async {
    vaultModeListenable.value = VaultMode.decoy;
    api.recoveryConfig = {
      'threshold': 2,
      'guardian_ids': ['g1', 'g2', 'g3'],
      'updated_at': DateTime.utc(2026, 6, 1).toIso8601String(),
    };
    await pumpSection(tester);

    expect(find.text('SOCIAL RECOVERY'), findsNothing);
    expect(find.text('YOU GUARD'), findsNothing);
    expect(find.text('Social recovery on'), findsNothing);
    expect(find.text('Set up social recovery'), findsNothing);
    expect(
      api.recoveryCalls,
      0,
      reason: 'a decoy session must not even fetch recovery state',
    );

    // Flipping back to a real unlock brings the section in.
    vaultModeListenable.value = VaultMode.real;
    await tester.pump();
    await tester.pump();
    expect(find.text('SOCIAL RECOVERY'), findsOneWidget);
  });

  testWidgets('real session renders config state, guarded accounts with '
      'held/missing shares, and pending ceremonies', (tester) async {
    api.recoveryConfig = null; // unconfigured
    api.guardedUsers = [
      {
        'user_id': 'friend-1',
        'user': {'username': 'maya'},
      },
      {
        'user_id': 'friend-2',
        'user': {'username': 'rio'},
      },
    ];
    // This device holds a share for friend-1 only (friend-2 simulates a
    // guardian reinstall without backup).
    await storage.saveHeldRecoveryShare(
      'friend-1',
      jsonEncode({'openchat_recovery_share': 1, 'owner_user_id': 'friend-1'}),
    );
    await pumpSection(tester);

    expect(find.text('SOCIAL RECOVERY'), findsOneWidget);
    expect(find.text('Social recovery off'), findsOneWidget);
    expect(find.text('Set up social recovery'), findsOneWidget);
    expect(find.text('YOU GUARD'), findsOneWidget);
    expect(find.text('@maya'), findsOneWidget);
    expect(find.text('Share held on this device'), findsOneWidget);
    expect(find.text('@rio'), findsOneWidget);
    expect(find.textContaining('Share missing on this device'), findsOneWidget);

    // A recovery_request WS event refreshes the pending list live.
    api.guardianRequests = [
      {
        'id': 'req-9',
        'user_id': 'friend-1',
        'ephemeral_pubkey': 'ARMOR',
        'user': {'username': 'maya'},
      },
    ];
    ws.handleRawFrame(
      jsonEncode({
        'type': 'recovery_request',
        'data': {'request_id': 'req-9', 'user_id': 'friend-1'},
      }),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('@maya is recovering'), findsOneWidget);
  });

  // ── (c) Ceremony screen live progress ──────────────────────────────────────

  testWidgets('ceremony screen progress updates when a recovery share event '
      'arrives, and Cancel completes the request', (tester) async {
    buildProvider();
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    api.recoveryRequestState = {
      'request': {'id': 'req-1', 'status': 'pending'},
      'threshold': 3,
      'encrypted_shares': <String>[],
    };
    const ceremony = RecoveryCeremony(
      requestId: 'req-1',
      ephemeralPrivateKey: 'EPHEMERAL-PRIVATE',
      ephemeralPublicKey: 'EPHEMERAL-PUBLIC',
      verificationCode: 'AAAA-BBBB-CCCC',
      verificationWords: [
        'aardvark',
        'adviser',
        'accrue',
        'aggregate',
        'adrift',
        'almighty',
      ],
    );

    await tester.pumpWidget(
      wrap(
        SocialRecoveryScreen(
          // startCeremony mints a PGP key on the native bridge — inject the
          // ceremony instead. The service below only ever reaches the
          // below-threshold early return of tryFinishCeremony (no PGP).
          service: SocialRecoveryService(storage: storage),
          initialCeremony: ceremony,
        ),
      ),
    );
    await tester.pump(); // post-frame -> _start
    await tester.pump(); // initial refresh resolves
    await tester.pump();

    expect(
      find.text('AAAA-BBBB-CCCC'),
      findsOneWidget,
      reason: 'the verification code must be displayed to read aloud',
    );
    for (final word in ceremony.verificationWords) {
      expect(find.text(word), findsOneWidget);
    }
    expect(find.text('0 of 3 shares received'), findsOneWidget);

    // A guardian submits a share: WS event + updated server state.
    api.recoveryRequestState = {
      'request': {'id': 'req-1', 'status': 'pending'},
      'threshold': 3,
      'encrypted_shares': <String>['encrypted-share-1'],
    };
    ws.handleRawFrame(
      jsonEncode({
        'type': 'recovery_share',
        'data': {'request_id': 'req-1', 'shares_submitted': 1},
      }),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(
      find.text('1 of 3 shares received'),
      findsOneWidget,
      reason: 'a share event must advance the threshold progress',
    );

    await tester.tap(find.text('Cancel ceremony'));
    await tester.pump();
    await tester.pump();

    expect(api.completeCalls, 1);
    expect(api.lastCompleteStatus, 'cancelled');

    // Dispose the screen so the 10s poll timer is cancelled cleanly.
    await tester.pumpWidget(const SizedBox());
  });
}

// ── Fakes (established pattern — see game_lobby_bubble_test.dart) ────────────

class _FakeApi extends ApiService {
  _FakeApi(super.storage);

  Map<String, dynamic>? recoveryConfig;
  List<Map<String, dynamic>> guardedUsers = [];
  List<Map<String, dynamic>> guardianRequests = [];
  Map<String, dynamic> recoveryRequestState = {};
  int recoveryCalls = 0;
  int completeCalls = 0;
  String? lastCompleteStatus;

  @override
  Future<List<Conversation>> listConversations() async => const [];

  @override
  Future<Map<String, dynamic>?> getRecoveryConfig() async {
    recoveryCalls++;
    return recoveryConfig == null
        ? null
        : Map<String, dynamic>.from(recoveryConfig!);
  }

  @override
  Future<List<Map<String, dynamic>>> listGuardedUsers() async => [
    for (final user in guardedUsers) Map<String, dynamic>.from(user),
  ];

  @override
  Future<List<Map<String, dynamic>>> listGuardianRecoveryRequests() async => [
    for (final req in guardianRequests) Map<String, dynamic>.from(req),
  ];

  @override
  Future<Map<String, dynamic>> getRecoveryRequest(String requestId) async =>
      Map<String, dynamic>.from(recoveryRequestState);

  @override
  Future<void> completeRecoveryRequest(
    String requestId, {
    required String status,
  }) async {
    completeCalls++;
    lastCompleteStatus = status;
  }
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
  Future<void> indexMessage(Message message, {String? conversationTitle}) =>
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
