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

  test(
    'quarantines an unreadable store instead of silently losing it',
    () async {
      await File(storePath).writeAsString('not encrypted outbox data');

      expect(await service.list(), isEmpty);

      final quarantined = File('$storePath.corrupt');
      expect(
        await quarantined.exists(),
        isTrue,
        reason:
            'corrupt bytes must be moved aside for recovery, not '
            'overwritten by the next write',
      );
      expect(await quarantined.readAsString(), 'not encrypted outbox data');
      expect(await File(storePath).exists(), isFalse);

      // The store must keep working after quarantine.
      await service.upsert(
        _item(
          id: 'after-corruption',
          action: OfflineOutboxAction.sendMessage,
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      );
      expect((await service.list()).single.id, 'after-corruption');
    },
  );

  test('quarantines a truncated store file on read', () async {
    await service.upsert(
      _item(
        id: 'outbox-1',
        action: OfflineOutboxAction.sendMessage,
        createdAt: DateTime.utc(2026, 1, 1),
        data: {'plaintext': 'queued while offline'},
      ),
    );

    // Simulate a torn write from a crash: keep a prefix whose length is not
    // a multiple of 4 so the damage is structurally detectable.
    final file = File(storePath);
    final encoded = await file.readAsString();
    await file.writeAsString(encoded.substring(0, (encoded.length ~/ 2) | 1));

    expect(await service.list(), isEmpty);
    expect(await File('$storePath.corrupt').exists(), isTrue);
    expect(await file.exists(), isFalse);
  });

  test('a wrong key reads empty WITHOUT quarantining the store', () async {
    await service.upsert(
      _item(
        id: 'outbox-1',
        action: OfflineOutboxAction.sendMessage,
        createdAt: DateTime.utc(2026, 1, 1),
      ),
    );

    // A throwaway session key (locked Linux keyring at launch) must not move
    // the intact store aside — it recovers next session with the real key.
    final wrongKeyReader = OfflineOutboxService(
      SecureStorageService(),
      storePath: storePath,
      attachmentDirPath: p.join(tempDir.path, 'attachments'),
      keyLoader: () async => List<int>.generate(32, (index) => 255 - index),
    );

    expect(await wrongKeyReader.list(), isEmpty);
    expect(await File('$storePath.corrupt').exists(), isFalse);
    expect(await File(storePath).exists(), isTrue);
    expect((await service.list()).single.id, 'outbox-1');
  });

  test('writes are atomic: no .tmp sibling survives and concurrent writers '
      'never drop each other\'s items', () async {
    final items = List.generate(
      8,
      (i) => _item(
        id: 'outbox-$i',
        action: OfflineOutboxAction.sendMessage,
        createdAt: DateTime.utc(2026, 1, 1 + i),
      ),
    );

    // Unserialized read-modify-write cycles would each read the same initial
    // store and clobber one another (last writer wins).
    await Future.wait(items.map(service.upsert));

    final restored = await service.list();
    expect(
      restored.map((item) => item.id),
      items.map((item) => item.id),
      reason:
          'concurrent upserts must be serialized through the mutation '
          'chain',
    );
    expect(await File('$storePath.tmp').exists(), isFalse);

    // Mixed mutations stay serialized too.
    await Future.wait([
      service.remove('outbox-0'),
      service.upsert(
        _item(
          id: 'outbox-9',
          action: OfflineOutboxAction.sendMessage,
          createdAt: DateTime.utc(2026, 1, 20),
        ),
      ),
      service.remove('outbox-3'),
    ]);

    expect((await service.list()).map((item) => item.id), [
      'outbox-1',
      'outbox-2',
      'outbox-4',
      'outbox-5',
      'outbox-6',
      'outbox-7',
      'outbox-9',
    ]);
    expect(await File('$storePath.tmp').exists(), isFalse);
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
