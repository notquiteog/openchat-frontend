import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

String openChatDeviceName({bool isWeb = kIsWeb, TargetPlatform? platform}) {
  if (isWeb) return 'Web';

  switch (platform ?? defaultTargetPlatform) {
    case TargetPlatform.android:
      return 'Android';
    case TargetPlatform.iOS:
      return 'iOS';
    case TargetPlatform.macOS:
      return 'macOS';
    case TargetPlatform.windows:
      return 'Windows';
    case TargetPlatform.linux:
      return 'Linux';
    case TargetPlatform.fuchsia:
      return 'Fuchsia';
  }
}

String sessionDeviceDisplayLabel(Map<String, dynamic> session) {
  final deviceName = _cleanSessionLabel(session['device_name']);
  if (deviceName != null) return deviceName;

  final userAgentLabel = operatingSystemFromUserAgent(session['user_agent']);
  return userAgentLabel ?? 'OpenChat session';
}

String? operatingSystemFromUserAgent(Object? value) {
  if (value is! String) return null;

  final userAgent = value.trim();
  if (userAgent.isEmpty || _isRawDartUserAgent(userAgent)) return null;

  final openChatLabel = _openChatUserAgentLabel(userAgent);
  if (openChatLabel != null) return openChatLabel;

  final lower = userAgent.toLowerCase();
  if (lower.contains('android')) return 'Android';
  if (lower.contains('iphone') ||
      lower.contains('ipad') ||
      lower.contains('ipod') ||
      lower.contains('ios')) {
    return 'iOS';
  }
  if (lower.contains('mac os x') ||
      lower.contains('macintosh') ||
      lower.contains('darwin')) {
    return 'macOS';
  }
  if (lower.contains('windows')) return 'Windows';
  if (lower.contains('linux') || lower.contains('x11')) return 'Linux';
  if (lower.contains('fuchsia')) return 'Fuchsia';

  return null;
}

String? _cleanSessionLabel(Object? value) {
  if (value is! String) return null;

  final label = value.trim();
  if (label.isEmpty || _isRawDartUserAgent(label)) return null;
  return label;
}

String? _openChatUserAgentLabel(String userAgent) {
  final match = RegExp(
    r'^OpenChat(?: Flutter)?/(Android|iOS|macOS|Windows|Linux|Fuchsia|Web)\b',
    caseSensitive: false,
  ).firstMatch(userAgent);
  if (match == null) return null;

  final label = match.group(1)?.toLowerCase();
  switch (label) {
    case 'android':
      return 'Android';
    case 'ios':
      return 'iOS';
    case 'macos':
      return 'macOS';
    case 'windows':
      return 'Windows';
    case 'linux':
      return 'Linux';
    case 'fuchsia':
      return 'Fuchsia';
    case 'web':
      return 'Web';
  }
  return null;
}

bool _isRawDartUserAgent(String value) {
  return value.toLowerCase().startsWith('dart/');
}
