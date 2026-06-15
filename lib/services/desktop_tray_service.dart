import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
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

  // Themed icon ids installed into hicolor by packaging/linux/* — what the
  // host resolves when tray_manager forwards the string as an icon NAME.
  static const _linuxThemedIcon = 'win.openchat.OpenChat';
  static const _linuxThemedIconUnread = 'win.openchat.OpenChat.unread';

  /// Mirrors tray_manager's `runningInSandbox()`: the exact condition under
  /// which its `setIcon` forwards the string verbatim as a themed-icon name
  /// instead of resolving it to a bundle file path (the host compositor can't
  /// see sandbox paths).
  static bool get _linuxIconByName =>
      Platform.environment.containsKey('FLATPAK_ID') ||
      Platform.environment.containsKey('SNAP') ||
      (Platform.environment['container']?.isNotEmpty ?? false) ||
      FileSystemEntity.isFileSync('/.dockerenv');

  /// Per-platform tray icon. Windows MUST get an .ico: Shell_NotifyIcon loads
  /// via LoadImage(IMAGE_ICON, LR_LOADFROMFILE), which only reads .ico files —
  /// a PNG yields a null HICON (invisible tray icon) while still reporting
  /// success to Dart.
  static String get _appIconAsset {
    if (Platform.isWindows) return 'assets/images/logo.ico';
    if (Platform.isLinux && _linuxIconByName) return _linuxThemedIcon;
    return 'assets/images/logo.png';
  }

  // Same logo with a red dot — tray_manager can only swap whole images, so
  // the unread state is a pre-rendered icon variant plus a tooltip count.
  static String get _appIconUnreadAsset {
    if (Platform.isWindows) return 'assets/images/logo_unread.ico';
    if (Platform.isLinux && _linuxIconByName) return _linuxThemedIconUnread;
    return 'assets/images/logo_unread.png';
  }

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
    // Stock GNOME ships no StatusNotifierWatcher (the AppIndicator extension
    // provides one), and ayatana registration still "succeeds" against the
    // bus — the icon just never renders. Hiding the window in that state
    // strands it, so stay un-initialized and let close/minimize fall back to
    // a normal taskbar minimize.
    if (Platform.isLinux && !await _linuxHasStatusNotifierWatcher()) {
      debugPrint(
        'DesktopTrayService: no org.kde.StatusNotifierWatcher on the session '
        'bus — tray disabled, close/minimize will minimize to the taskbar.',
      );
      return;
    }
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
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show', label: 'Show $_appName'),
            MenuItem.separator(),
            MenuItem(key: 'exit', label: 'Exit $_appName'),
          ],
        ),
      );
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

  /// True when something on the session bus implements the StatusNotifier
  /// protocol (KDE, GNOME with the AppIndicator extension, most other DEs).
  /// Errors default to true so an odd bus setup degrades to "try the tray
  /// anyway" rather than silently losing the feature.
  static Future<bool> _linuxHasStatusNotifierWatcher() async {
    DBusClient? client;
    try {
      client = DBusClient.session();
      final reply = await client.callMethod(
        destination: 'org.freedesktop.DBus',
        path: DBusObjectPath('/org/freedesktop/DBus'),
        interface: 'org.freedesktop.DBus',
        name: 'NameHasOwner',
        values: const [DBusString('org.kde.StatusNotifierWatcher')],
        replySignature: DBusSignature('b'),
      );
      return reply.returnValues.first.asBoolean();
    } catch (_) {
      return true;
    } finally {
      if (client != null) unawaited(client.close());
    }
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
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());

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

  /// Used by OS autostart launches after tray initialization. If the tray is
  /// unavailable, this falls back to a normal taskbar minimize via [_hideToTray].
  Future<void> hideToTrayOnLaunch() => _hideToTray();

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
