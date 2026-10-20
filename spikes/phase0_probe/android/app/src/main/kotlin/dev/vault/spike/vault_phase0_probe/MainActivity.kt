package dev.vault.spike.vault_phase0_probe

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import android.app.ActivityManager
import android.app.NotificationManager
import android.content.Intent
import android.os.Build
import android.os.PowerManager

class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vault.phase0/native")
            .setMethodCallHandler { call, result ->
                worker.execute {
                    try {
                        val value = when (call.method) {
                            "capabilities" -> CodecProbe.capabilities() + mapOf(
                                "networkStatePermissionGranted" to
                                    (checkSelfPermission(android.Manifest.permission.ACCESS_NETWORK_STATE) == android.content.pm.PackageManager.PERMISSION_GRANTED)
                            )
                            "encode720p" -> CodecProbe.encode720p()
                            "lifecycle" -> lifecycleSnapshot()
                            "startTransferService" -> {
                                val intent = Intent(this, TransferProbeService::class.java)
                                if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
                                mapOf("requested" to true)
                            }
                            "stopTransferService" -> {
                                stopService(Intent(this, TransferProbeService::class.java))
                                mapOf("stopRequested" to true)
                            }
                            else -> null
                        }
                        runOnUiThread {
                            if (value == null) result.notImplemented() else result.success(value)
                        }
                    } catch (error: Exception) {
                        runOnUiThread { result.error("probe_failed", error.toString(), null) }
                    }
                }
            }
    }

    override fun onDestroy() {
        worker.shutdown()
        super.onDestroy()
    }

    private fun lifecycleSnapshot(): Map<String, Any> {
        val power = getSystemService(PowerManager::class.java)
        val manager = getSystemService(ActivityManager::class.java)
        val notifications = getSystemService(NotificationManager::class.java)
        return mapOf(
            "transferServiceRunning" to TransferProbeService.running,
            "serviceType" to "dataSync (time-budgeted; not indefinite hosting)",
            "deviceIdle" to power.isDeviceIdleMode,
            "interactive" to power.isInteractive,
            "powerSaveMode" to power.isPowerSaveMode,
            "batteryOptimizationExempt" to power.isIgnoringBatteryOptimizations(packageName),
            "backgroundRestricted" to (Build.VERSION.SDK_INT >= 28 && manager.isBackgroundRestricted),
            "notificationsEnabled" to (Build.VERSION.SDK_INT >= 24 && notifications.areNotificationsEnabled())
        )
    }
}
