package com.openchat.openchat

import android.content.Intent
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity (not FlutterActivity) is required by local_auth:
// BiometricPrompt needs a FragmentActivity host, otherwise authenticate() fails
// with "no_fragment_activity" and biometric unlock can't be enabled.
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "openchat/call_foreground",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val title = call.argument<String>("title") ?: "OpenChat call"
                    val body = call.argument<String>("body") ?: "Call in progress"
                    val isVideo = call.argument<Boolean>("isVideo") ?: false
                    val intent = Intent(this, CallForegroundService::class.java).apply {
                        action = CallForegroundService.ACTION_START
                        putExtra(CallForegroundService.EXTRA_TITLE, title)
                        putExtra(CallForegroundService.EXTRA_BODY, body)
                        putExtra(CallForegroundService.EXTRA_IS_VIDEO, isVideo)
                    }
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }
                "stop" -> {
                    val intent = Intent(this, CallForegroundService::class.java).apply {
                        action = CallForegroundService.ACTION_STOP
                    }
                    stopService(intent)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
