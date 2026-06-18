import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/story.dart';
import 'package:openchat/models/user.dart';
import 'package:openchat/providers/auth_provider.dart';
import 'package:openchat/services/api_service.dart';
import 'package:openchat/services/secure_storage_service.dart';
import 'package:openchat/widgets/stories_strip.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SecureStorageService storage;
  late _FakeApi api;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    storage = SecureStorageService();
    api = _FakeApi(storage);
  });

  Widget wrap() => MaterialApp(
    home: Scaffold(
      body: MultiProvider(
        providers: [
          Provider<ApiService>.value(value: api),
          ChangeNotifierProvider<AuthProvider>.value(
            value: _FakeAuthProvider(_user('me', 'me'), api, storage),
          ),
          Provider<SecureStorageService>.value(value: storage),
        ],
        child: const StoriesStrip(),
      ),
    ),
  );

  testWidgets('several posts by one author collapse into a single ring', (
    tester,
  ) async {
    // Two posts from the same user — historically rendered as two tiles.
    api.stories = [
      _post('p2', 'other', minutesAgo: 1),
      _post('p1', 'other', minutesAgo: 10),
    ];

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    // One author ring (not one per post), plus the "Your story" add tile.
    expect(find.text('@other'), findsOneWidget);
    expect(find.text('Your story'), findsOneWidget);
  });

  testWidgets('distinct authors each get their own ring', (tester) async {
    api.stories = [
      _post('a1', 'alice', minutesAgo: 1),
      _post('b1', 'bob', minutesAgo: 2),
      _post('a2', 'alice', minutesAgo: 3),
    ];

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.text('@alice'), findsOneWidget);
    expect(find.text('@bob'), findsOneWidget);
  });
}

class _FakeApi extends ApiService {
  _FakeApi(super.storage);

  List<Story> stories = const [];

  @override
  Future<List<Story>> getStories({
    bool archive = false,
    bool pinned = false,
    String? userId,
    String? conversationId,
    int limit = 100,
  }) async => stories;
}

class _FakeAuthProvider extends AuthProvider {
  _FakeAuthProvider(this._user, ApiService api, SecureStorageService storage)
    : super(api, storage);

  final User _user;

  @override
  User? get currentUser => _user;
}

Story _post(String id, String userId, {required int minutesAgo}) {
  final created = DateTime.now().subtract(Duration(minutes: minutesAgo));
  return Story(
    id: id,
    userId: userId,
    caption: 'cap-$id',
    mediaType: 'text',
    user: _user(userId, userId),
    expiresAt: DateTime.now().add(const Duration(hours: 5)),
    createdAt: created,
    updatedAt: created,
  );
}

User _user(String id, String username) => User(
  id: id,
  username: username,
  publicKey: '',
  keyFingerprint: '',
  createdAt: DateTime.utc(2026, 6, 15),
);
