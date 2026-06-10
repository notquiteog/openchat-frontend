import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/screens/home/conversations_screen.dart';

// The inbox hides the stories strip above the fold (initial scroll offset =
// strip extent) and snaps it fully open or fully hidden when a drag ends
// midway. Pull-to-refresh was removed — the pull gesture means "reveal
// stories" and nothing else.
void main() {
  const extent = 98.5;

  group('storiesSnapTarget', () {
    test('no snap when the strip is fully hidden (at rest)', () {
      expect(storiesSnapTarget(extent, extent), isNull);
      expect(storiesSnapTarget(extent + 40, extent), isNull);
    });

    test('no snap when the strip is fully revealed', () {
      expect(storiesSnapTarget(0, extent), isNull);
      expect(storiesSnapTarget(-12, extent), isNull); // iOS overscroll bounce
    });

    test('a pull past halfway settles revealed', () {
      expect(storiesSnapTarget(extent * 0.25, extent), 0.0);
      expect(storiesSnapTarget(1, extent), 0.0);
    });

    test('a shallow pull settles hidden again', () {
      expect(storiesSnapTarget(extent * 0.75, extent), extent);
      expect(storiesSnapTarget(extent - 1, extent), extent);
    });

    test('the exact midpoint settles hidden (no accidental reveals)', () {
      expect(storiesSnapTarget(extent / 2, extent), extent);
    });
  });
}
