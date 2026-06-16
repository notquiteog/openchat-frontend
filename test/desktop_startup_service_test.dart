import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/services/desktop_startup_service.dart';

void main() {
  test(
    'tray startup timeout does not block app startup indefinitely',
    () async {
      final neverCompletes = Completer<void>();
      final stopwatch = Stopwatch()..start();

      await DesktopStartupService.runTrayInitializerWithTimeout(
        () => neverCompletes.future,
        const Duration(milliseconds: 20),
      );

      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    },
  );

  test('tray startup errors are non-fatal', () async {
    await expectLater(
      DesktopStartupService.runTrayInitializerWithTimeout(
        () async => throw StateError('tray unavailable'),
        const Duration(seconds: 1),
      ),
      completes,
    );
  });
}
