import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;

import 'glass.dart';

/// Single source of truth for when the app switches to the desktop shell
/// (navigation rail + split view) instead of the mobile bottom bar.
bool isDesktopShell(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= 900;

/// Chat content (message list, composer) stops stretching past this on wide
/// panes so a maximized window reads as a conversation column, not a wall.
const double kChatContentMaxWidth = 1040.0;

// ── Keyboard shortcuts ──────────────────────────────────────────────────────

enum DesktopShortcutAction {
  search,
  newChat,
  nextConversation,
  previousConversation,
  jumpToConversation,
  markSelectedRead,
  archiveSelected,
  openSettings,
  close,
  showCheatSheet,
}

enum DesktopShortcutSection { general, navigation, conversation }

class DesktopShortcutSpec {
  final DesktopShortcutAction action;
  final DesktopShortcutSection section;
  final LogicalKeyboardKey key;
  final String keyLabel;
  final String description;
  final bool platformModifier;
  final bool control;
  final bool meta;
  final bool alt;
  final bool shift;
  final int? index;
  final bool ignoreWhenEditing;

  const DesktopShortcutSpec({
    required this.action,
    required this.section,
    required this.key,
    required this.keyLabel,
    required this.description,
    this.platformModifier = false,
    this.control = false,
    this.meta = false,
    this.alt = false,
    this.shift = false,
    this.index,
    this.ignoreWhenEditing = false,
  });

  Iterable<SingleActivator> get activators sync* {
    if (platformModifier) {
      yield SingleActivator(key, control: true, alt: alt, shift: shift);
      yield SingleActivator(key, meta: true, alt: alt, shift: shift);
      return;
    }
    yield SingleActivator(
      key,
      control: control,
      meta: meta,
      alt: alt,
      shift: shift,
    );
  }

  String labelFor(BuildContext context) {
    if (ignoreWhenEditing) return keyLabel;
    final parts = <String>[];
    if (platformModifier) {
      parts.add(modKeyLabel(context));
    } else {
      if (control) parts.add('Ctrl');
      if (meta) parts.add('Cmd');
    }
    if (alt) parts.add('Alt');
    if (shift) parts.add('Shift');
    parts.add(keyLabel);
    return parts.join(' ');
  }
}

const desktopShortcutSpecs = <DesktopShortcutSpec>[
  DesktopShortcutSpec(
    action: DesktopShortcutAction.search,
    section: DesktopShortcutSection.general,
    key: LogicalKeyboardKey.keyK,
    keyLabel: 'K',
    description: 'Search',
    platformModifier: true,
  ),
  DesktopShortcutSpec(
    action: DesktopShortcutAction.newChat,
    section: DesktopShortcutSection.general,
    key: LogicalKeyboardKey.keyN,
    keyLabel: 'N',
    description: 'New chat',
    platformModifier: true,
  ),
  DesktopShortcutSpec(
    action: DesktopShortcutAction.openSettings,
    section: DesktopShortcutSection.general,
    key: LogicalKeyboardKey.comma,
    keyLabel: ',',
    description: 'Open settings',
    platformModifier: true,
  ),
  DesktopShortcutSpec(
    action: DesktopShortcutAction.showCheatSheet,
    section: DesktopShortcutSection.general,
    key: LogicalKeyboardKey.slash,
    keyLabel: '/',
    description: 'Show keyboard shortcuts',
    platformModifier: true,
  ),
  DesktopShortcutSpec(
    action: DesktopShortcutAction.showCheatSheet,
    section: DesktopShortcutSection.general,
    key: LogicalKeyboardKey.slash,
    keyLabel: '?',
    description: 'Show keyboard shortcuts',
    shift: true,
    ignoreWhenEditing: true,
  ),
  DesktopShortcutSpec(
    action: DesktopShortcutAction.close,
    section: DesktopShortcutSection.general,
    key: LogicalKeyboardKey.escape,
    keyLabel: 'Esc',
    description: 'Close search or pane',
  ),
  DesktopShortcutSpec(
    action: DesktopShortcutAction.previousConversation,
    section: DesktopShortcutSection.navigation,
    key: LogicalKeyboardKey.arrowUp,
    keyLabel: 'Up',
    description: 'Previous conversation',
    alt: true,
  ),
  DesktopShortcutSpec(
    action: DesktopShortcutAction.nextConversation,
    section: DesktopShortcutSection.navigation,
    key: LogicalKeyboardKey.arrowDown,
    keyLabel: 'Down',
    description: 'Next conversation',
    alt: true,
  ),
  DesktopShortcutSpec(
    action: DesktopShortcutAction.jumpToConversation,
    section: DesktopShortcutSection.navigation,
    key: LogicalKeyboardKey.digit1,
    keyLabel: '1',
    description: 'Open conversation 1',
    platformModifier: true,
    index: 1,
  ),
  DesktopShortcutSpec(
    action: DesktopShortcutAction.jumpToConversation,
    section: DesktopShortcutSection.navigation,
    key: LogicalKeyboardKey.digit2,
    keyLabel: '2',
    description: 'Open conversation 2',
    platformModifier: true,
    index: 2,
  ),
  DesktopShortcutSpec(
    action: DesktopShortcutAction.jumpToConversation,
    section: DesktopShortcutSection.navigation,
    key: LogicalKeyboardKey.digit3,
    keyLabel: '3',
    description: 'Open conversation 3',
    platformModifier: true,
    index: 3,
  ),
  DesktopShortcutSpec(
    action: DesktopShortcutAction.jumpToConversation,
    section: DesktopShortcutSection.navigation,
    key: LogicalKeyboardKey.digit4,
    keyLabel: '4',
    description: 'Open conversation 4',
    platformModifier: true,
    index: 4,
  ),
  DesktopShortcutSpec(
    action: DesktopShortcutAction.jumpToConversation,
    section: DesktopShortcutSection.navigation,
    key: LogicalKeyboardKey.digit5,
    keyLabel: '5',
    description: 'Open conversation 5',
    platformModifier: true,
    index: 5,
  ),
  DesktopShortcutSpec(
    action: DesktopShortcutAction.jumpToConversation,
    section: DesktopShortcutSection.navigation,
    key: LogicalKeyboardKey.digit6,
    keyLabel: '6',
    description: 'Open conversation 6',
    platformModifier: true,
    index: 6,
  ),
  DesktopShortcutSpec(
    action: DesktopShortcutAction.jumpToConversation,
    section: DesktopShortcutSection.navigation,
    key: LogicalKeyboardKey.digit7,
    keyLabel: '7',
    description: 'Open conversation 7',
    platformModifier: true,
    index: 7,
  ),
  DesktopShortcutSpec(
    action: DesktopShortcutAction.jumpToConversation,
    section: DesktopShortcutSection.navigation,
    key: LogicalKeyboardKey.digit8,
    keyLabel: '8',
    description: 'Open conversation 8',
    platformModifier: true,
    index: 8,
  ),
  DesktopShortcutSpec(
    action: DesktopShortcutAction.jumpToConversation,
    section: DesktopShortcutSection.navigation,
    key: LogicalKeyboardKey.digit9,
    keyLabel: '9',
    description: 'Open conversation 9',
    platformModifier: true,
    index: 9,
  ),
  DesktopShortcutSpec(
    action: DesktopShortcutAction.markSelectedRead,
    section: DesktopShortcutSection.conversation,
    key: LogicalKeyboardKey.keyM,
    keyLabel: 'M',
    description: 'Mark selected read',
    platformModifier: true,
    shift: true,
  ),
  DesktopShortcutSpec(
    action: DesktopShortcutAction.archiveSelected,
    section: DesktopShortcutSection.conversation,
    key: LogicalKeyboardKey.keyA,
    keyLabel: 'A',
    description: 'Archive selected conversation',
    platformModifier: true,
    shift: true,
  ),
];

String modKeyLabel(BuildContext context) =>
    Theme.of(context).platform == TargetPlatform.macOS ? '⌘' : 'Ctrl';

bool desktopShortcutTextInputFocused() {
  final focusContext = FocusManager.instance.primaryFocus?.context;
  if (focusContext == null) return false;
  return focusContext.widget is EditableText ||
      focusContext.findAncestorWidgetOfExactType<EditableText>() != null;
}

String desktopShortcutSectionLabel(DesktopShortcutSection section) {
  return switch (section) {
    DesktopShortcutSection.general => 'General',
    DesktopShortcutSection.navigation => 'Navigation',
    DesktopShortcutSection.conversation => 'Conversation',
  };
}

class DesktopShortcutsSheet extends StatelessWidget {
  final List<DesktopShortcutSpec> shortcuts;

  const DesktopShortcutsSheet({
    super.key,
    this.shortcuts = desktopShortcutSpecs,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final contentMaxHeight = (MediaQuery.sizeOf(context).height * 0.46)
        .clamp(220.0, 420.0)
        .toDouble();
    final sections = DesktopShortcutSection.values.where(
      (section) => shortcuts.any((shortcut) => shortcut.section == section),
    );

    return GlassAlertDialog(
      icon: const Icon(Icons.keyboard_alt_outlined),
      title: const Text('Keyboard shortcuts'),
      content: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 520, maxHeight: contentMaxHeight),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final section in sections) ...[
                Text(
                  desktopShortcutSectionLabel(section),
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: scheme.onSurface.withValues(alpha: 0.64),
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 8),
                for (final shortcut in shortcuts.where(
                  (shortcut) => shortcut.section == section,
                ))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ShortcutHintRow(
                      keys: shortcut.labelFor(context),
                      label: shortcut.description,
                      wide: true,
                    ),
                  ),
                const SizedBox(height: 8),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

/// A compact `Cmd K  Search`-style keyboard hint row.
class ShortcutHintRow extends StatelessWidget {
  final String keys;
  final String label;
  final bool wide;

  const ShortcutHintRow({
    super.key,
    required this.keys,
    required this.label,
    this.wide = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textColor = scheme.onSurface.withValues(alpha: 0.68);
    final row = Row(
      mainAxisSize: wide ? MainAxisSize.max : MainAxisSize.min,
      children: [
        GlassContainer(
          shape: const LiquidRoundedSuperellipse(borderRadius: 8),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          child: Text(
            keys,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
              color: textColor,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          fit: wide ? FlexFit.tight : FlexFit.loose,
          child: Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              color: scheme.onSurface.withValues(alpha: 0.56),
              fontWeight: FontWeight.w500,
              letterSpacing: 0,
            ),
          ),
        ),
      ],
    );

    if (!wide) return row;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
      child: row,
    );
  }
}

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

// ── Drag-and-drop overlay ───────────────────────────────────────────────────

/// Full-pane highlight shown while a desktop drag carries files over a
/// message surface. Place as the last child of the screen's body Stack.
class DropFilesOverlay extends StatelessWidget {
  const DropFilesOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned.fill(
      child: IgnorePointer(
        child: Container(
          margin: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: scheme.primary.withValues(alpha: 0.55),
              width: 2,
            ),
          ),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.file_upload_outlined,
                    color: scheme.onPrimary,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Drop files to send',
                    style: TextStyle(
                      color: scheme.onPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 13.5,
                    ),
                  ),
                ],
              ),
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
