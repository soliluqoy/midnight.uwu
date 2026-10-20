package dev.vault.vault

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Owned by the existing UI engine; never creates a background Flutter engine. */
class AvailabilityBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "dev.vault/availability")
    private val handler = Handler(Looper.getMainLooper())
    private var resumed = false
    private var pendingStart: MethodChannel.Result? = null
    private var permissionGrantedWhilePaused = false
    private val startTimeout = Runnable {
        PublishingService.stop("foregroundStartTimeout")
        failStart("foreground_start_timeout", "Android did not confirm the foreground service. Publication remains off.")
    }
    private val serviceListener: (String?) -> Unit = { reason ->
        handler.removeCallbacks(startTimeout)
        if (reason == null) {
            val result = pendingStart
            pendingStart = null
            result?.success(status())
        } else {
            failStart("publishing_stopped", "Publication remains off: $reason")
            channel.invokeMethod("stopped", reason)
        }
    }

    init {
        PublishingService.listener = serviceListener
        channel.setMethodCallHandler(::handle)
    }

    private fun status(): Map<String, Any?> = mapOf(
        "supported" to true,
        "platform" to "android",
        "publishing" to PublishingService.running,
        "autostart" to false,
        "canAutostart" to false,
        "canMinimizeToTray" to false,
        "backgroundMode" to "dataSyncForegroundService",
        "wakeLockHeld" to PublishingService.wakeLockHeld,
        "detail" to "User-started, time-limited dataSync foreground service. Android may suspend networking or kill the process; no Doze or internet reachability guarantee. Removing the task stops publication."
    )

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> result.success(status())
            "start" -> {
                if (!resumed || activity.isFinishing || activity.isDestroyed) {
                    result.error("foreground_required", "Open Midnight and tap Publish while the app is visible. Publication remains off.", null)
                } else if (pendingStart != null || PublishingService.starting) {
                    result.error("publishing_busy", "Finish the current Publish permission request first.", null)
                } else if (PublishingService.running) {
                    result.success(status())
                } else {
                    pendingStart = result
                    if (Build.VERSION.SDK_INT >= 33 && activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                        try {
                            activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQUEST_CODE)
                        } catch (error: Exception) {
                            failStart("notification_permission", "Could not request notification permission: ${error.message}")
                        }
                    } else {
                        beginStart()
                    }
                }
            }
            "stop" -> {
                permissionGrantedWhilePaused = false
                handler.removeCallbacks(startTimeout)
                failStart("publishing_cancelled", "Publication was stopped before startup completed.")
                PublishingService.stop("appStop")
                result.success(status())
            }
            "setAutostart", "minimizeToTray" -> result.error(
                "unsupported", "${call.method} is only available on Windows. Android publication must be started explicitly from the visible app.", null
            )
            else -> result.notImplemented()
        }
    }

    private fun beginStart() {
        if (pendingStart == null) return
        if (!resumed || activity.isFinishing || activity.isDestroyed) {
            failStart("foreground_required", "Return to Midnight and tap Publish while the app is visible. Publication remains off.")
            return
        }
        if (activity.getSystemService(NotificationManager::class.java)?.areNotificationsEnabled() != true) {
            failStart("notifications_disabled", "Enable Midnight notifications in Android Settings, then tap Publish again. A visible notification is required.")
            return
        }
        try {
            handler.postDelayed(startTimeout, 10_000L)
            PublishingService.launch(activity)
        } catch (error: Exception) {
            handler.removeCallbacks(startTimeout)
            failStart("foreground_start_restricted", "Android refused foreground publication: ${error.message}. Keep Midnight visible and retry explicitly.")
        }
    }

    fun onResume() {
        resumed = true
        if (permissionGrantedWhilePaused) {
            permissionGrantedWhilePaused = false
            beginStart()
        }
    }

    fun onPause() {
        resumed = false
    }

    /** Forward Activity.onRequestPermissionsResult; true means this bridge handled it. */
    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        if (pendingStart == null) return true
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            if (resumed) beginStart() else permissionGrantedWhilePaused = true
        } else {
            failStart("notification_permission_denied", "Notification permission is required for visible publishing. Publication remains off; enable notifications in Android Settings to retry.")
        }
        return true
    }

    private fun failStart(code: String, message: String) {
        val result = pendingStart
        pendingStart = null
        permissionGrantedWhilePaused = false
        result?.error(code, message, null)
    }

    /** Call before detaching the UI engine: publication cannot outlive its delivery runtime. */
    fun close() {
        resumed = false
        handler.removeCallbacks(startTimeout)
        failStart("engine_detached", "The Midnight UI engine stopped. Publication remains off.")
        PublishingService.stop("engineDetached")
        if (PublishingService.listener === serviceListener) PublishingService.listener = null
        channel.setMethodCallHandler(null)
    }

    companion object {
        private const val PERMISSION_REQUEST_CODE = 4302
    }
}
