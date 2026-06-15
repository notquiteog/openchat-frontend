import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/screens/call/sfu_call_screen.dart';

void main() {
  const tiles = [
    (sid: 'local', audioLevel: 0.1, isSpeaking: false),
    (sid: 'a', audioLevel: 0.4, isSpeaking: true),
    (sid: 'b', audioLevel: 0.7, isSpeaking: true),
  ];

  test('manual pin takes precedence over active-speaker ordering', () {
    expect(sfuFocusOrder(tiles: tiles, pinnedSid: 'a', autoFocus: true), [
      1,
      0,
      2,
    ]);
  });

  test('auto-focus puts the loudest speaking participant first', () {
    expect(sfuFocusOrder(tiles: tiles, autoFocus: true), [2, 0, 1]);
  });

  test('auto-focus tie keeps original order stable', () {
    const tied = [
      (sid: 'local', audioLevel: 0.2, isSpeaking: false),
      (sid: 'a', audioLevel: 0.5, isSpeaking: true),
      (sid: 'b', audioLevel: 0.5, isSpeaking: true),
    ];

    expect(sfuFocusOrder(tiles: tied, autoFocus: true), [1, 0, 2]);
  });

  test(
    'missing pin and disabled auto-focus fall back to local-first order',
    () {
      expect(sfuFocusOrder(tiles: tiles, pinnedSid: 'gone'), [0, 1, 2]);
      expect(sfuFocusOrder(tiles: tiles, autoFocus: false), [0, 1, 2]);
    },
  );

  test('one or zero participants keep identity order', () {
    expect(
      sfuFocusOrder(
        tiles: const [(sid: 'solo', audioLevel: 1, isSpeaking: true)],
        pinnedSid: 'solo',
        autoFocus: true,
      ),
      [0],
    );
    expect(sfuFocusOrder(tiles: const []), isEmpty);
  });
}
