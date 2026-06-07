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

/**
 * Foreground service of type `mediaProjection`.
 *
 * Android 14+ throws
 *   SecurityException: Media projections require a foreground service of type
 *   ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
 * (and kills the app) if MediaProjection.start() runs without such a service
 * already in the foreground. flutter_webrtc 1.4.1 does not manage this service,
 * so the app starts it (via the openchat/call_controls method channel) right
 * after obtaining the screen-capture consent token and before getDisplayMedia().
 */
class MediaProjectionService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }

        ensureChannel()
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            )
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
            "Screen sharing",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Active while OpenChat is sharing your screen"
            setSound(null, null)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("Sharing your screen")
            .setContentText("OpenChat is sharing your screen in a call")
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOnlyAlertOnce(true)
            .build()

    companion object {
        const val ACTION_START = "com.openchat.openchat.screenshare.START"
        const val ACTION_STOP = "com.openchat.openchat.screenshare.STOP"
        private const val CHANNEL_ID = "screen_share"
        private const val NOTIFICATION_ID = 3
    }
}
