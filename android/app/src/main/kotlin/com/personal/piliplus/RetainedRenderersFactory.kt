package com.personal.piliplus

import android.content.Context
import android.os.Handler
import android.os.Build
import androidx.media3.common.Format
import androidx.media3.common.util.Util
import androidx.media3.exoplayer.audio.AudioOutput
import androidx.media3.exoplayer.audio.AudioOutputProvider
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.AudioTrackAudioOutputProvider
import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.video.MediaCodecVideoRenderer
import androidx.media3.exoplayer.video.VideoRendererEventListener

/** A tiny warm-up sample must not size the retained decoder's input buffers. */
internal class RetainedRenderersFactory(
    context: Context,
    private val audioStartMs: () -> Int = { 0 },
    private val trace: () -> Media3StartupTrace? = { null },
) : DefaultRenderersFactory(context) {
    override fun buildAudioSink(context: Context, enableFloatOutput: Boolean, enableAudioOutputPlaybackParameters: Boolean): AudioSink {
        val delegate = AudioTrackAudioOutputProvider.Builder(context).build()
        val provider = object : AudioOutputProvider by delegate {
            override fun getAudioOutput(config: AudioOutputProvider.OutputConfig): AudioOutput {
                val output = delegate.getAudioOutput(config)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                    !config.isOffload && !config.isTunneling && Util.isEncodingLinearPcm(config.encoding)) {
                    val track = output.audioTrack
                    val before = track.startThresholdInFrames
                    val capacity = track.bufferSizeInFrames
                    val requested = audioStartMs().coerceIn(0, 100)
                    if (requested > 0) {
                        // Keep the normal capacity. Only decouple the initial
                        // start threshold from filling that entire buffer.
                        track.setStartThresholdInFrames((track.sampleRate * requested / 1000).coerceIn(1, capacity))
                    }
                    trace()?.mark("audio.buffer", "rate=${track.sampleRate} capacityFrames=$capacity defaultThresholdFrames=$before thresholdFrames=${track.startThresholdInFrames} requestedMs=$requested")
                }
                return output
            }
        }
        return DefaultAudioSink.Builder(context)
            .setEnableFloatOutput(enableFloatOutput)
            .setEnableAudioOutputPlaybackParameters(enableAudioOutputPlaybackParameters)
            .setAudioOutputProvider(provider).build()
    }

    override fun buildVideoRenderers(
        context: Context,
        extensionRendererMode: Int,
        selector: MediaCodecSelector,
        enableDecoderFallback: Boolean,
        eventHandler: Handler,
        eventListener: VideoRendererEventListener,
        allowedVideoJoiningTimeMs: Long,
        out: ArrayList<Renderer>,
    ) {
        out.add(object : MediaCodecVideoRenderer(
            context, selector, allowedVideoJoiningTimeMs, enableDecoderFallback,
            eventHandler, eventListener, 50,
        ) {
            override fun getCodecMaxValues(
                info: MediaCodecInfo,
                format: Format,
                streamFormats: Array<Format>,
            ): CodecMaxValues {
                val normal = super.getCodecMaxValues(info, format, streamFormats)
                return CodecMaxValues(normal.width, normal.height,
                    normal.inputSize.coerceAtLeast(2 * 1024 * 1024))
            }
        })
    }
}
