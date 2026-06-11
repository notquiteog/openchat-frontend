import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

/// A 3D six-sided die rendered with real perspective: six pip faces on a
/// cube, back-face culled, with a fixed light direction so faces shade as
/// the cube turns. Pure Flutter transforms — no shaders, no packages.
///
/// Face layout (opposite faces sum to 7, like a real die):
/// front 1 · back 6 · right 2 · left 5 · top 3 · bottom 4.
class Die3D extends StatelessWidget {
  const Die3D({super.key, required this.rotation, required this.size});

  /// Cube orientation (pure rotation — compose with [targetRotationFor] to
  /// land a chosen value facing the viewer).
  final Matrix4 rotation;
  final double size;

  /// Rotation (rx, ry) that brings [value]'s face toward the viewer.
  static (double, double) targetRotationFor(int value) => switch (value) {
        1 => (0, 0),
        2 => (0, math.pi / 2),
        3 => (math.pi / 2, 0),
        4 => (-math.pi / 2, 0),
        5 => (0, -math.pi / 2),
        6 => (0, math.pi),
        _ => (0, 0),
      };

  static final List<({int value, vm.Vector3 normal, Matrix4 place})> _faces = [
    (
      value: 1,
      normal: vm.Vector3(0, 0, -1),
      place: Matrix4.identity()..translateByDouble(0.0, 0.0, -0.5, 1.0),
    ),
    (
      value: 6,
      normal: vm.Vector3(0, 0, 1),
      place: Matrix4.identity()
        ..rotateY(math.pi)
        ..translateByDouble(0.0, 0.0, -0.5, 1.0),
    ),
    (
      value: 2,
      normal: vm.Vector3(1, 0, 0),
      place: Matrix4.identity()
        ..rotateY(-math.pi / 2)
        ..translateByDouble(0.0, 0.0, -0.5, 1.0),
    ),
    (
      value: 5,
      normal: vm.Vector3(-1, 0, 0),
      place: Matrix4.identity()
        ..rotateY(math.pi / 2)
        ..translateByDouble(0.0, 0.0, -0.5, 1.0),
    ),
    (
      value: 3,
      normal: vm.Vector3(0, -1, 0),
      place: Matrix4.identity()
        ..rotateX(-math.pi / 2)
        ..translateByDouble(0.0, 0.0, -0.5, 1.0),
    ),
    (
      value: 4,
      normal: vm.Vector3(0, 1, 0),
      place: Matrix4.identity()
        ..rotateX(math.pi / 2)
        ..translateByDouble(0.0, 0.0, -0.5, 1.0),
    ),
  ];

  /// Light from the viewer's upper left, normalized.
  static final vm.Vector3 _light = vm.Vector3(-0.35, -0.55, -0.75).normalized();

  @override
  Widget build(BuildContext context) {
    final visible = <Widget>[];
    for (final face in _faces) {
      final worldNormal = rotation.transform3(face.normal.clone());
      // Convex cube: a face is visible iff its outward normal points at the
      // viewer (screen z grows away from the viewer).
      if (worldNormal.z >= 0) continue;
      final brightness = worldNormal.dot(_light).clamp(0.0, 1.0);
      // Scale the unit-cube placement to pixels: translation happens in
      // face-local units of one cube edge.
      final place = face.place.clone();
      place.setTranslation(place.getTranslation()..scale(size));
      visible.add(
        Transform(
          alignment: Alignment.center,
          transform: place,
          child: _DieFace(
            value: face.value,
            size: size,
            brightness: brightness,
          ),
        ),
      );
    }
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..setEntry(3, 2, 0.0011)
        ..multiply(rotation),
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(clipBehavior: Clip.none, children: visible),
      ),
    );
  }
}

class _DieFace extends StatelessWidget {
  const _DieFace({
    required this.value,
    required this.size,
    required this.brightness,
  });

  final int value;
  final double size;

  /// 0 = fully in shadow, 1 = facing the light.
  final double brightness;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _DieFacePainter(value: value, brightness: brightness),
      ),
    );
  }
}

class _DieFacePainter extends CustomPainter {
  _DieFacePainter({required this.value, required this.brightness});

  final int value;
  final double brightness;

  /// Pip centers per value on the unit face.
  static const Map<int, List<Offset>> _pips = {
    1: [Offset(0.5, 0.5)],
    2: [Offset(0.28, 0.28), Offset(0.72, 0.72)],
    3: [Offset(0.25, 0.25), Offset(0.5, 0.5), Offset(0.75, 0.75)],
    4: [
      Offset(0.28, 0.28),
      Offset(0.72, 0.28),
      Offset(0.28, 0.72),
      Offset(0.72, 0.72),
    ],
    5: [
      Offset(0.26, 0.26),
      Offset(0.74, 0.26),
      Offset(0.5, 0.5),
      Offset(0.26, 0.74),
      Offset(0.74, 0.74),
    ],
    6: [
      Offset(0.3, 0.24),
      Offset(0.7, 0.24),
      Offset(0.3, 0.5),
      Offset(0.7, 0.5),
      Offset(0.3, 0.76),
      Offset(0.7, 0.76),
    ],
  };

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(size.width * 0.015),
      Radius.circular(size.width * 0.18),
    );

    // Ivory body, shaded by how squarely this face meets the light.
    final lit = Color.lerp(
      const Color(0xFFB9B5AC),
      const Color(0xFFFDFCF8),
      0.35 + 0.65 * brightness,
    )!;
    final shadowEdge = Color.lerp(lit, const Color(0xFF8E8A80), 0.45)!;
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [lit, shadowEdge],
        ).createShader(rect),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width * 0.02
        ..color = const Color(0x33000000),
    );

    final pipRadius = size.width * 0.075;
    final pipPaint = Paint()
      ..color = Color.lerp(
        const Color(0xFF3A3833),
        const Color(0xFF14130F),
        brightness,
      )!;
    final pipHighlight = Paint()..color = const Color(0x2EFFFFFF);
    for (final pip in _pips[value] ?? const <Offset>[]) {
      final center = Offset(pip.dx * size.width, pip.dy * size.height);
      canvas.drawCircle(center, pipRadius, pipPaint);
      // A drilled-pip glint: tiny offset highlight crescent.
      canvas.drawCircle(
        center.translate(-pipRadius * 0.25, -pipRadius * 0.25),
        pipRadius * 0.35,
        pipHighlight,
      );
    }
  }

  @override
  bool shouldRepaint(_DieFacePainter old) =>
      old.value != value || old.brightness != brightness;
}
