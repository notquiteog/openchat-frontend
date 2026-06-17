import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/widgets/glass.dart';

void main() {
  testWidgets(
    'GlassScreenScaffold.list shows the bar title and rows below it',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: GlassScreenScaffold.list(
            title: Text('Proxy & Tor'),
            children: [Text('Row A'), Text('Row B')],
          ),
        ),
      );
      await tester.pump();

      // Bar title + both rows render without throwing, and the body sits below
      // the (preferred-size) app bar rather than under it.
      expect(find.text('Proxy & Tor'), findsOneWidget);
      expect(find.text('Row A'), findsOneWidget);
      expect(find.text('Row B'), findsOneWidget);

      final barBottom = tester.getRect(find.text('Proxy & Tor')).bottom;
      final firstRowTop = tester.getRect(find.text('Row A')).top;
      expect(
        firstRowTop,
        greaterThan(barBottom),
        reason: 'list content must clear the glass app bar',
      );
    },
  );

  testWidgets('GlassScreenScaffold (body ctor) renders a custom body', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: GlassScreenScaffold(
          title: Text('Custom'),
          body: Center(child: Text('hello body')),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Custom'), findsOneWidget);
    expect(find.text('hello body'), findsOneWidget);
  });
}
