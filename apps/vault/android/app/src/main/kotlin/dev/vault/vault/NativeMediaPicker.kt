package dev.vault.vault

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.UUID

// Explicit document selection is streamed into temporary app-private staging.
// Dart imports a durable library-owned copy and deletes this staging file.
class NativeMediaPicker(private val activity: Activity) {
    private var pending: MethodChannel.Result? = null
    private val requestCode = 4179
    val busy: Boolean get() = pending != null

    fun pick(result: MethodChannel.Result) {
        if (busy) {
            result.error("busy", "Finish the current media selection first.", null)
            return
        }
        pending = result
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("image/*", "video/*"))
                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            }
            activity.startActivityForResult(intent, requestCode)
        } catch (error: Exception) {
            pending = null
            result.error("media_picker", error.message, null)
        }
    }

    fun handleResult(code: Int, resultCode: Int, data: Intent?): Boolean {
        if (code != requestCode) return false
        val result = pending ?: return true
        if (resultCode != Activity.RESULT_OK || data == null) {
            pending = null
            result.success(emptyList<Any>())
            return true
        }
        val uris = mutableListOf<Uri>()
        val clips = data.clipData
        if (clips != null) {
            for (index in 0 until clips.itemCount) uris.add(clips.getItemAt(index).uri)
        } else {
            data.data?.let { uris.add(it) }
        }
        Thread {
            val created = mutableListOf<File>()
            try {
                val cache = File(activity.cacheDir, "selected-media")
                if (!cache.exists() && !cache.mkdirs()) throw IOException("Cannot create temporary media storage.")
                val entries = uris.map { uri ->
                    var name = "Selected media"
                    activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                        if (cursor.moveToFirst()) name = cursor.getString(0) ?: name
                    }
                    val extension = name.substringAfterLast('.', "").take(8).filter { it.isLetterOrDigit() }
                    val file = File(cache, UUID.randomUUID().toString() + if (extension.isEmpty()) "" else ".$extension")
                    created.add(file)
                    val input = activity.contentResolver.openInputStream(uri)
                        ?: throw IOException("The selected provider did not open the media.")
                    input.use { source -> file.outputStream().use { source.copyTo(it, 64 * 1024) } }
                    mapOf("name" to name, "path" to file.absolutePath,
                        "bytes" to file.length(), "mime" to (activity.contentResolver.getType(uri) ?: ""))
                }
                activity.runOnUiThread { pending = null; result.success(entries) }
            } catch (error: Exception) {
                for (file in created) file.delete()
                activity.runOnUiThread { pending = null; result.error("media_selection_failed", error.message, null) }
            }
        }.start()
        return true
    }
}
