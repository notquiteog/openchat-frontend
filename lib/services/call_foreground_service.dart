import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract class CallForegroundController {
  Future<bool> start({
    required String title,
    required String body,
    required bool isVideo,
    required bool muted,
  });

  Future<void> stop();
}

enum CallForegroundAction { toggleMute, end }

class CallForegroundService implements CallForegroundController {
  static const MethodChannel _channel = MethodChannel(
    'openchat/call_foreground',
  );
  static final StreamController<CallForegroundAction> _actions =
      StreamController<CallForegroundAction>.broadcast();
  static bool _handlerInstalled = false;

  const CallForegroundService();

  static Stream<CallForegroundAction> get actions {
    init();
    return _actions.stream;
  }

  static void init() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'action') return null;
      final args = call.arguments;
      final action = args is Map ? args['action'] as String? : null;
      _addAction(action);
      return null;
    });
    unawaited(_drainPendingNativeActions());
  }

  static Future<void> _drainPendingNativeActions() async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) {
      return;
    }
    try {
      final pending = await _channel.invokeMethod<List<Object?>>(
        'takePendingActions',
      );
      if (pending == null) return;
      for (final action in pending) {
        _addAction(action as String?);
      }
    } catch (_) {}
  }

  static void _addAction(String? action) {
    switch (action) {
      case 'toggleMute':
        _actions.add(CallForegroundAction.toggleMute);
        return;
      case 'end':
        _actions.add(CallForegroundAction.end);
        return;
      default:
        return;
    }
  }

  @override
  Future<bool> start({
    required String title,
    required String body,
    required bool isVideo,
    required bool muted,
  }) async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) {
      return true;
    }
    try {
      final started = await _channel.invokeMethod<bool>(
        'start',
        <String, Object>{
          'title': title,
          'body': body,
          'isVideo': isVideo,
          'muted': muted,
        },
      );
      return started ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> stop() async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
  }
}
