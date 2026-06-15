import 'package:flutter/material.dart';

const defaultStoryBackground = 'gradient:#111827,#2563EB';

const storyBackgroundOptions = <String>[
  defaultStoryBackground,
  'gradient:#312E81,#DB2777',
  'gradient:#064E3B,#10B981',
  'solid:#111827',
  'solid:#7F1D1D',
  'solid:#1E3A8A',
];

BoxDecoration storyBackgroundDecoration(String? spec) {
  final parsed = (spec == null || spec.trim().isEmpty)
      ? defaultStoryBackground
      : spec.trim();
  if (parsed.startsWith('solid:')) {
    return BoxDecoration(color: _parseHexColor(parsed.substring(6)));
  }
  if (parsed.startsWith('gradient:')) {
    final colors = parsed
        .substring(9)
        .split(',')
        .map((part) => _parseHexColor(part))
        .toList(growable: false);
    if (colors.length >= 2) {
      return BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors.take(3).toList(growable: false),
        ),
      );
    }
  }
  return storyBackgroundDecoration(defaultStoryBackground);
}

Color _parseHexColor(String raw) {
  var hex = raw.trim();
  if (hex.startsWith('#')) hex = hex.substring(1);
  if (hex.length == 6) hex = 'FF$hex';
  final value = int.tryParse(hex, radix: 16);
  if (value == null) return const Color(0xFF111827);
  return Color(value);
}
