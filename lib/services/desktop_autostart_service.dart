import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:launch_at_startup/launch_at_startup.dart';

import 'desktop_startup_service.dart';

class DesktopAutostartService {
  static const _appName = 'OpenChat';

  @visibleForTesting
  static bool? debugSupportedOverride;

  @visibleForTesting
  static bool? debugSandboxedOverride;

  static bool get supported =>
      debugSupportedOverride ?? DesktopStartupService.supported;

  static bool get sandboxed => debugSandboxedOverride ?? _detectSandboxed();

  static bool get available => supported && !sandboxed;

  static bool _detectSandboxed() {
    if (kIsWeb) return false;
    return Platform.environment.containsKey('FLATPAK_ID') ||
        Platform.environment.containsKey('SNAP') ||
        (Platform.environment['container']?.isNotEmpty ?? false) ||
        FileSystemEntity.isFileSync('/.dockerenv');
  }

  static Future<void> setup() async {
    if (!available) return;
    try {
      launchAtStartup.setup(
        appName: _appName,
        appPath: Platform.resolvedExecutable,
        args: const [desktopStartMinimizedArg],
      );
    } catch (error) {
      debugPrint('Desktop autostart setup skipped: $error');
    }
  }

  static Future<bool> isEnabled() async {
    if (!available) return false;
    try {
      await setup();
      return launchAtStartup.isEnabled();
    } catch (error) {
      debugPrint('Desktop autostart status skipped: $error');
      return false;
    }
  }

  static Future<void> enable() async {
    if (!available) return;
    try {
      await setup();
      await launchAtStartup.enable();
    } catch (error) {
      debugPrint('Desktop autostart enable skipped: $error');
    }
  }

  static Future<void> disable() async {
    if (!available) return;
    try {
      await setup();
      await launchAtStartup.disable();
    } catch (error) {
      debugPrint('Desktop autostart disable skipped: $error');
    }
  }
}
