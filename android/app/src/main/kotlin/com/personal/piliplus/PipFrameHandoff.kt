package com.personal.piliplus

import android.graphics.PixelFormat
import android.graphics.Rect
import android.hardware.HardwareBuffer
import android.media.Image
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.view.SurfaceControl
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowInsets
import androidx.annotation.RequiresApi
import io.flutter.embedding.android.FlutterSurfaceView
import io.flutter.embedding.engine.renderer.FlutterRenderer
import java.time.Duration
import java.util.concurrent.Executors

/** Continuously fits each actual buffer through one producer/consumer queue.
 * A one-physical-pixel metadata row is outside the displayed crop. It is read
 * only during handoff, never saved, and is absent from the visible picture.
 * The compositor receives the original HardwareBuffer, without a bitmap copy.
 */
@RequiresApi(33)
class PipFrameHandoff(
    private val host: View,
    private val original: FlutterSurfaceView,
    private val renderer: FlutterRenderer,
    private val report: (String, Map<String, Any?>) -> Unit,
    private val changed: () -> Unit,
    private val sourceCrop: () -> Rect?,
    private val committed: () -> Unit,
    private val smallDestination: () -> Rect? = { null },
) {
    private val main = Handler(Looper.getMainLooper())
    private val releases = Executors.newSingleThreadExecutor()
    private val gate = PipFrameGate()
    @Volatile private var reader: ImageReader? = null
    @Volatile private var layer: SurfaceControl? = null
    @Volatile private var displayed: PipFrameGate.Request? = null
    @Volatile private var attached = false
    private val transactionLock = Any()
    private data class Geometry(val width: Int, val height: Int, val x: Int, val y: Int,
                                val source: Rect?, val destination: Rect?)
    @Volatile private var frameGeometry: Geometry? = null
    @Volatile private var disposed = false
    private val acquisitionThread = HandlerThread("PipBufferReady").apply { start() }
    private val acquisition = Handler(acquisitionThread.looper)
    val request get() = gate.current
    val started get() = reader != null
    val hasFrame get() = displayed != null
    fun refreshMetrics() { request?.let(::metrics) }

    fun resize(width: Int, height: Int, pip: Boolean) {
        if (disposed || width < 9 || height <= 0) return
        snapshotGeometry()
        val previous = request
        if (previous?.width == width && previous.height == height && previous.pip == pip) {
            metrics(previous)
            geometry()
            return
        }
        if (layer == null) {
            val root = host.rootSurfaceControl ?: return
            val candidate = SurfaceControl.Builder().setName("PiliPlus PiP verified buffer")
                .setBufferSize(width, height + 1).setFormat(PixelFormat.RGBA_8888).build()
            val attach = root.buildReparentTransaction(candidate)
            if (attach == null) { candidate.release(); return }
            // Under the Android window canvas, above the original SurfaceView.
            // Keep SurfaceView's hole punched so native platform views remain
            // able to draw above Flutter instead of being covered by this layer.
            attach.setLayer(candidate, -1)
            attach.addTransactionCommittedListener(host.context.mainExecutor) { attached = true }
            if (!root.applyTransactionOnDraw(attach)) { candidate.release(); attach.close(); return }
            layer = candidate
            host.invalidate()
            original.pause()
        }
        if (reader == null) {
        val next = ImageReader.newInstance(width, height + 1, PixelFormat.RGBA_8888, 8,
            HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE or HardwareBuffer.USAGE_COMPOSER_OVERLAY or
                HardwareBuffer.USAGE_CPU_READ_RARELY)
        next.setOnImageAvailableListener({ available -> acquire(available) }, acquisition)
        reader = next
        // Surface replacement is serialised by Flutter's raster thread. Old
        // queues cannot supply a frame to the new reader or its generation.
        renderer.swapSurface(next.surface)
        }
        val surface = reader!!.surface
        val result = PipBufferGeometry.resize(surface, width, height + 1)
        check(result == 0) { "Native buffer resize failed: $result" }
        val target = gate.request(width, height, pip)
        // Keep this SAME consumer/producer queue across every size change.
        // Old buffers remain consumable with their old geometry until the new
        // scene arrives; no pause/swap/restore cycle at PiP entry or exit.
        renderer.surfaceChanged(width, target.bufferHeight)
        // EGL reconnection may reset producer geometry to consumer defaults.
        check(PipBufferGeometry.resize(surface, width, target.bufferHeight) == 0)
        metrics(target)
        changed()
        report("requested", target.state())
        main.postDelayed({
            if (!disposed && request == target && !gate.accepted) {
                report("waiting", target.state())
                // Continue displaying the previous valid picture. No timeout
                // may authorize showing an unverified buffer.
            }
        }, 2000)
    }

    private val retired = mutableListOf<ImageReader>()
    private val outstanding = java.util.concurrent.ConcurrentHashMap<ImageReader, java.util.concurrent.atomic.AtomicInteger>()

    private fun acquire(source: ImageReader) {
        val image = try { source.acquireLatestImage() } catch (error: Exception) {
            main.post { report("acquireFailed", mapOf("error" to error.toString())) }; null
        } ?: return
        if (disposed || source !== reader) { image.close(); return }
        try {
            val startedNs = System.nanoTime()
            val width = image.width
            val height = image.height
            val previous = gate.lastAccepted
            val pending = gate.current
            val sameAcceptedShape = previous?.width == width && previous.bufferHeight == height
            val samePendingShape = pending?.width == width && pending.bufferHeight == height
            val needsMarker = !sameAcceptedShape || (samePendingShape && pending?.epoch != previous?.epoch)
            val marker = if (needsMarker) readMarker(image) else null
            val readUs = (System.nanoTime() - startedNs) / 1000
            consume(source, image, marker, width, height, readUs)
        } catch (error: Exception) {
            image.close()
            main.post { if (!disposed) report("readFailed", mapOf("error" to error.toString())) }
        }
    }

    private fun consume(source: ImageReader, image: Image,
                        marker: Int?, width: Int, height: Int, readUs: Long) {
        if (disposed || source !== reader) { image.close(); return }
        if (!attached) {
            acquisition.postDelayed({ consume(source, image, marker, width, height, readUs) }, 8)
            return
        }
        synchronized(transactionLock) {
        if (disposed) { image.close(); return }
        try {
            val target = gate.resolve(width, height, marker)
            if (target == null) {
                main.post { report("rejected", mapOf("epoch" to request?.epoch, "marker" to marker,
                    "width" to width, "height" to height, "readUs" to readUs)) }
                image.close()
                return
            }
            val hardware = image.hardwareBuffer ?: run { image.close(); return }
            val surface = layer ?: run { hardware.close(); image.close(); return }
            val first = displayed != target
            val count = outstanding.computeIfAbsent(source) { java.util.concurrent.atomic.AtomicInteger() }
            count.incrementAndGet()
            val transaction = SurfaceControl.Transaction()
            val fence = image.fence
            transaction.setBuffer(surface, hardware, fence) { released ->
                releases.execute {
                    try { released?.awaitForever() } finally {
                        released?.close()
                        image.close()
                        count.decrementAndGet()
                        main.post { closeRetired() }
                    }
                }
            }
            position(transaction, target)
            transaction.setVisibility(surface, true)
            if (first) transaction.setAlpha(original.surfaceControl, 0f)
            transaction.apply()
            displayed = target
            transaction.close()
            fence.close()
            hardware.close()
            if (first) {
                // The buffer and its crop/scale become visible in the SAME
                // compositor transaction. View alpha is only a follow-up guard.
                val timestamp = image.timestamp
                main.post {
                    if (!disposed) {
                        original.alpha = 1f
                        report("committed", target.state() + mapOf("timestampNs" to timestamp,
                            "bufferWidth" to width, "bufferHeight" to height, "readUs" to readUs))
                        committed()
                    }
                }
            }
            main.post { closeRetired() }
        } catch (error: Exception) {
            main.post { report("consumeFailed", mapOf("error" to error.toString(), "epoch" to request?.epoch)) }
            image.close()
        }
        }
    }

    private fun readMarker(image: Image): Int? {
        // Plane access waits for the producer fence. An unfinished GPU buffer
        // never becomes a readiness acknowledgement.
        image.fence.use { if (it.isValid && !it.await(Duration.ofMillis(100))) return null }
        val plane = image.planes.firstOrNull() ?: return null
        val bytes = plane.buffer
        val row = (image.height - 1) * plane.rowStride
        fun rgb(pixel: Int): Int {
            val offset = row + pixel * plane.pixelStride
            if (offset + 2 >= bytes.limit()) return -1
            return ((bytes.get(offset).toInt() and 255) shl 16) or
                ((bytes.get(offset + 1).toInt() and 255) shl 8) or (bytes.get(offset + 2).toInt() and 255)
        }
        return PipFrameGate.decode(rgb(1), rgb(4), rgb(7))
    }

    private fun metrics(target: PipFrameGate.Request, metadataRow: Boolean = true) {
        val value = PipFrameMetrics.create(target, host.resources.displayMetrics.density, metadataRow)
        value.physicalTouchSlop = ViewConfiguration.get(host.context).scaledTouchSlop
        if (!target.pip) {
            val insets = host.rootWindowInsets
            val padding = insets?.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            val ime = insets?.getInsets(WindowInsets.Type.ime())
            val gestures = insets?.getInsets(WindowInsets.Type.systemGestures())
            value.viewPaddingTop = padding?.top ?: 0
            value.viewPaddingLeft = padding?.left ?: 0
            value.viewPaddingRight = padding?.right ?: 0
            value.viewPaddingBottom = padding?.bottom ?: 0
            value.viewInsetBottom = ime?.bottom ?: 0
            value.systemGestureInsetTop = gestures?.top ?: 0
            value.systemGestureInsetBottom = gestures?.bottom ?: 0
            value.systemGestureInsetLeft = gestures?.left ?: 0
            value.systemGestureInsetRight = gestures?.right ?: 0
        }
        renderer.setViewportMetrics(value)
    }

    private fun snapshotGeometry() {
        val origin = IntArray(2)
        host.getLocationInWindow(origin)
        frameGeometry = Geometry(host.width, host.height, origin[0], origin[1],
            sourceCrop()?.let(::Rect), smallDestination()?.let(::Rect))
    }

    private fun position(transaction: SurfaceControl.Transaction, target: PipFrameGate.Request) {
        val surface = layer ?: return
        val geometry = frameGeometry ?: return
        val fit = PipFrameFit.calculate(target.width, target.bufferHeight, geometry.width, geometry.height,
            if (!target.pip) geometry.source else null, if (target.pip) geometry.destination else null)
        transaction.setCrop(surface, fit.crop).setScale(surface, fit.scale, fit.scale)
            .setPosition(surface, geometry.x + fit.x, geometry.y + fit.y)
    }

    fun geometry() {
        snapshotGeometry()
        synchronized(transactionLock) {
        val target = displayed ?: return
        SurfaceControl.Transaction().use { position(it, target); it.apply() }
        }
    }

    private fun closeRetired() {
        val iterator = retired.iterator()
        while (iterator.hasNext()) {
            val candidate = iterator.next()
            if ((outstanding[candidate]?.get() ?: 0) == 0) {
                candidate.close(); outstanding.remove(candidate); iterator.remove()
            }
        }
        if (disposed && retired.isEmpty()) releases.shutdown()
    }

    fun dispose() {
        disposed = true
        acquisitionThread.quitSafely()
        gate.cancel()
        reader?.setOnImageAvailableListener(null, null)
        synchronized(transactionLock) {
        layer?.let { SurfaceControl.Transaction().use { transaction ->
            transaction.setVisibility(it, false).setBuffer(it, null).reparent(it, null).apply()
        }; it.release() }
        reader?.let { retired.add(it) }
        reader = null
        layer = null
        }
        closeRetired()
        // Fence callbacks can arrive after destruction. Keep the release
        // executor available until they release the final acquired images.
    }
}
