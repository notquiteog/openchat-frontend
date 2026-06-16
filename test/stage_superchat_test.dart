import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/providers/stage_room_provider.dart';
import 'package:openchat/services/api_service.dart';
import 'package:openchat/services/secure_storage_service.dart';
import 'package:openchat/services/websocket_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stage super-chat state: backlog parsing, and the announce-once rule —
/// entries present at join are history (no banner), entries arriving later
/// are announced exactly once even though every stage_state repeats the list.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, dynamic> entry(String id, {String message = ''}) => {
    'id': id,
    'user_id': 'user-$id',
    'name': 'User $id',
    'provider': 'btc',
    'amount': '0.5',
    'message': message,
    'at': 1781000000,
  };

  Map<String, dynamic> state(List<Map<String, dynamic>> superchats) => {
    'conversation_id': 'conv-1',
    'active': true,
    'host_id': 'host-1',
    'speaker_ids': const <String>[],
    'raised_hands': const <String>[],
    'listener_count': 3,
    'superchats': superchats,
  };

  late StageRoomProvider stage;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'user_id': 'self-user'});
    final storage = SecureStorageService();
    stage = StageRoomProvider(
      ApiService(storage),
      WebSocketService(storage),
      storage,
    );
  });

  tearDown(() => stage.dispose());

  test('parses the superchat backlog from stage state', () {
    stage.debugApplyState(state([entry('b', message: 'hi'), entry('a')]));

    expect(stage.superchats, hasLength(2));
    expect(stage.superchats.first.id, 'b'); // newest-first, server order kept
    expect(stage.superchats.first.name, 'User b');
    expect(stage.superchats.first.amount, '0.5');
    expect(stage.superchats.first.message, 'hi');
  });

  test(
    'join backlog is silent; later arrivals announce exactly once',
    () async {
      final announced = <StageSuperchat>[];
      stage.superchatAnnouncements.listen(announced.add);

      // First state after joining: existing super-chats predate us — no banner.
      stage.debugApplyState(state([entry('old')]));
      await Future<void>.delayed(Duration.zero);
      expect(announced, isEmpty);

      // A new entry lands at the head: announced.
      stage.debugApplyState(state([entry('new'), entry('old')]));
      await Future<void>.delayed(Duration.zero);
      expect(announced.map((s) => s.id), ['new']);

      // The next heartbeat repeats the same list: nothing re-announced.
      stage.debugApplyState(state([entry('new'), entry('old')]));
      await Future<void>.delayed(Duration.zero);
      expect(announced, hasLength(1));

      // Two arrive between states: both announced, oldest-first.
      stage.debugApplyState(
        state([entry('n3'), entry('n2'), entry('new'), entry('old')]),
      );
      await Future<void>.delayed(Duration.zero);
      expect(announced.map((s) => s.id), ['new', 'n2', 'n3']);
    },
  );

  test(
    'an empty first backlog still primes — the first real one announces',
    () async {
      final announced = <StageSuperchat>[];
      stage.superchatAnnouncements.listen(announced.add);

      stage.debugApplyState(state(const []));
      stage.debugApplyState(state([entry('first')]));
      await Future<void>.delayed(Duration.zero);

      expect(announced.map((s) => s.id), ['first']);
    },
  );

  test('malformed entries are dropped, not crashed on', () {
    stage.debugApplyState(
      state([
        entry('ok'),
        {'no_id': true},
      ]),
    );
    expect(stage.superchats.map((s) => s.id), ['ok']);
  });
}
