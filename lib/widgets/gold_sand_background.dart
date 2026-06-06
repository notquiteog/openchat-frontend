import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Full-screen animated gold sand particle background driven by a fragment
/// shader ([shaders/gold_sand.frag]).
///
/// The shader is loaded once from assets and then redrawn every frame via a
/// [Ticker].  While the shader is loading (typically one frame) a solid dark
/// fallback colour is shown so there is no flash.  If the shader fails to load
/// (unsupported device, hot-restart asset mismatch, etc.) the fallback colour
/// remains — the UI above is unaffected.
///
/// The animated canvas is isolated in a [RepaintBoundary] and driven by a
/// [ValueNotifier] so only the painter layer is invalidated each frame; the
/// [child] widget tree is never unnecessarily rebuilt.
///
/// Usage:
/// ```dart
/// GoldSandBackground(child: myContent)
/// ```
class GoldSandBackground extends StatefulWidget {
  const GoldSandBackground({super.key, required this.child});

  final Widget child;

  @override
  State<GoldSandBackground> createState() => _GoldSandBackgroundState();
}

class _GoldSandBackgroundState extends State<GoldSandBackground>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<double> _elapsed = ValueNotifier(0);
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((d) => _elapsed.value = d.inMicroseconds / 1e6);
    _loadShader();
  }

  Future<void> _loadShader() async {
    try {
      final program =
          await ui.FragmentProgram.fromAsset('shaders/gold_sand.frag');
      if (!mounted) return;
      setState(() => _shader = program.fragmentShader());
      _ticker.start();
    } catch (e) {
      // Shader compilation or asset-loading failure.
      // The solid fallback colour is already shown; nothing else to do.
      debugPrint('GoldSandBackground: failed to load shader — $e');
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _elapsed.dispose();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shader = _shader;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Background layer — either the live shader or a static fallback
        if (shader != null)
          RepaintBoundary(
            child: ListenableBuilder(
              listenable: _elapsed,
              builder: (_, _) => CustomPaint(
                painter: _GoldSandPainter(
                  shader: shader,
                  elapsed: _elapsed.value,
                ),
              ),
            ),
          )
        else
          // Fallback: dark colour close to the shader's clearColor
          const ColoredBox(color: Color(0xFF0F0F0F)),

        // Foreground content (login / register form)
        widget.child,
      ],
    );
  }
}

/// [CustomPainter] that sets the three shader uniforms and fills the canvas.
///
/// Uniform layout (matches gold_sand.frag declaration order):
///   index 0 — uTime   (float, elapsed seconds)
///   index 1 — uSize.x (float, canvas width)
///   index 2 — uSize.y (float, canvas height)
class _GoldSandPainter extends CustomPainter {
  _GoldSandPainter({required this.shader, required this.elapsed});

  final ui.FragmentShader shader;
  final double elapsed;

  @override
  void paint(Canvas canvas, Size size) {
    shader
      ..setFloat(0, elapsed)
      ..setFloat(1, size.width)
      ..setFloat(2, size.height);

    canvas.drawRect(
      Offset.zero & size,
      Paint()..shader = shader,
    );
  }

  @override
  bool shouldRepaint(_GoldSandPainter old) => old.elapsed != elapsed;
}
