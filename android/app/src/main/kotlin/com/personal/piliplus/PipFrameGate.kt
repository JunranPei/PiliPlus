package com.personal.piliplus

import io.flutter.embedding.engine.renderer.FlutterRenderer

object PipFrameMetrics {
    fun create(target: PipFrameGate.Request, density: Float, metadataRow: Boolean = true): FlutterRenderer.ViewportMetrics =
        FlutterRenderer.ViewportMetrics().apply {
            devicePixelRatio = density
            width = target.width
            height = if (metadataRow) target.bufferHeight else target.height
            // Flutter 3.44 consumes these as ViewConstraints. Leaving their
            // constructor defaults at zero produces a 0x0 root despite the
            // non-zero physical width and height.
            minWidth = width
            maxWidth = width
            minHeight = height
            maxHeight = height
        }
}

/** A layout acknowledgement alone must never authorize a buffer replacement. */
class PipFrameGate {
    data class Request(val epoch: Int, val width: Int, val height: Int, val pip: Boolean) {
        val bufferHeight get() = height + 1
        fun state(): Map<String, Any> = mapOf(
            "epoch" to epoch, "width" to width, "height" to height, "pip" to pip,
        )
    }
    @Volatile var current: Request? = null
        private set
    var accepted = false
        private set
    private var serial = 0
    @Volatile var lastAccepted: Request? = null
        private set

    @Synchronized fun request(width: Int, height: Int, pip: Boolean): Request {
        require(width >= 9 && height > 0)
        serial = serial % 0xFFFFFF + 1
        return Request(serial, width, height, pip).also { current = it; accepted = false }
    }

    @Synchronized fun accepts(epoch: Int, width: Int, height: Int, marker: Int?): Boolean {
        val target = current ?: return false
        if (target.epoch != epoch || target.width != width || target.bufferHeight != height) return false
        if (!accepted && marker != epoch) return false
        accepted = true
        lastAccepted = target
        return true
    }

    @Synchronized fun resolve(width: Int, height: Int, marker: Int?): Request? {
        val previous = lastAccepted
        if (previous != null && previous.width == width && previous.bufferHeight == height &&
            (marker == null || marker == previous.epoch)) return previous
        val target = current ?: return null
        return if (accepts(target.epoch, width, height, marker)) target else null
    }

    @Synchronized fun cancel() { current = null; lastAccepted = null; accepted = false }

    companion object {
        const val MAGIC = 0x19B76D
        fun decode(magic: Int, epoch: Int, inverse: Int): Int? =
            if (magic == MAGIC && inverse == (epoch xor 0xFFFFFF)) epoch else null
    }
}
