import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/providers/stage_room_provider.dart';
import 'package:openchat/services/api_service.dart';
import 'package:openchat/services/secure_storage_service.dart';
import 'package:openchat/services/websocket_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// join()/leave() race: a leave (or dispose) that lands while join's awaits
/// are still in flight must win — the join continuation re-checks the
/// teardown generation after every await and bails out instead of
/// resurrecting provider state (mic, heartbeat, room reference).
///
/// The fake API pauses joinStage on a completer so the test can interleave
/// leave() deterministically. The race window after Room.connect can't be
/// unit-tested (livekit Room needs platform channels), but it runs the same
/// generation check.
class _FakeApi extends ApiService {
  _FakeApi(super.storage);

  Completer<Map<String, dynamic>>? joinGate;
  int joinCalls = 0;
  int leaveCalls = 0;

  @override
  Future<Map<String, dynamic>> joinStage(String convID) {
    joinCalls++;
    final gate = joinGate;
    if (gate != null) return gate.future;
    return Future.value(<String, dynamic>{});
  }

  @override
  Future<void> leaveStage(String convID) async {
    leaveCalls++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeApi api;
  late StageRoomProvider stage;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'user_id': 'self-user'});
    final storage = SecureStorageService();
    api = _FakeApi(storage);
    stage = StageRoomProvider(api, WebSocketService(storage), storage);
  });

  tearDown(() => stage.dispose());

  test('leave() during an in-flight join wins; join does not resurrect state',
      () async {
    api.joinGate = Completer<Map<String, dynamic>>();

    final joinFuture = stage.join('conv-1');
    // Let join reach the awaited joinStage call.
    await Future<void>.delayed(Duration.zero);
    expect(stage.connecting, isTrue);
    expect(api.joinCalls, 1);

    // User backs out while the join API call is still in flight.
    await stage.leave();
    expect(stage.connecting, isFalse);
    expect(stage.isActive, isFalse);

    // The server now answers the original join with a perfectly good room —
    // but the continuation lost the generation race and must stand down.
    api.joinGate!.complete(<String, dynamic>{
      'url': 'wss://example.test',
      'token': 'tok',
      'role': 'host',
      'state': <String, dynamic>{
        'conversation_id': 'conv-1',
        'host_id': 'self-user',
        'speaker_ids': <String>[],
        'raised_hands': <String>[],
        'listener_count': 1,
      },
    });
    await joinFuture;

    expect(stage.isActive, isFalse, reason: 'no room may be kept');
    expect(stage.connecting, isFalse);
    expect(stage.conversationId, isNull);
    expect(stage.micEnabled, isFalse);
    // The orphaned server-side registration was undone.
    expect(api.leaveCalls, greaterThanOrEqualTo(1));
  });

  test('dispose() during an in-flight join wins the same way', () async {
    api.joinGate = Completer<Map<String, dynamic>>();

    final joinFuture = stage.join('conv-2');
    await Future<void>.delayed(Duration.zero);

    stage.dispose();
    api.joinGate!.complete(<String, dynamic>{
      'url': 'wss://example.test',
      'token': 'tok',
      'role': 'listener',
    });
    await joinFuture;

    expect(stage.isActive, isFalse);
    expect(stage.conversationId, isNull);
    // Recreate so the shared tearDown's dispose() is harmless.
    final storage = SecureStorageService();
    stage = StageRoomProvider(api, WebSocketService(storage), storage);
  });

  test('a join that loses the race does not block a later join', () async {
    final gate1 = Completer<Map<String, dynamic>>();
    api.joinGate = gate1;
    final first = stage.join('conv-1');
    await Future<void>.delayed(Duration.zero);
    await stage.leave();

    // A new join may start immediately (connecting flag was reset by the
    // teardown, not left dangling by the doomed first join).
    final gate2 = Completer<Map<String, dynamic>>();
    api.joinGate = gate2;
    final second = stage.join('conv-1');
    await Future<void>.delayed(Duration.zero);
    expect(stage.connecting, isTrue);
    expect(api.joinCalls, 2);

    // Resolve both: the second fails on the empty payload (no url/token) and
    // cleans up after itself — but it did run. The first then resumes with a
    // valid-looking payload and must stand down (its generation is long gone).
    gate2.complete(<String, dynamic>{});
    await second;
    expect(stage.error, isNotNull);
    expect(stage.connecting, isFalse);

    gate1.complete(<String, dynamic>{'url': 'wss://x', 'token': 't'});
    await first;
    expect(stage.isActive, isFalse);
    expect(stage.conversationId, isNull);
  });
}
