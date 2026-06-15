import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image_cropper/image_cropper.dart';

class ImageEditService {
  const ImageEditService._();

  static bool get isSupported =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  /// Opens the platform crop/rotate UI for a chat photo. Returns null when the
  /// editor is unavailable or dismissed so callers can fall back to the source.
  static Future<File?> editImage(File source) async {
    if (!isSupported) return null;
    final cropped = await ImageCropper().cropImage(
      sourcePath: source.path,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Edit photo',
          lockAspectRatio: false,
          hideBottomControls: false,
        ),
        IOSUiSettings(
          title: 'Edit photo',
          aspectRatioLockEnabled: false,
          rotateButtonsHidden: false,
        ),
      ],
    );
    if (cropped == null) return null;
    return File(cropped.path);
  }
}
