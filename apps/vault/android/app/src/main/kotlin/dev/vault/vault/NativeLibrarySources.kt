package dev.vault.vault

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** Persisted user-selected trees only. No broad storage scan or media copy. */
class NativeLibrarySources(private val activity: Activity) {
    private val requestCode = 4180
    private var pending: MethodChannel.Result? = null
    private val maxEntries = 20000
    private val maxRead = 256 * 1024
    private val workers = ThreadPoolExecutor(2, 2, 30, TimeUnit.SECONDS,
        ArrayBlockingQueue<Runnable>(16), ThreadPoolExecutor.AbortPolicy())

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "pickSourceTree") {
            if (pending != null) { result.error("busy", "Finish the current folder selection.", null); return }
            pending = result
            try {
                activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                }, requestCode)
            } catch (error: Exception) { pending = null; result.error("source_picker", error.message, null) }
            return
        }
        if (call.method !in setOf("enumerateTree", "sourceStat", "sourceReadAt", "releaseSourceTree", "inspectMedia")) {
            result.notImplemented(); return
        }
        val work = Runnable {
            try {
                val text = call.argument<String>("uri") ?: throw IOException("A selected source URI is required.")
                val uri = Uri.parse(text)
                if (uri.scheme != "content" && !(call.method == "inspectMedia" && uri.scheme == "file"))
                    throw IOException("Only selected content URIs are supported.")
                val value: Any? = when (call.method) {
                    "inspectMedia" -> NativeMediaProbe(activity).inspect(uri, call.argument<String>("mimeType") ?: "")
                    "enumerateTree" -> enumerate(uri)
                    "sourceStat" -> stat(uri)
                    "sourceReadAt" -> readAt(uri, call.argument<Number>("offset")?.toLong() ?: -1,
                        call.argument<Number>("length")?.toLong() ?: -1)
                    "releaseSourceTree" -> {
                        activity.contentResolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        null
                    }
                    else -> throw IOException("Unsupported source operation.")
                }
                activity.runOnUiThread { result.success(value) }
            } catch (error: Exception) {
                activity.runOnUiThread { result.error("source_unavailable", error.message ?: "Source unavailable or permission lost.", null) }
            }
        }
        try { workers.execute(work) }
        catch (error: RejectedExecutionException) {
            result.error("source_busy", "Source worker queue is full or closing; retry when current reads finish.", null)
        }
    }

    fun close() {
        workers.shutdownNow()
        pending?.error("closed", "Folder selection ended because the app closed.", null)
        pending = null
    }

    fun handleResult(code: Int, resultCode: Int, data: Intent?): Boolean {
        if (code != requestCode) return false
        val result = pending ?: return true
        pending = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { result.success(null); return true }
        try {
            val flags = data.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION
            if (flags == 0) throw IOException("The provider did not grant read access.")
            activity.contentResolver.takePersistableUriPermission(uri, flags)
            val root = DocumentsContract.buildDocumentUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri))
            val info = stat(root)
            result.success(mapOf("uri" to uri.toString(), "name" to info["name"]))
        } catch (error: Exception) { result.error("source_permission", error.message, null) }
        return true
    }

    private val projection = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,
        DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE,
        DocumentsContract.Document.COLUMN_SIZE, DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        DocumentsContract.Document.COLUMN_FLAGS)

    private fun stat(uri: Uri): Map<String, Any> {
        activity.contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
            if (!cursor.moveToFirst()) throw IOException("The selected document no longer exists.")
            val mime = cursor.getString(2) ?: "application/octet-stream"
            if ((cursor.getInt(5) and DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT) != 0)
                throw IOException("Virtual documents cannot provide stable random-access media.")
            if (mime != DocumentsContract.Document.MIME_TYPE_DIR && (cursor.isNull(3) || cursor.isNull(4)))
                throw IOException("Provider must expose media size and modification time.")
            return mapOf("uri" to uri.toString(), "name" to (cursor.getString(1) ?: "Selected document"),
                "mimeType" to mime, "size" to cursor.getLong(3), "modifiedMillis" to cursor.getLong(4))
        }
        throw IOException("Provider did not return document metadata.")
    }

    private fun enumerate(tree: Uri): List<Map<String, Any>> {
        if (!DocumentsContract.isTreeUri(tree)) throw IOException("Select a persistent source tree first.")
        val entries = mutableListOf<Map<String, Any>>()
        val visited = mutableSetOf<String>()
        var visitedCount = 0
        fun visit(documentId: String, depth: Int) {
            if (depth > 32) throw IOException("Folder nesting exceeds the supported depth of 32.")
            if (!visited.add(documentId)) throw IOException("Provider returned a cyclic document tree.")
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, documentId)
            val cursor = activity.contentResolver.query(children, projection, null, null, null)
                ?: throw IOException("Provider could not enumerate the selected folder.")
            cursor.use {
                while (it.moveToNext()) {
                    if (++visitedCount > maxEntries) throw IOException("Source exceeds the 20,000-document limit.")
                    val id = it.getString(0) ?: throw IOException("Provider returned no document ID.")
                    val mime = it.getString(2) ?: "application/octet-stream"
                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) { visit(id, depth + 1); continue }
                    if (!mime.startsWith("image/") && !mime.startsWith("video/")) continue
                    if ((it.getInt(5) and DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT) != 0)
                        throw IOException("Virtual media documents do not support durable random access.")
                    if (it.isNull(3) || it.isNull(4)) throw IOException("Media provider must expose size and modification time.")
                    val uri = DocumentsContract.buildDocumentUriUsingTree(tree, id)
                    entries.add(mapOf("uri" to uri.toString(), "name" to (it.getString(1) ?: "Selected media"),
                        "size" to it.getLong(3), "modifiedMillis" to it.getLong(4)))
                }
            }
        }
        visit(DocumentsContract.getTreeDocumentId(tree), 0)
        return entries
    }

    private fun readAt(uri: Uri, offset: Long, requestedLength: Long): ByteArray {
        if (offset < 0 || requestedLength < 0 || requestedLength > maxRead.toLong())
            throw IOException("Read must be 0–256 KiB at a nonnegative offset.")
        val length = requestedLength.toInt()
        val descriptor = activity.contentResolver.openFileDescriptor(uri, "r")
            ?: throw IOException("Provider did not open the media; permission may have been revoked.")
        ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { stream ->
                // Non-seekable/cloud-only providers fail visibly instead of
                // silently making a whole-library copy or fake successful read.
                stream.channel.position(offset)
                val buffer = ByteArray(length)
                var count = 0
                while (count < length) {
                    val read = stream.read(buffer, count, length - count)
                    if (read < 0) break
                    count += read
                }
                return if (count == length) buffer else buffer.copyOf(count)
        }
    }
}
