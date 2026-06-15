import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

class ConnectionQualityBars extends StatelessWidget {
  final lk.ConnectionQuality quality;

  const ConnectionQualityBars({super.key, required this.quality});

  static int activeBarsFor(lk.ConnectionQuality quality) {
    return switch (quality) {
      lk.ConnectionQuality.excellent => 3,
      lk.ConnectionQuality.good => 2,
      lk.ConnectionQuality.poor || lk.ConnectionQuality.lost => 1,
      lk.ConnectionQuality.unknown => 0,
    };
  }

  static String labelFor(lk.ConnectionQuality quality) {
    return switch (quality) {
      lk.ConnectionQuality.excellent => 'Strong connection',
      lk.ConnectionQuality.good => 'Good connection',
      lk.ConnectionQuality.poor => 'Poor connection',
      lk.ConnectionQuality.lost => 'Connection lost',
      lk.ConnectionQuality.unknown => 'Connection quality unknown',
    };
  }

  Color _activeColor(BuildContext context) {
    return switch (quality) {
      lk.ConnectionQuality.excellent => const Color(0xFF30D158),
      lk.ConnectionQuality.good => const Color(0xFFFFD60A),
      lk.ConnectionQuality.poor ||
      lk.ConnectionQuality.lost => const Color(0xFFFF453A),
      lk.ConnectionQuality.unknown => Colors.transparent,
    };
  }

  @override
  Widget build(BuildContext context) {
    final activeBars = activeBarsFor(quality);
    if (activeBars == 0) return const SizedBox.shrink();
    final activeColor = _activeColor(context);
    return Semantics(
      label: labelFor(quality),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.34),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
        ),
        child: SizedBox(
          width: 30,
          height: 24,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < 3; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1.5),
                  child: AnimatedContainer(
                    key: i < activeBars
                        ? Key('connection-quality-active-bar-$i')
                        : Key('connection-quality-inactive-bar-$i'),
                    duration: const Duration(milliseconds: 160),
                    width: 4,
                    height: 7 + (i * 4),
                    decoration: BoxDecoration(
                      color: i < activeBars
                          ? activeColor
                          : Colors.white.withValues(alpha: 0.24),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
