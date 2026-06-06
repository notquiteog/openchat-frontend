import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/theme/app_theme.dart';
import 'package:openchat/widgets/glass.dart';

void main() {
  testWidgets('GlassContainer reduced mode avoids backdrop filters', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(reduceTransparency: true),
        home: const GlassAccessibilityScope(
          reduceTransparency: true,
          child: Scaffold(
            body: Center(
              child: GlassContainer(
                width: 160,
                height: 64,
                allowElevation: true,
                child: Text('Reduced'),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(BackdropFilter), findsNothing);

    final surface = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: find.byType(GlassContainer),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    final decoration = surface.decoration as ShapeDecoration;
    expect(decoration.color?.a, 1);
  });

  testWidgets('reduced transparency disables overscroll effects', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(reduceTransparency: true),
        scrollBehavior: const OpenChatScrollBehavior(reduceTransparency: true),
        home: Scaffold(
          body: ListView.builder(
            itemCount: 30,
            itemBuilder: (context, index) =>
                SizedBox(height: 48, child: Text('Item $index')),
          ),
        ),
      ),
    );

    expect(find.byType(GlowingOverscrollIndicator), findsNothing);
    expect(find.byType(StretchingOverscrollIndicator), findsNothing);
  });
}
