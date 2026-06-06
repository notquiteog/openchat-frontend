import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'glass.dart';

/// A compact swatch picker: "default" chip, preset palette, and a custom
/// color button that opens an HSV color wheel dialog.
class ColorChoices extends StatelessWidget {
  final int? selected;
  final void Function(int?) onSelected;

  const ColorChoices({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  static const List<Color> _palette = [
    Color(0xFFEF5350), Color(0xFFEC407A), Color(0xFFAB47BC),
    Color(0xFF7E57C2), Color(0xFF5C6BC0), Color(0xFF3D5AFE),
    Color(0xFF42A5F5), Color(0xFF26C6DA), Color(0xFF26A69A),
    Color(0xFF66BB6A), Color(0xFFD4E157), Color(0xFFFFCA28),
    Color(0xFFFFA726), Color(0xFFFF7043), Color(0xFF8D6E63),
    Color(0xFF546E7A), Color(0xFF26323A), Color(0xFFECEFF1),
  ];

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        // Default / clear
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
          _Swatch(
            color: color,
            selected: selected == color.toARGB32(),
            onTap: () => onSelected(color.toARGB32()),
          ),
        // Custom color
        GestureDetector(
          onTap: () => _pickCustom(context),
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const SweepGradient(
                colors: [
                  Color(0xFFFF0000),
                  Color(0xFFFFFF00),
                  Color(0xFF00FF00),
                  Color(0xFF00FFFF),
                  Color(0xFF0000FF),
                  Color(0xFFFF00FF),
                  Color(0xFFFF0000),
                ],
              ),
              border: Border.all(
                color: Colors.grey.withValues(alpha: 0.5),
                width: 1,
              ),
            ),
            child: const Icon(Icons.colorize, size: 15, color: Colors.white),
          ),
        ),
      ],
    );
  }

  Future<void> _pickCustom(BuildContext context) async {
    // Start from the currently-selected color if any, otherwise white.
    final initial = selected != null
        ? Color(selected!)
        : const Color(0xFFFFFFFF);
    final picked = await showDialog<Color>(
      context: context,
      builder: (_) => _CustomColorDialog(initial: initial),
    );
    if (picked != null) onSelected(picked.toARGB32());
  }
}

class _Swatch extends StatelessWidget {
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  const _Swatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.onSurface
                : Colors.white.withValues(alpha: 0.7),
            width: selected ? 3 : 1,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: color.withValues(alpha: 0.55),
                    blurRadius: 8,
                    spreadRadius: -1,
                  ),
                ]
              : null,
        ),
      ),
    );
  }
}

// ── Custom HSV color picker dialog ───────────────────────────────────────────

class _CustomColorDialog extends StatefulWidget {
  final Color initial;
  const _CustomColorDialog({required this.initial});

  @override
  State<_CustomColorDialog> createState() => _CustomColorDialogState();
}

class _CustomColorDialogState extends State<_CustomColorDialog> {
  late double _hue;
  late double _sat;
  late double _val;

  @override
  void initState() {
    super.initState();
    final hsv = HSVColor.fromColor(widget.initial);
    _hue = hsv.hue;
    _sat = hsv.saturation;
    _val = hsv.value;
  }

  Color get _current =>
      HSVColor.fromAHSV(1, _hue, _sat, _val).toColor();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassAlertDialog(
      title: const Text('Custom color'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Preview
          AnimatedContainer(
            duration: const Duration(milliseconds: 80),
            width: double.infinity,
            height: 52,
            decoration: BoxDecoration(
              color: _current,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.18),
                width: 0.5,
              ),
            ),
          ),
          const SizedBox(height: 20),
          // Hue wheel bar
          _HueBar(
            hue: _hue,
            onChanged: (v) => setState(() => _hue = v),
          ),
          const SizedBox(height: 12),
          _SatValSlider(
            label: 'Saturation',
            value: _sat,
            left: Colors.white,
            right: HSVColor.fromAHSV(1, _hue, 1, 1).toColor(),
            onChanged: (v) => setState(() => _sat = v),
          ),
          const SizedBox(height: 8),
          _SatValSlider(
            label: 'Brightness',
            value: _val,
            left: Colors.black,
            right: HSVColor.fromAHSV(1, _hue, _sat, 1).toColor(),
            onChanged: (v) => setState(() => _val = v),
          ),
          const SizedBox(height: 10),
          // Hex display
          Row(
            children: [
              const Icon(CupertinoIcons.number, size: 16),
              const SizedBox(width: 4),
              Text(
                _current.toARGB32().toRadixString(16).toUpperCase().padLeft(8, '0').substring(2),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                ),
              ),
              const Spacer(),
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        GlassButtonWidget(
          onPressed: () => Navigator.pop(context),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: const Text('Cancel'),
        ),
        GlassButtonWidget(
          onPressed: () => Navigator.pop(context, _current),
          color: Theme.of(context).colorScheme.primary,
          foregroundColor: Theme.of(context).colorScheme.onPrimary,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: const Text('Select'),
        ),
      ],
    );
  }
}

class _HueBar extends StatelessWidget {
  final double hue;
  final ValueChanged<double> onChanged;
  const _HueBar({required this.hue, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Hue',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: 4),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 14,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            trackShape: _HueTrackShape(),
          ),
          child: Slider(
            value: hue,
            min: 0,
            max: 360,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

class _HueTrackShape extends RoundedRectSliderTrackShape {
  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    final Rect trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final paint = Paint()
      ..shader = const LinearGradient(
        colors: [
          Color(0xFFFF0000),
          Color(0xFFFFFF00),
          Color(0xFF00FF00),
          Color(0xFF00FFFF),
          Color(0xFF0000FF),
          Color(0xFFFF00FF),
          Color(0xFFFF0000),
        ],
      ).createShader(trackRect);
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(trackRect, const Radius.circular(7)),
      paint,
    );
  }
}

class _SatValSlider extends StatelessWidget {
  final String label;
  final double value;
  final Color left;
  final Color right;
  final ValueChanged<double> onChanged;

  const _SatValSlider({
    required this.label,
    required this.value,
    required this.left,
    required this.right,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: 4),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 14,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            trackShape: _GradientTrackShape(left: left, right: right),
          ),
          child: Slider(value: value, onChanged: onChanged),
        ),
      ],
    );
  }
}

class _GradientTrackShape extends RoundedRectSliderTrackShape {
  final Color left;
  final Color right;
  const _GradientTrackShape({required this.left, required this.right});

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    final Rect trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final paint = Paint()
      ..shader = LinearGradient(
        colors: [left, right],
      ).createShader(trackRect);
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(trackRect, const Radius.circular(7)),
      paint,
    );
  }
}
