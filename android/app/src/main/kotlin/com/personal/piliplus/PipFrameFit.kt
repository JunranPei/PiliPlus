package com.personal.piliplus

import android.graphics.Rect

/** Applies the actual image's content region to the current display bounds. */
data class PipFrameFit(val crop: Rect, val scale: Float, val x: Float, val y: Float) {
    companion object {
        fun calculate(bufferWidth: Int, bufferHeight: Int, windowWidth: Int, windowHeight: Int,
                      videoRegion: Rect? = null, destination: Rect? = null): PipFrameFit {
            require(bufferWidth > 0 && bufferHeight > 1 && windowWidth > 0 && windowHeight > 0)
            val content = Rect(0, 0, bufferWidth, bufferHeight - 1)
            val source = videoRegion?.let(::Rect) ?: Rect(content)
            require(source.intersect(content) && !source.isEmpty)
            val target = destination ?: Rect(0, 0, windowWidth, windowHeight)
            require(!target.isEmpty)
            val scale = minOf(target.width().toFloat() / source.width(), target.height().toFloat() / source.height())
            return PipFrameFit(source, scale,
                target.left + (target.width() - source.width() * scale) / 2f - source.left * scale,
                target.top + (target.height() - source.height() * scale) / 2f - source.top * scale)
        }
    }
}
