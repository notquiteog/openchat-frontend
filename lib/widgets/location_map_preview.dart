import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/message.dart';

class LocationMapPreview extends StatelessWidget {
  final MessageLocation location;
  final bool compact;
  final bool showCoordinates;

  const LocationMapPreview({
    super.key,
    required this.location,
    this.compact = true,
    this.showCoordinates = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pinSize = compact ? 38.0 : 58.0;
    final accuracy = location.accuracy;
    final accuracyRadius = accuracy == null
        ? 0.0
        : (compact ? 22.0 : 44.0) +
              math.min(compact ? 58.0 : 150.0, math.sqrt(accuracy) * 3.4);

    return Stack(
      fit: StackFit.expand,
      children: [
        CustomPaint(
          painter: _LocationMapPainter(
            latitude: location.latitude,
            longitude: location.longitude,
            scheme: scheme,
            compact: compact,
          ),
        ),
        if (accuracy != null)
          Center(
            child: Container(
              width: accuracyRadius,
              height: accuracyRadius,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.primary.withValues(alpha: compact ? 0.16 : 0.18),
                border: Border.all(
                  color: scheme.primary.withValues(alpha: 0.35),
                  width: compact ? 1 : 2,
                ),
              ),
            ),
          ),
        Center(
          child: Icon(
            Icons.location_on,
            size: pinSize,
            color: Colors.redAccent,
            shadows: const [Shadow(blurRadius: 14, color: Colors.black54)],
          ),
        ),
        if (location.isLive)
          Positioned(
            top: compact ? 8 : 18,
            left: compact ? 8 : 18,
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 8 : 12,
                vertical: compact ? 4 : 7,
              ),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                color: Colors.redAccent.withValues(alpha: 0.92),
                boxShadow: const [
                  BoxShadow(
                    blurRadius: 16,
                    color: Colors.black26,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: Text(
                location.isActive ? 'Live' : 'Ended',
                style: TextStyle(
                  fontSize: compact ? 11 : 14,
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ),
        if (showCoordinates)
          Positioned(
            left: 18,
            right: 18,
            bottom: 18,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.white24),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: Text(
                  '${location.latitude.toStringAsFixed(6)}, ${location.longitude.toStringAsFixed(6)}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _LocationMapPainter extends CustomPainter {
  final double latitude;
  final double longitude;
  final ColorScheme scheme;
  final bool compact;

  const _LocationMapPainter({
    required this.latitude,
    required this.longitude,
    required this.scheme,
    required this.compact,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final seed = latitude * 13.37 + longitude * 7.91;
    final background = Paint()
      ..shader = LinearGradient(
        colors: [
          Color.lerp(scheme.surfaceContainerHighest, scheme.primary, 0.10)!,
          Color.lerp(scheme.surface, scheme.secondaryContainer, 0.45)!,
        ],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ).createShader(rect);
    canvas.drawRect(rect, background);

    final parkPaint = Paint()
      ..color = Color.lerp(
        Colors.green.shade200,
        scheme.surface,
        0.25,
      )!.withValues(alpha: 0.34);
    for (var i = 0; i < 5; i++) {
      final cx = size.width * (0.12 + ((math.sin(seed + i) + 1) / 2) * 0.76);
      final cy =
          size.height * (0.10 + ((math.cos(seed * 0.7 + i) + 1) / 2) * 0.80);
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(cx, cy),
          width: size.width * (0.18 + i * 0.018),
          height: size.height * (0.12 + i * 0.012),
        ),
        parkPaint,
      );
    }

    final gridPaint = Paint()
      ..color = scheme.onSurface.withValues(alpha: 0.08)
      ..strokeWidth = compact ? 0.8 : 1.2;
    final grid = compact ? 34.0 : 56.0;
    for (var x = -grid; x < size.width + grid; x += grid) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x + size.height * 0.18, size.height),
        gridPaint,
      );
    }
    for (var y = -grid; y < size.height + grid; y += grid) {
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y - size.width * 0.08),
        gridPaint,
      );
    }

    final roadBase = Paint()
      ..color = scheme.surface.withValues(alpha: 0.92)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = compact ? 13 : 24;
    final roadLine = Paint()
      ..color = scheme.primary.withValues(alpha: 0.28)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = compact ? 2.1 : 3.2;

    for (var i = 0; i < 4; i++) {
      final y = size.height * (0.18 + i * 0.20);
      final bend = math.sin(seed + i * 1.8) * size.height * 0.18;
      final path = Path()
        ..moveTo(-size.width * 0.08, y)
        ..quadraticBezierTo(
          size.width * 0.36,
          y + bend,
          size.width * 1.08,
          y - bend * 0.55,
        );
      canvas.drawPath(path, roadBase);
      canvas.drawPath(path, roadLine);
    }

    final crossRoad = Paint()
      ..color = scheme.surface.withValues(alpha: 0.72)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = compact ? 7 : 15;
    for (var i = 0; i < 3; i++) {
      final x = size.width * (0.24 + i * 0.26);
      final path = Path()
        ..moveTo(x, -size.height * 0.08)
        ..quadraticBezierTo(
          x + math.cos(seed + i) * size.width * 0.18,
          size.height * 0.48,
          x - math.sin(seed + i) * size.width * 0.20,
          size.height * 1.08,
        );
      canvas.drawPath(path, crossRoad);
    }

    final vignette = Paint()
      ..shader = RadialGradient(
        colors: [Colors.transparent, Colors.black.withValues(alpha: 0.18)],
        stops: const [0.58, 1],
      ).createShader(rect);
    canvas.drawRect(rect, vignette);
  }

  @override
  bool shouldRepaint(covariant _LocationMapPainter oldDelegate) {
    return oldDelegate.latitude != latitude ||
        oldDelegate.longitude != longitude ||
        oldDelegate.scheme != scheme ||
        oldDelegate.compact != compact;
  }
}
