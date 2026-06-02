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
    private var callForegroundChannel: MethodChannel? = null
    private var callForegroundActionsReady = false
    private val pendingCallForegroundActions = mutableListOf<String>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "openchat/call_foreground",
        )
        callForegroundChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val title = call.argument<String>("title") ?: "OpenChat call"
                    val body = call.argument<String>("body") ?: "Call in progress"
                    val isVideo = call.argument<Boolean>("isVideo") ?: false
                    val muted = call.argument<Boolean>("muted") ?: false
                    val intent = Intent(this, CallForegroundService::class.java).apply {
                        action = CallForegroundService.ACTION_START
                        putExtra(CallForegroundService.EXTRA_TITLE, title)
                        putExtra(CallForegroundService.EXTRA_BODY, body)
                        putExtra(CallForegroundService.EXTRA_IS_VIDEO, isVideo)
                        putExtra(CallForegroundService.EXTRA_MUTED, muted)
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
                "takePendingActions" -> {
                    callForegroundActionsReady = true
                    val pending = pendingCallForegroundActions.toList()
                    pendingCallForegroundActions.clear()
                    result.success(pending)
                }
                else -> result.notImplemented()
            }
        }
        dispatchCallForegroundIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        dispatchCallForegroundIntent(intent)
    }

    private fun dispatchCallForegroundIntent(intent: Intent?) {
        val action = when (intent?.action) {
            CallForegroundService.ACTION_TOGGLE_MUTE -> "toggleMute"
            CallForegroundService.ACTION_END -> "end"
            else -> null
        } ?: return

        if (callForegroundActionsReady) {
            callForegroundChannel?.invokeMethod("action", mapOf("action" to action))
        } else {
            pendingCallForegroundActions.add(action)
        }
    }
}
