import 'package:flutter/material.dart';

import 'glass.dart';

/// Single source of truth for when the app switches to the desktop shell
/// (navigation rail + split view) instead of the mobile bottom bar.
bool isDesktopShell(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= 900;

/// Chat content (message list, composer) stops stretching past this on wide
/// panes so a maximized window reads as a conversation column, not a wall.
const double kChatContentMaxWidth = 1040.0;

// ── Context menu ─────────────────────────────────────────────────────────────

/// One row of a desktop right-click menu. Mirrors the fields of the mobile
/// action-sheet items so call sites can build both from the same data.
class GlassContextMenuItem<T> {
  final T value;
  final IconData icon;
  final String label;
  final Color? color;
  final bool dividerBefore;

  const GlassContextMenuItem({
    required this.value,
    required this.icon,
    required this.label,
    this.color,
    this.dividerBefore = false,
  });
}

/// Cursor-anchored glass menu for pointer devices: the desktop counterpart of
/// the long-press bottom sheets. Flips above the anchor when there is no room
/// below and clamps to the window edges.
Future<T?> showGlassContextMenu<T>({
  required BuildContext context,
  required Offset anchor,
  required List<GlassContextMenuItem<T>> items,
  double width = 252,
}) {
  return showDialog<T>(
    context: context,
    barrierColor: Colors.transparent,
    builder: (ctx) {
      return CustomSingleChildLayout(
        delegate: _ContextMenuLayoutDelegate(
          anchor: anchor,
          padding: MediaQuery.viewPaddingOf(ctx),
        ),
        child: _GlassContextMenu<T>(items: items, width: width),
      );
    },
  );
}

class _ContextMenuLayoutDelegate extends SingleChildLayoutDelegate {
  final Offset anchor;
  final EdgeInsets padding;

  const _ContextMenuLayoutDelegate({
    required this.anchor,
    required this.padding,
  });

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    const gap = 4.0;
    final minX = padding.left + 8;
    final maxX = size.width - padding.right - childSize.width - 8;
    final minY = padding.top + 8;
    final maxY = size.height - padding.bottom - childSize.height - 8;
    var dx = anchor.dx;
    var dy = anchor.dy + gap;
    // Flip above the cursor when the menu would not fit below it.
    if (dy > maxY) dy = anchor.dy - childSize.height - gap;
    dx = dx.clamp(minX, maxX < minX ? minX : maxX);
    dy = dy.clamp(minY, maxY < minY ? minY : maxY);
    return Offset(dx, dy);
  }

  @override
  bool shouldRelayout(_ContextMenuLayoutDelegate oldDelegate) =>
      anchor != oldDelegate.anchor || padding != oldDelegate.padding;
}

class _GlassContextMenu<T> extends StatelessWidget {
  final List<GlassContextMenuItem<T>> items;
  final double width;

  const _GlassContextMenu({required this.items, required this.width});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      child: GlassContainer(
        shape: const LiquidRoundedSuperellipse(borderRadius: 16),
        allowElevation: true,
        clipBehavior: Clip.antiAlias,
        child: Material(
          type: MaterialType.transparency,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final item in items) ...[
                  if (item.dividerBefore)
                    Divider(
                      height: 9,
                      indent: 14,
                      endIndent: 14,
                      color: scheme.outlineVariant.withValues(alpha: 0.3),
                    ),
                  _ContextMenuRow<T>(item: item),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ContextMenuRow<T> extends StatefulWidget {
  final GlassContextMenuItem<T> item;

  const _ContextMenuRow({required this.item});

  @override
  State<_ContextMenuRow<T>> createState() => _ContextMenuRowState<T>();
}

class _ContextMenuRowState<T> extends State<_ContextMenuRow<T>> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final item = widget.item;
    final tint = item.color ?? scheme.onSurface;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.pop(context, item.value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 80),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              color: _hovered
                  ? scheme.onSurface.withValues(alpha: 0.07)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(item.icon, size: 18, color: tint.withValues(alpha: 0.85)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: tint,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Navigation rail ──────────────────────────────────────────────────────────

class DesktopNavRailTab {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final int badgeCount;

  const DesktopNavRailTab({
    required this.icon,
    required this.activeIcon,
    required this.label,
    this.badgeCount = 0,
  });
}

/// The desktop shell's left edge: tab destinations up top, search in the
/// middle, settings pinned to the bottom. Replaces the mobile bottom bar on
/// wide windows.
class DesktopNavRail extends StatelessWidget {
  static const double width = 76;

  final List<DesktopNavRailTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onTabSelected;
  final bool searchActive;
  final VoidCallback onSearchTap;
  final VoidCallback onSettingsTap;

  const DesktopNavRail({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onTabSelected,
    required this.searchActive,
    required this.onSearchTap,
    required this.onSettingsTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.03),
        border: Border(
          right: BorderSide(
            color: scheme.onSurface.withValues(alpha: 0.08),
            width: 0.5,
          ),
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 10),
            for (var i = 0; i < tabs.length; i++)
              _RailButton(
                icon: i == selectedIndex && !searchActive
                    ? tabs[i].activeIcon
                    : tabs[i].icon,
                label: tabs[i].label,
                selected: i == selectedIndex && !searchActive,
                badgeCount: tabs[i].badgeCount,
                onTap: () => onTabSelected(i),
              ),
            _RailButton(
              icon: searchActive ? Icons.search_rounded : Icons.search,
              label: 'Search',
              selected: searchActive,
              onTap: onSearchTap,
            ),
            const Spacer(),
            _RailButton(
              icon: Icons.settings_outlined,
              label: 'Settings',
              selected: false,
              onTap: onSettingsTap,
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }
}

class _RailButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final int badgeCount;
  final VoidCallback onTap;

  const _RailButton({
    required this.icon,
    required this.label,
    required this.selected,
    this.badgeCount = 0,
    required this.onTap,
  });

  @override
  State<_RailButton> createState() => _RailButtonState();
}

class _RailButtonState extends State<_RailButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = widget.selected;
    final fg = selected
        ? scheme.primary
        : scheme.onSurface.withValues(alpha: _hovered ? 0.85 : 0.6);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.13)
                  : _hovered
                  ? scheme.onSurface.withValues(alpha: 0.06)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Badge(
                  isLabelVisible: widget.badgeCount > 0,
                  label: Text(
                    widget.badgeCount > 99 ? '99+' : '${widget.badgeCount}',
                  ),
                  child: Icon(widget.icon, size: 24, color: fg),
                ),
                const SizedBox(height: 3),
                Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    letterSpacing: 0,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Split-view sidebar resize handle ────────────────────────────────────────

/// Invisible-until-hovered drag strip between the inbox sidebar and the chat
/// pane. Double-click resets to the default width.
class SidebarResizeHandle extends StatefulWidget {
  final ValueChanged<double> onDragDelta;
  final VoidCallback onDragEnd;
  final VoidCallback onReset;

  const SidebarResizeHandle({
    super.key,
    required this.onDragDelta,
    required this.onDragEnd,
    required this.onReset,
  });

  @override
  State<SidebarResizeHandle> createState() => _SidebarResizeHandleState();
}

class _SidebarResizeHandleState extends State<SidebarResizeHandle> {
  bool _hovered = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = _hovered || _dragging;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (_) => setState(() => _dragging = true),
        onHorizontalDragUpdate: (d) => widget.onDragDelta(d.delta.dx),
        onHorizontalDragEnd: (_) {
          setState(() => _dragging = false);
          widget.onDragEnd();
        },
        onHorizontalDragCancel: () {
          setState(() => _dragging = false);
          widget.onDragEnd();
        },
        onDoubleTap: widget.onReset,
        child: SizedBox(
          width: 7,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: active ? 3 : 0.5,
              color: active
                  ? scheme.primary.withValues(alpha: 0.45)
                  : scheme.onSurface.withValues(alpha: 0.08),
            ),
          ),
        ),
      ),
    );
  }
}
