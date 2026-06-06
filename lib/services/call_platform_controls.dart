import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class CallPlatformControls {
  static const MethodChannel _channel = MethodChannel('openchat/call_controls');

  const CallPlatformControls();

  Future<bool> selectAudioOutput(
    String deviceId, {
    bool isVideo = false,
  }) async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return false;
    try {
      final routed = await _channel.invokeMethod<bool>(
        'selectAudioOutput',
        <String, Object?>{'deviceId': deviceId, 'isVideo': isVideo},
      );
      return routed ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> setMicrophoneMuted(bool muted) async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return false;
    try {
      final routed = await _channel.invokeMethod<bool>(
        'setMicrophoneMuted',
        <String, Object?>{'muted': muted},
      );
      return routed ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> clearAudioOutput() async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    try {
      await _channel.invokeMethod<void>('clearAudioOutput');
    } catch (_) {}
  }
}
