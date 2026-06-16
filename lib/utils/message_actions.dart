import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../models/message.dart';
import '../services/attachment_service.dart';

class ForwardPayload {
  final String messageType;
  final String plaintext;
  final String? attachmentId;

  const ForwardPayload({
    required this.messageType,
    required this.plaintext,
    this.attachmentId,
  });
}

bool isForwardable(Message message) {
  if (!message.isDecrypted) return false;
  final content = message.content;
  return switch (message.type) {
    MessageType.text => (message.decryptedContent ?? '').trim().isNotEmpty,
    MessageType.sticker =>
      (message.decryptedPayload ?? message.decryptedContent ?? '')
          .trim()
          .isNotEmpty,
    MessageType.image ||
    MessageType.video ||
    MessageType.voice ||
    MessageType.audio ||
    MessageType.animation ||
    MessageType.videoNote ||
    MessageType.livePhoto ||
    MessageType.file => (content?.attachmentId ?? '').trim().isNotEmpty,
    MessageType.location => (message.decryptedPayload ?? '').trim().isNotEmpty,
    MessageType.venue => (message.decryptedPayload ?? '').trim().isNotEmpty,
    MessageType.contact => content?.contact != null,
    MessageType.poll => message.poll != null,
    MessageType.system ||
    MessageType.dice ||
    MessageType.game ||
    MessageType.checklist ||
    MessageType.invoice ||
    MessageType.paymentRequest ||
    MessageType.paymentTransfer => false,
  };
}

ForwardPayload? buildForwardPayload(
  Message message, {
  required bool anonymous,
  String? fromUsername,
  required String Function(MessageType type) wireTypeOf,
}) {
  if (!isForwardable(message)) return null;
  final attribution = _forwardAttribution(
    anonymous: anonymous,
    fromUsername: fromUsername,
  );

  return switch (message.type) {
    MessageType.text => _forwardText(message, attribution),
    MessageType.sticker => _forwardSticker(message),
    MessageType.location ||
    MessageType.venue => _forwardRawPayload(message, wireTypeOf),
    MessageType.poll => null,
    MessageType.image ||
    MessageType.video ||
    MessageType.voice ||
    MessageType.audio ||
    MessageType.animation ||
    MessageType.videoNote ||
    MessageType.livePhoto ||
    MessageType.file ||
    MessageType.contact => _forwardMessageContent(
      message,
      attribution,
      wireTypeOf,
    ),
    MessageType.system ||
    MessageType.dice ||
    MessageType.game ||
    MessageType.checklist ||
    MessageType.invoice ||
    MessageType.paymentRequest ||
    MessageType.paymentTransfer => null,
  };
}

String messageTypeWireName(MessageType type) {
  return switch (type) {
    MessageType.sticker => 'sticker',
    MessageType.file => 'file',
    MessageType.image => 'image',
    MessageType.video => 'video',
    MessageType.voice => 'voice',
    MessageType.audio => 'audio',
    MessageType.animation => 'animation',
    MessageType.videoNote => 'video_note',
    MessageType.livePhoto => 'live_photo',
    MessageType.poll => 'poll',
    MessageType.location => 'location',
    MessageType.venue => 'venue',
    MessageType.contact => 'contact',
    MessageType.dice => 'dice',
    MessageType.game => 'game',
    MessageType.checklist => 'checklist',
    MessageType.invoice => 'invoice',
    MessageType.paymentRequest => 'payment_request',
    MessageType.paymentTransfer => 'payment_transfer',
    MessageType.system => 'system',
    MessageType.text => 'text',
  };
}

String? _forwardAttribution({
  required bool anonymous,
  required String? fromUsername,
}) {
  if (anonymous) return null;
  final username = fromUsername?.trim();
  if (username == null || username.isEmpty) return null;
  return '@$username';
}

ForwardPayload? _forwardText(Message message, String? attribution) {
  final text = message.decryptedContent ?? '';
  if (text.trim().isEmpty) return null;
  final plaintext = attribution == null
      ? text
      : jsonEncode({'text': text, 'forwarded_from': attribution});
  return ForwardPayload(messageType: 'text', plaintext: plaintext);
}

ForwardPayload? _forwardSticker(Message message) {
  final stickerId = (message.decryptedPayload ?? message.decryptedContent ?? '')
      .trim();
  if (stickerId.isEmpty) return null;
  return ForwardPayload(messageType: 'sticker', plaintext: stickerId);
}

ForwardPayload? _forwardRawPayload(
  Message message,
  String Function(MessageType type) wireTypeOf,
) {
  final raw = message.decryptedPayload;
  if (raw == null || raw.trim().isEmpty) return null;
  return ForwardPayload(messageType: wireTypeOf(message.type), plaintext: raw);
}

ForwardPayload? _forwardMessageContent(
  Message message,
  String? attribution,
  String Function(MessageType type) wireTypeOf,
) {
  final content = message.content;
  if (content == null) return null;
  final forwarded = MessageContent(
    text: content.text,
    entities: content.entities,
    attachmentId: content.attachmentId,
    fileName: content.fileName,
    fileSize: content.fileSize,
    mimeType: content.mimeType,
    durationMs: content.durationMs,
    linkPreview: content.linkPreview,
    // A forward should not silently re-arm a one-time media reveal for the new
    // recipient; spoiler blur remains a normal display preference.
    viewOnce: false,
    hasSpoiler: content.hasSpoiler,
    suppressLinkPreview: content.suppressLinkPreview,
    waveform: content.waveform,
    replyMarkup: content.replyMarkup,
    contact: content.contact,
    forwardedFrom: attribution,
    fileKey: content.fileKey,
    fileNonce: content.fileNonce,
  );
  return ForwardPayload(
    messageType: wireTypeOf(message.type),
    plaintext: jsonEncode(forwarded.toJson()),
    attachmentId: content.attachmentId,
  );
}

String messageDeepLink({
  required String conversationId,
  required String messageId,
}) {
  return Uri(
    scheme: 'openchat',
    host: 'message',
    queryParameters: {
      'conversation_id': conversationId,
      'message_id': messageId,
    },
  ).toString();
}

class MessageLink {
  final String conversationId;
  final String messageId;

  const MessageLink({required this.conversationId, required this.messageId});

  @override
  bool operator ==(Object other) =>
      other is MessageLink &&
      other.conversationId == conversationId &&
      other.messageId == messageId;

  @override
  int get hashCode => Object.hash(conversationId, messageId);
}

MessageLink? messageLinkFromUri(Uri uri) {
  if (uri.scheme.toLowerCase() != 'openchat') return null;
  if (uri.host.toLowerCase() != 'message') return null;
  final conversationId = uri.queryParameters['conversation_id']?.trim();
  final messageId = uri.queryParameters['message_id']?.trim();
  if (!_validMessageLinkPart(conversationId)) return null;
  if (!_validMessageLinkPart(messageId)) return null;
  return MessageLink(conversationId: conversationId!, messageId: messageId!);
}

bool _validMessageLinkPart(String? value) {
  if (value == null || value.isEmpty || value.length > 256) return false;
  return !value.contains(RegExp(r'[\x00-\x1F\x7F]'));
}

bool canDownloadMessageAttachment(Message message) {
  return message.content?.attachmentId != null;
}

Future<File> saveMessageAttachment({
  required Message message,
  required AttachmentService attachmentService,
}) async {
  final content = message.content;
  final attachmentId = content?.attachmentId;
  if (content == null || attachmentId == null) {
    throw StateError('message has no downloadable attachment');
  }

  final Uint8List bytes;
  if (content.fileKey != null && content.fileNonce != null) {
    bytes = await attachmentService.downloadAndDecrypt(
      attachmentId: attachmentId,
      fileKeyB64: content.fileKey!,
      fileNonceB64: content.fileNonce!,
    );
  } else if (!message.isEncrypted) {
    bytes = await attachmentService.downloadRaw(attachmentId: attachmentId);
  } else {
    throw StateError('missing attachment key');
  }

  final dir = await getApplicationDocumentsDirectory();
  final file = File('${dir.path}/${suggestedAttachmentFileName(message)}');
  await file.writeAsBytes(bytes);
  return file;
}

String suggestedAttachmentFileName(Message message) {
  final content = message.content;
  final explicit = content?.fileName?.trim();
  if (explicit != null && explicit.isNotEmpty) return _safeFileName(explicit);

  final attachmentId = content?.attachmentId ?? message.id;
  final extension = _extensionFor(message);
  return _safeFileName('openchat_$attachmentId$extension');
}

String _extensionFor(Message message) {
  final mime = message.content?.mimeType?.toLowerCase() ?? '';
  if (mime.contains('jpeg')) return '.jpg';
  if (mime.contains('png')) return '.png';
  if (mime.contains('webp')) return '.webp';
  if (mime.contains('gif')) return '.gif';
  if (mime.contains('mp4')) return '.mp4';
  if (mime.contains('webm')) return '.webm';
  if (mime.contains('mpeg')) return '.mp3';
  if (mime.contains('ogg')) return '.ogg';
  if (mime.contains('pdf')) return '.pdf';

  return switch (message.type) {
    MessageType.image || MessageType.livePhoto => '.webp',
    MessageType.video || MessageType.videoNote => '.mp4',
    MessageType.voice => '.ogg',
    MessageType.audio => '.mp3',
    _ => '',
  };
}

String _safeFileName(String value) {
  final cleaned = value.replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_').trim();
  return cleaned.isEmpty ? 'openchat_attachment' : cleaned;
}
