import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'notification_service.dart';

/// Manages the system-tray icon and window-lifecycle interception on desktop.
///
/// Uses [tray_manager] (pub.dev/packages/tray_manager), which ships a proper
/// Win32 Shell_NotifyIcon implementation for Windows, AppKit NSStatusItem for
/// macOS, and AppIndicator/libayatana for Linux.
///
/// The [DesktopStartupService] stores the service instance in a static field
/// so Dart's GC cannot collect it while the app is running.
class DesktopTrayService with WindowListener, TrayListener {
  static const _appName = 'OpenChat';
  static const _appIconAsset = 'assets/images/logo.png';
  // Same logo with a red dot — tray_manager can only swap whole images, so
  // the unread state is a pre-rendered icon variant plus a tooltip count.
  static const _appIconUnreadAsset = 'assets/images/logo_unread.png';

  bool _initialized = false;
  bool _trayInitialized = false;
  bool _quitting = false;
  bool _hidingToTray = false;
  bool _showingUnreadIcon = false;

  static bool get supported =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  Future<void> init() async {
    if (!supported || _initialized) return;
    _initialized = true;

    await windowManager.ensureInitialized();
    windowManager.addListener(this);

    // Always prevent close so we can intercept the × button.
    await windowManager.setPreventClose(true);
    await windowManager.setTitle(_appName);
    NotificationService.setAppFocused(await windowManager.isFocused());

    await _initTray();
  }

  Future<void> _initTray() async {
    try {
      trayManager.addListener(this);
      await trayManager.setIcon(_appIconAsset);

      // setToolTip is not implemented on Linux (AppIndicator has no tooltip
      // API), so wrap it independently so a MissingPluginException here cannot
      // prevent the context menu from being registered.
      try {
        await trayManager.setToolTip(_appName);
      } catch (_) {
        // Silently ignore — tooltip is cosmetic only.
      }

      // Two items only: Show brings the window back; Exit quits cleanly.
      // "Hide to tray" is omitted — closing or minimising already hides.
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: 'Show $_appName'),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: 'Exit $_appName'),
      ]));
      _trayInitialized = true;
    } catch (e, st) {
      debugPrint(
        'DesktopTrayService: tray init failed — $e\n$st\n'
        'Close/minimize will fall back to taskbar minimize.',
      );
    }
  }

  /// Reflects the unread state on the tray: dot-badged icon variant plus a
  /// "N unread" tooltip (tooltip is unsupported on Linux AppIndicator).
  Future<void> setUnreadBadge(bool unread, int count) async {
    if (!_trayInitialized) return;
    try {
      if (unread != _showingUnreadIcon) {
        _showingUnreadIcon = unread;
        await trayManager.setIcon(unread ? _appIconUnreadAsset : _appIconAsset);
      }
      try {
        await trayManager.setToolTip(
          unread ? '$_appName — $count unread' : _appName,
        );
      } catch (_) {
        // Cosmetic only; not implemented on Linux.
      }
    } catch (_) {}
  }

  // ── TrayListener ──────────────────────────────────────────────────────────

  @override
  void onTrayIconMouseDown() {
    if (Platform.isMacOS) {
      // On macOS the tray_manager native code does NOT auto-show the context
      // menu — it only fires this event.  We must call popUpContextMenu()
      // explicitly.  Directly restoring the window on left-click would be
      // non-standard; showing the menu lets the user choose "Show" or "Exit".
      unawaited(trayManager.popUpContextMenu());
      return;
    }
    // Windows / Linux: left-click = restore the window immediately.
    unawaited(showWindow());
  }

  @override
  void onTrayIconRightMouseDown() =>
      unawaited(trayManager.popUpContextMenu());

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(showWindow());
      case 'exit':
        unawaited(_exitApp());
    }
  }

  // ── WindowListener ────────────────────────────────────────────────────────

  @override
  Future<void> onWindowClose() async {
    if (_quitting) {
      await windowManager.destroy();
      return;
    }
    final preventClose = await windowManager.isPreventClose();
    if (!preventClose) return;
    await _hideToTray();
  }

  @override
  void onWindowFocus() => NotificationService.setAppFocused(true);

  @override
  void onWindowBlur() => NotificationService.setAppFocused(false);

  @override
  void onWindowMinimize() {
    if (_trayInitialized) {
      unawaited(_hideToTray());
    }
    // When the tray icon is unavailable, let the OS handle minimize normally.
  }

  @override
  void onWindowRestore() {
    unawaited(windowManager.setSkipTaskbar(false));
    NotificationService.setAppFocused(true);
  }

  /// Restore and focus the window (from the tray, or when a notification tap
  /// must surface a hidden app). Public for the app shell's tap routing.
  Future<void> showWindow() async {
    await windowManager.setSkipTaskbar(false);
    await windowManager.show();
    await windowManager.focus();
    NotificationService.setAppFocused(true);
  }

  // ── Private helpers ───────────────────────────────────────────────────────

  Future<void> _hideToTray() async {
    if (_quitting || _hidingToTray) return;

    if (!_trayInitialized) {
      // Tray icon unavailable — minimize to taskbar so the user can restore.
      await windowManager.minimize();
      NotificationService.setAppFocused(false);
      return;
    }

    _hidingToTray = true;
    try {
      NotificationService.setAppFocused(false);
      await windowManager.setSkipTaskbar(true);
      await windowManager.hide();
    } finally {
      _hidingToTray = false;
    }
  }

  Future<void> _exitApp() async {
    _quitting = true;
    NotificationService.setAppFocused(false);
    await windowManager.setPreventClose(false);
    await _destroyTray();
    windowManager.removeListener(this);
    await windowManager.destroy();
    exit(0);
  }

  void dispose() {
    if (!supported) return;
    windowManager.removeListener(this);
    unawaited(_destroyTray());
  }

  Future<void> _destroyTray() async {
    if (!_trayInitialized) return;
    _trayInitialized = false;
    trayManager.removeListener(this);
    await trayManager.destroy();
  }
}
