package com.openchat.openchat

import io.flutter.embedding.android.FlutterFragmentActivity

// FlutterFragmentActivity (not FlutterActivity) is required by local_auth:
// BiometricPrompt needs a FragmentActivity host, otherwise authenticate() fails
// with "no_fragment_activity" and biometric unlock can't be enabled.
class MainActivity : FlutterFragmentActivity()
