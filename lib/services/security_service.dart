import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bridges the native `openchat/security` platform channel:
///   * screenshot / screen-recording prevention (Android FLAG_SECURE; iOS
///     secure-layer hosting), and
///   * screenshot *detection* (a stream of events, used by view-once media).
///
/// Screen security is reference-counted: a persistent global toggle (Trust
/// Center) plus any number of transient "always-on" requests from sensitive
/// screens (view-once viewer, PIN gate, key/recovery/QR). The screen stays
/// secure while the global flag is on OR at least one force-secure lease is held.
class SecurityService {
  SecurityService._();
  static final SecurityService instance = SecurityService._();

  static const MethodChannel _channel = MethodChannel('openchat/security');
  final StreamController<void> _screenshots =
      StreamController<void>.broadcast();

  bool _globalSecure = false;
  int _forceSecureCount = 0;
  bool _detecting = false;
  bool _handlerInstalled = false;

  bool get _supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Fires whenever the OS reports the user captured a screenshot while
  /// detection is active. Listen only while a view-once item is on screen.
  Stream<void> get screenshots {
    _ensureHandler();
    return _screenshots.stream;
  }

  void _ensureHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'screenshotTaken' && !_screenshots.isClosed) {
        _screenshots.add(null);
      }
      return null;
    });
  }

  /// Persistent global setting from the Trust Center. The caller persists the
  /// boolean; this just applies it.
  Future<void> setGlobalSecure(bool enabled) async {
    _globalSecure = enabled;
    await _apply();
  }

  /// Force screen security on for a sensitive screen. Returns a release callback
  /// to call on dispose; the screen reverts to the global setting once every
  /// lease is released. Safe to call on unsupported platforms (no-op).
  Future<VoidCallback> pushForceSecure() async {
    _forceSecureCount++;
    await _apply();
    var released = false;
    return () {
      if (released) return;
      released = true;
      if (_forceSecureCount > 0) _forceSecureCount--;
      unawaited(_apply());
    };
  }

  Future<void> _apply() async {
    if (!_supported) return;
    final secure = _globalSecure || _forceSecureCount > 0;
    try {
      await _channel.invokeMethod('setScreenSecure', {'secure': secure});
    } catch (_) {
      // Channel unavailable (e.g. desktop/web) — ignore.
    }
  }

  Future<void> startScreenshotDetection() async {
    if (!_supported || _detecting) return;
    _detecting = true;
    _ensureHandler();
    try {
      await _channel.invokeMethod('startScreenshotDetection');
    } catch (_) {}
  }

  Future<void> stopScreenshotDetection() async {
    if (!_supported || !_detecting) return;
    _detecting = false;
    try {
      await _channel.invokeMethod('stopScreenshotDetection');
    } catch (_) {}
  }
}
