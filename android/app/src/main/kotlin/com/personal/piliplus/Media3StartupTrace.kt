package com.personal.piliplus

import android.os.SystemClock
import android.util.Log
import androidx.media3.common.Format
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import androidx.media3.exoplayer.DecoderReuseEvaluation
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.source.LoadEventInfo
import androidx.media3.exoplayer.source.MediaLoadData
import java.util.IdentityHashMap

/** Bounded timings only: never logs signed URLs, headers, or video contents. */
internal class Media3StartupTrace(
    private val playerId: Int,
    private val sourceId: Int,
    private val beginMs: Long,
    private val onCurrentSurfaceFrame: (Long) -> Unit = {},
) : AnalyticsListener, TransferListener {
    private data class Transfer(val begin: Long, var bytes: Long = 0)
    private val transfers = IdentityHashMap<DataSource, Transfer>()
    @Volatile private var untilMs = beginMs + 15_000
    private var underruns = 0

    fun mark(name: String, detail: String = "", timestampMs: Long = SystemClock.elapsedRealtime()) {
        if (timestampMs > untilMs) return
        Log.i("Media3Startup", "id=$playerId source=$sourceId tMs=${timestampMs - beginMs} phase=$name $detail")
    }

    fun firstFrame() {
        mark("firstFrame")
        untilMs = SystemClock.elapsedRealtime() + 1_500
    }

    override fun onLoadStarted(eventTime: AnalyticsListener.EventTime, load: LoadEventInfo, data: MediaLoadData) {
        mark("load.start", "task=${load.loadTaskId} type=${data.dataType} track=${data.trackType} range=${load.dataSpec.position} length=${load.dataSpec.length}", eventTime.realtimeMs)
    }

    override fun onLoadCompleted(eventTime: AnalyticsListener.EventTime, load: LoadEventInfo, data: MediaLoadData) {
        mark("load.end", "task=${load.loadTaskId} type=${data.dataType} track=${data.trackType} durationMs=${load.loadDurationMs} bytes=${load.bytesLoaded}", eventTime.realtimeMs)
    }

    override fun onVideoDecoderInitialized(eventTime: AnalyticsListener.EventTime, decoderName: String, initializedTimestampMs: Long, initializationDurationMs: Long) {
        mark("video.decoder", "decoder=$decoderName durationMs=$initializationDurationMs", initializedTimestampMs)
    }

    override fun onAudioDecoderInitialized(eventTime: AnalyticsListener.EventTime, decoderName: String, initializedTimestampMs: Long, initializationDurationMs: Long) {
        mark("audio.decoder", "decoder=$decoderName durationMs=$initializationDurationMs", initializedTimestampMs)
    }

    override fun onVideoInputFormatChanged(eventTime: AnalyticsListener.EventTime, format: Format, evaluation: DecoderReuseEvaluation?) {
        mark("video.format", "codec=${format.codecs} size=${format.width}x${format.height} reuse=${evaluation?.result} discard=${evaluation?.discardReasons}", eventTime.realtimeMs)
    }

    override fun onAudioInputFormatChanged(eventTime: AnalyticsListener.EventTime, format: Format, evaluation: DecoderReuseEvaluation?) {
        mark("audio.format", "codec=${format.codecs} sampleRate=${format.sampleRate} reuse=${evaluation?.result} discard=${evaluation?.discardReasons}", eventTime.realtimeMs)
    }

    override fun onAudioTrackInitialized(eventTime: AnalyticsListener.EventTime, config: AudioSink.AudioTrackConfig) {
        mark("audio.track", timestampMs = eventTime.realtimeMs)
    }

    override fun onAudioPositionAdvancing(eventTime: AnalyticsListener.EventTime, playoutStartSystemTimeMs: Long) {
        val delay = System.currentTimeMillis() - playoutStartSystemTimeMs
        mark("audio.advancing", "callbackDelayMs=$delay",
            SystemClock.elapsedRealtime() - delay.coerceAtLeast(0))
    }

    override fun onAudioUnderrun(eventTime: AnalyticsListener.EventTime, bufferSize: Int, bufferSizeMs: Long, elapsedSinceLastFeedMs: Long) {
        if (++underruns <= 10) {
            Log.w("Media3Playback", "audioUnderrun id=$playerId source=$sourceId count=$underruns bufferMs=$bufferSizeMs sinceFeedMs=$elapsedSinceLastFeedMs")
        }
    }

    override fun onPlaybackStateChanged(eventTime: AnalyticsListener.EventTime, state: Int) {
        mark("state", "value=$state", eventTime.realtimeMs)
    }

    override fun onRenderedFirstFrame(eventTime: AnalyticsListener.EventTime, output: Any, renderTimeMs: Long) {
        if (renderTimeMs < beginMs) {
            mark("video.staleSurfaceFrame", "ageMs=${beginMs - renderTimeMs}")
            return
        }
        mark("video.surfaceRendered", "callbackDelayMs=${SystemClock.elapsedRealtime() - renderTimeMs}", renderTimeMs)
        onCurrentSurfaceFrame(renderTimeMs)
    }

    override fun onTransferInitializing(source: DataSource, spec: DataSpec, isNetwork: Boolean) {
        if (!isNetwork || SystemClock.elapsedRealtime() > untilMs) return
        synchronized(transfers) { transfers[source] = Transfer(SystemClock.elapsedRealtime()) }
        mark("net.begin", "host=${spec.uri.host} file=${spec.uri.path.hashCode()} range=${spec.position} length=${spec.length}")
    }

    override fun onTransferStart(source: DataSource, spec: DataSpec, isNetwork: Boolean) {
        val transfer = synchronized(transfers) { transfers[source] } ?: return
        mark("net.headers", "host=${spec.uri.host} file=${spec.uri.path.hashCode()} waitMs=${SystemClock.elapsedRealtime() - transfer.begin}")
    }

    override fun onBytesTransferred(source: DataSource, spec: DataSpec, isNetwork: Boolean, bytes: Int) {
        val first = synchronized(transfers) {
            val transfer = transfers[source] ?: return
            val first = transfer.bytes == 0L
            transfer.bytes += bytes
            first
        }
        if (first) mark("net.firstByte", "host=${spec.uri.host} file=${spec.uri.path.hashCode()}")
    }

    override fun onTransferEnd(source: DataSource, spec: DataSpec, isNetwork: Boolean) {
        val transfer = synchronized(transfers) { transfers.remove(source) } ?: return
        mark("net.end", "host=${spec.uri.host} file=${spec.uri.path.hashCode()} durationMs=${SystemClock.elapsedRealtime() - transfer.begin} bytes=${transfer.bytes}")
    }
}
