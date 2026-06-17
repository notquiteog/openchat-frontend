import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/story.dart';
import 'package:openchat/models/user.dart';
import 'package:openchat/providers/auth_provider.dart';
import 'package:openchat/screens/stories/my_stories_screen.dart';
import 'package:openchat/services/api_service.dart';
import 'package:openchat/services/secure_storage_service.dart';
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

  Widget wrap() {
    return MaterialApp(
      home: MultiProvider(
        providers: [
          Provider<ApiService>.value(value: api),
          ChangeNotifierProvider<AuthProvider>.value(
            value: _FakeAuthProvider(_user('me', 'me'), api, storage),
          ),
          Provider<SecureStorageService>.value(value: storage),
        ],
        child: const MyStoriesScreen(),
      ),
    );
  }

  testWidgets('partitions active vs archived and sums aggregate totals', (
    tester,
  ) async {
    api.stories = [
      _story('a1', views: 5, reactions: 2),
      _story('a2', views: 3, reactions: 0),
      _story('arch', views: 10, reactions: 4, archived: true),
    ];

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.text('Active'), findsOneWidget);
    expect(find.text('Archived & expired'), findsOneWidget);
    // Aggregate header sums across every story.
    expect(find.text('18 views'), findsOneWidget);
    expect(find.text('6 reactions'), findsOneWidget);
  });

  testWidgets('manage sheet pins a story via the API', (tester) async {
    api.stories = [_story('a1', views: 1, reactions: 0)];

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('story-row-manage')));
    await tester.pumpAndSettle();

    expect(find.text('Manage story'), findsOneWidget);
    expect(find.text('Pin to profile'), findsOneWidget);

    await tester.tap(find.text('Pin to profile'));
    await tester.pumpAndSettle();

    expect(api.lastPinId, 'a1');
    expect(api.lastPinValue, true);
  });
}

class _FakeApi extends ApiService {
  _FakeApi(super.storage);

  List<Story> stories = const [];
  String? lastPinId;
  bool? lastPinValue;
  String? lastDeleteId;

  @override
  Future<List<Story>> getStories({
    bool archive = false,
    bool pinned = false,
    String? userId,
    String? conversationId,
    int limit = 100,
  }) async {
    return stories;
  }

  @override
  Future<Story> pinStory(String storyId, bool pinned) async {
    lastPinId = storyId;
    lastPinValue = pinned;
    return stories.firstWhere((s) => s.id == storyId);
  }

  @override
  Future<void> deleteStory(String storyId) async {
    lastDeleteId = storyId;
    stories = stories.where((s) => s.id != storyId).toList();
  }
}

class _FakeAuthProvider extends AuthProvider {
  _FakeAuthProvider(this._user, ApiService api, SecureStorageService storage)
    : super(api, storage);

  final User _user;

  @override
  User? get currentUser => _user;
}

Story _story(
  String id, {
  required int views,
  required int reactions,
  bool archived = false,
}) {
  final created = DateTime.utc(2026, 6, 15, 12);
  // Active stories must expire in the future relative to the real wall clock,
  // since the screen partitions active/archived against DateTime.now().
  return Story(
    id: id,
    userId: 'me',
    caption: 'cap-$id',
    mediaType: 'image',
    viewCount: views,
    reactionCount: reactions,
    archivedAt: archived ? created : null,
    expiresAt: DateTime.now().add(const Duration(hours: 5)),
    createdAt: created,
    updatedAt: created,
  );
}

User _user(String id, String username) {
  return User(
    id: id,
    username: username,
    publicKey: '',
    keyFingerprint: '',
    createdAt: DateTime.utc(2026, 6, 15),
  );
}
