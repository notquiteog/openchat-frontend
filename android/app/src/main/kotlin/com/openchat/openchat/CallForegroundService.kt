package com.openchat.openchat

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
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
        ensureChannel()

        val notification = buildNotification(title, body)
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

    private fun buildNotification(title: String, body: String): Notification =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOnlyAlertOnce(true)
            .build()

    companion object {
        const val ACTION_START = "com.openchat.openchat.call.START"
        const val ACTION_STOP = "com.openchat.openchat.call.STOP"
        const val EXTRA_TITLE = "title"
        const val EXTRA_BODY = "body"
        const val EXTRA_IS_VIDEO = "isVideo"
        private const val CHANNEL_ID = "active_calls"
        private const val NOTIFICATION_ID = 2
    }
}
