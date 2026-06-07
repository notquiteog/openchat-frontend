package com.openchat.openchat

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import androidx.core.content.ContextCompat
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
    private var selectedCallAudioRoute: String? = null

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
                    val connectedAtMillis = call.argument<Long>("connectedAtMillis")
                    val intent = Intent(this, CallForegroundService::class.java).apply {
                        action = CallForegroundService.ACTION_START
                        putExtra(CallForegroundService.EXTRA_TITLE, title)
                        putExtra(CallForegroundService.EXTRA_BODY, body)
                        putExtra(CallForegroundService.EXTRA_IS_VIDEO, isVideo)
                        putExtra(CallForegroundService.EXTRA_MUTED, muted)
                        if (connectedAtMillis != null) {
                            putExtra(CallForegroundService.EXTRA_CONNECTED_AT_MILLIS, connectedAtMillis)
                        }
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
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "openchat/call_controls",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "selectAudioOutput" -> {
                    val deviceId = call.argument<String>("deviceId") ?: ""
                    result.success(selectAudioOutput(deviceId))
                }
                "setMicrophoneMuted" -> {
                    val muted = call.argument<Boolean>("muted") ?: false
                    result.success(setMicrophoneMuted(muted))
                }
                "clearAudioOutput" -> {
                    clearAudioOutput()
                    result.success(null)
                }
                "startMediaProjection" -> {
                    // Android 14+ requires a running mediaProjection foreground
                    // service before getDisplayMedia() / MediaProjection.start().
                    val intent = Intent(this, MediaProjectionService::class.java).apply {
                        action = MediaProjectionService.ACTION_START
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
                "stopMediaProjection" -> {
                    val intent = Intent(this, MediaProjectionService::class.java).apply {
                        action = MediaProjectionService.ACTION_STOP
                    }
                    stopService(intent)
                    result.success(null)
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

    private fun audioManager(): AudioManager =
        getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private fun selectAudioOutput(deviceId: String): Boolean {
        if (deviceId.isBlank()) return false
        val manager = audioManager()
        selectedCallAudioRoute = deviceId
        manager.mode = AudioManager.MODE_IN_COMMUNICATION

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val desiredTypes = when (deviceId) {
                "speaker" -> intArrayOf(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER)
                "earpiece" -> intArrayOf(AudioDeviceInfo.TYPE_BUILTIN_EARPIECE)
                "bluetooth" -> intArrayOf(
                    AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                    AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
                    AudioDeviceInfo.TYPE_BLE_HEADSET,
                    AudioDeviceInfo.TYPE_BLE_SPEAKER,
                )
                "wired-headset" -> intArrayOf(
                    AudioDeviceInfo.TYPE_WIRED_HEADSET,
                    AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                    AudioDeviceInfo.TYPE_USB_HEADSET,
                )
                else -> intArrayOf()
            }
            for (type in desiredTypes) {
                val device = manager.availableCommunicationDevices.firstOrNull {
                    it.type == type
                }
                if (device != null && manager.setCommunicationDevice(device)) {
                    manager.isSpeakerphoneOn = deviceId == "speaker"
                    return true
                }
            }
        }

        @Suppress("DEPRECATION")
        return when (deviceId) {
            "speaker" -> {
                manager.stopBluetoothSco()
                manager.isBluetoothScoOn = false
                manager.isSpeakerphoneOn = true
                true
            }
            "earpiece" -> {
                manager.stopBluetoothSco()
                manager.isBluetoothScoOn = false
                manager.isSpeakerphoneOn = false
                true
            }
            "bluetooth" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                    ContextCompat.checkSelfPermission(
                        this,
                        Manifest.permission.BLUETOOTH_CONNECT,
                    ) != PackageManager.PERMISSION_GRANTED
                ) {
                    return false
                }
                manager.isSpeakerphoneOn = false
                manager.startBluetoothSco()
                manager.isBluetoothScoOn = true
                true
            }
            "wired-headset" -> {
                manager.stopBluetoothSco()
                manager.isBluetoothScoOn = false
                manager.isSpeakerphoneOn = false
                true
            }
            else -> false
        }
    }

    private fun setMicrophoneMuted(muted: Boolean): Boolean {
        val manager = audioManager()
        manager.mode = AudioManager.MODE_IN_COMMUNICATION
        manager.isMicrophoneMute = muted
        return true
    }

    private fun clearAudioOutput() {
        val manager = audioManager()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            manager.clearCommunicationDevice()
        }
        @Suppress("DEPRECATION")
        manager.stopBluetoothSco()
        @Suppress("DEPRECATION")
        manager.isBluetoothScoOn = false
        manager.isSpeakerphoneOn = false
        manager.mode = AudioManager.MODE_NORMAL
        selectedCallAudioRoute = null
    }
}
