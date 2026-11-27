package com.jarvis.jarvis

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * Microphone foreground service. It does not record anything itself — it gives the process the
 * "while-in-use" microphone access Android requires for background listening and shows the
 * mandatory, always-visible notification with Stop / Turn off actions.
 */
class JarvisListenerService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP_ALL -> {
                DeviceChannel.emit(mapOf("type" to "notificationStop"))
                return START_NOT_STICKY
            }
            ACTION_DISABLE -> {
                DeviceChannel.emit(mapOf("type" to "notificationDisable"))
                return START_NOT_STICKY
            }
            ACTION_UPDATE -> {
                status = intent.getStringExtra(EXTRA_TEXT) ?: status
                if (running) notify(this)
                return START_NOT_STICKY
            }
        }
        createChannel(this)
        try {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                build(this),
                if (Build.VERSION.SDK_INT >= 30) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0,
            )
            running = true
        } catch (e: Exception) {
            // Thrown if started from the background or without RECORD_AUDIO.
            running = false
            lastError = e.message
            stopSelf()
        }
        // Not sticky: Android forbids restarting a microphone service from the background.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        DeviceChannel.emit(mapOf("type" to "serviceStopped"))
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "jarvis_listening"
        private const val NOTIFICATION_ID = 7001
        const val ACTION_STOP_ALL = "com.jarvis.STOP_ALL"
        const val ACTION_DISABLE = "com.jarvis.DISABLE"
        const val ACTION_UPDATE = "com.jarvis.UPDATE"
        const val EXTRA_TEXT = "text"

        @Volatile var running = false
        @Volatile var lastError: String? = null
        @Volatile var status: String = "Listening for \"Leo\" (on-device)"

        fun createChannel(ctx: Context) {
            if (Build.VERSION.SDK_INT >= 26) {
                val nm = ctx.getSystemService(NotificationManager::class.java)
                if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                    nm.createNotificationChannel(
                        NotificationChannel(CHANNEL_ID, "LEO listening", NotificationManager.IMPORTANCE_LOW).apply {
                            description = "Shown while LEO can hear the wake word"
                            setShowBadge(false)
                        }
                    )
                }
            }
        }

        private fun pending(ctx: Context, action: String, req: Int): PendingIntent =
            PendingIntent.getService(
                ctx, req,
                Intent(ctx, JarvisListenerService::class.java).setAction(action),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )

        fun build(ctx: Context): Notification {
            val open = PendingIntent.getActivity(
                ctx, 0,
                Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            return NotificationCompat.Builder(ctx, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_jarvis)
                .setContentTitle("LEO is listening")
                .setContentText(status)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setContentIntent(open)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .addAction(0, "STOP", pending(ctx, ACTION_STOP_ALL, 1))
                .addAction(0, "Turn off listening", pending(ctx, ACTION_DISABLE, 2))
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
                .build()
        }

        fun notify(ctx: Context) {
            ctx.getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, build(ctx))
        }
    }
}
