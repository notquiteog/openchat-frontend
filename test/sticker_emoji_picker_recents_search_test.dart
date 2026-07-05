import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/providers/settings_provider.dart';
import 'package:openchat/services/api_service.dart';
import 'package:openchat/services/secure_storage_service.dart';
import 'package:openchat/widgets/custom_emoji_picker.dart';
import 'package:openchat/widgets/sticker_picker.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _PickerApi extends ApiService {
  _PickerApi() : super(SecureStorageService());

  // The list endpoint now hydrates each pack's `stickers` inline (one batched
  // query server-side), so the picker no longer fetches per-pack.
  @override
  Future<List<dynamic>> getStickerPacks() async => [
    <String, dynamic>{
      'id': 'stickers-animals',
      'name': 'Animals',
      'stickers': [
        <String, dynamic>{
          'id': 'sticker-party',
          'name': 'Party Cat',
          'emoji': '🎉',
        },
        <String, dynamic>{
          'id': 'sticker-bread',
          'name': 'Toast Wave',
          'emoji': '🍞',
        },
      ],
    },
    <String, dynamic>{
      'id': 'stickers-space',
      'name': 'Space',
      'stickers': [
        <String, dynamic>{
          'id': 'sticker-rocket',
          'name': 'Solar Rocket',
          'emoji': '🚀',
        },
        <String, dynamic>{
          'id': 'sticker-planet',
          'name': 'Planet Mood',
          'emoji': '🪐',
        },
      ],
    },
  ];

  @override
  Future<Map<String, dynamic>> getStickerPack(String packID) async {
    return switch (packID) {
      'stickers-animals' => <String, dynamic>{
        'id': packID,
        'name': 'Animals',
        'stickers': [
          <String, dynamic>{
            'id': 'sticker-party',
            'name': 'Party Cat',
            'emoji': '🎉',
          },
          <String, dynamic>{
            'id': 'sticker-bread',
            'name': 'Toast Wave',
            'emoji': '🍞',
          },
        ],
      },
      'stickers-space' => <String, dynamic>{
        'id': packID,
        'name': 'Space',
        'stickers': [
          <String, dynamic>{
            'id': 'sticker-rocket',
            'name': 'Solar Rocket',
            'emoji': '🚀',
          },
          <String, dynamic>{
            'id': 'sticker-planet',
            'name': 'Planet Mood',
            'emoji': '🪐',
          },
        ],
      },
      _ => <String, dynamic>{'id': packID, 'name': 'Missing', 'stickers': []},
    };
  }

  @override
  Future<List<dynamic>> getCustomEmojiPacks() async => [
    <String, dynamic>{'id': 'emoji-party', 'name': 'Party'},
    <String, dynamic>{'id': 'emoji-music', 'name': 'Music'},
  ];

  @override
  Future<Map<String, dynamic>> getCustomEmojiPack(String packID) async {
    return switch (packID) {
      'emoji-party' => <String, dynamic>{
        'id': packID,
        'name': 'Party',
        'custom_emojis': [
          <String, dynamic>{
            'id': 'emoji-confetti',
            'name': 'Confetti Burst',
            'emoji': '🎉',
          },
          <String, dynamic>{
            'id': 'emoji-sparkle',
            'name': 'Sparkle Wink',
            'emoji': '✨',
          },
        ],
      },
      'emoji-music' => <String, dynamic>{
        'id': packID,
        'name': 'Music',
        'custom_emojis': [
          <String, dynamic>{
            'id': 'emoji-drum',
            'name': 'Drum Roll',
            'emoji': '🥁',
          },
        ],
      },
      _ => <String, dynamic>{
        'id': packID,
        'name': 'Missing',
        'custom_emojis': [],
      },
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  Future<SettingsProvider> loadedSettings() async {
    final settings = SettingsProvider();
    await settings.load();
    return settings;
  }

  Future<void> pumpPicker(
    WidgetTester tester, {
    required SettingsProvider settings,
    required Widget child,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            Provider<ApiService>.value(value: _PickerApi()),
            ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ],
          child: Scaffold(body: child),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('StickerPicker shows recents and searches across packs', (
    tester,
  ) async {
    final settings = await loadedSettings();
    await settings.recordRecentSticker('sticker-party');
    await settings.recordRecentSticker('missing-sticker');
    String? selected;

    await pumpPicker(
      tester,
      settings: settings,
      child: StickerPicker(onStickerSelected: (id) => selected = id),
    );

    expect(find.byIcon(Icons.history_rounded), findsOneWidget);
    expect(find.byTooltip('Party Cat'), findsOneWidget);
    expect(find.byTooltip('Solar Rocket'), findsNothing);

    await tester.tap(find.byTooltip('Party Cat'));
    expect(selected, 'sticker-party');

    await tester.enterText(find.byType(TextField), 'rocket');
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.history_rounded), findsNothing);
    expect(find.byTooltip('Solar Rocket'), findsOneWidget);
    expect(find.byTooltip('Party Cat'), findsNothing);

    selected = null;
    await tester.tap(find.byTooltip('Solar Rocket'));
    expect(selected, 'sticker-rocket');

    await tester.enterText(find.byType(TextField), '🪐');
    await tester.pumpAndSettle();

    expect(find.byTooltip('Planet Mood'), findsOneWidget);
  });

  testWidgets('CustomEmojiPicker shows recents and searches across packs', (
    tester,
  ) async {
    final settings = await loadedSettings();
    await settings.recordRecentEmoji('emoji-confetti');
    await settings.recordRecentEmoji('missing-emoji');
    Map<String, dynamic>? selected;

    await pumpPicker(
      tester,
      settings: settings,
      child: CustomEmojiPicker(onEmojiSelected: (emoji) => selected = emoji),
    );

    expect(find.byIcon(Icons.history_rounded), findsOneWidget);
    expect(find.byTooltip('Confetti Burst'), findsOneWidget);
    expect(find.byTooltip('Drum Roll'), findsNothing);

    await tester.tap(find.byTooltip('Confetti Burst'));
    expect(selected?['id'], 'emoji-confetti');

    await tester.enterText(find.byType(TextField), 'drum');
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.history_rounded), findsNothing);
    expect(find.byTooltip('Drum Roll'), findsOneWidget);
    expect(find.byTooltip('Confetti Burst'), findsNothing);

    selected = null;
    await tester.tap(find.byTooltip('Drum Roll'));
    expect(selected?['id'], 'emoji-drum');

    await tester.enterText(find.byType(TextField), '✨');
    await tester.pumpAndSettle();

    expect(find.byTooltip('Sparkle Wink'), findsOneWidget);
  });
}
