import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:openchat/models/conversation.dart';
import 'package:openchat/models/message.dart';
import 'package:openchat/models/user.dart';
import 'package:openchat/providers/settings_provider.dart';
import 'package:openchat/services/attachment_service.dart';
import 'package:openchat/services/api_service.dart';
import 'package:openchat/services/secure_storage_service.dart';
import 'package:openchat/widgets/conversation_encryption_status.dart';
import 'package:openchat/widgets/message_bubble.dart';
import 'package:openchat/widgets/message_image_layout.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Conversation _dmConversation({required EncryptionMode encryptionMode}) {
  return Conversation(
    id: 'conv-1',
    type: ConversationType.dm,
    encryptionMode: encryptionMode,
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

Message _voiceMessage() {
  final msg = Message(
    id: 'voice-msg-1',
    conversationId: 'conv-1',
    senderId: 'user-a',
    type: MessageType.voice,
    encryptedPayload: 'cipher',
    signature: '',
    isEncrypted: false,
    createdAt: DateTime.utc(2026, 1, 1),
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

class _RecordingApiService extends ApiService {
  _RecordingApiService() : super(SecureStorageService());

  String? requestedFileName;
  int? requestedFileSize;
  String? requestedMimeType;
  String? uploadedMimeType;
  Uint8List? uploadedBytes;
  String? confirmedAttachmentId;

  @override
  Future<UploadRequest> requestUpload({
    required String fileName,
    required int fileSize,
    required String mimeType,
  }) async {
    requestedFileName = fileName;
    requestedFileSize = fileSize;
    requestedMimeType = mimeType;
    return UploadRequest(
      attachmentId: 'opaque-attachment-id',
      uploadUrl: 'https://upload.invalid/object',
      expiresIn: 900,
    );
  }

  @override
  Future<void> uploadBytes(
    String uploadUrl,
    Uint8List bytes,
    String mimeType, {
    UploadProgressCallback? onProgress,
  }) async {
    uploadedBytes = bytes;
    uploadedMimeType = mimeType;
    onProgress?.call(bytes.length, bytes.length);
  }

  @override
  Future<void> confirmUpload(String attachmentId) async {
    confirmedAttachmentId = attachmentId;
  }
}

void main() {
  testWidgets('DM header shows encryption mode labels', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationEncryptionStatus(
            conversation: _dmConversation(encryptionMode: EncryptionMode.pgp),
          ),
        ),
      ),
    );
    expect(find.text('PGP'), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationEncryptionStatus(
            conversation: _dmConversation(encryptionMode: EncryptionMode.mls),
          ),
        ),
      ),
    );
    expect(find.text('MLS'), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationEncryptionStatus(
            conversation: _dmConversation(
              encryptionMode: EncryptionMode.plaintext,
            ),
          ),
        ),
      ),
    );
    expect(find.text('None'), findsOneWidget);
  });

  test('desktop image layout is capped and advertises expand affordance', () {
    final layout = MessageImageLayout.forViewport(const Size(1440, 900));
    expect(layout.maxBubbleWidth, lessThanOrEqualTo(520));
    expect(layout.maxImageHeight, lessThanOrEqualTo(420));
    expect(layout.reservedImageHeight, layout.maxBubbleWidth * 0.75);
    expect(
      layout.reservedImageHeight,
      lessThanOrEqualTo(layout.maxImageHeight),
    );
    expect(MessageImageLayout.expandTooltip, 'Expand image');
  });

  test(
    'gallery image conversion outputs webp and strips marker bytes',
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
      final withMarker = Uint8List.fromList([...encoded, ...marker.codeUnits]);
      await fixture.writeAsBytes(withMarker);

      final prepared = await AttachmentService.prepareGalleryPhotoForUpload(
        fixture,
        webpEncoder: (_, _) async => Uint8List.fromList([
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
        String.fromCharCodes(prepared.bytes.skip(8).take(4).toList()),
        'WEBP',
      );
      expect(String.fromCharCodes(prepared.bytes).contains(marker), isFalse);
    },
  );

  test(
    'gallery image conversion falls back when platform WebP is unavailable',
    () async {
      final dir = await Directory.systemTemp.createTemp('chat-media-test');
      addTearDown(() async {
        await dir.delete(recursive: true);
      });

      final fixture = File('${dir.path}/desktop-photo.jpg');
      final raw = img.Image(width: 4, height: 4);
      raw.setPixelRgba(0, 0, 0, 128, 255, 255);
      await fixture.writeAsBytes(img.encodeJpg(raw));

      final prepared = await AttachmentService.prepareGalleryPhotoForUpload(
        fixture,
        webpEncoder: (_, _) async => null,
      );

      expect(prepared.fileName, 'desktop-photo.webp');
      expect(prepared.mimeType, 'image/webp');
      expect(String.fromCharCodes(prepared.bytes.take(4).toList()), 'RIFF');
      expect(
        String.fromCharCodes(prepared.bytes.skip(8).take(4).toList()),
        'WEBP',
      );
    },
  );

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

  test('voice note upload payload includes duration metadata', () {
    const pending = PendingAttachment(
      attachmentId: 'voice-attachment-1',
      fileName: 'voice.m4a',
      fileSize: 2048,
      mimeType: 'audio/mp4',
      messageType: MessageType.voice,
      durationMs: 3600,
      fileKey: 'key',
      fileNonce: 'nonce',
    );

    expect(pending.toPayloadJson()['duration_ms'], 3600);
  });

  test('chat artifact unwraps encrypted structured payment payloads', () {
    final msg = Message(
      id: 'payment-msg-1',
      conversationId: 'conv-1',
      senderId: '',
      sealedSender: true,
      type: MessageType.text,
      encryptedPayload: 'cipher',
      signature: '',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final artifact = ChatArtifact.encodePayload(
      kind: 'payment_request',
      payload: {
        'kind': 'payment_request',
        'request': {'id': 'request-1', 'title': 'Dinner', 'note': 'Pizza'},
      },
    );
    msg.setDecryptedContent(
      jsonEncode({
        'openchat_message': 1,
        'type': 'payment_request',
        'payload': artifact,
      }),
      verifiedSenderId: 'sender-1',
    );

    expect(msg.type, MessageType.paymentRequest);
    expect(msg.senderId, 'sender-1');
    expect(msg.artifact?.kind, 'payment_request');
    expect(msg.artifact?.payloadMap?['request'], isA<Map>());
    expect(msg.decryptedPayload, contains('Dinner'));
    expect(msg.encryptedPayload, isNot(contains('Dinner')));
  });

  test(
    'encrypted attachment uploads register opaque server metadata',
    () async {
      final api = _RecordingApiService();
      final service = AttachmentService(api);
      final upload = EncryptedAttachmentUpload(
        ciphertext: Uint8List.fromList([1, 2, 3, 4]),
        fileName: 'family-photo.jpg',
        fileSize: 2048,
        encryptedFileSize: 4,
        mimeType: 'image/jpeg',
        messageType: MessageType.image,
        fileKey: 'key',
        fileNonce: 'nonce',
      );

      final pending = await service.uploadEncryptedAttachment(upload);

      expect(api.requestedFileName, 'attachment.bin');
      expect(api.requestedFileSize, upload.ciphertext.length);
      expect(api.requestedMimeType, 'application/octet-stream');
      expect(api.uploadedMimeType, 'application/octet-stream');
      expect(api.uploadedBytes, upload.ciphertext);
      expect(api.confirmedAttachmentId, 'opaque-attachment-id');

      final payload = pending.toPayloadJson(caption: 'private caption');
      expect(payload['file_name'], 'family-photo.jpg');
      expect(payload['mime_type'], 'image/jpeg');
      expect(payload['text'], 'private caption');
    },
  );

  testWidgets('message bubbles stay on the content layer (no backdrop blur)', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(message: _textMessage(), isMe: true),
        ),
      ),
    );

    // Liquid Glass keeps bubbles off the refractive layer so text stays crisp
    // and overlapping bubbles never muddy each other.
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('voice notes render an inline player before playback', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(message: _voiceMessage(), isMe: true),
        ),
      ),
    );

    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    expect(find.text('00:03'), findsOneWidget);
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
          body: MessageBubble(message: _textMessage(), isMe: true),
        ),
      ),
    );

    final text = tester.widget<Text>(find.text('hello'));
    expect(text.style?.color, Colors.white);
  });

  testWidgets('outgoing bubbles use a solid (opaque) accent fill', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(message: _textMessage(), isMe: true),
        ),
      ),
    );

    final fillAlphas = tester
        .widgetList<Container>(find.byType(Container))
        .map((container) => container.decoration)
        .whereType<BoxDecoration>()
        .map((decoration) => decoration.color)
        .whereType<Color>()
        .map((color) => color.a)
        .toList();

    // The bubble now paints a fully-opaque brand-accent fill on the content
    // layer rather than a translucent glass tint.
    expect(fillAlphas, isNotEmpty);
    expect(fillAlphas.reduce((a, b) => a > b ? a : b), 1.0);
  });

  testWidgets('outgoing bubbles show read receipts', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: _textMessage(),
            isMe: true,
            readByOthers: true,
          ),
        ),
      ),
    );

    expect(find.text('Read'), findsOneWidget);
  });

  testWidgets('strict privacy warns before opening message links', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'strict_privacy_mode': true});
    final settings = SettingsProvider();
    await settings.load();
    final message = _textMessage();
    message.setDecryptedContent('Read https://example.com/post');

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: settings,
        child: MaterialApp(
          home: Scaffold(body: MessageBubble(message: message, isMe: false)),
        ),
      ),
    );

    await tester.tap(
      find.textContaining('https://example.com/post', findRichText: true),
    );
    await tester.pumpAndSettle();

    expect(find.text('Open link?'), findsOneWidget);
    expect(find.textContaining('Opening this link can reveal'), findsOneWidget);
  });

  testWidgets('incoming sender bubble colors keep readable text', (
    tester,
  ) async {
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
