import 'package:flutter/material.dart';

/// A compact swatch picker: a "default" choice followed by a preset palette.
class ColorChoices extends StatelessWidget {
  final int? selected;
  final void Function(int?) onSelected;

  const ColorChoices({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  static const List<Color> _palette = [
    Color(0xFFEF5350),
    Color(0xFFEC407A),
    Color(0xFFAB47BC),
    Color(0xFF7E57C2),
    Color(0xFF5C6BC0),
    Color(0xFF42A5F5),
    Color(0xFF26A69A),
    Color(0xFF66BB6A),
    Color(0xFFD4E157),
    Color(0xFFFFCA28),
    Color(0xFFFFA726),
    Color(0xFF8D6E63),
    Color(0xFF26323A),
    Color(0xFFECEFF1),
  ];

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        GestureDetector(
          onTap: () => onSelected(null),
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: selected == null ? primary : Colors.grey,
                width: selected == null ? 3 : 1,
              ),
            ),
            child: const Icon(Icons.format_color_reset, size: 16),
          ),
        ),
        for (final color in _palette)
          GestureDetector(
            onTap: () => onSelected(color.toARGB32()),
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected == color.toARGB32()
                      ? primary
                      : Colors.white.withValues(alpha: 0.8),
                  width: selected == color.toARGB32() ? 3 : 1,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
