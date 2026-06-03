import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
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
  Map<String, dynamic> toPayloadJson({String caption = ''}) => {
    'text': caption,
    'attachment_id': attachmentId,
    'file_name': fileName,
    'file_size': fileSize,
    'mime_type': mimeType,
    if (durationMs != null) 'duration_ms': durationMs,
    'file_key': fileKey,
    'file_nonce': fileNonce,
  };
}

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

  // Decrypted attachment bytes are content-immutable per attachmentId, so cache
  // them process-wide to avoid re-downloading + re-decrypting on every rebuild
  // (e.g. image bubbles scrolling in and out of view). Static because the
  // service is constructed per use. Bounded LRU by entry count.
  static final Map<String, Uint8List> _decryptedCache = {};
  static const int _maxCacheEntries = 60;

  AttachmentService(this._api);

  // ---- Pickers ----

  Future<PendingAttachment?> pickImage({bool fromCamera = false}) async {
    final XFile? file = fromCamera
        ? await _imagePicker.pickImage(
            source: ImageSource.camera,
            imageQuality: 85,
          )
        : await _imagePicker.pickImage(
            source: ImageSource.gallery,
            imageQuality: 85,
          );
    if (file == null) return null;
    final prepared = await prepareGalleryPhotoForUpload(File(file.path));
    return _processPrepared(prepared);
  }

  Future<PendingAttachment?> pickVideo({bool fromCamera = false}) async {
    final XFile? file = fromCamera
        ? await _imagePicker.pickVideo(source: ImageSource.camera)
        : await _imagePicker.pickVideo(source: ImageSource.gallery);
    if (file == null) return null;
    final prepared = await prepareFileForUpload(File(file.path));
    return _processPrepared(prepared);
  }

  Future<PendingAttachment?> pickFile() async {
    final file = await fs.openFile();
    if (file == null) return null;
    final prepared = await prepareSelectedFileForUpload(file);
    return _processPrepared(prepared);
  }

  Future<PendingAttachment?> pickVoice() async {
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
    final prepared = await prepareSelectedFileForUpload(file);
    return _processPrepared(
      PreparedAttachmentInput(
        bytes: prepared.bytes,
        fileName: prepared.fileName,
        mimeType: prepared.mimeType,
        messageType: MessageType.voice,
        originalFileSize: prepared.originalFileSize,
      ),
    );
  }

  Future<PendingAttachment> uploadVoiceNote(
    File file, {
    Duration? duration,
  }) async {
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
    );
  }

  // ---- Core: encrypt + upload ----

  static Future<PreparedAttachmentInput> prepareGalleryPhotoForUpload(
    File file, {
    Future<Uint8List?> Function(File file, Uint8List bytes)? webpEncoder,
  }) async {
    final originalBytes = await file.readAsBytes();
    final compressed = await (webpEncoder ?? _compressToWebp)(
      file,
      originalBytes,
    );
    if (compressed == null) {
      throw StateError('Could not encode gallery photo as WebP');
    }
    final fileName = _webpFileName(file.path);
    return PreparedAttachmentInput(
      bytes: compressed,
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
  }) async {
    final bytes = prepared.bytes;
    final fileName = prepared.fileName;
    final mimeType = prepared.mimeType;
    final msgType = prepared.messageType;

    // 1. Generate a random AES-256-GCM key + 12-byte nonce.
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

    // 4. Request a presigned upload URL.
    final uploadReq = await _api.requestUpload(
      fileName: fileName,
      fileSize: ciphertext.length,
      mimeType: mimeType,
    );

    // 5. Upload the ciphertext directly to object storage.
    await _api.uploadBytes(uploadReq.uploadUrl, ciphertext, mimeType);

    // 6. Confirm the upload.
    await _api.confirmUpload(uploadReq.attachmentId);

    return PendingAttachment(
      attachmentId: uploadReq.attachmentId,
      fileName: fileName,
      fileSize:
          prepared.originalFileSize, // original unencrypted size for display
      mimeType: mimeType,
      messageType: msgType,
      durationMs: durationMs,
      fileKey: keyB64,
      fileNonce: nonceB64,
    );
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
      if (out == null) return null;
      return Uint8List.fromList(out);
    } catch (_) {
      return null;
    }
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
