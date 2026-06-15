import 'package:flutter/material.dart';

import 'custom_emoji_image.dart';
import 'glass.dart';
import 'message_action_sheet.dart';

/// Result of the tap-to-react bar.
sealed class ReactionBarResult {
  const ReactionBarResult();
}

/// A recent reaction was tapped (unicode emoji or `custom:<id>`).
class ReactionPicked extends ReactionBarResult {
  final String key;
  const ReactionPicked(this.key);
}

/// The "+" was tapped — open the full reaction picker.
class ReactionExpand extends ReactionBarResult {
  const ReactionExpand();
}

/// Single tap on a message → a liquid-glass reaction bar (recents + an expand
/// button) morphing out of the tap point. Returns the chosen reaction, a
/// request to expand the picker, or null if dismissed.
Future<ReactionBarResult?> showMessageReactionBar({
  required BuildContext context,
  required Offset anchor,
  required List<String> recentReactionKeys,
}) {
  return _showMorphMenu<ReactionBarResult>(
    context: context,
    anchor: anchor,
    builder: (ctx) => _ReactionBar(
      keys: recentReactionKeys,
      onPick: (k) => Navigator.pop(ctx, ReactionPicked(k)),
      onExpand: () => Navigator.pop(ctx, const ReactionExpand()),
    ),
  );
}

/// Long-press (or right-click) on a message → the iOS-26 action menu (reply,
/// forward, delete, …) as grouped liquid-glass cards morphing out of the press
/// point. Returns the chosen action value, or null if dismissed.
Future<T?> showMessageContextMenu<T>({
  required BuildContext context,
  required Offset anchor,
  required List<MessageActionSheetItem<T>> actions,
  double width = 268,
}) {
  return _showMorphMenu<T>(
    context: context,
    anchor: anchor,
    builder: (ctx) => _ActionMenu<T>(width: width, actions: actions),
  );
}

/// Shared anchored "morph" dialog: scales + fades the [builder] content out of
/// the [anchor] point, positioned near it and clamped to the safe area.
Future<R?> _showMorphMenu<R>({
  required BuildContext context,
  required Offset anchor,
  required WidgetBuilder builder,
}) {
  return showGeneralDialog<R>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.black.withValues(alpha: 0.18),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (ctx, _, _) => CustomSingleChildLayout(
      delegate: _MenuLayoutDelegate(
        anchor: anchor,
        padding: MediaQuery.viewPaddingOf(ctx),
      ),
      child: builder(ctx),
    ),
    transitionBuilder: (ctx, anim, _, child) {
      final media = MediaQuery.sizeOf(ctx);
      final align = Alignment(
        (anchor.dx / media.width).clamp(0.0, 1.0) * 2 - 1,
        (anchor.dy / media.height).clamp(0.0, 1.0) * 2 - 1,
      );
      return FadeTransition(
        opacity: CurvedAnimation(
          parent: anim,
          curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
        ),
        child: ScaleTransition(
          alignment: align,
          scale: Tween<double>(begin: 0.86, end: 1.0).animate(
            CurvedAnimation(
              parent: anim,
              curve: Curves.easeOutBack,
              reverseCurve: Curves.easeInCubic,
            ),
          ),
          child: child,
        ),
      );
    },
  );
}

/// The grouped action cards (long-press). The trailing "caution" cluster (the
/// first row flagged `dividerBefore` and everything after it) drops into its own
/// card below, iOS-style.
class _ActionMenu<T> extends StatelessWidget {
  final double width;
  final List<MessageActionSheetItem<T>> actions;

  const _ActionMenu({required this.width, required this.actions});

  @override
  Widget build(BuildContext context) {
    final firstDivider = actions.indexWhere((a) => a.dividerBefore);
    final groups = firstDivider > 0
        ? <List<MessageActionSheetItem<T>>>[
            actions.sublist(0, firstDivider),
            actions.sublist(firstDivider),
          ]
        : <List<MessageActionSheetItem<T>>>[actions];

    return SizedBox(
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var g = 0; g < groups.length; g++) ...[
            GlassMenuSection(
              frosted: true,
              margin: EdgeInsets.zero,
              entries: [
                for (final action in groups[g])
                  GlassMenuEntry(
                    icon: action.icon,
                    label: action.label,
                    subtitle: action.subtitle,
                    color: action.color,
                    onTap: () => Navigator.pop(context, action.value),
                  ),
              ],
            ),
            if (g != groups.length - 1) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

/// The liquid-glass tapback pill: recent reactions + an expand button.
class _ReactionBar extends StatelessWidget {
  final List<String> keys;
  final ValueChanged<String> onPick;
  final VoidCallback onExpand;

  const _ReactionBar({
    required this.keys,
    required this.onPick,
    required this.onExpand,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassContainer(
      shape: const LiquidRoundedSuperellipse(borderRadius: 30),
      allowElevation: true,
      glowIntensity: 0.06,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final key in keys)
            _BarButton(
              onTap: () => onPick(key),
              child: ReactionGlyph(key, size: 27),
            ),
          Container(
            width: 1,
            height: 26,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            color: scheme.onSurface.withValues(alpha: 0.14),
          ),
          _BarButton(
            onTap: onExpand,
            child: Icon(
              Icons.add_rounded,
              size: 24,
              color: scheme.onSurface.withValues(alpha: 0.8),
            ),
          ),
        ],
      ),
    );
  }
}

class _BarButton extends StatefulWidget {
  final VoidCallback onTap;
  final Widget child;

  const _BarButton({required this.onTap, required this.child});

  @override
  State<_BarButton> createState() => _BarButtonState();
}

class _BarButtonState extends State<_BarButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 1.22 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutBack,
        child: Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _pressed
                ? scheme.primary.withValues(alpha: 0.18)
                : Colors.transparent,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Positions the menu near the press point: centered horizontally on the
/// finger, dropping below it and flipping above when there is no room, clamped
/// to the safe area.
class _MenuLayoutDelegate extends SingleChildLayoutDelegate {
  final Offset anchor;
  final EdgeInsets padding;

  const _MenuLayoutDelegate({required this.anchor, required this.padding});

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    const gap = 10.0;
    final minX = padding.left + 8;
    final maxX = size.width - padding.right - childSize.width - 8;
    final minY = padding.top + 8;
    final maxY = size.height - padding.bottom - childSize.height - 8;
    var dx = anchor.dx - childSize.width / 2;
    var dy = anchor.dy + gap;
    if (dy > maxY) dy = anchor.dy - childSize.height - gap;
    dx = dx.clamp(minX, maxX < minX ? minX : maxX);
    dy = dy.clamp(minY, maxY < minY ? minY : maxY);
    return Offset(dx, dy);
  }

  @override
  bool shouldRelayout(_MenuLayoutDelegate oldDelegate) =>
      anchor != oldDelegate.anchor || padding != oldDelegate.padding;
}
