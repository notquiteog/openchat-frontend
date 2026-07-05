import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/message.dart';
import '../providers/chat_provider.dart';

/// The result of a save/share operation, so the UI can pick the right toast.
enum DataExportOutcome {
  /// The user picked a destination (desktop) or the share sheet was dispatched.
  saved,

  /// The user dismissed the desktop save dialog — no file written, no error.
  cancelled,

  /// There were no conversations to export.
  empty,
}

/// Builds and hands off a CLIENT-SIDE, plaintext dump of the locally-decrypted
/// conversations. Nothing leaves through the server: the JSON is assembled from
/// the already-decrypted messages held in [ChatProvider] and written straight
/// to a file the user saves (desktop) or shares (mobile).
class DataExportService {
  /// Current on-disk shape of the export. Bump on any breaking layout change.
  static const int exportVersion = 1;

  /// Assembles the pretty-printed JSON export from [chatProvider]. Messages
  /// with no decryptable content are skipped gracefully; the rest are sorted by
  /// [Message.createdAt] ascending within each conversation.
  String buildExportJson(ChatProvider chatProvider) {
    final conversations = <Map<String, dynamic>>[];

    for (final conversation in chatProvider.conversations) {
      final messages = chatProvider.messagesFor(conversation.id).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

      final exportedMessages = <Map<String, dynamic>>[];
      for (final message in messages) {
        final text = message.decryptedContent;
        final content = message.content;
        // Skip anything we can't render in plaintext (undecryptable, or a bare
        // control message with neither text nor an attachment).
        if (text == null && content?.attachmentId == null) continue;

        exportedMessages.add({
          'id': message.id,
          'sender': message.sender?.username ?? message.senderId,
          'sent_at': message.createdAt.toUtc().toIso8601String(),
          'text': text,
          'attachment': content?.attachmentId == null
              ? null
              : {'fileName': content?.fileName, 'mimeType': content?.mimeType},
        });
      }

      conversations.add({
        'id': conversation.id,
        'title': conversation.name,
        'type': conversation.type.name,
        'messages': exportedMessages,
      });
    }

    final payload = <String, dynamic>{
      'export_version': exportVersion,
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'conversations': conversations,
    };

    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  /// Builds the export and either saves it to a user-chosen file (desktop) or
  /// hands it to the platform share sheet (mobile). Returns a
  /// [DataExportOutcome] describing what happened so callers can toast.
  Future<DataExportOutcome> exportAndSave(ChatProvider chatProvider) async {
    if (chatProvider.conversations.isEmpty) {
      return DataExportOutcome.empty;
    }

    final json = buildExportJson(chatProvider);
    final now = DateTime.now().toUtc();
    final stamp =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}'
        '-${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
    final fileName = 'openchat-export-$stamp.json';

    // Mobile: write to a temp file and share it. Desktop: prompt for a save
    // location and write there directly. Mirrors trust_center_screen's
    // desktop-save + mobile-share split.
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$fileName');
      await file.writeAsString(json);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], text: 'OpenChat data export'),
      );
      return DataExportOutcome.saved;
    }

    final location = await getSaveLocation(suggestedName: fileName);
    if (location == null) return DataExportOutcome.cancelled;
    await File(location.path).writeAsString(json);
    return DataExportOutcome.saved;
  }
}
