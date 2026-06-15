import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/widgets/glass.dart';
import 'package:openchat/widgets/voice_note_recorder.dart';

void main() {
  testWidgets('voice recorder sheet renders glass controls', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: VoiceNoteRecorderSheet())),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Cancel'), findsOneWidget);
    expect(find.byTooltip('Send'), findsOneWidget);
    expect(find.byType(GlassCircleIconButton), findsAtLeastNWidgets(3));
  });
}
