package dev.vault.spike.vault_phase0_probe

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

// Short user-initiated active-transfer experiment, not an idle-hosting policy.
class TransferProbeService : Service() {
    companion object { @Volatile var running = false }

    override fun onCreate() {
        super.onCreate()
        val manager = getSystemService(NotificationManager::class.java)
        val channel = "vault-phase0-transfers"
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(channel,
                "Vault feasibility transfer test", NotificationManager.IMPORTANCE_LOW))
        }
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, channel) else Notification.Builder(this)
        val notification = builder.setContentTitle("Vault Phase 0 transfer test")
            .setContentText("Temporary local test. Stops when the test finishes.")
            .setSmallIcon(android.R.drawable.stat_sys_upload).setOngoing(true).build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(4101, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else { startForeground(4101, notification) }
        running = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int) = START_NOT_STICKY
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onTimeout(startId: Int, fgsType: Int) { stopSelf() }
    override fun onDestroy() { running = false; super.onDestroy() }
}
