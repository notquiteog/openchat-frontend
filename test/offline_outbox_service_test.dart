import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/services/offline_outbox_service.dart';
import 'package:openchat/services/secure_storage_service.dart';
import 'package:path/path.dart' as p;

OfflineOutboxItem _item({
  required String id,
  required OfflineOutboxAction action,
  required DateTime createdAt,
  Map<String, dynamic> data = const {},
}) {
  return OfflineOutboxItem(
    id: id,
    action: action,
    conversationId: 'conv-1',
    createdAt: createdAt,
    data: data,
  );
}

void main() {
  late Directory tempDir;
  late String storePath;
  late OfflineOutboxService service;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('openchat_outbox_test_');
    storePath = p.join(tempDir.path, 'offline_outbox.json');
    service = OfflineOutboxService(
      SecureStorageService(),
      storePath: storePath,
      attachmentDirPath: p.join(tempDir.path, 'attachments'),
      keyLoader: () async => List<int>.generate(32, (index) => index),
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('encrypts metadata and restores queued items in send order', () async {
    final later = _item(
      id: 'outbox-2',
      action: OfflineOutboxAction.sendMessage,
      createdAt: DateTime.utc(2026, 1, 2),
      data: {'plaintext': 'offline secret'},
    );
    final earlier = _item(
      id: 'outbox-1',
      action: OfflineOutboxAction.editMessage,
      createdAt: DateTime.utc(2026, 1, 1),
      data: {'plaintext': 'edited secret'},
    );

    await service.replaceAll([later, earlier]);

    final stored = await File(storePath).readAsString();
    expect(stored.trim().startsWith('{'), isFalse);
    expect(stored, isNot(contains('offline secret')));

    final restored = await service.list();
    expect(restored.map((item) => item.id), ['outbox-1', 'outbox-2']);
    expect(restored.first.action, OfflineOutboxAction.editMessage);
    expect(restored.last.data['plaintext'], 'offline secret');
  });

  test(
    'upserts item status and removes queued attachment ciphertext',
    () async {
      final ciphertextPath = await service.saveAttachmentCiphertext(
        'upload-1',
        Uint8List.fromList([1, 2, 3, 4]),
      );
      expect(await service.readAttachmentCiphertext(ciphertextPath), [
        1,
        2,
        3,
        4,
      ]);

      final upload = _item(
        id: 'upload-1',
        action: OfflineOutboxAction.attachmentUpload,
        createdAt: DateTime.utc(2026, 1, 1),
        data: {'ciphertext_path': ciphertextPath},
      );
      await service.upsert(upload);
      await service.upsert(
        upload.copyWith(
          attempts: 2,
          status: OfflineOutboxStatus.failed,
          lastError: 'network down',
        ),
      );

      final restored = await service.list();
      expect(restored.single.attempts, 2);
      expect(restored.single.status, OfflineOutboxStatus.failed);
      expect(restored.single.lastError, 'network down');

      await service.remove('upload-1');

      expect(await service.list(), isEmpty);
      expect(await File(ciphertextPath).exists(), isFalse);
    },
  );

  test('ignores unreadable encrypted store data', () async {
    await File(storePath).writeAsString('not encrypted outbox data');

    expect(await service.list(), isEmpty);
  });

  test('keeps custom outbox stores isolated', () async {
    final chatStore = OfflineOutboxService(
      SecureStorageService(),
      storePath: p.join(tempDir.path, 'chat.json'),
      attachmentDirPath: p.join(tempDir.path, 'chat_attachments'),
      keyLoader: () async => List<int>.generate(32, (index) => index),
    );
    final channelStore = OfflineOutboxService(
      SecureStorageService(),
      storePath: p.join(tempDir.path, 'channel.json'),
      attachmentDirPath: p.join(tempDir.path, 'channel_attachments'),
      keyLoader: () async => List<int>.generate(32, (index) => index),
    );

    await chatStore.upsert(
      _item(
        id: 'chat-1',
        action: OfflineOutboxAction.sendMessage,
        createdAt: DateTime.utc(2026, 1, 1),
      ),
    );
    await channelStore.upsert(
      _item(
        id: 'channel-1',
        action: OfflineOutboxAction.channelPost,
        createdAt: DateTime.utc(2026, 1, 2),
      ),
    );

    expect((await chatStore.list()).map((item) => item.id), ['chat-1']);
    expect((await channelStore.list()).map((item) => item.id), ['channel-1']);
  });
}
