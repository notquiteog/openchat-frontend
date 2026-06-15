import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/screens/custom_emojis/custom_emoji_discover_screen.dart';
import 'package:openchat/screens/stickers/sticker_discover_screen.dart';
import 'package:openchat/services/api_service.dart';
import 'package:openchat/services/secure_storage_service.dart';
import 'package:provider/provider.dart';

class _FakeDiscoverApi extends ApiService {
  _FakeDiscoverApi(super.storage);

  @override
  Future<List<dynamic>> discoverStickerPacks(String query) async => [
    {
      'id': 'stickers-popular',
      'name': 'Popular Stickers',
      'description': 'community favorites',
      'install_count': 5,
    },
    {
      'id': 'stickers-new',
      'name': 'Fresh Stickers',
      'description': '',
      'install_count': 0,
    },
  ];

  @override
  Future<List<dynamic>> discoverCustomEmojiPacks(String query) async => [
    {
      'id': 'emoji-popular',
      'name': 'Popular Emoji',
      'description': 'tiny moods',
      'install_count': 1,
    },
    {
      'id': 'emoji-new',
      'name': 'Fresh Emoji',
      'description': '',
      'install_count': 0,
    },
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  Future<void> pumpWithApi(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Provider<ApiService>.value(
          value: _FakeDiscoverApi(SecureStorageService()),
          child: child,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('sticker discovery renders non-zero install count badges', (
    tester,
  ) async {
    await pumpWithApi(tester, const StickerDiscoverScreen());

    expect(find.text('Popular Stickers'), findsOneWidget);
    expect(find.text('5 installs'), findsOneWidget);
    expect(find.text('Fresh Stickers'), findsOneWidget);
    expect(find.text('0 installs'), findsNothing);
  });

  testWidgets('custom emoji discovery pluralizes install count badges', (
    tester,
  ) async {
    await pumpWithApi(tester, const CustomEmojiDiscoverScreen());

    expect(find.text('Popular Emoji'), findsOneWidget);
    expect(find.text('1 install'), findsOneWidget);
    expect(find.text('Fresh Emoji'), findsOneWidget);
    expect(find.text('0 installs'), findsNothing);
  });
}
