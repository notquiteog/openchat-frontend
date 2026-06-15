import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:openchat/widgets/connection_quality_bars.dart';

void main() {
  testWidgets('connection quality bars map LiveKit quality to active bars', (
    tester,
  ) async {
    final cases = {
      lk.ConnectionQuality.excellent: 3,
      lk.ConnectionQuality.good: 2,
      lk.ConnectionQuality.poor: 1,
      lk.ConnectionQuality.lost: 1,
    };

    for (final entry in cases.entries) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ConnectionQualityBars(quality: entry.key)),
        ),
      );

      final activeBars = find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key as ValueKey<String>).value.startsWith(
              'connection-quality-active-bar-',
            ),
      );
      expect(activeBars, findsNWidgets(entry.value), reason: '${entry.key}');
      expect(
        find.bySemanticsLabel(ConnectionQualityBars.labelFor(entry.key)),
        findsOneWidget,
      );
    }
  });

  testWidgets('unknown connection quality renders no bars', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ConnectionQualityBars(quality: lk.ConnectionQuality.unknown),
        ),
      ),
    );

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key as ValueKey<String>).value.startsWith(
              'connection-quality-active-bar-',
            ),
      ),
      findsNothing,
    );
  });
}
