package dev.vault.vault

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import kotlin.math.max

/** Actual selected-source metadata and small posters, never sample artwork. */
class NativeMediaProbe(private val activity: Activity) {
    fun inspect(uri: Uri, mimeType: String): Map<String, Any> {
        if (uri.scheme != "file" && uri.scheme != "content") throw IOException("Unsupported media URI.")
        return when {
            mimeType.startsWith("image/") -> image(uri)
            mimeType.startsWith("video/") -> video(uri)
            else -> mapOf("unavailable" to "Unsupported media type.")
        }
    }

    private fun input(uri: Uri): InputStream = if (uri.scheme == "file") {
        File(uri.path ?: throw IOException("Missing file path.")).inputStream()
    } else activity.contentResolver.openInputStream(uri)
        ?: throw IOException("Source unavailable or permission revoked.")

    private fun image(uri: Uri): Map<String, Any> {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        input(uri).use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0)
            return mapOf("unavailable" to "This image codec is unsupported by Android.")
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / sample > 640) sample *= 2
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        val decoded = input(uri).use { BitmapFactory.decodeStream(it, null, options) }
            ?: return mapOf("width" to bounds.outWidth, "height" to bounds.outHeight,
                "unavailable" to "Android could not decode a preview.")
        val result = mutableMapOf<String, Any>("width" to bounds.outWidth, "height" to bounds.outHeight)
        try { result["poster"] = poster(decoded) }
        finally { decoded.recycle() }
        return result
    }

    private fun video(uri: Uri): Map<String, Any> {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(activity, uri)
            val width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull()
            val height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull()
            val duration = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
            val result = mutableMapOf<String, Any>()
            if (width != null && width > 0) result["width"] = width
            if (height != null && height > 0) result["height"] = height
            if (duration != null && duration >= 0) result["durationMillis"] = duration
            if (Build.VERSION.SDK_INT >= 27 && width != null && height != null && width > 0 && height > 0) {
                val scale = max(width, height).toDouble() / 320.0
                val targetWidth = max(1, (width / max(1.0, scale)).toInt())
                val targetHeight = max(1, (height / max(1.0, scale)).toInt())
                val frame = retriever.getScaledFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                    targetWidth, targetHeight)
                if (frame != null) {
                    try { result["poster"] = poster(frame) }
                    finally { frame.recycle() }
                } else result["unavailable"] = "Android returned no decodable video frame."
            } else result["unavailable"] = "A bounded video preview requires Android API 27+ and valid dimensions."
            return result
        } finally { retriever.release() }
    }

    private fun poster(source: Bitmap): ByteArray {
        var bound = 320
        while (true) {
            val scale = max(source.width, source.height).toDouble() / bound
            val scaled = if (scale > 1) Bitmap.createScaledBitmap(source,
                max(1, (source.width / scale).toInt()), max(1, (source.height / scale).toInt()), true) else source
            val bytes = ByteArrayOutputStream()
            try { if (!scaled.compress(Bitmap.CompressFormat.JPEG, 80, bytes)) throw IOException("Preview encoding failed.") }
            finally { if (scaled !== source) scaled.recycle() }
            val encoded = bytes.toByteArray()
            if (encoded.size <= 128 * 1024) return encoded
            if (bound <= 40) throw IOException("Preview exceeds the bounded poster size.")
            bound /= 2
        }
    }
}
