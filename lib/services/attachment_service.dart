import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/message.dart';
import '../services/api_service.dart';

/// Describes a file selected and ready to send.
class PendingAttachment {
  final String attachmentId;
  final String fileName;
  final int fileSize;
  final String mimeType;
  final MessageType messageType;
  final int? durationMs;
  // AES-256-GCM key + nonce encoded as base64 — included in the PGP payload only
  final String fileKey;
  final String fileNonce;

  /// Local file path of the just-picked media, kept only for in-app preview
  /// (e.g. the story composer). Transient — never uploaded or serialized.
  final String? previewPath;

  const PendingAttachment({
    required this.attachmentId,
    required this.fileName,
    required this.fileSize,
    required this.mimeType,
    required this.messageType,
    this.durationMs,
    required this.fileKey,
    required this.fileNonce,
    this.previewPath,
  });

  /// Returns a copy carrying a local [previewPath] for preview rendering.
  PendingAttachment withPreview(String? path) => PendingAttachment(
    attachmentId: attachmentId,
    fileName: fileName,
    fileSize: fileSize,
    mimeType: mimeType,
    messageType: messageType,
    durationMs: durationMs,
    fileKey: fileKey,
    fileNonce: fileNonce,
    previewPath: path,
  );

  /// Encode as the JSON that goes into the PGP-encrypted message payload.
  Map<String, dynamic> toPayloadJson({
    String caption = '',
    bool viewOnce = false,
    bool hasSpoiler = false,
  }) => {
    'text': caption,
    'attachment_id': attachmentId,
    'file_name': fileName,
    'file_size': fileSize,
    'mime_type': mimeType,
    if (durationMs != null) 'duration_ms': durationMs,
    if (viewOnce) 'view_once': true,
    if (hasSpoiler) 'has_spoiler': true,
    'file_key': fileKey,
    'file_nonce': fileNonce,
  };
}

class EncryptedAttachmentUpload {
  final Uint8List ciphertext;
  final String fileName;
  final int fileSize;
  final int encryptedFileSize;
  final String mimeType;
  final MessageType messageType;
  final int? durationMs;
  final List<double>? waveform;
  final String fileKey;
  final String fileNonce;

  const EncryptedAttachmentUpload({
    required this.ciphertext,
    required this.fileName,
    required this.fileSize,
    required this.encryptedFileSize,
    required this.mimeType,
    required this.messageType,
    this.durationMs,
    this.waveform,
    required this.fileKey,
    required this.fileNonce,
  });

  Map<String, dynamic> toMetadataJson() => {
    'file_name': fileName,
    'file_size': fileSize,
    'encrypted_file_size': encryptedFileSize,
    'mime_type': mimeType,
    'message_type': messageType.name,
    if (durationMs != null) 'duration_ms': durationMs,
    if (waveform != null && waveform!.isNotEmpty) 'waveform': waveform,
    'file_key': fileKey,
    'file_nonce': fileNonce,
  };

  factory EncryptedAttachmentUpload.fromMetadataJson(
    Map<String, dynamic> json, {
    required Uint8List ciphertext,
  }) {
    return EncryptedAttachmentUpload(
      ciphertext: ciphertext,
      fileName: json['file_name'] as String? ?? 'attachment',
      fileSize: json['file_size'] as int? ?? 0,
      encryptedFileSize:
          json['encrypted_file_size'] as int? ?? ciphertext.length,
      mimeType: json['mime_type'] as String? ?? 'application/octet-stream',
      messageType: MessageType.values.firstWhere(
        (type) => type.name == json['message_type'],
        orElse: () => MessageType.file,
      ),
      durationMs: json['duration_ms'] as int?,
      waveform: (json['waveform'] as List?)
          ?.map((e) => (e as num).toDouble())
          .toList(),
      fileKey: json['file_key'] as String? ?? '',
      fileNonce: json['file_nonce'] as String? ?? '',
    );
  }

  Map<String, dynamic> toPayloadJson({
    required String attachmentId,
    String caption = '',
    bool viewOnce = false,
    bool hasSpoiler = false,
  }) => {
    'text': caption,
    'attachment_id': attachmentId,
    'file_name': fileName,
    'file_size': fileSize,
    'mime_type': mimeType,
    if (durationMs != null) 'duration_ms': durationMs,
    if (waveform != null && waveform!.isNotEmpty) 'waveform': waveform,
    if (viewOnce) 'view_once': true,
    if (hasSpoiler) 'has_spoiler': true,
    'file_key': fileKey,
    'file_nonce': fileNonce,
  };

  PendingAttachment toPendingAttachment(String attachmentId) {
    return PendingAttachment(
      attachmentId: attachmentId,
      fileName: fileName,
      fileSize: fileSize,
      mimeType: mimeType,
      messageType: messageType,
      durationMs: durationMs,
      fileKey: fileKey,
      fileNonce: fileNonce,
    );
  }
}

enum AttachmentUploadStage {
  preparing,
  encrypting,
  uploading,
  confirming,
  sending,
}

class AttachmentUploadProgress {
  final AttachmentUploadStage stage;
  final int sentBytes;
  final int totalBytes;

  const AttachmentUploadProgress({
    required this.stage,
    this.sentBytes = 0,
    this.totalBytes = 0,
  });

  double? get fraction {
    if (totalBytes <= 0) return null;
    return (sentBytes / totalBytes).clamp(0.0, 1.0).toDouble();
  }
}

typedef AttachmentUploadProgressCallback =
    void Function(AttachmentUploadProgress progress);

/// Bytes + metadata prepared for encryption/upload.
class PreparedAttachmentInput {
  final Uint8List bytes;
  final String fileName;
  final String mimeType;
  final MessageType messageType;
  final int originalFileSize;

  const PreparedAttachmentInput({
    required this.bytes,
    required this.fileName,
    required this.mimeType,
    required this.messageType,
    required this.originalFileSize,
  });
}

class _AttachmentCacheEntry {
  final Uint8List bytes;
  final int size;

  _AttachmentCacheEntry(this.bytes) : size = bytes.lengthInBytes;
}

class AttachmentService {
  final ApiService _api;
  final _cipher = AesGcm.with256bits();
  final _imagePicker = ImagePicker();
  static const String _serverOpaqueFileName = 'attachment.bin';
  static const String _serverOpaqueMimeType = 'application/octet-stream';

  // Decrypted attachment bytes are content-immutable per attachmentId, so cache
  // them process-wide to avoid re-downloading + re-decrypting on every rebuild
  // (e.g. image bubbles scrolling in and out of view). Static because the
  // service is constructed per use. Bounded LRU by bytes, and large entries are
  // intentionally not cached so videos/files do not pin process memory.
  static final Map<String, _AttachmentCacheEntry> _decryptedCache = {};
  static const int _maxDecryptedCacheBytes = 48 * 1024 * 1024; // 48 MB
  static const int _maxDecryptedCacheEntryBytes = 12 * 1024 * 1024; // 12 MB
  static int _decryptedCacheBytes = 0;
  static const Duration _downloadConnectTimeout = Duration(seconds: 12);
  static const Duration _downloadTimeout = Duration(minutes: 2);

  // Disk-backed store for attachment ciphertext received over the mesh (#26).
  // A mesh attachment may never be uploaded to the server (the sender stayed
  // offline), so its ciphertext must survive here for downloadAndDecrypt to
  // resolve it locally. Keyed by the (stable, client-chosen) attachment id.
  static const String _localAttachmentDirName = 'mesh_attachments';
  static const int _localStoreMaxBytes = 512 * 1024 * 1024; // 512 MB
  static const Duration _localStoreMaxAge = Duration(days: 7);

  AttachmentService(this._api);

  static Uint8List? _getCachedAttachment(String attachmentId) {
    final cached = _decryptedCache.remove(attachmentId);
    if (cached == null) return null;
    _decryptedCache[attachmentId] = cached; // move to most-recently-used
    return cached.bytes;
  }

  static void _putCachedAttachment(String attachmentId, Uint8List bytes) {
    if (attachmentId.isEmpty) return;
    final previous = _decryptedCache.remove(attachmentId);
    if (previous != null) _decryptedCacheBytes -= previous.size;
    if (bytes.lengthInBytes > _maxDecryptedCacheEntryBytes) {
      _pruneDecryptedCache();
      return;
    }
    final entry = _AttachmentCacheEntry(bytes);
    _decryptedCache[attachmentId] = entry;
    _decryptedCacheBytes += entry.size;
    _pruneDecryptedCache();
  }

  static void _pruneDecryptedCache() {
    while (_decryptedCacheBytes > _maxDecryptedCacheBytes &&
        _decryptedCache.isNotEmpty) {
      final oldestKey = _decryptedCache.keys.first;
      final oldest = _decryptedCache.remove(oldestKey);
      if (oldest != null) _decryptedCacheBytes -= oldest.size;
    }
    if (_decryptedCacheBytes < 0) _decryptedCacheBytes = 0;
  }

  Future<Directory> _localAttachmentDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, _localAttachmentDirName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Persist a mesh-received attachment ciphertext under its stable id (#26) so
  /// the bubble's [downloadAndDecrypt] can resolve it without the server.
  /// Best-effort: a failure just means a later server fetch.
  Future<void> saveLocalAttachment(
    String attachmentId,
    Uint8List ciphertext,
  ) async {
    if (attachmentId.isEmpty) return;
    try {
      final dir = await _localAttachmentDir();
      await File(
        p.join(dir.path, '$attachmentId.bin'),
      ).writeAsBytes(ciphertext, flush: true);
      await _pruneLocalStore(dir);
    } catch (_) {}
  }

  Future<Uint8List?> _lookupLocalCiphertext(String attachmentId) async {
    if (attachmentId.isEmpty) return null;
    try {
      final file = File(
        p.join((await _localAttachmentDir()).path, '$attachmentId.bin'),
      );
      if (await file.exists()) return await file.readAsBytes();
    } catch (_) {}
    return null;
  }

  // Keep the local mesh store bounded: drop anything past the age cap, then the
  // oldest files until under the size cap. Best-effort.
  Future<void> _pruneLocalStore(Directory dir) async {
    try {
      final files = <(File, FileStat)>[];
      await for (final e in dir.list()) {
        if (e is File) files.add((e, await e.stat()));
      }
      final now = DateTime.now();
      var total = files.fold<int>(0, (sum, e) => sum + e.$2.size);
      final survivors = <(File, FileStat)>[];
      for (final e in files) {
        if (now.difference(e.$2.modified) > _localStoreMaxAge) {
          total -= e.$2.size;
          try {
            await e.$1.delete();
          } catch (_) {}
        } else {
          survivors.add(e);
        }
      }
      survivors.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
      for (final e in survivors) {
        if (total <= _localStoreMaxBytes) break;
        total -= e.$2.size;
        try {
          await e.$1.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<Uint8List> _decryptAttachmentCiphertext(
    Uint8List ciphertext,
    String fileKeyB64,
  ) async {
    final secretKey = SecretKey(base64Decode(fileKeyB64));
    final secretBox = SecretBox.fromConcatenation(
      ciphertext,
      nonceLength: _cipher.nonceLength,
      macLength: _cipher.macAlgorithm.macLength,
    );
    final plaintext = await _cipher.decrypt(secretBox, secretKey: secretKey);
    return stripAttachmentPadding(Uint8List.fromList(plaintext));
  }

  // ---- Pickers ----

  // image_picker gallery/video is not implemented on desktop (Linux/macOS/Windows);
  // use file_selector there, which is already present for file + voice picks.
  static bool get _isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows);

  static const _imageTypeGroup = fs.XTypeGroup(
    label: 'Images',
    mimeTypes: [
      'image/jpeg',
      'image/png',
      'image/gif',
      'image/webp',
      'image/heic',
    ],
    extensions: ['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic'],
  );

  static const _videoTypeGroup = fs.XTypeGroup(
    label: 'Videos',
    mimeTypes: [
      'video/mp4',
      'video/quicktime',
      'video/x-matroska',
      'video/webm',
    ],
    extensions: ['mp4', 'mov', 'mkv', 'webm'],
  );

  Future<PendingAttachment?> pickImage({
    bool fromCamera = false,
    AttachmentUploadProgressCallback? onProgress,
  }) async {
    final File? imageFile;
    if (!fromCamera && _isDesktop) {
      final picked = await fs.openFile(acceptedTypeGroups: [_imageTypeGroup]);
      if (picked == null) return null;
      imageFile = File(picked.path);
    } else {
      final XFile? picked = await _imagePicker.pickImage(
        source: fromCamera ? ImageSource.camera : ImageSource.gallery,
        imageQuality: 85,
      );
      if (picked == null) return null;
      imageFile = File(picked.path);
    }
    onProgress?.call(
      const AttachmentUploadProgress(stage: AttachmentUploadStage.preparing),
    );
    final prepared = await prepareGalleryPhotoForUpload(imageFile);
    final pending = await _processPrepared(prepared, onProgress: onProgress);
    return pending.withPreview(imageFile.path);
  }

  Future<File?> pickEditableImage() async {
    if (_isDesktop) {
      final picked = await fs.openFile(acceptedTypeGroups: [_imageTypeGroup]);
      return picked == null ? null : File(picked.path);
    }
    final XFile? picked = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );
    return picked == null ? null : File(picked.path);
  }

  Future<EncryptedAttachmentUpload?> pickImageForOutbox({
    bool fromCamera = false,
    AttachmentUploadProgressCallback? onProgress,
  }) async {
    final File? imageFile;
    if (!fromCamera && _isDesktop) {
      final picked = await fs.openFile(acceptedTypeGroups: [_imageTypeGroup]);
      if (picked == null) return null;
      imageFile = File(picked.path);
    } else {
      final XFile? picked = await _imagePicker.pickImage(
        source: fromCamera ? ImageSource.camera : ImageSource.gallery,
        imageQuality: 85,
      );
      if (picked == null) return null;
      imageFile = File(picked.path);
    }
    onProgress?.call(
      const AttachmentUploadProgress(stage: AttachmentUploadStage.preparing),
    );
    final prepared = await prepareGalleryPhotoForUpload(imageFile);
    return encryptPreparedAttachment(prepared, onProgress: onProgress);
  }

  /// Picks several photos at once and returns one encrypted upload per image,
  /// for sending a multi-photo album.
  Future<List<EncryptedAttachmentUpload>> pickImagesForAlbum({
    AttachmentUploadProgressCallback? onProgress,
  }) async {
    final files = <File>[];
    if (_isDesktop) {
      final picked = await fs.openFiles(acceptedTypeGroups: [_imageTypeGroup]);
      files.addAll(picked.map((p) => File(p.path)));
    } else {
      final picked = await _imagePicker.pickMultiImage(imageQuality: 85);
      files.addAll(picked.map((x) => File(x.path)));
    }
    final out = <EncryptedAttachmentUpload>[];
    for (final file in files) {
      onProgress?.call(
        const AttachmentUploadProgress(stage: AttachmentUploadStage.preparing),
      );
      final prepared = await prepareGalleryPhotoForUpload(file);
      out.add(await encryptPreparedAttachment(prepared));
    }
    return out;
  }

  Future<PendingAttachment?> pickVideo({
    bool fromCamera = false,
    AttachmentUploadProgressCallback? onProgress,
  }) async {
    final File? videoFile;
    if (!fromCamera && _isDesktop) {
      final picked = await fs.openFile(acceptedTypeGroups: [_videoTypeGroup]);
      if (picked == null) return null;
      videoFile = File(picked.path);
    } else {
      final XFile? picked = await _imagePicker.pickVideo(
        source: fromCamera ? ImageSource.camera : ImageSource.gallery,
      );
      if (picked == null) return null;
      videoFile = File(picked.path);
    }
    onProgress?.call(
      const AttachmentUploadProgress(stage: AttachmentUploadStage.preparing),
    );
    final prepared = await prepareFileForUpload(videoFile);
    final pending = await _processPrepared(prepared, onProgress: onProgress);
    return pending.withPreview(videoFile.path);
  }

  Future<EncryptedAttachmentUpload?> pickVideoForOutbox({
    bool fromCamera = false,
    AttachmentUploadProgressCallback? onProgress,
  }) async {
    final File? videoFile;
    if (!fromCamera && _isDesktop) {
      final picked = await fs.openFile(acceptedTypeGroups: [_videoTypeGroup]);
      if (picked == null) return null;
      videoFile = File(picked.path);
    } else {
      final XFile? picked = await _imagePicker.pickVideo(
        source: fromCamera ? ImageSource.camera : ImageSource.gallery,
      );
      if (picked == null) return null;
      videoFile = File(picked.path);
    }
    onProgress?.call(
      const AttachmentUploadProgress(stage: AttachmentUploadStage.preparing),
    );
    final prepared = await prepareFileForUpload(videoFile);
    return encryptPreparedAttachment(prepared, onProgress: onProgress);
  }

  Future<PendingAttachment?> pickFile({
    AttachmentUploadProgressCallback? onProgress,
  }) async {
    final file = await fs.openFile();
    if (file == null) return null;
    onProgress?.call(
      const AttachmentUploadProgress(stage: AttachmentUploadStage.preparing),
    );
    final prepared = await prepareSelectedFileForUpload(file);
    return _processPrepared(prepared, onProgress: onProgress);
  }

  Future<EncryptedAttachmentUpload?> pickFileForOutbox({
    AttachmentUploadProgressCallback? onProgress,
  }) async {
    final file = await fs.openFile();
    if (file == null) return null;
    onProgress?.call(
      const AttachmentUploadProgress(stage: AttachmentUploadStage.preparing),
    );
    final prepared = await prepareSelectedFileForUpload(file);
    return encryptPreparedAttachment(prepared, onProgress: onProgress);
  }

  Future<PendingAttachment?> pickVoice({
    AttachmentUploadProgressCallback? onProgress,
  }) async {
    final file = await fs.openFile(
      acceptedTypeGroups: const [
        fs.XTypeGroup(
          label: 'Audio',
          mimeTypes: ['audio/*'],
          extensions: [
            'aac',
            'aiff',
            'flac',
            'm4a',
            'mp3',
            'oga',
            'ogg',
            'opus',
            'wav',
            'webm',
          ],
        ),
      ],
    );
    if (file == null) return null;
    onProgress?.call(
      const AttachmentUploadProgress(stage: AttachmentUploadStage.preparing),
    );
    final prepared = await prepareSelectedFileForUpload(file);
    return _processPrepared(
      PreparedAttachmentInput(
        bytes: prepared.bytes,
        fileName: prepared.fileName,
        mimeType: prepared.mimeType,
        messageType: MessageType.voice,
        originalFileSize: prepared.originalFileSize,
      ),
      onProgress: onProgress,
    );
  }

  Future<PendingAttachment> uploadVoiceNote(
    File file, {
    Duration? duration,
    AttachmentUploadProgressCallback? onProgress,
  }) async {
    onProgress?.call(
      const AttachmentUploadProgress(stage: AttachmentUploadStage.preparing),
    );
    final prepared = await prepareFileForUpload(file);
    return _processPrepared(
      PreparedAttachmentInput(
        bytes: prepared.bytes,
        fileName: prepared.fileName,
        mimeType: prepared.mimeType == 'application/octet-stream'
            ? 'audio/mp4'
            : prepared.mimeType,
        messageType: MessageType.voice,
        originalFileSize: prepared.originalFileSize,
      ),
      durationMs: duration?.inMilliseconds,
      onProgress: onProgress,
    );
  }

  Future<EncryptedAttachmentUpload> prepareVoiceNoteForOutbox(
    File file, {
    Duration? duration,
    List<double>? waveform,
    AttachmentUploadProgressCallback? onProgress,
  }) async {
    onProgress?.call(
      const AttachmentUploadProgress(stage: AttachmentUploadStage.preparing),
    );
    final prepared = await prepareFileForUpload(file);
    return encryptPreparedAttachment(
      PreparedAttachmentInput(
        bytes: prepared.bytes,
        fileName: prepared.fileName,
        mimeType: prepared.mimeType == 'application/octet-stream'
            ? 'audio/mp4'
            : prepared.mimeType,
        messageType: MessageType.voice,
        originalFileSize: prepared.originalFileSize,
      ),
      durationMs: duration?.inMilliseconds,
      waveform: waveform,
      onProgress: onProgress,
    );
  }

  // ---- Core: encrypt + upload ----

  static Future<PreparedAttachmentInput> prepareGalleryPhotoForUpload(
    File file, {
    Future<Uint8List?> Function(File file, Uint8List bytes)? webpEncoder,
  }) async {
    final originalBytes = await file.readAsBytes();
    // Animated GIFs must NOT be re-encoded to single-frame WebP — that freezes
    // them to the first frame. Preserve the original bytes (the File path
    // already does this), so the image bubble's Image.memory animates them.
    if (_isAnimatedGif(originalBytes)) {
      return PreparedAttachmentInput(
        bytes: originalBytes,
        fileName: '${p.basenameWithoutExtension(file.path)}.gif',
        mimeType: 'image/gif',
        messageType: MessageType.image,
        originalFileSize: originalBytes.length,
      );
    }
    final encoded = await (webpEncoder ?? _compressToWebp)(file, originalBytes);
    final webpBytes = _isWebP(encoded)
        ? encoded
        : _encodeWebpWithDartImage(originalBytes);
    if (!_isWebP(webpBytes)) {
      throw StateError(
        'Could not encode gallery photo as WebP. Try sending it as a file.',
      );
    }
    final fileName = _webpFileName(file.path);
    return PreparedAttachmentInput(
      bytes: webpBytes!,
      fileName: fileName,
      mimeType: 'image/webp',
      messageType: MessageType.image,
      originalFileSize: originalBytes.length,
    );
  }

  static Future<PreparedAttachmentInput> prepareSelectedFileForUpload(
    XFile file,
  ) async {
    final bytes = await file.readAsBytes();
    final fileName = file.name.isNotEmpty ? file.name : p.basename(file.path);
    final mimeType =
        file.mimeType ??
        lookupMimeType(fileName, headerBytes: bytes) ??
        lookupMimeType(file.path, headerBytes: bytes) ??
        'application/octet-stream';
    return PreparedAttachmentInput(
      bytes: bytes,
      fileName: fileName,
      mimeType: mimeType,
      messageType: _mimeToMessageTypeStatic(mimeType),
      originalFileSize: bytes.length,
    );
  }

  static Future<PreparedAttachmentInput> prepareFileForUpload(File file) async {
    final bytes = await file.readAsBytes();
    final fileName = p.basename(file.path);
    final mimeType =
        lookupMimeType(file.path, headerBytes: bytes) ??
        'application/octet-stream';
    return PreparedAttachmentInput(
      bytes: bytes,
      fileName: fileName,
      mimeType: mimeType,
      messageType: _mimeToMessageTypeStatic(mimeType),
      originalFileSize: bytes.length,
    );
  }

  Future<PendingAttachment> _processPrepared(
    PreparedAttachmentInput prepared, {
    int? durationMs,
    AttachmentUploadProgressCallback? onProgress,
  }) async {
    final encrypted = await encryptPreparedAttachment(
      prepared,
      durationMs: durationMs,
      onProgress: onProgress,
    );
    return uploadEncryptedAttachment(encrypted, onProgress: onProgress);
  }

  Future<EncryptedAttachmentUpload> encryptPreparedAttachment(
    PreparedAttachmentInput prepared, {
    int? durationMs,
    List<double>? waveform,
    AttachmentUploadProgressCallback? onProgress,
  }) async {
    final bytes = prepared.bytes;
    final fileName = prepared.fileName;
    final mimeType = prepared.mimeType;
    final msgType = prepared.messageType;

    // 1. Generate a random AES-256-GCM key + 12-byte nonce.
    onProgress?.call(
      const AttachmentUploadProgress(stage: AttachmentUploadStage.encrypting),
    );
    final secretKey = await _cipher.newSecretKey();
    final nonce = _cipher.newNonce();

    // 2. Encrypt the file bytes client-side — padded to a size bucket first,
    // so the ciphertext length the server (and any traffic observer) sees
    // does not reveal the exact file size.
    final secretBox = await _cipher.encrypt(
      padAttachmentPlaintext(bytes),
      secretKey: secretKey,
      nonce: nonce,
    );
    final ciphertext = Uint8List.fromList(secretBox.concatenation());

    // 3. Encode key + nonce as base64 to embed in the PGP payload.
    final keyBytes = await secretKey.extractBytes();
    final keyB64 = base64Encode(keyBytes);
    final nonceB64 = base64Encode(nonce);

    return EncryptedAttachmentUpload(
      ciphertext: ciphertext,
      fileName: fileName,
      fileSize: prepared.originalFileSize,
      encryptedFileSize: ciphertext.length,
      mimeType: mimeType,
      messageType: msgType,
      durationMs: durationMs,
      waveform: waveform,
      fileKey: keyB64,
      fileNonce: nonceB64,
    );
  }

  Future<PendingAttachment> uploadEncryptedAttachment(
    EncryptedAttachmentUpload encrypted, {
    AttachmentUploadProgressCallback? onProgress,
    // Pin the attachment id (#26) so a mesh-relayed copy and this upload share
    // one identity. Null ⇒ server-assigned (the normal online path).
    String? attachmentId,
  }) async {
    // 4. Request a presigned upload URL.
    final uploadReq = await _api.requestUpload(
      fileName: _serverOpaqueFileName,
      fileSize: encrypted.ciphertext.length,
      mimeType: _serverOpaqueMimeType,
      attachmentId: attachmentId,
    );

    // 5. Upload the ciphertext directly to object storage.
    onProgress?.call(
      AttachmentUploadProgress(
        stage: AttachmentUploadStage.uploading,
        totalBytes: encrypted.ciphertext.length,
      ),
    );
    await _api.uploadBytes(
      uploadReq.uploadUrl,
      encrypted.ciphertext,
      _serverOpaqueMimeType,
      onProgress: (sent, total) => onProgress?.call(
        AttachmentUploadProgress(
          stage: AttachmentUploadStage.uploading,
          sentBytes: sent,
          totalBytes: total,
        ),
      ),
    );

    // 6. Confirm the upload.
    onProgress?.call(
      AttachmentUploadProgress(
        stage: AttachmentUploadStage.confirming,
        sentBytes: encrypted.ciphertext.length,
        totalBytes: encrypted.ciphertext.length,
      ),
    );
    await _api.confirmUpload(uploadReq.attachmentId, uploadReq.uploadToken);

    return encrypted.toPendingAttachment(uploadReq.attachmentId);
  }

  static Future<Uint8List?> _compressToWebp(File file, Uint8List bytes) async {
    try {
      List<int>? out;
      if (kIsWeb) {
        out = await FlutterImageCompress.compressWithList(
          bytes,
          format: CompressFormat.webp,
          quality: 86,
          keepExif: false,
        );
      } else {
        out = await FlutterImageCompress.compressWithFile(
          file.absolute.path,
          format: CompressFormat.webp,
          quality: 86,
          keepExif: false,
        );
      }
      final webp = out == null ? null : Uint8List.fromList(out);
      if (_isWebP(webp)) return webp;
    } catch (_) {
      // Desktop platform compressors can lack WebP support. Fall through to
      // the pure-Dart pixel re-encode path so gallery photos still upload.
    }
    return _encodeWebpWithDartImage(bytes);
  }

  static Uint8List? _encodeWebpWithDartImage(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    final webp = img.encodeWebP(decoded);
    return _isWebP(webp) ? webp : null;
  }

  /// True for a GIF with more than one frame (i.e. an animation worth
  /// preserving). Checks the GIF magic first so non-GIFs never pay the decode.
  static bool _isAnimatedGif(Uint8List bytes) {
    if (bytes.length < 6) return false;
    // 'GIF87a' / 'GIF89a'
    if (bytes[0] != 0x47 || bytes[1] != 0x49 || bytes[2] != 0x46) return false;
    try {
      final decoded = img.decodeGif(bytes);
      return decoded != null && decoded.numFrames > 1;
    } catch (_) {
      return false;
    }
  }

  static bool _isWebP(Uint8List? bytes) {
    if (bytes == null || bytes.length < 12) return false;
    return bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50;
  }

  static String _webpFileName(String originalPath) {
    final stem = p.basenameWithoutExtension(originalPath);
    return '$stem.webp';
  }

  // ---- Download + decrypt ----

  /// Downloads and decrypts an attachment, returning the plaintext bytes.
  Future<Uint8List> downloadAndDecrypt({
    required String attachmentId,
    required String fileKeyB64,
    required String fileNonceB64,
  }) async {
    // Serve from the process-wide cache when we've already fetched this one.
    final cached = _getCachedAttachment(attachmentId);
    if (cached != null) return cached;

    // Mesh-delivered attachments (#26) live in a local ciphertext store and may
    // never have reached the server — try it before any network call.
    final localCiphertext = await _lookupLocalCiphertext(attachmentId);
    if (localCiphertext != null) {
      final bytes = await _decryptAttachmentCiphertext(
        localCiphertext,
        fileKeyB64,
      );
      _putCachedAttachment(attachmentId, bytes);
      return bytes;
    }

    final info = await _api.getDownloadUrl(attachmentId);

    // Download the encrypted bytes from the presigned URL.
    final ciphertext = await _downloadBytes(info.downloadUrl);

    // Decrypt with AES-256-GCM (nonce is embedded in the concatenated ciphertext).
    final bytes = await _decryptAttachmentCiphertext(ciphertext, fileKeyB64);

    _putCachedAttachment(attachmentId, bytes);
    return bytes;
  }

  // ── Size-bucket padding ─────────────────────────────────────────────────────
  // AES-GCM preserves plaintext length exactly, so without padding the stored
  // ciphertext leaks the file's size to the byte — enough to fingerprint known
  // files. Plaintext is framed as: 8-byte magic, uint64-LE true length, file
  // bytes, zeros up to a padmé-style bucket (block = 2^(bitlen-3), ≥4KB) for a
  // bounded ~12.5% max overhead. Pre-padding attachments lack the magic and
  // pass through untouched.
  static const _padMagic = <int>[
    0x4F,
    0x43,
    0x50,
    0x41,
    0x44,
    0x31,
    0x00,
    0x00,
  ];
  static const _padHeaderLength = 16; // magic + uint64 length
  static const _padMinBlock = 4096;

  @visibleForTesting
  static int paddedAttachmentSize(int framedLength) {
    var block = _padMinBlock;
    // Block = 2^(bitLength-4): at most a sixteenth of the value, so one
    // wasted block is ≤ ~12.5% overhead even just past a power of two, while
    // nearby sizes still collapse into shared buckets.
    final dynamicBlock = 1 << (framedLength.bitLength - 4);
    if (dynamicBlock > block) block = dynamicBlock;
    return ((framedLength + block - 1) ~/ block) * block;
  }

  @visibleForTesting
  static Uint8List padAttachmentPlaintext(List<int> bytes) {
    final framedLength = _padHeaderLength + bytes.length;
    final padded = Uint8List(paddedAttachmentSize(framedLength));
    padded.setRange(0, _padMagic.length, _padMagic);
    ByteData.sublistView(
      padded,
      _padMagic.length,
      _padHeaderLength,
    ).setUint64(0, bytes.length, Endian.little);
    padded.setRange(_padHeaderLength, _padHeaderLength + bytes.length, bytes);
    return padded;
  }

  @visibleForTesting
  static Uint8List stripAttachmentPadding(Uint8List bytes) {
    if (bytes.length < _padHeaderLength) return bytes;
    for (var i = 0; i < _padMagic.length; i++) {
      if (bytes[i] != _padMagic[i]) return bytes; // legacy unpadded attachment
    }
    final trueLength = ByteData.sublistView(
      bytes,
      _padMagic.length,
      _padHeaderLength,
    ).getUint64(0, Endian.little);
    // Compare against the available payload directly — computing
    // header+length first could overflow on a corrupt huge value.
    if (trueLength < 0 || trueLength > bytes.length - _padHeaderLength) {
      return bytes;
    }
    return Uint8List.fromList(
      bytes.sublist(_padHeaderLength, _padHeaderLength + trueLength),
    );
  }

  Future<Uint8List> downloadRaw({required String attachmentId}) async {
    final cached = _getCachedAttachment(attachmentId);
    if (cached != null) return cached;

    // Mesh-delivered ciphertext (#26), local-first like downloadAndDecrypt.
    final localCiphertext = await _lookupLocalCiphertext(attachmentId);
    if (localCiphertext != null) {
      _putCachedAttachment(attachmentId, localCiphertext);
      return localCiphertext;
    }

    final info = await _api.getDownloadUrl(attachmentId);
    final bytes = await _downloadBytes(info.downloadUrl);

    _putCachedAttachment(attachmentId, bytes);
    return bytes;
  }

  @visibleForTesting
  Future<Uint8List> debugDownloadBytes(String url) => _downloadBytes(url);

  Future<Uint8List> _downloadBytes(String url) async {
    final httpClient = HttpClient()
      ..connectionTimeout = _downloadConnectTimeout;
    try {
      final request = await httpClient
          .getUrl(Uri.parse(url))
          .timeout(_downloadConnectTimeout);
      final response = await request.close().timeout(_downloadTimeout);
      // Must await here: without it the finally force-closes the client while
      // the response body is still streaming, aborting every download.
      return await _readResponse(response).timeout(_downloadTimeout);
    } finally {
      httpClient.close(force: true);
    }
  }

  Future<Uint8List> _readResponse(HttpClientResponse resp) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in resp.timeout(_downloadTimeout)) {
      builder.add(chunk);
    }
    return builder.toBytes();
  }

  static MessageType _mimeToMessageTypeStatic(String mime) {
    if (mime.startsWith('image/')) return MessageType.image;
    if (mime.startsWith('video/')) return MessageType.video;
    return MessageType.file;
  }
}
