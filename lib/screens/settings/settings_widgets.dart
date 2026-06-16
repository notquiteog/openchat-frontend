import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../widgets/glass.dart';

/// Shared iOS-26 liquid-glass building blocks for the Settings hub and its
/// sub-pages. Extracted so the hub and every settings sub-page render
/// identical rows, section headers, dividers, and the glass screen scaffold
/// without duplicating boilerplate.

/// A glass settings screen: an [extendBodyBehindAppBar] [Scaffold] with a
/// frosted [GlassAppBar] over a [ListView] whose top padding clears the
/// translucent bar. This is the canonical recipe shared by every pushed
/// settings sub-page.
class SettingsScaffold extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final List<Widget>? actions;

  const SettingsScaffold({
    super.key,
    required this.title,
    required this.children,
    this.actions,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassAppBar(title: Text(title), actions: actions),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          MediaQuery.paddingOf(context).top + kToolbarHeight + 12,
          16,
          MediaQuery.paddingOf(context).bottom + 32,
        ),
        children: children,
      ),
    );
  }
}

/// An uppercase, tracked-out section header above a [SettingsGroup] — matches
/// the grouped-table headers iOS 26 uses in Settings.
class SettingsSectionHeader extends StatelessWidget {
  final String title;
  const SettingsSectionHeader(this.title, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
    child: Text(
      title.toUpperCase(),
      style: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.90),
        letterSpacing: 1.4,
      ),
    ),
  );
}

/// A glass-backed grouped card. Children are stacked in a column with a
/// hairline [SettingsDivider] auto-inserted between consecutive rows — the
/// most common source of divider bugs when building grouped sections by hand.
class SettingsGroup extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsetsGeometry? margin;

  const SettingsGroup({super.key, required this.children, this.margin});

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      rows.add(children[i]);
      if (i != children.length - 1) rows.add(const SettingsDivider());
    }
    return GlassCard(
      padding: EdgeInsets.zero,
      margin: margin,
      child: Column(children: rows),
    );
  }
}

/// A 0.5dp hairline separator inside glass cards, indented past the leading
/// icon to align with the row text.
class SettingsDivider extends StatelessWidget {
  const SettingsDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      thickness: 0.5,
      indent: 66,
      endIndent: 0,
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.10),
    );
  }
}

/// A tappable settings row — backed by [GlassListTile] for native iOS-26 tap
/// feedback. Renders a circular tinted icon, a title, an optional subtitle,
/// and a trailing widget (defaults to a disclosure chevron).
class SettingsTile extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final Color? titleColor;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool isLast;

  const SettingsTile({
    super.key,
    required this.icon,
    this.iconColor,
    required this.title,
    this.titleColor,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final effectiveColor = iconColor ?? scheme.primary;
    return GlassListTile(
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: effectiveColor.withValues(alpha: 0.14),
        ),
        child: Icon(icon, size: 17, color: effectiveColor),
      ),
      title: Text(
        title,
        style: titleColor != null
            ? TextStyle(color: titleColor, fontWeight: FontWeight.w600)
            : const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: subtitle != null ? Text(subtitle!) : null,
      trailing:
          trailing ??
          Icon(
            CupertinoIcons.chevron_forward,
            size: 14,
            color: scheme.onSurface.withValues(alpha: 0.40),
          ),
      onTap: onTap,
      isLast: isLast,
      showDivider: false,
    );
  }
}

/// A settings row with a trailing [GlassSwitch] — backed by [GlassListTile].
class SettingsSwitchTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;
  final bool isLast;

  const SettingsSwitchTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassListTile(
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: scheme.primary.withValues(alpha: 0.14),
        ),
        child: Icon(icon, size: 17, color: scheme.primary),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: subtitle != null ? Text(subtitle!) : null,
      trailing: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: GlassSwitch(
          value: value,
          onChanged: enabled ? onChanged : (_) {},
          activeColor: scheme.primary,
          enableHaptics: enabled,
        ),
      ),
      onTap: enabled ? () => onChanged(!value) : null,
      isLast: isLast,
      showDivider: false,
    );
  }
}

/// A small pill badge used in a row's trailing slot to show a count
/// (e.g. pending outbox items).
class SettingsCountBadge extends StatelessWidget {
  final int count;

  const SettingsCountBadge({super.key, required this.count});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: scheme.primary.withValues(alpha: 0.14),
          width: 0.5,
        ),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: TextStyle(
          color: scheme.primary,
          fontSize: 12,
          fontWeight: FontWeight.w800,
          letterSpacing: 0,
        ),
      ),
    );
  }
}
