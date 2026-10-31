package com.personal.piliplus

import android.media.MediaCodecList
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** Fills Android's shared capability cache without allocating a decoder. */
class StartupCodecRegistry(messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "com.personal.piliplus/startup_codecs")
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { action ->
        Thread(action, "PiliCodecRegistry").apply { isDaemon = true }
    }
    private var started = false
    private var disposed = false

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "prepareCodecRegistry") {
                result.notImplemented()
            } else if (disposed || started) {
                result.success(mapOf("started" to false))
            } else {
                started = true
                worker.execute {
                    val begin = System.nanoTime()
                    val response = try {
                        // The constructor shares initCodecList's static cache
                        // with the legacy getters used by FFmpeg's JNI wrapper.
                        val count = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.size
                        val end = System.nanoTime()
                        mapOf(
                            "started" to true,
                            "success" to true,
                            "codecCount" to count,
                            "beginMonoNs" to begin,
                            "endMonoNs" to end,
                            "totalMs" to (end - begin) / 1e6,
                            "thread" to Thread.currentThread().name,
                        )
                    } catch (error: Exception) {
                        mapOf("started" to true, "success" to false,
                            "errorType" to error.javaClass.simpleName)
                    }
                    main.post {
                        if (!disposed) result.success(response)
                    }
                    worker.shutdown()
                }
            }
        }
    }

    fun dispose() {
        disposed = true
        channel.setMethodCallHandler(null)
        // Let the one system query finish without delivering into a
        // destroyed engine. It owns no Surface, decoder, or media connection.
        worker.shutdown()
    }
}
