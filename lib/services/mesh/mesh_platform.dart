/// Mesh wire protocol, layer 0 prelude: what the local radio can do here.
///
/// Central (scan + dial) comes from the flutter_blue_ce parity fork, which
/// covers Android, iOS, macOS, Windows (WinRT), and Linux (BlueZ).
/// Peripheral (advertise + GATT server) comes from ble_peripheral, which has
/// Android, iOS, macOS, and Windows implementations but no Linux one — so
/// Linux runs central-only: it finds and links to dual-role peers, but two
/// central-only devices cannot see each other. Web Bluetooth needs a
/// per-device user-gesture chooser and has no peripheral mode at all, so the
/// mesh stays unsupported there.
library;

import 'package:flutter/foundation.dart';

enum MeshRole {
  /// Advertise + scan simultaneously: Android, iOS, macOS, Windows.
  dualRole,

  /// Scan + connect only — not discoverable by other devices: Linux.
  centralOnly,

  unsupported;

  bool get canRun => this != MeshRole.unsupported;
  bool get advertises => this == MeshRole.dualRole;
}

MeshRole meshRoleFor(TargetPlatform platform, {required bool isWeb}) {
  if (isWeb) return MeshRole.unsupported;
  return switch (platform) {
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.macOS ||
    TargetPlatform.windows =>
      MeshRole.dualRole,
    TargetPlatform.linux => MeshRole.centralOnly,
    _ => MeshRole.unsupported,
  };
}

/// The role for the device this build is running on.
MeshRole get currentMeshRole =>
    meshRoleFor(defaultTargetPlatform, isWeb: kIsWeb);
