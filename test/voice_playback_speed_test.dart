import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/message.dart';
import 'package:openchat/providers/settings_provider.dart';
import 'package:openchat/widgets/message_bubble.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Message _voiceMessage() {
  final msg = Message(
    id: 'voice-speed-msg-1',
    conversationId: 'conv-1',
    senderId: 'user-a',
    type: MessageType.voice,
    encryptedPayload: 'cipher',
    signature: '',
    isEncrypted: false,
    createdAt: DateTime.utc(2026, 6, 15),
  );
  msg.setDecryptedContent(
    jsonEncode({
      'text': '',
      'attachment_id': 'voice-attachment-1',
      'file_name': 'voice.m4a',
      'file_size': 2048,
      'mime_type': 'audio/mp4',
      'duration_ms': 3600,
    }),
  );
  return msg;
}

void main() {
  test('voice playback speed defaults, clamps, and persists', () async {
    SharedPreferences.setMockInitialValues({});
    final provider = SettingsProvider();
    await provider.load();

    expect(provider.voicePlaybackSpeed, 1.0);

    await provider.setVoicePlaybackSpeed(1.5);
    expect(provider.voicePlaybackSpeed, 1.5);

    final reloaded = SettingsProvider();
    await reloaded.load();
    expect(reloaded.voicePlaybackSpeed, 1.5);

    await reloaded.setVoicePlaybackSpeed(3.0);
    expect(reloaded.voicePlaybackSpeed, 2.0);

    await reloaded.setVoicePlaybackSpeed(0.5);
    expect(reloaded.voicePlaybackSpeed, 1.0);
  });

  testWidgets('voice bubble speed chip cycles and persists', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsProvider();
    await settings.load();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: settings,
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                child: MessageBubble(message: _voiceMessage(), isMe: true),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('1x'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('1x'));
    await tester.pump();
    expect(find.text('1.5x'), findsOneWidget);
    expect(settings.voicePlaybackSpeed, 1.5);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('1.5x'));
    await tester.pump();
    expect(find.text('2x'), findsOneWidget);
    expect(settings.voicePlaybackSpeed, 2.0);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('2x'));
    await tester.pump();
    expect(find.text('1x'), findsOneWidget);
    expect(settings.voicePlaybackSpeed, 1.0);
    expect(tester.takeException(), isNull);
  });
}
