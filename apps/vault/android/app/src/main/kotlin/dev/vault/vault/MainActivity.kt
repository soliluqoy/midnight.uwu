package dev.vault.vault

import android.app.Activity
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

class MainActivity : FlutterActivity() {
    private data class ExportRequest(
        val source: String,
        val result: MethodChannel.Result
    )
    private var pendingExport: ExportRequest? = null
    private val exportRequestCode = 4178
    private val mediaPicker = NativeMediaPicker(this)
    private val librarySources = NativeLibrarySources(this)
    private var availabilityBridge: AvailabilityBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        availabilityBridge = AvailabilityBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.vault.vault/library_sources")
            .setMethodCallHandler { call, result -> librarySources.handle(call, result) }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.vault.vault/media_export")
            .setMethodCallHandler { call, result ->
                if (call.method == "pickMedia") {
                    if (pendingExport != null) {
                        result.error("busy", "Finish the current save first.", null)
                    } else {
                        mediaPicker.pick(result)
                    }
                    return@setMethodCallHandler
                }
                if (call.method != "saveMedia") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                if (pendingExport != null || mediaPicker.busy) {
                    result.error("busy", "Finish the current save first.", null)
                    return@setMethodCallHandler
                }
                val source = call.argument<String>("source")
                val name = call.argument<String>("name")
                if (source.isNullOrEmpty() || name.isNullOrEmpty()) {
                    result.error("invalid_source", "A local source and filename are required.", null)
                    return@setMethodCallHandler
                }
                pendingExport = ExportRequest(source, result)
                try {
                    val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = call.argument<String>("mime") ?: "application/octet-stream"
                        putExtra(Intent.EXTRA_TITLE, name)
                    }
                    startActivityForResult(intent, exportRequestCode)
                } catch (error: Exception) {
                    pendingExport = null
                    result.error("save_destination", error.message, null)
                }
            }
    }

    @Deprecated("Handles explicit document selection and save results.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (mediaPicker.handleResult(requestCode, resultCode, data)) return
        if (librarySources.handleResult(requestCode, resultCode, data)) return
        if (requestCode != exportRequestCode) return
        val request = pendingExport ?: return
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            pendingExport = null
            request.result.success(null)
            return
        }
        val destination = data.data!!
        Thread {
            try {
                val input = File(request.source).inputStream()
                input.use { source ->
                    val output = contentResolver.openOutputStream(destination)
                        ?: throw IOException("The selected provider did not open a destination.")
                    output.use { source.copyTo(it, 64 * 1024) }
                }
                runOnUiThread {
                    pendingExport = null
                    request.result.success(destination.toString())
                }
            } catch (error: Exception) {
                runOnUiThread {
                    pendingExport = null
                    request.result.error("save_failed", error.message, null)
                }
            }
        }.start()
    }

    override fun onResume() {
        super.onResume()
        availabilityBridge?.onResume()
    }

    override fun onPause() {
        availabilityBridge?.onPause()
        super.onPause()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        availabilityBridge?.onRequestPermissionsResult(requestCode, grantResults)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        librarySources.close()
        availabilityBridge?.close()
        availabilityBridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
