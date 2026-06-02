import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract class CallForegroundController {
  Future<bool> start({
    required String title,
    required String body,
    required bool isVideo,
  });

  Future<void> stop();
}

class CallForegroundService implements CallForegroundController {
  static const MethodChannel _channel =
      MethodChannel('openchat/call_foreground');

  const CallForegroundService();

  @override
  Future<bool> start({
    required String title,
    required String body,
    required bool isVideo,
  }) async {
    if (kIsWeb || !Platform.isAndroid) return true;
    try {
      final started = await _channel.invokeMethod<bool>(
        'start',
        <String, Object>{
          'title': title,
          'body': body,
          'isVideo': isVideo,
        },
      );
      return started ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> stop() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
  }
}
