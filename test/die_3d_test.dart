import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/widgets/die_3d.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

void main() {
  group('Die3D geometry', () {
    /// The face normals as placed in the widget (front 1, back 6, right 2,
    /// left 5, top 3, bottom 4 — opposite faces sum to 7).
    final normals = <int, vm.Vector3>{
      1: vm.Vector3(0, 0, -1),
      2: vm.Vector3(1, 0, 0),
      3: vm.Vector3(0, -1, 0),
      4: vm.Vector3(0, 1, 0),
      5: vm.Vector3(-1, 0, 0),
      6: vm.Vector3(0, 0, 1),
    };

    test('targetRotationFor turns every value to face the viewer', () {
      for (var value = 1; value <= 6; value++) {
        final (rx, ry) = Die3D.targetRotationFor(value);
        final rotation = Matrix4.identity()
          ..rotateX(rx)
          ..rotateY(ry);
        final n = rotation.transform3(normals[value]!.clone());
        // Toward the viewer = -z in Flutter's coordinate system.
        expect(n.z, closeTo(-1, 1e-9), reason: 'value $value');
        expect(n.x.abs() + n.y.abs(), closeTo(0, 1e-9), reason: 'value $value');
      }
    });

    test('full 2π spins land on the same orientation', () {
      final (rx, ry) = Die3D.targetRotationFor(3);
      final spun = Matrix4.identity()
        ..rotateX(rx + 4 * math.pi)
        ..rotateY(ry - 6 * math.pi);
      final n = spun.transform3(normals[3]!.clone());
      expect(n.z, closeTo(-1, 1e-9));
    });
  });

  testWidgets('Die3D renders and culls to at most 3 visible faces',
      (tester) async {
    final (rx, ry) = Die3D.targetRotationFor(5);
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: Die3D(
            // Presentation tilt + target: shows the 5 plus two edge faces.
            rotation: Matrix4.identity()
              ..rotateX(-0.3)
              ..rotateY(0.35)
              ..rotateX(rx)
              ..rotateY(ry),
            size: 54,
          ),
        ),
      ),
    );
    // A convex cube can never show more than 3 faces.
    final faces = find
        .descendant(of: find.byType(Die3D), matching: find.byType(CustomPaint))
        .evaluate()
        .length;
    expect(faces, inInclusiveRange(1, 3));
  });
}
