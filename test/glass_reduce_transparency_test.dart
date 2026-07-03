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

  // Regression for the SFU reaction picker over live call video: the sheet
  // wraps its glass in ForcedOpaqueGlass while a video texture is live, and
  // that wrapper must flip BOTH the accessibility scope (app wrappers) and
  // the glass theme (raw package widgets still blur when blur > 0) so no
  // BackdropFilter ends up above the RTCVideoView (desktop call rule 1).
  testWidgets('ForcedOpaqueGlass forces backdrop-free rendering', (
    tester,
  ) async {
    late BuildContext probe;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ForcedOpaqueGlass(
            child: GlassContainer(
              padding: const EdgeInsets.all(14),
              child: AdaptiveLiquidGlassLayer(
                child: GlassButton.custom(
                  onTap: () {},
                  width: 52,
                  height: 52,
                  shape: const LiquidOval(),
                  useOwnLayer: false,
                  quality: GlassQuality.standard,
                  child: Builder(
                    builder: (context) {
                      probe = context;
                      return const Text('🎉');
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(BackdropFilter), findsNothing);
    expect(glassReduceTransparency(probe), isTrue);
    final settings = GlassThemeData.of(probe).settingsFor(probe);
    expect(settings?.blur, 0);
    expect(settings?.thickness, 0);
  });

  testWidgets('ForcedOpaqueGlass disabled leaves the subtree untouched', (
    tester,
  ) async {
    late BuildContext probe;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ForcedOpaqueGlass(
            enabled: false,
            child: GlassContainer(
              child: Builder(
                builder: (context) {
                  probe = context;
                  return const Text('normal');
                },
              ),
            ),
          ),
        ),
      ),
    );

    expect(glassReduceTransparency(probe), isFalse);
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
