import 'dart:math' as math;
import 'package:flutter/material.dart';

class MessageImageLayout {
  static const String expandTooltip = 'Expand image';

  final double maxBubbleWidth;
  final double maxImageHeight;

  const MessageImageLayout({
    required this.maxBubbleWidth,
    required this.maxImageHeight,
  });

  factory MessageImageLayout.forViewport(Size viewport) {
    final width = viewport.width;
    final height = viewport.height;
    final desktop = width >= 1000;

    if (desktop) {
      return MessageImageLayout(
        maxBubbleWidth: math.min(width * 0.42, 460),
        maxImageHeight: math.min(height * 0.5, 380),
      );
    }

    return MessageImageLayout(
      maxBubbleWidth: width * 0.75,
      maxImageHeight: math.min(height * 0.45, 360),
    );
  }
}
