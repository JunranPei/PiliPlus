package com.personal.piliplus

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Handler
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.RandomAccessFile
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/** Animated screenshots use Android's decoder and WebP encoder, never libmpv. */
internal class NativeWebpExporter(private val channel: MethodChannel, private val main: Handler) {
    private val executor = Executors.newSingleThreadExecutor()
    private val cancelled = ConcurrentHashMap<Int, Boolean>()

    fun cancel(id: Int) { cancelled[id] = true }

    fun export(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<Number>("exportId")!!.toInt()
        val url = call.argument<String>("url")!!
        val outFile = File(call.argument<String>("outFile")!!)
        val startMs = call.argument<Number>("startMs")!!.toLong()
        val durationMs = call.argument<Number>("durationMs")!!.toLong()
        val preset = call.argument<String>("preset") ?: "default"
        val lossless = preset in setOf("drawing", "icon", "text")
        val quality = if (lossless) 100 else if (preset == "photo") 90 else 85
        cancelled[id] = false
        executor.execute {
            val retriever = MediaMetadataRetriever()
            val success = runCatching {
                if (url.startsWith("http")) retriever.setDataSource(url, mapOf(
                    "User-Agent" to "Mozilla/5.0", "Referer" to "https://www.bilibili.com",
                )) else retriever.setDataSource(url.removePrefix("file://"))
                require(durationMs > 0L)
                RandomAccessFile(outFile, "rw").use { file ->
                    file.setLength(0)
                    file.writeBytes("RIFF"); file.u32(0); file.writeBytes("WEBP")
                    var timeMs = 0L
                    var canvasWidth = 0
                    var canvasHeight = 0
                    while (timeMs < durationMs) {
                        check(cancelled[id] != true)
                        val frame = retriever.getFrameAtTime((startMs + timeMs) * 1000L, MediaMetadataRetriever.OPTION_CLOSEST)
                            ?: error("No video frame at ${startMs + timeMs}")
                        if (timeMs == 0L) {
                            canvasWidth = frame.width; canvasHeight = frame.height
                            file.writeBytes("VP8X"); file.u32(10)
                            file.write(byteArrayOf(0x12, 0, 0, 0))
                            file.u24(canvasWidth - 1); file.u24(canvasHeight - 1)
                            file.writeBytes("ANIM"); file.u32(6)
                            file.u32(0); file.write(byteArrayOf(0, 0))
                        }
                        val bytes = ByteArrayOutputStream()
                        frame.compress(if (Build.VERSION.SDK_INT >= 30) {
                            if (lossless) Bitmap.CompressFormat.WEBP_LOSSLESS else Bitmap.CompressFormat.WEBP_LOSSY
                        } else Bitmap.CompressFormat.WEBP, quality, bytes)
                        frame.recycle()
                        val chunks = imageChunks(bytes.toByteArray())
                        val frameDuration = minOf(100L, durationMs - timeMs).toInt()
                        file.writeBytes("ANMF"); file.u32(16 + chunks.size)
                        file.u24(0); file.u24(0)
                        file.u24(canvasWidth - 1); file.u24(canvasHeight - 1)
                        file.u24(frameDuration); file.writeByte(2)
                        file.write(chunks)
                        if ((16 + chunks.size) % 2 != 0) file.writeByte(0)
                        timeMs += frameDuration
                        val progress = timeMs.toDouble() / durationMs
                        main.post { channel.invokeMethod("exportProgress", mapOf("exportId" to id, "progress" to progress)) }
                    }
                    val size = file.length() - 8L
                    require(size <= 0xffffffffL)
                    file.seek(4); file.u32(size.toInt())
                }
                true
            }.getOrDefault(false)
            runCatching { retriever.release() }
            cancelled.remove(id)
            if (!success) outFile.delete()
            main.post { result.success(success) }
        }
    }

    private fun imageChunks(data: ByteArray): ByteArray {
        val output = ByteArrayOutputStream()
        var offset = 12
        while (offset + 8 <= data.size) {
            val tag = String(data, offset, 4, Charsets.US_ASCII)
            val size = (0..3).fold(0) { value, n -> value or ((data[offset + 4 + n].toInt() and 255) shl (8 * n)) }
            val end = offset + 8 + size + (size and 1)
            require(size >= 0 && end <= data.size)
            if (tag == "VP8 " || tag == "VP8L" || tag == "ALPH") output.write(data, offset, end - offset)
            offset = end
        }
        return output.toByteArray().also { require(it.isNotEmpty()) }
    }

    fun dispose() { cancelled.keys.forEach { cancelled[it] = true }; executor.shutdown() }
    private fun RandomAccessFile.u24(value: Int) { repeat(3) { writeByte(value ushr (8 * it)) } }
    private fun RandomAccessFile.u32(value: Int) { repeat(4) { writeByte(value ushr (8 * it)) } }
}
