import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/story.dart';
import 'package:openchat/models/story_viewer.dart';
import 'package:openchat/models/user.dart';
import 'package:openchat/providers/auth_provider.dart';
import 'package:openchat/providers/settings_provider.dart';
import 'package:openchat/screens/stories/story_viewer_screen.dart';
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

  Widget wrap(Story story, {String currentUserId = 'me'}) {
    return MaterialApp(
      home: MultiProvider(
        providers: [
          Provider<ApiService>.value(value: api),
          ChangeNotifierProvider<AuthProvider>.value(
            value: _FakeAuthProvider(_user(currentUserId, 'me'), api, storage),
          ),
          ChangeNotifierProvider<SettingsProvider>(
            create: (_) => SettingsProvider(),
          ),
          Provider<SecureStorageService>.value(value: storage),
        ],
        child: StoryViewerScreen(stories: [story]),
      ),
    );
  }

  test('StoryViewer.fromJson parses optional reaction and viewedAt', () {
    final viewedAt = DateTime.utc(2026, 6, 15, 12);
    final viewer = StoryViewer.fromJson({
      'user_id': 'u1',
      'username': 'maya',
      'display_name': 'Maya',
      'avatar_url': '/avatars/maya.webp',
      'reaction': '🔥',
      'viewed_at': viewedAt.toIso8601String(),
    });

    expect(viewer.userId, 'u1');
    expect(viewer.username, 'maya');
    expect(viewer.displayName, 'Maya');
    expect(viewer.avatarUrl, '/avatars/maya.webp');
    expect(viewer.reaction, '🔥');
    expect(viewer.viewedAt, viewedAt);

    final noReaction = StoryViewer.fromJson({
      'user_id': 'u2',
      'username': 'rio',
      'viewed_at': viewedAt.toIso8601String(),
    });
    expect(noReaction.reaction, isNull);
  });

  testWidgets('author can open story viewers sheet from the view-count badge', (
    tester,
  ) async {
    api.viewers = [
      StoryViewer(
        userId: 'viewer-1',
        username: 'maya',
        displayName: 'Maya',
        reaction: '🔥',
        viewedAt: DateTime.utc(2026, 6, 15, 12),
      ),
      StoryViewer(
        userId: 'viewer-2',
        username: 'rio',
        viewedAt: DateTime.utc(2026, 6, 15, 11),
      ),
    ];

    await tester.pumpWidget(wrap(_story(userId: 'me', viewCount: 2)));
    await tester.pump();

    await tester.tap(find.byKey(const Key('story-view-count-badge')));
    await tester.pumpAndSettle();

    expect(api.viewerCalls, 1);
    expect(find.text('Viewers'), findsOneWidget);
    expect(find.text('Maya'), findsOneWidget);
    expect(find.text('@maya'), findsOneWidget);
    expect(find.text('@rio'), findsWidgets);
    expect(find.text('🔥'), findsWidgets);
  });

  testWidgets('non-author badge does not open the viewers sheet', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(_story(userId: 'other', viewCount: 2)));
    await tester.pump();

    await tester.tap(find.byKey(const Key('story-view-count-badge')));
    await tester.pumpAndSettle();

    expect(api.viewerCalls, 0);
    expect(find.text('Viewers'), findsNothing);
  });

  testWidgets('text stories render without an attachment download error', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(_textStory(userId: 'other')));
    await tester.pump();

    expect(api.viewCalls, 1);
    expect(find.text('hello text story'), findsOneWidget);
    expect(find.text('Could not load story.'), findsNothing);
    expect(find.text('Reply to story...'), findsOneWidget);
  });

  testWidgets('reply bar is hidden for own and channel stories', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(_textStory(userId: 'me')));
    await tester.pump();
    expect(find.text('Reply to story...'), findsNothing);

    await tester.pumpWidget(
      wrap(_textStory(userId: 'other', conversationId: 'channel-1')),
    );
    await tester.pump();
    expect(find.text('Reply to story...'), findsNothing);
  });
}

class _FakeApi extends ApiService {
  _FakeApi(super.storage);

  List<StoryViewer> viewers = const [];
  int viewerCalls = 0;
  int viewCalls = 0;

  @override
  Future<List<StoryViewer>> getStoryViewers(String storyId) async {
    viewerCalls++;
    return viewers;
  }

  @override
  Future<Story> viewStory(String storyId) async {
    viewCalls++;
    return _textStory(userId: 'other');
  }
}

class _FakeAuthProvider extends AuthProvider {
  _FakeAuthProvider(this._user, ApiService api, SecureStorageService storage)
    : super(api, storage);

  final User _user;

  @override
  User? get currentUser => _user;
}

Story _story({required String userId, required int viewCount}) {
  final now = DateTime.utc(2026, 6, 15, 12);
  return Story(
    id: 'story-1',
    userId: userId,
    viewCount: viewCount,
    expiresAt: now.add(const Duration(hours: 1)),
    createdAt: now,
    updatedAt: now,
  );
}

Story _textStory({required String userId, String? conversationId}) {
  final now = DateTime.utc(2026, 6, 15, 12);
  return Story(
    id: 'story-text',
    userId: userId,
    conversationId: conversationId,
    caption: 'hello text story',
    background: 'solid:#112233',
    mediaType: 'text',
    expiresAt: now.add(const Duration(hours: 1)),
    createdAt: now,
    updatedAt: now,
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
