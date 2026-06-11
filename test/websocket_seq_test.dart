import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/services/secure_storage_service.dart';
import 'package:openchat/services/websocket_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Sequence handling on the client: track the highest durable seq, drop
// duplicate deliveries (replay racing live events), tolerate out-of-order
// live delivery, and reset cleanly on logout.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late WebSocketService ws;
  late List<WsEvent> received;

  String frame(int seq, {String type = 'new_message', int n = 0}) =>
      jsonEncode({
        'type': type,
        'data': {'n': n},
        if (seq > 0) 'seq': seq,
      });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ws = WebSocketService(SecureStorageService());
    received = [];
    ws.events.listen(received.add);
  });

  tearDown(() => ws.dispose());

  test('tracks the highest sequence number seen', () async {
    ws.handleRawFrame(frame(1));
    ws.handleRawFrame(frame(2));
    ws.handleRawFrame(frame(5));
    await Future<void>.delayed(Duration.zero);

    expect(ws.lastSeq, 5);
    expect(received, hasLength(3));
  });

  test('drops an exact duplicate delivery', () async {
    ws.handleRawFrame(frame(7));
    ws.handleRawFrame(frame(7));
    await Future<void>.delayed(Duration.zero);

    expect(received, hasLength(1));
    expect(ws.lastSeq, 7);
  });

  test('accepts out-of-order live events (seq below lastSeq, unseen)',
      () async {
    ws.handleRawFrame(frame(10));
    ws.handleRawFrame(frame(9)); // cross-instance reordering — not a dupe
    await Future<void>.delayed(Duration.zero);

    expect(received, hasLength(2));
    expect(ws.lastSeq, 10);
  });

  test('ephemeral events (no seq) always pass through', () async {
    ws.handleRawFrame(frame(0, type: 'typing'));
    ws.handleRawFrame(frame(0, type: 'typing'));
    await Future<void>.delayed(Duration.zero);

    expect(received, hasLength(2));
    expect(ws.lastSeq, 0);
  });

  test('newline-batched frames each get their own seq handling', () async {
    final batched = '${frame(1, n: 1)}\n${frame(2, n: 2)}\n${frame(1, n: 1)}';
    ws.handleRawFrame(batched);
    await Future<void>.delayed(Duration.zero);

    expect(received, hasLength(2)); // third line is a duplicate of seq 1
    expect(ws.lastSeq, 2);
  });

  test('resync_required parses into its own event type', () async {
    ws.handleRawFrame(jsonEncode({'type': 'resync_required', 'data': {}}));
    await Future<void>.delayed(Duration.zero);

    expect(received.single.type, WsEventType.resyncRequired);
  });

  test('resetSequence forgets the resume position', () async {
    ws.handleRawFrame(frame(42));
    await Future<void>.delayed(Duration.zero);
    expect(ws.lastSeq, 42);

    await ws.resetSequence();
    expect(ws.lastSeq, 0);

    // The same seq is deliverable again (fresh account stream).
    ws.handleRawFrame(frame(42));
    await Future<void>.delayed(Duration.zero);
    expect(received, hasLength(2));
  });

  // ── Broadcast-conversation (cid/cseq) stream ──────────────────────────────

  String convFrame(String cid, int cseq, {int n = 0}) => jsonEncode({
        'type': 'new_message',
        'data': {'n': n},
        'cid': cid,
        'cseq': cseq,
      });

  test('cseq events never advance the per-user lastSeq', () async {
    ws.handleRawFrame(frame(3));
    ws.handleRawFrame(convFrame('conv-a', 99));
    await Future<void>.delayed(Duration.zero);

    expect(ws.lastSeq, 3, reason: 'broadcast events must not corrupt _lastSeq');
    expect(ws.convSeqs['conv-a'], 99);
    expect(received, hasLength(2));
    expect(received.last.cid, 'conv-a');
    expect(received.last.cseq, 99);
  });

  test('duplicate cseq within one conversation is dropped', () async {
    ws.handleRawFrame(convFrame('conv-a', 5));
    ws.handleRawFrame(convFrame('conv-a', 5));
    await Future<void>.delayed(Duration.zero);

    expect(received, hasLength(1));
  });

  test('the same cseq in different conversations is independent', () async {
    ws.handleRawFrame(convFrame('conv-a', 5));
    ws.handleRawFrame(convFrame('conv-b', 5));
    await Future<void>.delayed(Duration.zero);

    expect(received, hasLength(2));
    expect(ws.convSeqs, {'conv-a': 5, 'conv-b': 5});
  });

  test('out-of-order live cseq below the max still delivers', () async {
    ws.handleRawFrame(convFrame('conv-a', 10));
    ws.handleRawFrame(convFrame('conv-a', 9));
    await Future<void>.delayed(Duration.zero);

    expect(received, hasLength(2));
    expect(ws.convSeqs['conv-a'], 10);
  });

  test('conv_resync_required parses into its own event type', () async {
    ws.handleRawFrame(jsonEncode({
      'type': 'conv_resync_required',
      'data': {'conversation_id': 'conv-a'},
    }));
    await Future<void>.delayed(Duration.zero);

    expect(received.single.type, WsEventType.convResyncRequired);
    expect(received.single.data['conversation_id'], 'conv-a');
  });

  test('resetSequence forgets broadcast positions too', () async {
    ws.handleRawFrame(convFrame('conv-a', 7));
    await Future<void>.delayed(Duration.zero);
    expect(ws.convSeqs, isNotEmpty);

    await ws.resetSequence();
    expect(ws.convSeqs, isEmpty);

    ws.handleRawFrame(convFrame('conv-a', 7));
    await Future<void>.delayed(Duration.zero);
    expect(received, hasLength(2), reason: 'same cseq deliverable post-reset');
  });
}
