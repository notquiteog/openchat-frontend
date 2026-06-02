import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:nativeapi/nativeapi.dart' as native;
import 'package:window_manager/window_manager.dart';

class DesktopTrayService with WindowListener {
  static const _appIconAsset = 'assets/images/logo.png';

  native.Image? _trayIconImage;
  native.Menu? _contextMenu;
  native.MenuItem? _showItem;
  native.MenuItem? _quitItem;
  native.TrayIcon? _trayIcon;
  bool _quitting = false;

  static bool get supported =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  Future<void> init() async {
    if (!supported) return;
    if (_trayIcon != null) return;
    if (!native.TrayManager.instance.isSupported) return;

    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);
    await windowManager.setTitle('OpenChat');

    final trayIcon = native.TrayIcon();
    final contextMenu = native.Menu();
    final showItem = native.MenuItem('Show OpenChat');
    final quitItem = native.MenuItem('Quit OpenChat');

    showItem.on<native.MenuItemClickedEvent>((_) {
      unawaited(_showWindow());
    });
    quitItem.on<native.MenuItemClickedEvent>((_) {
      unawaited(_quit());
    });

    contextMenu.addItem(showItem);
    contextMenu.addSeparator();
    contextMenu.addItem(quitItem);

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
    _quitItem = quitItem;
    _trayIcon = trayIcon;
  }

  @override
  Future<void> onWindowClose() async {
    if (_quitting) {
      await windowManager.destroy();
      return;
    }
    await windowManager.hide();
    await windowManager.setSkipTaskbar(true);
  }

  Future<void> _showWindow() async {
    await windowManager.setSkipTaskbar(false);
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _quit() async {
    _quitting = true;
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  void dispose() {
    if (!supported) return;
    windowManager.removeListener(this);

    _trayIcon?.dispose();
    _trayIcon = null;

    _showItem?.dispose();
    _showItem = null;
    _quitItem?.dispose();
    _quitItem = null;

    _contextMenu?.dispose();
    _contextMenu = null;

    _trayIconImage?.dispose();
    _trayIconImage = null;
  }
}
