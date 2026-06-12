import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'secure_storage_service.dart';

enum OfflineOutboxAction {
  sendMessage,
  editMessage,
  reaction,
  attachmentUpload,
  channelPost,
  channelAttachmentUpload,
  channelReaction,
}

enum OfflineOutboxStatus { queued, sending, failed }

class OfflineOutboxItem {
  final String id;
  final OfflineOutboxAction action;
  final String conversationId;
  final DateTime createdAt;
  final int attempts;
  final OfflineOutboxStatus status;
  final String? lastError;
  final Map<String, dynamic> data;

  const OfflineOutboxItem({
    required this.id,
    required this.action,
    required this.conversationId,
    required this.createdAt,
    this.attempts = 0,
    this.status = OfflineOutboxStatus.queued,
    this.lastError,
    this.data = const {},
  });

  OfflineOutboxItem copyWith({
    int? attempts,
    OfflineOutboxStatus? status,
    String? lastError,
    Map<String, dynamic>? data,
    bool clearLastError = false,
  }) {
    return OfflineOutboxItem(
      id: id,
      action: action,
      conversationId: conversationId,
      createdAt: createdAt,
      attempts: attempts ?? this.attempts,
      status: status ?? this.status,
      lastError: clearLastError ? null : lastError ?? this.lastError,
      data: data ?? this.data,
    );
  }

  factory OfflineOutboxItem.fromJson(Map<String, dynamic> json) {
    return OfflineOutboxItem(
      id: json['id'] as String? ?? '',
      action: OfflineOutboxAction.values.firstWhere(
        (action) => action.name == json['action'],
        orElse: () => OfflineOutboxAction.sendMessage,
      ),
      conversationId: json['conversation_id'] as String? ?? '',
      createdAt:
          DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.now(),
      attempts: json['attempts'] as int? ?? 0,
      status: OfflineOutboxStatus.values.firstWhere(
        (status) => status.name == json['status'],
        orElse: () => OfflineOutboxStatus.queued,
      ),
      lastError: json['last_error'] as String?,
      data: Map<String, dynamic>.from(json['data'] as Map? ?? const {}),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'action': action.name,
    'conversation_id': conversationId,
    'created_at': createdAt.toUtc().toIso8601String(),
    'attempts': attempts,
    'status': status.name,
    if (lastError != null) 'last_error': lastError,
    'data': data,
  };
}

class OfflineOutboxService {
  final SecureStorageService _storage;
  final String? _storePath;
  final String? _attachmentDirPath;
  final String _storeFileName;
  final String _attachmentDirName;
  final Future<List<int>> Function()? _keyLoader;
  final _cipher = AesGcm.with256bits();

  SecretKey? _secretKey;
  List<int>? _keyBytes;

  /// Tail of the mutation chain. Every read-modify-write of the store file is
  /// appended here, so concurrent writers (ChatProvider's upsert/update paths
  /// racing drainOutbox) can never interleave their reads and writes and drop
  /// each other's items.
  Future<void> _mutationQueue = Future.value();

  OfflineOutboxService(
    SecureStorageService storage, {
    String? storePath,
    String? attachmentDirPath,
    String storeFileName = 'offline_outbox.json',
    String attachmentDirName = 'offline_outbox_attachments',
    Future<List<int>> Function()? keyLoader,
  }) : this._(
         storage,
         storePath: storePath,
         attachmentDirPath: attachmentDirPath,
         storeFileName: storeFileName,
         attachmentDirName: attachmentDirName,
         keyLoader: keyLoader,
       );

  OfflineOutboxService._(
    this._storage, {
    this._storePath,
    this._attachmentDirPath,
    this._storeFileName = 'offline_outbox.json',
    this._attachmentDirName = 'offline_outbox_attachments',
    this._keyLoader,
  });

  Future<List<OfflineOutboxItem>> list() => _readItems();

  Future<void> upsert(OfflineOutboxItem item) => _enqueueMutation(() async {
    final items = List<OfflineOutboxItem>.from(await _readItems());
    final index = items.indexWhere((existing) => existing.id == item.id);
    if (index == -1) {
      items.add(item);
    } else {
      items[index] = item;
    }
    items.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    await _writeItems(items);
  });

  Future<void> replaceAll(List<OfflineOutboxItem> items) =>
      _enqueueMutation(() async {
        final sorted = List<OfflineOutboxItem>.from(items)
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
        await _writeItems(sorted);
      });

  Future<void> remove(String id) => _enqueueMutation(() async {
    final items = List<OfflineOutboxItem>.from(await _readItems());
    final removed = items.where((item) => item.id == id).toList();
    items.removeWhere((item) => item.id == id);
    await _writeItems(items);
    for (final item in removed) {
      final path = item.data['ciphertext_path'] as String?;
      if (path != null && path.isNotEmpty) {
        await deleteAttachmentCiphertext(path);
      }
    }
  });

  Future<void> clearAll() => _enqueueMutation(() async {
    await _writeItems(const []);
    try {
      final dir = await _attachmentDir();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  });

  /// Appends [action] to the single mutation chain. A failed action must not
  /// wedge the chain, so the stored tail swallows the error while the caller
  /// still receives it.
  Future<void> _enqueueMutation(Future<void> Function() action) {
    final result = _mutationQueue.then((_) => action());
    _mutationQueue = result.catchError((_) {});
    return result;
  }

  Future<String> saveAttachmentCiphertext(
    String outboxId,
    Uint8List bytes,
  ) async {
    final dir = await _attachmentDir();
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, '$outboxId.bin'));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<Uint8List> readAttachmentCiphertext(String path) async {
    return Uint8List.fromList(await File(path).readAsBytes());
  }

  Future<void> deleteAttachmentCiphertext(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<List<OfflineOutboxItem>> _readItems() async {
    final file = await _storeFile();
    if (!await file.exists()) return const [];
    final encoded = await file.readAsString();
    if (encoded.trim().isEmpty) return const [];
    try {
      final decoded = await _decryptJson(encoded);
      final rawItems = decoded['items'];
      if (rawItems is! List) return const [];
      return rawItems
          .whereType<Map>()
          .map(
            (item) =>
                OfflineOutboxItem.fromJson(Map<String, dynamic>.from(item)),
          )
          .where((item) => item.id.isNotEmpty && item.conversationId.isNotEmpty)
          .toList();
    } on SecretBoxAuthenticationError {
      // Wrong key, not a damaged file — typically the throwaway session key
      // minted while the Linux keyring is locked at launch. The store on disk
      // is intact and recovers next session, so it must NOT be quarantined:
      // read empty for this session (see getOrCreateOutboxKey).
      return const [];
    } catch (error) {
      // Truncated/corrupt store (e.g. power loss mid-write before the atomic
      // rename existed). Move it aside instead of pretending it's empty, so
      // the bytes survive for recovery rather than being silently overwritten
      // by the next write — which would also orphan any ciphertexts in the
      // attachment dir that only the store references.
      await _quarantineCorruptStore(file, error);
      return const [];
    }
  }

  Future<void> _quarantineCorruptStore(File file, Object error) async {
    debugPrint(
      'OfflineOutboxService: unreadable outbox store ${file.path} '
      '($error); moving aside to ${p.basename(file.path)}.corrupt',
    );
    try {
      await file.rename('${file.path}.corrupt');
    } catch (renameError) {
      debugPrint(
        'OfflineOutboxService: failed to quarantine corrupt store: '
        '$renameError',
      );
    }
  }

  Future<void> _writeItems(List<OfflineOutboxItem> items) async {
    final file = await _storeFile();
    await file.parent.create(recursive: true);
    final encrypted = await _encryptJson({
      'version': 1,
      'items': items.map((item) => item.toJson()).toList(),
    });
    // Crash-safe write: never rewrite the only copy of queued messages in
    // place. Write a sibling, flush it, then atomically rename over the store
    // so a crash mid-write leaves either the old or the new file — never a
    // truncated one.
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(encrypted, flush: true);
    await tmp.rename(file.path);
  }

  Future<File> _storeFile() async {
    final explicit = _storePath;
    if (explicit != null) return File(explicit);
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, _storeFileName));
  }

  Future<Directory> _attachmentDir() async {
    final explicit = _attachmentDirPath;
    if (explicit != null) return Directory(explicit);
    final dir = await getApplicationSupportDirectory();
    return Directory(p.join(dir.path, _attachmentDirName));
  }

  Future<String> _encryptJson(Map<String, Object?> json) async {
    final box = await _cipher.encrypt(
      utf8.encode(jsonEncode(json)),
      secretKey: await _secret(),
    );
    return base64Encode(box.concatenation());
  }

  Future<Map<String, dynamic>> _decryptJson(String encoded) async {
    final box = SecretBox.fromConcatenation(
      base64Decode(encoded),
      nonceLength: _cipher.nonceLength,
      macLength: _cipher.macAlgorithm.macLength,
    );
    final bytes = await _cipher.decrypt(box, secretKey: await _secret());
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
    return const {};
  }

  Future<SecretKey> _secret() async {
    final existing = _secretKey;
    if (existing != null) return existing;
    final bytes = await _loadKeyBytes();
    final key = SecretKey(bytes);
    _secretKey = key;
    return key;
  }

  Future<List<int>> _loadKeyBytes() async {
    final existing = _keyBytes;
    if (existing != null) return existing;
    final loader = _keyLoader;
    final bytes = loader != null
        ? await loader()
        : base64Decode(await _storage.getOrCreateOutboxKey());
    if (bytes.length != 32) {
      throw StateError('outbox key must be 32 bytes');
    }
    _keyBytes = List<int>.unmodifiable(bytes);
    return _keyBytes!;
  }
}
