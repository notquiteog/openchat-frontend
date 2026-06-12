import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/widgets/day_separator.dart';
import 'package:openchat/widgets/desktop.dart';

void main() {
  group('daySeparatorLabel', () {
    test('today and yesterday', () {
      final now = DateTime.now();
      expect(daySeparatorLabel(now), 'Today');
      expect(
        daySeparatorLabel(now.subtract(const Duration(days: 1))),
        'Yesterday',
      );
    });

    test('within the last week uses a weekday name', () {
      final now = DateTime.now();
      final label = daySeparatorLabel(now.subtract(const Duration(days: 3)));
      expect(label, isNot('Today'));
      expect(label, isNot('Yesterday'));
      // Weekday names carry no digits; calendar dates do.
      expect(label.contains(RegExp(r'\d')), isFalse);
    });

    test('older than a week uses a calendar date', () {
      final label = daySeparatorLabel(
        DateTime.now().subtract(const Duration(days: 30)),
      );
      expect(label.contains(RegExp(r'\d')), isTrue);
    });

    test('a different year is spelled out', () {
      expect(daySeparatorLabel(DateTime(2003, 5, 28)), contains('2003'));
    });
  });

  group('isSameCalendarDay', () {
    test('same day across times, different across midnight', () {
      expect(
        isSameCalendarDay(DateTime(2026, 6, 11, 1), DateTime(2026, 6, 11, 23)),
        isTrue,
      );
      expect(
        isSameCalendarDay(DateTime(2026, 6, 11, 23, 59), DateTime(2026, 6, 12)),
        isFalse,
      );
    });
  });

  group('showGlassContextMenu', () {
    testWidgets('returns the tapped item value', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.expand();
            },
          ),
        ),
      );

      final result = showGlassContextMenu<String>(
        context: ctx,
        anchor: const Offset(100, 100),
        items: const [
          GlassContextMenuItem(
            value: 'reply',
            icon: Icons.reply_rounded,
            label: 'Reply',
          ),
          GlassContextMenuItem(
            value: 'delete',
            icon: Icons.delete_outline_rounded,
            label: 'Delete',
            dividerBefore: true,
          ),
        ],
      );
      await tester.pumpAndSettle();

      expect(find.text('Reply'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(await result, 'delete');
    });

    testWidgets('dismisses with null on barrier tap', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.expand();
            },
          ),
        ),
      );

      final result = showGlassContextMenu<String>(
        context: ctx,
        anchor: const Offset(40, 40),
        items: const [
          GlassContextMenuItem(
            value: 'pin',
            icon: Icons.push_pin_rounded,
            label: 'Pin Chat',
          ),
        ],
      );
      await tester.pumpAndSettle();
      // Tap far from the small menu anchored near the top-left corner.
      await tester.tapAt(const Offset(700, 500));
      await tester.pumpAndSettle();
      expect(await result, isNull);
      expect(find.text('Pin Chat'), findsNothing);
    });

    testWidgets('menu stays inside the window near edges', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.expand();
            },
          ),
        ),
      );
      final size = tester.view.physicalSize / tester.view.devicePixelRatio;

      showGlassContextMenu<String>(
        context: ctx,
        // Bottom-right corner: the menu must flip/clamp inward.
        anchor: Offset(size.width - 2, size.height - 2),
        items: const [
          GlassContextMenuItem(
            value: 'a',
            icon: Icons.reply_rounded,
            label: 'Reply',
          ),
          GlassContextMenuItem(
            value: 'b',
            icon: Icons.copy_rounded,
            label: 'Copy',
          ),
        ],
      );
      await tester.pumpAndSettle();

      final menuBox = tester.getRect(
        find.byWidgetPredicate(
          (w) => w.runtimeType.toString().startsWith('_GlassContextMenu'),
        ),
      );
      expect(menuBox.right, lessThanOrEqualTo(size.width));
      expect(menuBox.bottom, lessThanOrEqualTo(size.height));
      expect(menuBox.left, greaterThanOrEqualTo(0));
      expect(menuBox.top, greaterThanOrEqualTo(0));
    });
  });

  group('DesktopNavRail', () {
    testWidgets('fires tab, search, and settings callbacks', (tester) async {
      int? tappedTab;
      var searchTaps = 0;
      var settingsTaps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                DesktopNavRail(
                  tabs: const [
                    DesktopNavRailTab(
                      icon: Icons.chat_bubble_outline,
                      activeIcon: Icons.chat_bubble,
                      label: 'Chats',
                      badgeCount: 3,
                    ),
                    DesktopNavRailTab(
                      icon: Icons.campaign_outlined,
                      activeIcon: Icons.campaign,
                      label: 'Channels',
                    ),
                  ],
                  selectedIndex: 0,
                  onTabSelected: (i) => tappedTab = i,
                  searchActive: false,
                  onSearchTap: () => searchTaps++,
                  onSettingsTap: () => settingsTaps++,
                ),
                const Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
      );

      expect(find.text('3'), findsOneWidget); // unread badge
      await tester.tap(find.text('Channels'));
      expect(tappedTab, 1);
      await tester.tap(find.text('Search'));
      expect(searchTaps, 1);
      await tester.tap(find.text('Settings'));
      expect(settingsTaps, 1);
    });
  });
}
