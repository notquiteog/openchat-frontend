import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/api_service.dart';
import '../../widgets/color_choices.dart';
import '../../widgets/glass.dart';
import 'settings_widgets.dart';

/// Appearance & accessibility: theme, accent colour, transparency, text sizes,
/// motion, list layout, and language. All rendered on the iOS-26 liquid-glass
/// primitives.
class AppearanceSettingsScreen extends StatelessWidget {
  const AppearanceSettingsScreen({super.key});

  static const List<Color> _accentPalette = [
    Color(SettingsProvider.defaultSeed), // OpenChat blue (default)
    Color(0xFF6750A4), Color(0xFF7E57C2), Color(0xFFAB47BC),
    Color(0xFFEC407A), Color(0xFFEF5350), Color(0xFFFF7043),
    Color(0xFFFFA726), Color(0xFFFFCA28), Color(0xFF66BB6A),
    Color(0xFF26A69A), Color(0xFF26C6DA), Color(0xFF42A5F5),
    Color(0xFF546E7A), Color(0xFF37474F),
  ];

  // #46 — supported app languages. Grows as translations are contributed
  // (copy app_en.arb → app_<tag>.arb, add the tag here, run `flutter gen-l10n`).
  static const _supportedLanguages = {'en': 'English'};

  String _languageLabel(String? tag) {
    if (tag == null || tag.isEmpty) return 'System default';
    return _supportedLanguages[tag] ?? tag;
  }

  Future<void> _pickLanguage(
    BuildContext context,
    SettingsProvider settings,
  ) async {
    String? tag;
    var picked = false;
    await showGlassActionSheet<void>(
      context: context,
      title: 'Language',
      actions: [
        GlassActionSheetAction(
          label: 'System default',
          onPressed: () {
            tag = null;
            picked = true;
          },
        ),
        for (final entry in _supportedLanguages.entries)
          GlassActionSheetAction(
            label: entry.value,
            onPressed: () {
              tag = entry.key;
              picked = true;
            },
          ),
      ],
    );
    if (picked) await settings.setLocale(tag);
  }

  Future<void> _pickAccentColor(
    BuildContext context,
    SettingsProvider settings,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: const Text('Accent color'),
        content: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final c in _accentPalette)
              GestureDetector(
                onTap: () {
                  settings.setSeedColor(c);
                  Navigator.pop(ctx);
                },
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: c,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: settings.seedColorValue == c.toARGB32()
                          ? Theme.of(ctx).colorScheme.onSurface
                          : Colors.transparent,
                      width: 3,
                    ),
                    boxShadow: settings.seedColorValue == c.toARGB32()
                        ? [
                            BoxShadow(
                              color: c.withValues(alpha: 0.5),
                              blurRadius: 10,
                              spreadRadius: -2,
                            ),
                          ]
                        : null,
                  ),
                ),
              ),
            // Custom color button
            GestureDetector(
              onTap: () async {
                Navigator.pop(ctx);
                await _pickCustomAccentColor(context, settings);
              },
              child: Container(
                width: 40,
                height: 40,
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
                    color: Colors.white.withValues(alpha: 0.4),
                    width: 1.5,
                  ),
                ),
                child: const Icon(
                  Icons.colorize,
                  size: 18,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              settings.resetSeedColor();
              Navigator.pop(ctx);
            },
            child: const Text('Reset'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickCustomAccentColor(
    BuildContext context,
    SettingsProvider settings,
  ) async {
    final initial = settings.seedColor;
    final picked = await showDialog<Color>(
      context: context,
      builder: (_) => _CustomAccentColorDialog(initial: initial),
    );
    if (picked != null) {
      await settings.setSeedColor(picked);
    }
  }

  /// The current user's own message-bubble colour is global — it is published to
  /// their profile so the same colour shows in every chat, to themselves and to
  /// everyone they message.
  Future<void> _pickBubbleColor(BuildContext context) async {
    final api = context.read<ApiService>();
    final auth = context.read<AuthProvider>();
    final current = auth.currentUser?.bubbleColor;
    await showDialog<void>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: const Text('My bubble color'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'The colour of your own message bubbles, shown to everyone you '
                'chat with.',
                style: TextStyle(
                  color: Theme.of(
                    ctx,
                  ).colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(height: 14),
              ColorChoices(
                selected: current,
                onSelected: (c) async {
                  Navigator.pop(ctx);
                  await api.updateProfile(
                    bubbleColor: c,
                    clearBubbleColor: c == null,
                  );
                  await auth.refreshCurrentUser();
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final user = context.watch<AuthProvider>().currentUser;
    final scheme = Theme.of(context).colorScheme;
    final bubbleColor = user?.bubbleColor != null
        ? Color(user!.bubbleColor!)
        : scheme.primary;

    return SettingsScaffold(
      title: 'Appearance',
      children: [
        const SettingsSectionHeader('Theme'),
        SettingsGroup(
          children: [
            _ThemeModeTile(settings: settings),
            SettingsTile(
              icon: Icons.palette_outlined,
              title: 'Accent color',
              subtitle: 'Theme color used across the app',
              trailing: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: settings.seedColor,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: settings.seedColor.withValues(alpha: 0.45),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
              ),
              onTap: () => _pickAccentColor(context, settings),
            ),
            SettingsTile(
              icon: Icons.chat_bubble_outline_rounded,
              title: 'My bubble color',
              subtitle: 'Your own message bubbles, shown in every chat',
              trailing: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: bubbleColor,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: bubbleColor.withValues(alpha: 0.45),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
              ),
              onTap: () => _pickBubbleColor(context),
            ),
            SettingsSwitchTile(
              icon: Icons.water_drop_outlined,
              title: 'Reduce transparency',
              subtitle: 'Use more opaque surfaces throughout the app',
              value: settings.reduceTransparency,
              onChanged: settings.setReduceTransparency,
            ),
          ],
        ),
        const SizedBox(height: 20),

        const SettingsSectionHeader('Text'),
        SettingsGroup(
          children: [
            _UiTextScaleTile(settings: settings),
            _MessageFontSizeTile(settings: settings),
            SettingsSwitchTile(
              icon: Icons.format_bold_rounded,
              title: 'Bold text',
              subtitle: 'Use heavier font weights across the app',
              value: settings.boldText,
              onChanged: settings.setBoldText,
            ),
          ],
        ),
        const SizedBox(height: 20),

        const SettingsSectionHeader('Motion'),
        SettingsGroup(
          children: [
            SettingsSwitchTile(
              icon: Icons.motion_photos_off_outlined,
              title: 'Reduce motion',
              subtitle:
                  'Shorten or disable screen transitions and glass effects',
              value: settings.reduceMotion,
              onChanged: settings.setReduceMotion,
            ),
          ],
        ),
        const SizedBox(height: 20),

        const SettingsSectionHeader('Layout'),
        SettingsGroup(
          children: [
            SettingsSwitchTile(
              icon: Icons.campaign_outlined,
              title: 'Channels in their own tab',
              subtitle: 'Off: channels appear in your Chats list',
              value: settings.channelsOwnTab,
              onChanged: settings.setChannelsOwnTab,
            ),
            SettingsSwitchTile(
              icon: Icons.smart_toy_outlined,
              title: 'Bots in their own tab',
              subtitle: 'Off: bot chats appear in your Chats list',
              value: settings.botsOwnTab,
              onChanged: settings.setBotsOwnTab,
            ),
          ],
        ),
        const SizedBox(height: 20),

        const SettingsSectionHeader('Language'),
        SettingsGroup(
          children: [
            SettingsTile(
              icon: Icons.translate_rounded,
              title: 'Language',
              subtitle: _languageLabel(settings.localeTag),
              onTap: () => _pickLanguage(context, settings),
            ),
          ],
        ),
      ],
    );
  }
}

/// Light / Dark / System theme control via a glass segmented control.
class _ThemeModeTile extends StatelessWidget {
  final SettingsProvider settings;
  const _ThemeModeTile({required this.settings});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Exhaustive switch (no default) so a future ThemeMode value is a compile
    // error rather than an out-of-range segment index.
    final selectedIndex = switch (settings.themeMode) {
      ThemeMode.light => 0,
      ThemeMode.dark => 1,
      ThemeMode.system => 2,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.brightness_6_outlined,
                color: scheme.primary,
                size: 22,
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Theme',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          GlassSegmentedControl(
            segments: const ['Light', 'Dark', 'System'],
            selectedIndex: selectedIndex,
            onSegmentSelected: (i) => settings.setThemeMode(
              const [ThemeMode.light, ThemeMode.dark, ThemeMode.system][i],
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageFontSizeTile extends StatelessWidget {
  final SettingsProvider settings;
  const _MessageFontSizeTile({required this.settings});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final scale = settings.messageFontScale;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.text_fields_rounded, color: scheme.primary, size: 22),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Message text size',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Text('${(scale * 100).round()}%'),
            ],
          ),
          const SizedBox(height: 6),
          // Live preview bubble.
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 6),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                'The quick brown fox',
                textScaler: TextScaler.linear(scale),
                style: const TextStyle(fontSize: 15),
              ),
            ),
          ),
          GlassSlider(
            value: scale,
            min: SettingsProvider.minMessageFontScale,
            max: SettingsProvider.maxMessageFontScale,
            divisions: 14,
            onChanged: settings.setMessageFontScale,
          ),
        ],
      ),
    );
  }
}

/// App-wide UI text scale slider. The whole app (this screen included) is
/// already under the combined MediaQuery.textScaler, so dragging rescales
/// everything live — that *is* the preview; no explicit textScaler here (which
/// would double-apply on top of the ambient scaler).
class _UiTextScaleTile extends StatelessWidget {
  final SettingsProvider settings;
  const _UiTextScaleTile({required this.settings});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final scale = settings.uiTextScale;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.format_size_rounded, color: scheme.primary, size: 22),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'App text size',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Text('${(scale * 100).round()}%'),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            'Scales text across the whole app, combined with your device size.',
            style: TextStyle(
              fontSize: 12.5,
              color: scheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          GlassSlider(
            value: scale,
            min: SettingsProvider.minUiTextScale,
            max: SettingsProvider.maxUiTextScale,
            divisions: 6,
            onChanged: settings.setUiTextScale,
          ),
        ],
      ),
    );
  }
}

// ── Custom accent color HSV picker ───────────────────────────────────────────

class _CustomAccentColorDialog extends StatefulWidget {
  final Color initial;
  const _CustomAccentColorDialog({required this.initial});

  @override
  State<_CustomAccentColorDialog> createState() =>
      _CustomAccentColorDialogState();
}

class _CustomAccentColorDialogState extends State<_CustomAccentColorDialog> {
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

  Color get _current => HSVColor.fromAHSV(1, _hue, _sat, _val).toColor();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassAlertDialog(
      title: const Text('Custom accent color'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 80),
            width: double.infinity,
            height: 52,
            decoration: BoxDecoration(
              color: _current,
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: _current.withValues(alpha: 0.55),
                  blurRadius: 20,
                  spreadRadius: -2,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _label(context, 'Hue'),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 14,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              trackShape: _HueTrackShape(),
            ),
            child: Slider(
              value: _hue,
              min: 0,
              max: 360,
              onChanged: (v) => setState(() => _hue = v),
            ),
          ),
          _label(context, 'Saturation'),
          _gradientSlider(
            value: _sat,
            left: HSVColor.fromAHSV(1, _hue, 0, _val).toColor(),
            right: HSVColor.fromAHSV(1, _hue, 1, _val).toColor(),
            onChanged: (v) => setState(() => _sat = v),
          ),
          _label(context, 'Brightness'),
          _gradientSlider(
            value: _val,
            left: Colors.black,
            right: HSVColor.fromAHSV(1, _hue, _sat, 1).toColor(),
            onChanged: (v) => setState(() => _val = v),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(
                CupertinoIcons.number,
                size: 14,
                color: scheme.onSurface.withValues(alpha: 0.55),
              ),
              const SizedBox(width: 4),
              Text(
                _current
                    .toARGB32()
                    .toRadixString(16)
                    .toUpperCase()
                    .padLeft(8, '0')
                    .substring(2),
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.4,
                  color: scheme.onSurface.withValues(alpha: 0.75),
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _current),
          child: const Text('Apply'),
        ),
      ],
    );
  }

  Widget _label(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: Theme.of(
            context,
          ).colorScheme.onSurface.withValues(alpha: 0.55),
        ),
      ),
    ),
  );

  Widget _gradientSlider({
    required double value,
    required Color left,
    required Color right,
    required ValueChanged<double> onChanged,
  }) {
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 14,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
        trackShape: _GradientTrackShape(left: left, right: right),
      ),
      child: Slider(value: value, onChanged: onChanged),
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
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(trackRect, const Radius.circular(7)),
      Paint()
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
        ).createShader(trackRect),
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
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(trackRect, const Radius.circular(7)),
      Paint()
        ..shader = LinearGradient(
          colors: [left, right],
        ).createShader(trackRect),
    );
  }
}
