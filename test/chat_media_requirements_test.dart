import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:openchat/models/conversation.dart';
import 'package:openchat/models/message.dart';
import 'package:openchat/models/user.dart';
import 'package:openchat/services/attachment_service.dart';
import 'package:openchat/widgets/conversation_encryption_status.dart';
import 'package:openchat/widgets/message_bubble.dart';
import 'package:openchat/widgets/message_image_layout.dart';

Conversation _dmConversation({required bool encryptionEnabled}) {
  return Conversation(
    id: 'conv-1',
    type: ConversationType.dm,
    encryptionEnabled: encryptionEnabled,
    createdAt: DateTime.utc(2026, 1, 1),
    createdBy: 'user-a',
  );
}

Message _textMessage() {
  final msg = Message(
    id: 'msg-1',
    conversationId: 'conv-1',
    senderId: 'user-a',
    type: MessageType.text,
    encryptedPayload: 'cipher',
    signature: '',
    createdAt: DateTime.utc(2026, 1, 1),
  );
  msg.setDecryptedContent('hello');
  return msg;
}

Message _incomingTextMessageWithBubble(int bubbleColor) {
  final msg = _textMessage();
  msg.sender = User(
    id: 'user-b',
    username: 'alice',
    publicKey: 'pub',
    keyFingerprint: 'fingerprint',
    bubbleColor: bubbleColor,
    createdAt: DateTime.utc(2026, 1, 1),
  );
  return msg;
}

void main() {
  testWidgets('DM header shows encrypted/off status labels', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationEncryptionStatus(
            conversation: _dmConversation(encryptionEnabled: true),
          ),
        ),
      ),
    );
    expect(find.text('Encrypted'), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationEncryptionStatus(
            conversation: _dmConversation(encryptionEnabled: false),
          ),
        ),
      ),
    );
    expect(find.text('Encryption off'), findsOneWidget);
  });

  test('desktop image layout is capped and advertises expand affordance', () {
    final layout = MessageImageLayout.forViewport(const Size(1440, 900));
    expect(layout.maxBubbleWidth, lessThanOrEqualTo(520));
    expect(layout.maxImageHeight, lessThanOrEqualTo(420));
    expect(MessageImageLayout.expandTooltip, 'Expand image');
  });

  test('gallery image conversion outputs webp and strips marker bytes',
      () async {
    final dir = await Directory.systemTemp.createTemp('chat-media-test');
    addTearDown(() async {
      await dir.delete(recursive: true);
    });

    final fixture = File('${dir.path}/photo.jpg');
    final raw = img.Image(width: 5, height: 5);
    raw.setPixelRgba(0, 0, 255, 0, 0, 255);
    final encoded = img.encodeJpg(raw);
    const marker = 'GPS-META-MARKER';
    final withMarker = Uint8List.fromList([
      ...encoded,
      ...marker.codeUnits,
    ]);
    await fixture.writeAsBytes(withMarker);

    final prepared = await AttachmentService.prepareGalleryPhotoForUpload(
      fixture,
      webpEncoder: (_, __) async => Uint8List.fromList([
        ...'RIFF'.codeUnits,
        1,
        0,
        0,
        0,
        ...'WEBP'.codeUnits,
        0,
      ]),
    );

    expect(prepared.fileName.endsWith('.webp'), isTrue);
    expect(prepared.mimeType, 'image/webp');
    expect(String.fromCharCodes(prepared.bytes.take(4).toList()), 'RIFF');
    expect(
        String.fromCharCodes(prepared.bytes.skip(8).take(4).toList()), 'WEBP');
    expect(String.fromCharCodes(prepared.bytes).contains(marker), isFalse);
  });

  test('file upload path preserves original name and mime type', () async {
    final dir = await Directory.systemTemp.createTemp('chat-file-test');
    addTearDown(() async {
      await dir.delete(recursive: true);
    });

    final fixture = File('${dir.path}/notes.txt');
    await fixture.writeAsString('plain text payload');

    final prepared = await AttachmentService.prepareFileForUpload(fixture);

    expect(prepared.fileName, 'notes.txt');
    expect(prepared.mimeType, 'text/plain');
  });

  testWidgets('message bubbles render a glass blur shell', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: _textMessage(),
            isMe: true,
          ),
        ),
      ),
    );

    expect(find.byType(BackdropFilter), findsWidgets);
  });

  testWidgets('default outgoing bubble text is always white', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.lightBlue,
            primary: Colors.lightBlueAccent,
            onPrimary: Colors.blueGrey,
          ),
        ),
        home: Scaffold(
          body: MessageBubble(
            message: _textMessage(),
            isMe: true,
          ),
        ),
      ),
    );

    final text = tester.widget<Text>(find.text('hello'));
    expect(text.style?.color, Colors.white);
  });

  testWidgets('message bubbles use a highly translucent glass tint',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: _textMessage(),
            isMe: true,
          ),
        ),
      ),
    );

    final tintedDecorations = tester
        .widgetList<Container>(find.byType(Container))
        .map((container) => container.decoration)
        .whereType<BoxDecoration>()
        .map((decoration) => decoration.color)
        .whereType<Color>()
        .where((color) => color.a < 1)
        .toList();

    expect(tintedDecorations, isNotEmpty);
    expect(
      tintedDecorations.map((color) => color.a).reduce((a, b) => a > b ? a : b),
      lessThanOrEqualTo(0.38),
    );
  });

  testWidgets('incoming sender bubble colors keep readable text',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: _incomingTextMessageWithBubble(0xFF102033),
            isMe: false,
          ),
        ),
      ),
    );

    final text = tester.widget<Text>(find.text('hello'));
    expect(text.style?.color, Colors.white);
  });
}
