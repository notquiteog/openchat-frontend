package com.openchat.openchat

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

class CallForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }

        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "OpenChat call"
        val body = intent?.getStringExtra(EXTRA_BODY) ?: "Call in progress"
        val isVideo = intent?.getBooleanExtra(EXTRA_IS_VIDEO, false) ?: false
        val muted = intent?.getBooleanExtra(EXTRA_MUTED, false) ?: false
        ensureChannel()

        val notification = buildNotification(title, body, muted)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            var foregroundType = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            if (isVideo) {
                foregroundType = foregroundType or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            }
            startForeground(NOTIFICATION_ID, notification, foregroundType)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        return START_STICKY
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Active calls",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Keeps OpenChat calls active while the app is in the background"
            setSound(null, null)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(title: String, body: String, muted: Boolean): Notification =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(mainActivityIntent(ACTION_OPEN, REQUEST_OPEN))
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOnlyAlertOnce(true)
            .setUsesChronometer(true)
            .addAction(
                android.R.drawable.ic_btn_speak_now,
                if (muted) "Unmute" else "Mute",
                mainActivityIntent(ACTION_TOGGLE_MUTE, REQUEST_TOGGLE_MUTE),
            )
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "End",
                mainActivityIntent(ACTION_END, REQUEST_END),
            )
            .build()

    private fun mainActivityIntent(actionName: String, requestCode: Int): PendingIntent {
        val immutableFlag =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or immutableFlag
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            action = actionName
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        return PendingIntent.getActivity(this, requestCode, launchIntent, flags)
    }

    companion object {
        const val ACTION_START = "com.openchat.openchat.call.START"
        const val ACTION_STOP = "com.openchat.openchat.call.STOP"
        const val ACTION_OPEN = "com.openchat.openchat.call.OPEN"
        const val ACTION_TOGGLE_MUTE = "com.openchat.openchat.call.TOGGLE_MUTE"
        const val ACTION_END = "com.openchat.openchat.call.END"
        const val EXTRA_TITLE = "title"
        const val EXTRA_BODY = "body"
        const val EXTRA_IS_VIDEO = "isVideo"
        const val EXTRA_MUTED = "muted"
        private const val CHANNEL_ID = "active_calls"
        private const val NOTIFICATION_ID = 2
        private const val REQUEST_OPEN = 20
        private const val REQUEST_TOGGLE_MUTE = 21
        private const val REQUEST_END = 22
    }
}
