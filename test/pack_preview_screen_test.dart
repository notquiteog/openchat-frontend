import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/user.dart';
import 'package:openchat/providers/auth_provider.dart';
import 'package:openchat/screens/packs/pack_preview_screen.dart';
import 'package:openchat/services/api_service.dart';
import 'package:openchat/services/secure_storage_service.dart';
import 'package:openchat/utils/pack_links.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  Future<_FakePackApi> pumpPreview(
    WidgetTester tester, {
    required PackKind kind,
    required String packId,
    Map<String, dynamic>? pack,
    bool failLoad = false,
  }) async {
    final storage = SecureStorageService();
    final api = _FakePackApi(storage)
      ..pack = pack ?? _pack(id: packId, kind: kind)
      ..failLoad = failLoad;
    final auth = _FakeAuthProvider(_user('me'), api, storage);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<ApiService>.value(value: api),
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ],
        child: MaterialApp(
          home: PackPreviewScreen(kind: kind, packId: packId),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return api;
  }

  testWidgets('sticker preview adds the pack to the sticker library', (
    tester,
  ) async {
    final api = await pumpPreview(
      tester,
      kind: PackKind.sticker,
      packId: 'p1',
      pack: _pack(
        id: 'p1',
        kind: PackKind.sticker,
        items: const [
          {'id': 's1'},
          {'id': 's2'},
        ],
      ),
    );

    expect(find.text('Sticker pack'), findsOneWidget);
    expect(find.text('2 stickers'), findsOneWidget);

    await tester.tap(find.text('Add to library'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(api.addedStickerPacks, ['p1']);
    expect(api.addedEmojiPacks, isEmpty);
  });

  testWidgets('custom emoji preview adds the pack to the emoji library', (
    tester,
  ) async {
    final api = await pumpPreview(
      tester,
      kind: PackKind.customEmoji,
      packId: 'e1',
      pack: _pack(
        id: 'e1',
        kind: PackKind.customEmoji,
        items: const [
          {'id': 'e1'},
        ],
      ),
    );

    expect(find.text('Custom emoji pack'), findsOneWidget);
    expect(find.text('1 custom emoji'), findsOneWidget);

    await tester.tap(find.text('Add to library'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(api.addedEmojiPacks, ['e1']);
    expect(api.addedStickerPacks, isEmpty);
  });

  testWidgets('preview renders an error state when the pack cannot load', (
    tester,
  ) async {
    await pumpPreview(
      tester,
      kind: PackKind.sticker,
      packId: 'missing',
      failLoad: true,
    );

    expect(find.text('Pack unavailable'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('owner sees an already-in-library action instead of add', (
    tester,
  ) async {
    final api = await pumpPreview(
      tester,
      kind: PackKind.sticker,
      packId: 'mine',
      pack: _pack(id: 'mine', kind: PackKind.sticker, creatorId: 'me'),
    );

    expect(find.text('Already in your library'), findsOneWidget);
    await tester.tap(find.text('Already in your library'));
    await tester.pump();

    expect(api.addedStickerPacks, isEmpty);
  });
}

class _FakePackApi extends ApiService {
  _FakePackApi(super.storage);

  late Map<String, dynamic> pack;
  bool failLoad = false;
  final addedStickerPacks = <String>[];
  final addedEmojiPacks = <String>[];

  @override
  Future<Map<String, dynamic>> getStickerPack(String packID) async {
    if (failLoad) throw ApiException(404, 'NOT_FOUND', 'missing');
    return pack;
  }

  @override
  Future<Map<String, dynamic>> getCustomEmojiPack(String packID) async {
    if (failLoad) throw ApiException(404, 'NOT_FOUND', 'missing');
    return pack;
  }

  @override
  Future<void> addStickerPackToLibrary(String packID) async {
    addedStickerPacks.add(packID);
  }

  @override
  Future<void> addCustomEmojiPackToLibrary(String packID) async {
    addedEmojiPacks.add(packID);
  }
}

class _FakeAuthProvider extends AuthProvider {
  _FakeAuthProvider(this._user, ApiService api, SecureStorageService storage)
    : super(api, storage);

  final User _user;

  @override
  User? get currentUser => _user;
}

Map<String, dynamic> _pack({
  required String id,
  required PackKind kind,
  String creatorId = 'other',
  List<Map<String, dynamic>> items = const [],
}) {
  return {
    'id': id,
    'name': kind == PackKind.sticker ? 'Tiny Stickers' : 'Tiny Emoji',
    'description': 'A tiny pack',
    'creator_id': creatorId,
    if (kind == PackKind.sticker) 'stickers': items,
    if (kind == PackKind.customEmoji) 'custom_emojis': items,
  };
}

User _user(String id) {
  return User(
    id: id,
    username: id,
    publicKey: 'PUB',
    keyFingerprint: 'FP',
    createdAt: DateTime.utc(2026, 6, 15),
  );
}
