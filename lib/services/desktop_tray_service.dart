import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:nativeapi/nativeapi.dart' as native;
import 'package:window_manager/window_manager.dart';

import 'notification_service.dart';

class DesktopTrayService with WindowListener {
  static const _appIconAsset = 'assets/images/logo.png';

  native.Image? _trayIconImage;
  native.Menu? _contextMenu;
  native.MenuItem? _showItem;
  native.MenuItem? _hideItem;
  native.MenuItem? _exitItem;
  native.TrayIcon? _trayIcon;
  bool _quitting = false;
  bool _hidingToTray = false;

  static bool get supported =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  Future<void> init() async {
    if (!supported) return;
    if (_trayIcon != null) return;

    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);
    await windowManager.setTitle('OpenChat');
    NotificationService.setAppFocused(await windowManager.isFocused());

    if (!native.TrayManager.instance.isSupported) {
      await windowManager.setPreventClose(false);
      windowManager.removeListener(this);
      return;
    }

    final trayIcon = native.TrayIcon();
    final contextMenu = native.Menu();
    final showItem = native.MenuItem('Show OpenChat');
    final hideItem = native.MenuItem('Hide to tray');
    final exitItem = native.MenuItem('Exit OpenChat');

    showItem.on<native.MenuItemClickedEvent>((_) {
      unawaited(_showWindow());
    });
    hideItem.on<native.MenuItemClickedEvent>((_) {
      unawaited(_hideToTray());
    });
    exitItem.on<native.MenuItemClickedEvent>((_) {
      unawaited(_exitApp());
    });

    contextMenu.addItem(showItem);
    contextMenu.addItem(hideItem);
    contextMenu.addSeparator();
    contextMenu.addItem(exitItem);

    _trayIconImage = native.Image.fromAsset(_appIconAsset);
    if (_trayIconImage != null) {
      trayIcon.icon = _trayIconImage;
    }
    trayIcon.title = 'OpenChat';
    trayIcon.tooltip = 'OpenChat';
    trayIcon.contextMenu = contextMenu;
    trayIcon.contextMenuTrigger = native.ContextMenuTrigger.rightClicked;
    trayIcon.on<native.TrayIconClickedEvent>((_) {
      unawaited(_showWindow());
    });
    trayIcon.on<native.TrayIconDoubleClickedEvent>((_) {
      unawaited(_showWindow());
    });
    trayIcon.isVisible = true;

    _contextMenu = contextMenu;
    _showItem = showItem;
    _hideItem = hideItem;
    _exitItem = exitItem;
    _trayIcon = trayIcon;
  }

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
  void onWindowFocus() {
    NotificationService.setAppFocused(true);
  }

  @override
  void onWindowBlur() {
    NotificationService.setAppFocused(false);
  }

  @override
  void onWindowMinimize() {
    unawaited(_hideToTray());
  }

  @override
  void onWindowRestore() {
    unawaited(windowManager.setSkipTaskbar(false));
    NotificationService.setAppFocused(true);
  }

  Future<void> _showWindow() async {
    await windowManager.setSkipTaskbar(false);
    await windowManager.show();
    await windowManager.focus();
    NotificationService.setAppFocused(true);
  }

  Future<void> _hideToTray() async {
    if (_quitting || _hidingToTray) return;
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
    _disposeTray();
    await windowManager.destroy();
    exit(0);
  }

  void dispose() {
    if (!supported) return;
    windowManager.removeListener(this);
    _disposeTray();
  }

  void _disposeTray() {
    _trayIcon?.dispose();
    _trayIcon = null;

    _showItem?.dispose();
    _showItem = null;
    _hideItem?.dispose();
    _hideItem = null;
    _exitItem?.dispose();
    _exitItem = null;

    _contextMenu?.dispose();
    _contextMenu = null;

    _trayIconImage?.dispose();
    _trayIconImage = null;
  }
}
