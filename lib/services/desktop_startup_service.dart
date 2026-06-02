import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'desktop_tray_service.dart';

typedef DesktopTrayInitializer = Future<void> Function();

class DesktopStartupService {
  static const trayStartupTimeout = Duration(seconds: 2);

  static bool get supported =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  static void configureDatabaseFactory() {
    if (!supported) return;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  static Future<void> startTray({
    DesktopTrayInitializer? initializer,
    Duration timeout = trayStartupTimeout,
  }) async {
    if (!supported) return;
    await runTrayInitializerWithTimeout(
      initializer ?? DesktopTrayService().init,
      timeout,
    );
  }

  @visibleForTesting
  static Future<void> runTrayInitializerWithTimeout(
    DesktopTrayInitializer initializer,
    Duration timeout,
  ) async {
    try {
      await initializer().timeout(timeout);
    } catch (error) {
      debugPrint('Desktop tray startup skipped: $error');
    }
  }
}
