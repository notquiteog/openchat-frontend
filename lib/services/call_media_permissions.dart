import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:permission_handler/permission_handler.dart';

class CallPermissionException implements Exception {
  final String message;

  const CallPermissionException(this.message);

  @override
  String toString() => message;
}

typedef CallMediaPermissionGate =
    Future<void> Function({required bool isVideo});

Future<void> ensureCallMediaPermissions({required bool isVideo}) async {
  if (!_needsRuntimeCallMediaPermissions) return;

  final denied = <String, PermissionStatus>{};
  final microphone = await Permission.microphone.request();
  if (!microphone.isGranted) denied['microphone'] = microphone;

  if (isVideo) {
    final camera = await Permission.camera.request();
    if (!camera.isGranted) denied['camera'] = camera;
  }

  if (denied.isEmpty) return;

  final names = _formatPermissionNames(denied.keys.toList(growable: false));
  final permanentlyDenied = denied.values.any(
    (status) => status.isPermanentlyDenied || status.isRestricted,
  );
  final permissionLabel = denied.length == 1 ? 'permission' : 'permissions';
  final verb = denied.length == 1 ? 'is' : 'are';
  final nextStep = permanentlyDenied
      ? 'Enable $names in system settings, then try again.'
      : 'Grant $names access, then try again.';
  final kind = isVideo ? 'video' : 'voice';

  throw CallPermissionException(
    '${_capitalize(names)} $permissionLabel $verb required before $kind calls can start. $nextStep',
  );
}

bool get _needsRuntimeCallMediaPermissions {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
}

String _formatPermissionNames(List<String> names) {
  if (names.length <= 1) return names.single;
  return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
}

String _capitalize(String value) {
  if (value.isEmpty) return value;
  return '${value[0].toUpperCase()}${value.substring(1)}';
}
