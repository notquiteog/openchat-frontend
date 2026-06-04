import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

class DefaultFirebaseOptions {
  static const FirebaseOptions _placeholder = FirebaseOptions(
    apiKey: 'REPLACE_WITH_API_KEY',
    appId: '1:000000000000:android:0000000000000000000000',
    messagingSenderId: '000000000000',
    projectId: 'your-firebase-project-id',
  );

  static const String _apiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const String _androidAppId = String.fromEnvironment(
    'FIREBASE_ANDROID_APP_ID',
  );
  static const String _iosAppId = String.fromEnvironment('FIREBASE_IOS_APP_ID');
  static const String _messagingSenderId = String.fromEnvironment(
    'FIREBASE_MESSAGING_SENDER_ID',
  );
  static const String _projectId = String.fromEnvironment(
    'FIREBASE_PROJECT_ID',
  );
  static const String _storageBucket = String.fromEnvironment(
    'FIREBASE_STORAGE_BUCKET',
  );
  static const String _iosBundleId = String.fromEnvironment(
    'FIREBASE_IOS_BUNDLE_ID',
    defaultValue: 'com.openchat.openchat',
  );

  static bool get hasDartDefines =>
      _apiKey.isNotEmpty &&
      _messagingSenderId.isNotEmpty &&
      _projectId.isNotEmpty &&
      (_androidAppId.isNotEmpty || _iosAppId.isNotEmpty);

  static bool get currentPlatformConfigured {
    final options = currentPlatform;
    return options.projectId != _placeholder.projectId &&
        !options.apiKey.startsWith('REPLACE_WITH');
  }

  static FirebaseOptions get currentPlatform {
    if (kIsWeb) return _placeholder;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        if (hasDartDefines && _androidAppId.isNotEmpty) {
          return FirebaseOptions(
            apiKey: _apiKey,
            appId: _androidAppId,
            messagingSenderId: _messagingSenderId,
            projectId: _projectId,
            storageBucket: _storageBucket.isEmpty ? null : _storageBucket,
          );
        }
        return _placeholder;
      case TargetPlatform.iOS:
        if (hasDartDefines && _iosAppId.isNotEmpty) {
          return FirebaseOptions(
            apiKey: _apiKey,
            appId: _iosAppId,
            messagingSenderId: _messagingSenderId,
            projectId: _projectId,
            storageBucket: _storageBucket.isEmpty ? null : _storageBucket,
            iosBundleId: _iosBundleId,
          );
        }
        return _placeholder;
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        return _placeholder;
    }
  }
}
