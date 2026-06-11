import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/services/mesh/mesh_platform.dart';

void main() {
  group('mesh platform roles', () {
    test('dual role where both flutter_blue_ce and ble_peripheral exist', () {
      for (final platform in [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.windows,
      ]) {
        final role = meshRoleFor(platform, isWeb: false);
        expect(role, MeshRole.dualRole, reason: '$platform');
        expect(role.canRun, isTrue);
        expect(role.advertises, isTrue);
      }
    });

    test('Linux is central-only (no ble_peripheral implementation)', () {
      final role = meshRoleFor(TargetPlatform.linux, isWeb: false);
      expect(role, MeshRole.centralOnly);
      expect(role.canRun, isTrue);
      expect(role.advertises, isFalse);
    });

    test('web is unsupported regardless of the reported platform', () {
      for (final platform in TargetPlatform.values) {
        final role = meshRoleFor(platform, isWeb: true);
        expect(role, MeshRole.unsupported, reason: '$platform');
        expect(role.canRun, isFalse);
      }
    });

    test('fuchsia is unsupported', () {
      expect(
        meshRoleFor(TargetPlatform.fuchsia, isWeb: false),
        MeshRole.unsupported,
      );
    });
  });
}
