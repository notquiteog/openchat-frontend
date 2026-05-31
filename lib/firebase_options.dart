// AUTO-GENERATED TEMPLATE — overwrite this file with the output of:
//
//   dart pub global activate flutterfire_cli
//   flutterfire configure
//
// To enable push notifications:
//   1. Create a Firebase project at https://console.firebase.google.com/
//   2. Add Android (package: com.openchat.openchat) and iOS (bundle ID: com.openchat.openchat) apps
//   3. Run `flutterfire configure` — it will overwrite this file and the platform config files
//   4. Replace android/app/google-services.json and ios/Runner/GoogleService-Info.plist with real downloads
//   5. On the server, set FIREBASE_SERVICE_ACCOUNT_JSON so the backend can send FCM messages
//
// With the placeholder values below the app compiles and runs normally;
// enabling Push Notifications in Settings will fail gracefully with
// "Firebase is not configured" until real credentials are provided.

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError('Web is not supported by this app.');
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for '
          '${defaultTargetPlatform.name} — run flutterfire configure.',
        );
    }
  }

  // Replace ALL values below with the real output from flutterfire configure.
  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'REPLACE_WITH_YOUR_ANDROID_API_KEY',
    appId: '1:000000000000:android:0000000000000000000000',
    messagingSenderId: '000000000000',
    projectId: 'your-firebase-project-id',
    storageBucket: 'your-firebase-project-id.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'REPLACE_WITH_YOUR_IOS_API_KEY',
    appId: '1:000000000000:ios:0000000000000000000000',
    messagingSenderId: '000000000000',
    projectId: 'your-firebase-project-id',
    storageBucket: 'your-firebase-project-id.firebasestorage.app',
    iosBundleId: 'com.openchat.openchat',
  );
}
