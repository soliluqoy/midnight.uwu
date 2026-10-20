package dev.vault.spike.vault_phase0_probe

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.SystemClock

object CodecProbe {
    fun capabilities(): Map<String, Any> {
        val codecs = MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos
            .filter { it.supportedTypes.any { type -> type.equals("video/avc", true) } }
            .map { info ->
                val caps = info.getCapabilitiesForType("video/avc")
                mapOf(
                    "name" to info.name,
                    "encoder" to info.isEncoder,
                    "hardwareAccelerated" to (Build.VERSION.SDK_INT >= 29 && info.isHardwareAccelerated),
                    "softwareOnly" to (Build.VERSION.SDK_INT >= 29 && info.isSoftwareOnly),
                    "supports720p30" to (caps.videoCapabilities?.areSizeAndRateSupported(1280, 720, 30.0) ?: false),
                    "colorFormats" to caps.colorFormats.toList()
                )
            }
        return mapOf(
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "androidRelease" to Build.VERSION.RELEASE,
            "sdk" to Build.VERSION.SDK_INT,
            "h264Codecs" to codecs
        )
    }

    fun encode720p(): Map<String, Any> {
        val info = MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.firstOrNull {
            it.isEncoder && Build.VERSION.SDK_INT >= 29 && it.isHardwareAccelerated &&
                it.supportedTypes.any { type -> type.equals("video/avc", true) } &&
                it.getCapabilitiesForType("video/avc").videoCapabilities?.areSizeAndRateSupported(1280, 720, 30.0) == true
        } ?: return mapOf("passed" to false, "reason" to "No advertised hardware H264 720p30 encoder")
        val caps = info.getCapabilitiesForType("video/avc")
        val supported = caps.colorFormats
        val color = when {
            supported.contains(MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible) ->
                MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible
            supported.contains(MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar) ->
                MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar
            supported.contains(MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar) ->
                MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar
            else -> return mapOf("passed" to false, "codec" to info.name, "reason" to "No supported byte-buffer YUV420 format")
        }
        val format = MediaFormat.createVideoFormat("video/avc", 1280, 720).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, color)
            setInteger(MediaFormat.KEY_BIT_RATE, 2_500_000)
            setInteger(MediaFormat.KEY_FRAME_RATE, 30)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
        }
        val codec = MediaCodec.createByCodecName(info.name)
        var started = false
        try {
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()
            started = true
            val frame = ByteArray(1280 * 720 * 3 / 2) { 128.toByte() }
            frame.fill(16.toByte(), 0, 1280 * 720)
            val bufferInfo = MediaCodec.BufferInfo()
            var outputFrames = 0
            var encodedBytes = 0L
            var outputFormat = ""
            var eos = false
            fun drain(waitMicros: Long) {
                while (true) {
                    val index = codec.dequeueOutputBuffer(bufferInfo, waitMicros)
                    when {
                        index == MediaCodec.INFO_TRY_AGAIN_LATER -> return
                        index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> outputFormat = codec.outputFormat.toString()
                        index >= 0 -> {
                            if (bufferInfo.size > 0 && bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                                outputFrames++
                                encodedBytes += bufferInfo.size
                            }
                            if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) eos = true
                            codec.releaseOutputBuffer(index, false)
                        }
                    }
                }
            }
            val start = SystemClock.elapsedRealtimeNanos()
            val frameCount = 150
            for (index in 0 until frameCount) {
                val target = start + index * 1_000_000_000L / 30
                val wait = target - SystemClock.elapsedRealtimeNanos()
                if (wait > 0) Thread.sleep(wait / 1_000_000, (wait % 1_000_000).toInt())
                var input = codec.dequeueInputBuffer(10_000)
                while (input < 0) {
                    drain(0)
                    if (SystemClock.elapsedRealtimeNanos() - start > 15_000_000_000L) error("Input timeout")
                    input = codec.dequeueInputBuffer(10_000)
                }
                codec.getInputBuffer(input)!!.apply { clear(); put(frame) }
                codec.queueInputBuffer(input, 0, frame.size, index * 1_000_000L / 30, 0)
                drain(0)
            }
            var input = codec.dequeueInputBuffer(10_000)
            while (input < 0) {
                drain(0)
                if (SystemClock.elapsedRealtimeNanos() - start > 15_000_000_000L) error("EOS input timeout")
                input = codec.dequeueInputBuffer(10_000)
            }
            codec.queueInputBuffer(input, 0, 0, frameCount * 1_000_000L / 30, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
            while (!eos) {
                if (SystemClock.elapsedRealtimeNanos() - start > 20_000_000_000L) error("EOS output timeout")
                drain(10_000)
            }
            val elapsedMs = (SystemClock.elapsedRealtimeNanos() - start) / 1_000_000.0
            return mapOf(
                "passed" to (outputFrames == frameCount && elapsedMs < 5500),
                "scope" to "Native MediaCodec synthetic constant frames only; not WebRTC file injection or sustained thermal proof",
                "codec" to info.name,
                "hardwareAccelerated" to true,
                "inputFrames" to frameCount,
                "outputFrames" to outputFrames,
                "milliseconds" to elapsedMs,
                "framesPerSecond" to (outputFrames * 1000.0 / elapsedMs),
                "encodedBytes" to encodedBytes,
                "requestedBitrate" to 2_500_000,
                "constantInputDoesNotValidateTargetBitrate" to true,
                "outputFormat" to outputFormat
            )
        } finally {
            if (started) codec.stop()
            codec.release()
        }
    }
}
