import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

/// A 3D six-sided die rendered with real perspective: six pip faces on a
/// cube, back-face culled, lit by a fixed directional light with a Blinn-Phong
/// specular term so a glossy hotspot sweeps across faces as the cube turns.
/// Pure Flutter transforms + CustomPaint — no shaders, no packages.
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

  static ({
    int value,
    vm.Vector3 normal,
    vm.Vector3 u,
    vm.Vector3 v,
    Matrix4 place,
  }) _face(int value, Matrix4 orient) {
    final rot = orient.getRotation();
    return (
      value: value,
      normal: rot.transform(vm.Vector3(0, 0, -1)),
      // Face-local x/y axes in cube space, so lighting can be expressed in
      // the face's own 2D coordinates (x right, y down).
      u: rot.transform(vm.Vector3(1, 0, 0)),
      v: rot.transform(vm.Vector3(0, 1, 0)),
      place: orient.clone()..translateByDouble(0.0, 0.0, -0.5, 1.0),
    );
  }

  static final List<
      ({
        int value,
        vm.Vector3 normal,
        vm.Vector3 u,
        vm.Vector3 v,
        Matrix4 place,
      })> _faces = [
    _face(1, Matrix4.identity()),
    _face(6, Matrix4.identity()..rotateY(math.pi)),
    _face(2, Matrix4.identity()..rotateY(-math.pi / 2)),
    _face(5, Matrix4.identity()..rotateY(math.pi / 2)),
    _face(3, Matrix4.identity()..rotateX(-math.pi / 2)),
    _face(4, Matrix4.identity()..rotateX(math.pi / 2)),
  ];

  /// Light from the viewer's upper left, normalized.
  static final vm.Vector3 _light = vm.Vector3(-0.35, -0.55, -0.75).normalized();

  /// Blinn-Phong half-vector between the light and the viewer (view direction
  /// is -z: screen z grows away from the camera).
  static final vm.Vector3 _half =
      (_light + vm.Vector3(0, 0, -1)).normalized();

  @override
  Widget build(BuildContext context) {
    final visible = <Widget>[];
    for (final face in _faces) {
      final worldNormal = rotation.transform3(face.normal.clone());
      // Convex cube: a face is visible iff its outward normal points at the
      // viewer (screen z grows away from the viewer).
      if (worldNormal.z >= 0) continue;
      final worldU = rotation.transform3(face.u.clone());
      final worldV = rotation.transform3(face.v.clone());
      final diffuse = worldNormal.dot(_light).clamp(0.0, 1.0);
      // Specular: sharp Blinn-Phong lobe. The hotspot drifts across the face
      // toward the half-vector's tangential component, as if the face were
      // slightly domed — that moving glint is what sells the material.
      final spec =
          math.pow(worldNormal.dot(_half).clamp(0.0, 1.0), 30).toDouble();
      final specCenter = Offset(_half.dot(worldU), _half.dot(worldV));
      final lightDir = Offset(_light.dot(worldU), _light.dot(worldV));
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
            brightness: diffuse,
            spec: spec,
            specCenter: specCenter,
            lightDir: lightDir,
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
    required this.spec,
    required this.specCenter,
    required this.lightDir,
  });

  final int value;
  final double size;

  /// 0 = fully in shadow, 1 = facing the light.
  final double brightness;

  /// Specular lobe intensity (0..1) and its center in face coords (fraction
  /// of a half-face from center).
  final double spec;
  final Offset specCenter;

  /// Light direction projected into this face's 2D plane (x right, y down).
  final Offset lightDir;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _DieFacePainter(
          value: value,
          brightness: brightness,
          spec: spec,
          specCenter: specCenter,
          lightDir: lightDir,
        ),
      ),
    );
  }
}

class _DieFacePainter extends CustomPainter {
  _DieFacePainter({
    required this.value,
    required this.brightness,
    required this.spec,
    required this.specCenter,
    required this.lightDir,
  });

  final int value;
  final double brightness;
  final double spec;
  final Offset specCenter;
  final Offset lightDir;

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
    final center = rect.center;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(size.width * 0.012),
      Radius.circular(size.width * 0.20),
    );

    // Clean resin-white body, cool grey in shadow; the gradient runs along
    // the light so the lit corner reads brighter than the far corner.
    final lit = Color.lerp(
      const Color(0xFFAFB3BC),
      const Color(0xFFFFFFFF),
      0.30 + 0.70 * brightness,
    )!;
    final shaded = Color.lerp(lit, const Color(0xFF7E828C), 0.40)!;
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment(
            lightDir.dx.clamp(-1.0, 1.0),
            lightDir.dy.clamp(-1.0, 1.0),
          ),
          end: Alignment(
            (-lightDir.dx).clamp(-1.0, 1.0),
            (-lightDir.dy).clamp(-1.0, 1.0),
          ),
          colors: [lit, shaded],
        ).createShader(rect),
    );

    // Ambient occlusion: corners and edges sit deeper than the face center.
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = RadialGradient(
          radius: 0.78,
          colors: const [
            Color(0x00000000),
            Color(0x00000000),
            Color(0x24000000),
          ],
          stops: const [0.0, 0.62, 1.0],
        ).createShader(rect),
    );

    // Broad sheen + sharp glint where the Blinn-Phong lobe peaks. The center
    // tracks the half-vector so the highlight sweeps as the cube tumbles.
    if (spec > 0.01) {
      final hotspot = center + specCenter * size.width * 0.60;
      canvas.drawRRect(
        rrect,
        Paint()
          ..shader = RadialGradient(
            colors: [
              Colors.white.withValues(alpha: 0.50 * spec),
              Colors.white.withValues(alpha: 0.12 * spec),
              Colors.transparent,
            ],
            stops: const [0.0, 0.35, 1.0],
          ).createShader(
            Rect.fromCircle(center: hotspot, radius: size.width * 0.55),
          ),
      );
    }

    // Beveled rim: catches light on the lit side, falls into shadow opposite.
    final bevel = rrect.deflate(size.width * 0.012);
    canvas.drawRRect(
      bevel,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width * 0.028
        ..shader = LinearGradient(
          begin: Alignment(
            lightDir.dx.clamp(-1.0, 1.0),
            lightDir.dy.clamp(-1.0, 1.0),
          ),
          end: Alignment(
            (-lightDir.dx).clamp(-1.0, 1.0),
            (-lightDir.dy).clamp(-1.0, 1.0),
          ),
          colors: [
            Colors.white.withValues(alpha: 0.50 * brightness),
            Colors.black.withValues(alpha: 0.22),
          ],
        ).createShader(rect),
    );

    // Hairline contour keeps the silhouette crisp against any bubble color.
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width * 0.012
        ..color = const Color(0x26000000),
    );

    // Drilled pips: each is a concave pit. The wall away from the light is
    // lit, the near rim shadows the pit, and a thin catch-light crescent
    // rings the far edge.
    final pipRadius = size.width * 0.072;
    final toLight = lightDir.distance > 1e-4
        ? lightDir / lightDir.distance
        : const Offset(-0.7, -0.7);
    final pitDark = Color.lerp(
      const Color(0xFF26282E),
      const Color(0xFF0C0D10),
      brightness,
    )!;
    final pitLitWall = Color.lerp(
      const Color(0xFF3A3D44),
      const Color(0xFF565B66),
      brightness,
    )!;
    for (final pip in _pips[value] ?? const <Offset>[]) {
      final c = Offset(pip.dx * size.width, pip.dy * size.height);
      // Catch-light crescent: a bright disc peeking out on the far-from-light
      // side, mostly covered by the pit drawn after it.
      canvas.drawCircle(
        c - toLight * (pipRadius * 0.10),
        pipRadius,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.40 * brightness + 0.08),
      );
      // The pit itself, nudged toward the light so the crescent survives;
      // shaded dark near the light-side rim, lighter on the far wall.
      canvas.drawCircle(
        c + toLight * (pipRadius * 0.06),
        pipRadius * 0.96,
        Paint()
          ..shader = RadialGradient(
            colors: [pitLitWall, pitDark],
            stops: const [0.0, 1.0],
          ).createShader(
            Rect.fromCircle(
              center: c - toLight * (pipRadius * 0.45),
              radius: pipRadius * 1.5,
            ),
          ),
      );
    }
  }

  @override
  bool shouldRepaint(_DieFacePainter old) =>
      old.value != value ||
      old.brightness != brightness ||
      old.spec != spec ||
      old.specCenter != specCenter ||
      old.lightDir != lightDir;
}
