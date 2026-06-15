import 'dart:io';

import 'package:flutter/foundation.dart';

import 'desktop_tray_service.dart';

typedef DesktopTrayInitializer = Future<void> Function();

const desktopStartMinimizedArg = '--minimized';

class DesktopStartupService {
  static const trayStartupTimeout = Duration(seconds: 2);

  /// Persists the [DesktopTrayService] for the lifetime of the process.
  ///
  /// The service registers itself as a [WindowListener] inside [init], and the
  /// window_manager plugin holds a strong reference to it through its internal
  /// listener list. However, to be explicit and defensive against any future
  /// refactoring of window_manager, we also keep a static reference here so
  /// Dart's GC can never collect the instance between app startup and the first
  /// window event.
  static DesktopTrayService? _instance;

  /// The live tray (null off-desktop / before startTray) — lets BadgeService
  /// reflect unread state on the tray icon.
  static DesktopTrayService? get tray => _instance;

  static bool get supported =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  static Future<void> startTray({
    DesktopTrayInitializer? initializer,
    Duration timeout = trayStartupTimeout,
    bool startMinimized = false,
  }) async {
    if (!supported) return;

    if (initializer == null) {
      // Create and persist the canonical singleton instance.
      _instance = DesktopTrayService();
      await runTrayInitializerWithTimeout(_instance!.init, timeout);
      if (startMinimized) {
        try {
          await _instance!.hideToTrayOnLaunch();
        } catch (error) {
          debugPrint('Desktop autostart hide skipped: $error');
        }
      }
    } else {
      // Test path: caller supplies a custom initializer.
      await runTrayInitializerWithTimeout(initializer, timeout);
    }
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
