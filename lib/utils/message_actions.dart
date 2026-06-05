import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../models/message.dart';
import '../services/attachment_service.dart';

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
