package dev.vault.vault

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager

/** A user-started eligibility aid, not a headless engine or reachability guarantee. */
class PublishingService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null
    private val budgetExpired = Runnable { finish("dataSyncBudgetExpired") }

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> finish("notificationStop")
            ACTION_START -> {
                // A restored or stale intent must never restart publication.
                if (!starting) {
                    if (!running) finish("staleStartRejected")
                    return START_NOT_STICKY
                }
                try {
                    val manager = requireNotNull(getSystemService(NotificationManager::class.java)) {
                        "Android notification service is unavailable."
                    }
                    check(manager.areNotificationsEnabled()) { "Enable Midnight notifications before publishing." }
                    if (Build.VERSION.SDK_INT >= 26) {
                        manager.createNotificationChannel(NotificationChannel(
                            CHANNEL_ID, "Publishing availability", NotificationManager.IMPORTANCE_LOW
                        ))
                        val channel = manager.getNotificationChannel(CHANNEL_ID)
                        check(channel != null && channel.importance != NotificationManager.IMPORTANCE_NONE) {
                            "Enable the Publishing availability notification channel before publishing."
                        }
                    }
                    if (Build.VERSION.SDK_INT >= 29) {
                        startForeground(NOTIFICATION_ID, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
                    } else {
                        startForeground(NOTIFICATION_ID, notification())
                    }
                    val power = requireNotNull(getSystemService(PowerManager::class.java)) {
                        "Android power service is unavailable."
                    }
                    wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Vault:Publishing").apply {
                        setReferenceCounted(false)
                        acquire(LOCAL_BUDGET_MS)
                    }
                    handler.postDelayed(budgetExpired, LOCAL_BUDGET_MS)
                    starting = false
                    running = true
                    listener?.invoke(null)
                } catch (error: Exception) {
                    finish("foregroundStartFailed: ${error.message ?: error.javaClass.simpleName}")
                }
            }
            else -> finish("processRestartRejected")
        }
        return START_NOT_STICKY
    }

    private fun notification(): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val stop = PendingIntent.getService(
            this, 1, Intent(this, PublishingService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL_ID)
            else Notification.Builder(this)
        return builder
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("Midnight publishing availability")
            .setContentText("Publication enabled. Android may still restrict networking.")
            .setContentIntent(open)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .addAction(Notification.Action.Builder(null, "Open", open).build())
            .addAction(Notification.Action.Builder(null, "Stop", stop).build())
            .build()
    }

    private fun finish(reason: String) {
        handler.removeCallbacks(budgetExpired)
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } finally {
            wakeLock = null
            stopForeground(STOP_FOREGROUND_REMOVE)
            getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION_ID)
            transitionStopped(reason)
            stopSelf()
        }
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        finish("taskRemoved")
        super.onTaskRemoved(rootIntent)
    }

    // Android 15's shared dataSync budget may expire before our conservative timer.
    override fun onTimeout(startId: Int, fgsType: Int) {
        finish("dataSyncTimeout")
    }

    override fun onDestroy() {
        finish("serviceDestroyed")
        if (instance === this) instance = null
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "vault_publishing"
        private const val NOTIFICATION_ID = 4301
        private const val ACTION_START = "dev.vault.vault.PUBLISHING_START"
        private const val ACTION_STOP = "dev.vault.vault.PUBLISHING_STOP"
        // Never renew this lock or attempt to circumvent the OS's six-hour quota.
        private const val LOCAL_BUDGET_MS = 6L * 60 * 60 * 1000 - 60 * 1000
        private var instance: PublishingService? = null
        var running = false
            private set
        var starting = false
            private set
        var listener: ((String?) -> Unit)? = null
        val wakeLockHeld: Boolean get() = instance?.wakeLock?.isHeld == true

        fun launch(context: Context) {
            check(!running && !starting) { "Publishing is already active or starting." }
            starting = true
            try {
                val intent = Intent(context, PublishingService::class.java).setAction(ACTION_START)
                if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent)
                else context.startService(intent)
            } catch (error: Exception) {
                transitionStopped("foregroundStartRestricted: ${error.message ?: error.javaClass.simpleName}")
                throw error
            }
        }

        fun stop(reason: String) {
            val service = instance
            if (service != null) service.finish(reason) else transitionStopped(reason)
        }

        private fun transitionStopped(reason: String) {
            val wasActive = running || starting
            running = false
            starting = false
            if (wasActive) listener?.invoke(reason)
        }
    }
}
