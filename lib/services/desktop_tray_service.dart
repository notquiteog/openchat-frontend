import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

class DesktopTrayService with WindowListener, TrayListener {
  bool _quitting = false;

  static bool get supported =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  Future<void> init() async {
    if (!supported) return;
    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);
    await windowManager.setTitle('OpenChat');

    trayManager.addListener(this);
    await trayManager.setIcon('assets/images/logo.png');
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show', label: 'Show OpenChat'),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: 'Quit OpenChat'),
        ],
      ),
    );
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

  @override
  Future<void> onTrayIconMouseDown() async {
    await _showWindow();
  }

  @override
  Future<void> onTrayIconRightMouseDown() async {
    await trayManager.popUpContextMenu();
  }

  @override
  Future<void> onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'show':
        await _showWindow();
      case 'quit':
        _quitting = true;
        await windowManager.setPreventClose(false);
        await windowManager.destroy();
    }
  }

  Future<void> _showWindow() async {
    await windowManager.setSkipTaskbar(false);
    await windowManager.show();
    await windowManager.focus();
  }

  void dispose() {
    if (!supported) return;
    windowManager.removeListener(this);
    trayManager.removeListener(this);
  }
}
