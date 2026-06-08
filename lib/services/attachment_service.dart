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

  const PendingAttachment({
    required this.attachmentId,
    required this.fileName,
    required this.fileSize,
    required this.mimeType,
    required this.messageType,
    this.durationMs,
    required this.fileKey,
    required this.fileNonce,
  });

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

class AttachmentService {
  final ApiService _api;
  final _cipher = AesGcm.with256bits();
  final _imagePicker = ImagePicker();
  static const String _serverOpaqueFileName = 'attachment.bin';
  static const String _serverOpaqueMimeType = 'application/octet-stream';

  // Decrypted attachment bytes are content-immutable per attachmentId, so cache
  // them process-wide to avoid re-downloading + re-decrypting on every rebuild
  // (e.g. image bubbles scrolling in and out of view). Static because the
  // service is constructed per use. Bounded LRU by entry count.
  static final Map<String, Uint8List> _decryptedCache = {};
  static const int _maxCacheEntries = 60;

  AttachmentService(this._api);

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
    return _processPrepared(prepared, onProgress: onProgress);
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
    return _processPrepared(prepared, onProgress: onProgress);
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

    // 2. Encrypt the file bytes client-side.
    final secretBox = await _cipher.encrypt(
      bytes,
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
  }) async {
    // 4. Request a presigned upload URL.
    final uploadReq = await _api.requestUpload(
      fileName: _serverOpaqueFileName,
      fileSize: encrypted.ciphertext.length,
      mimeType: _serverOpaqueMimeType,
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
    final cached = _decryptedCache[attachmentId];
    if (cached != null) {
      _decryptedCache.remove(attachmentId); // move to most-recently-used
      _decryptedCache[attachmentId] = cached;
      return cached;
    }

    final info = await _api.getDownloadUrl(attachmentId);

    // Download the encrypted bytes from the presigned URL.
    final httpClient = HttpClient();
    final request = await httpClient.getUrl(Uri.parse(info.downloadUrl));
    final response = await request.close();
    final ciphertext = await _readResponse(response);

    // Decrypt with AES-256-GCM (nonce is embedded in the concatenated ciphertext).
    final keyBytes = base64Decode(fileKeyB64);
    final secretKey = SecretKey(keyBytes);
    final secretBox = SecretBox.fromConcatenation(
      ciphertext,
      nonceLength: _cipher.nonceLength,
      macLength: _cipher.macAlgorithm.macLength,
    );
    final plaintext = await _cipher.decrypt(secretBox, secretKey: secretKey);
    final bytes = Uint8List.fromList(plaintext);

    _decryptedCache[attachmentId] = bytes;
    if (_decryptedCache.length > _maxCacheEntries) {
      _decryptedCache.remove(_decryptedCache.keys.first); // evict oldest
    }
    return bytes;
  }

  Future<Uint8List> downloadRaw({required String attachmentId}) async {
    final cached = _decryptedCache[attachmentId];
    if (cached != null) {
      _decryptedCache.remove(attachmentId);
      _decryptedCache[attachmentId] = cached;
      return cached;
    }

    final info = await _api.getDownloadUrl(attachmentId);
    final httpClient = HttpClient();
    final request = await httpClient.getUrl(Uri.parse(info.downloadUrl));
    final response = await request.close();
    final bytes = await _readResponse(response);

    _decryptedCache[attachmentId] = bytes;
    if (_decryptedCache.length > _maxCacheEntries) {
      _decryptedCache.remove(_decryptedCache.keys.first);
    }
    return bytes;
  }

  Future<Uint8List> _readResponse(HttpClientResponse resp) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in resp) {
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
