package com.personal.piliplus

import android.content.Context
import android.os.Handler
import androidx.media3.common.Format
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.video.MediaCodecVideoRenderer
import androidx.media3.exoplayer.video.VideoRendererEventListener

/** A tiny warm-up sample must not size the retained decoder's input buffers. */
internal class RetainedRenderersFactory(context: Context) : DefaultRenderersFactory(context) {
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
