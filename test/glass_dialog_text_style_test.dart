import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/widgets/glass.dart';

void main() {
  testWidgets('GlassDialog text inherits no debug underline decoration', (
    tester,
  ) async {
    late BuildContext triggerContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            triggerContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    final dialogFuture = GlassDialog.show<void>(
      context: triggerContext,
      title: 'Privacy notice',
      message: 'No debug underline should be inherited.',
      actions: [
        GlassDialogAction(
          label: 'OK',
          onPressed: () => Navigator.pop(triggerContext),
        ),
      ],
    );
    await tester.pump();

    final titleContext = tester.element(find.text('Privacy notice'));
    final messageContext = tester.element(
      find.text('No debug underline should be inherited.'),
    );

    expect(
      DefaultTextStyle.of(titleContext).style.decoration,
      TextDecoration.none,
    );
    expect(
      DefaultTextStyle.of(messageContext).style.decoration,
      TextDecoration.none,
    );

    Navigator.of(titleContext).pop();
    await dialogFuture;
  });
}
