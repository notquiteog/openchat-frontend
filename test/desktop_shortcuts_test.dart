import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/widgets/desktop.dart';

String _activatorId(SingleActivator activator) {
  return [
    activator.trigger.keyId,
    activator.control,
    activator.meta,
    activator.alt,
    activator.shift,
  ].join(':');
}

void main() {
  test('desktop shortcut specs cover shell and conversation actions', () {
    final actions = desktopShortcutSpecs
        .map((shortcut) => shortcut.action)
        .toSet();

    expect(actions, contains(DesktopShortcutAction.search));
    expect(actions, contains(DesktopShortcutAction.newChat));
    expect(actions, contains(DesktopShortcutAction.nextConversation));
    expect(actions, contains(DesktopShortcutAction.previousConversation));
    expect(actions, contains(DesktopShortcutAction.jumpToConversation));
    expect(actions, contains(DesktopShortcutAction.markSelectedRead));
    expect(actions, contains(DesktopShortcutAction.archiveSelected));
    expect(actions, contains(DesktopShortcutAction.openSettings));
    expect(actions, contains(DesktopShortcutAction.close));
    expect(actions, contains(DesktopShortcutAction.showCheatSheet));
  });

  test('desktop shortcut activators do not collide', () {
    final activatorIds = <String>{};

    for (final shortcut in desktopShortcutSpecs) {
      for (final activator in shortcut.activators) {
        expect(
          activatorIds.add(_activatorId(activator)),
          isTrue,
          reason:
              '${shortcut.description} duplicates ${_activatorId(activator)}',
        );
      }
    }
  });

  test('navigation shortcuts use Alt+Up and Alt+Down', () {
    final previous = desktopShortcutSpecs.singleWhere(
      (shortcut) =>
          shortcut.action == DesktopShortcutAction.previousConversation,
    );
    final next = desktopShortcutSpecs.singleWhere(
      (shortcut) => shortcut.action == DesktopShortcutAction.nextConversation,
    );

    final previousActivator = previous.activators.single;
    final nextActivator = next.activators.single;

    expect(previousActivator.trigger, LogicalKeyboardKey.arrowUp);
    expect(previousActivator.alt, isTrue);
    expect(previousActivator.control, isFalse);
    expect(previousActivator.meta, isFalse);
    expect(nextActivator.trigger, LogicalKeyboardKey.arrowDown);
    expect(nextActivator.alt, isTrue);
    expect(nextActivator.control, isFalse);
    expect(nextActivator.meta, isFalse);
  });

  test('jump shortcuts cover conversations one through nine', () {
    final jumps =
        desktopShortcutSpecs
            .where(
              (shortcut) =>
                  shortcut.action == DesktopShortcutAction.jumpToConversation,
            )
            .map((shortcut) => shortcut.index)
            .toList()
          ..sort();

    expect(jumps, [1, 2, 3, 4, 5, 6, 7, 8, 9]);
  });

  testWidgets('shortcut labels use platform modifier labels', (tester) async {
    late BuildContext macContext;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Theme(
          data: ThemeData(platform: TargetPlatform.macOS),
          child: Builder(
            builder: (context) {
              macContext = context;
              return const SizedBox();
            },
          ),
        ),
      ),
    );

    final search = desktopShortcutSpecs.firstWhere(
      (shortcut) => shortcut.action == DesktopShortcutAction.search,
    );

    expect(modKeyLabel(macContext), '⌘');
    expect(search.labelFor(macContext), '⌘ K');

    late BuildContext windowsContext;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Theme(
          data: ThemeData(platform: TargetPlatform.windows),
          child: Builder(
            builder: (context) {
              windowsContext = context;
              return const SizedBox();
            },
          ),
        ),
      ),
    );

    expect(modKeyLabel(windowsContext), 'Ctrl');
    expect(search.labelFor(windowsContext), 'Ctrl K');
  });

  testWidgets('desktop shortcuts sheet renders every shortcut', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: DesktopShortcutsSheet())),
    );

    expect(find.text('Keyboard shortcuts'), findsOneWidget);
    expect(find.text('General'), findsOneWidget);
    expect(find.text('Navigation'), findsOneWidget);
    expect(find.text('Conversation'), findsOneWidget);
    expect(find.text('Alt Up'), findsOneWidget);
    expect(find.text('Alt Down'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);

    for (final description
        in desktopShortcutSpecs
            .map((shortcut) => shortcut.description)
            .toSet()) {
      expect(find.text(description), findsWidgets);
    }
  });

  testWidgets('bare question shortcut guard detects editable focus', (
    tester,
  ) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TextField(focusNode: focusNode)),
      ),
    );

    expect(desktopShortcutTextInputFocused(), isFalse);

    await tester.tap(find.byType(TextField));
    await tester.pump();

    expect(focusNode.hasFocus, isTrue);
    expect(desktopShortcutTextInputFocused(), isTrue);

    focusNode.unfocus();
    await tester.pump();

    expect(desktopShortcutTextInputFocused(), isFalse);
  });
}
