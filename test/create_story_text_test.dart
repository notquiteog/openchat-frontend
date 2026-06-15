import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/story.dart';
import 'package:openchat/providers/settings_provider.dart';
import 'package:openchat/screens/stories/create_story_screen.dart';
import 'package:openchat/services/api_service.dart';
import 'package:openchat/services/secure_storage_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('publishes a public text story without an attachment', (
    tester,
  ) async {
    final storage = SecureStorageService();
    final api = _CapturingStoryApi(storage);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<ApiService>.value(value: api),
          ChangeNotifierProvider<SettingsProvider>(
            create: (_) => SettingsProvider(),
          ),
        ],
        child: const MaterialApp(home: CreateStoryScreen()),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Text'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'Bright text day');
    await tester.tap(find.text('Public'));
    await tester.pump();
    await tester.tap(find.text('Share story'));
    await tester.pump();

    expect(api.mediaType, 'text');
    expect(api.attachmentId, isNull);
    expect(api.caption, 'Bright text day');
    expect(api.background, isNotEmpty);
    expect(api.privacy, 'public');
  });
}

class _CapturingStoryApi extends ApiService {
  _CapturingStoryApi(super.storage);

  String? attachmentId;
  String? mediaType;
  String? caption;
  String? background;
  String? privacy;

  @override
  Future<Story> createStory({
    String? attachmentId,
    int fileSize = 0,
    required String mediaType,
    String? fileName,
    String? mimeType,
    String? fileKey,
    String? fileNonce,
    String? background,
    String? encryptedPayload,
    String caption = '',
    String privacy = 'contacts',
    List<String> allowUserIds = const [],
    String? conversationId,
    int expiresInSeconds = 24 * 60 * 60,
    bool pinned = false,
    bool noForwards = false,
    List<Map<String, dynamic>> entities = const [],
  }) async {
    this.attachmentId = attachmentId;
    this.mediaType = mediaType;
    this.caption = caption;
    this.background = background;
    this.privacy = privacy;
    final now = DateTime.utc(2026, 6, 15, 12);
    return Story(
      id: 'story-created',
      userId: 'me',
      attachmentId: attachmentId,
      caption: caption,
      background: background,
      mediaType: mediaType,
      privacy: privacy,
      expiresAt: now.add(const Duration(hours: 1)),
      createdAt: now,
      updatedAt: now,
    );
  }
}
