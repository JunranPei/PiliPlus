package com.personal.piliplus

import android.app.Activity
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.util.Log
import android.view.Choreographer
import android.view.FrameMetrics
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import android.view.ViewTreeObserver
import android.view.Window
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.embedding.engine.FlutterEngine
import org.json.JSONObject
import java.io.BufferedWriter
import java.io.File
import java.util.IdentityHashMap
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * Opt-in observations of the Android window containing ordinary playback.
 *
 * A vsync or Window FrameMetrics event is not proof that a decoded video buffer
 * was displayed. Flutter's external video texture is not an Android TextureView.
 * The optional texture probe records consumed image metadata separately;
 * SurfaceFlinger latch/present fences and actual image dimensions are not
 * inferred here. Never changes a Surface, transform, producer listener, draw
 * order, or frame scheduling of the application.
 */
class PlaybackDiagnostics(private val activity: Activity, messenger: BinaryMessenger, engine: FlutterEngine? = null) :
    MethodChannel.MethodCallHandler {
    companion object {
        private const val CHANNEL = "piliplus/playback_diagnostics"
        private const val TAG = "PiliPlaybackTrace"
        private const val MAX_PENDING = 2048
        private const val MAX_FILE_BYTES = 64L * 1024 * 1024
        private const val MAX_DURATION_MS = 120_000L
    }

    private val channel = MethodChannel(messenger, CHANNEL)
    private val main = Handler(Looper.getMainLooper())
    private var workerThread: HandlerThread? = null
    private var worker: Handler? = null
    private var writer: BufferedWriter? = null // Accessed only on worker.
    private var directory: File? = null
    private var file: File? = null
    private val sequence = AtomicLong()
    private val pending = AtomicInteger()
    private val dropped = AtomicLong()
    private val written = AtomicLong()
    private val bytes = AtomicLong()
    @Volatile private var configured = false
    @Volatile private var active = false
    @Volatile private var disposed = false
    @Volatile private var capped = false
    @Volatile private var ioError: String? = null
    @Volatile private var source: Map<String, Any?> = emptyMap()
    private val textureProbe = engine?.let { PlaybackTextureProbe(it, ::event) { source } }
    private var deadlineMonoNs = 0L
    private var scheduled = false
    private var frameIndex = 0L
    private var lastVsyncNs = 0L
    private var observer: ViewTreeObserver? = null
    private var metricsListener: Window.OnFrameMetricsAvailableListener? = null
    private val observed = IdentityHashMap<SurfaceView, SurfaceHolder.Callback>()
    private var lastFlushNs = 0L // Accessed only on worker.

    private val endCapture = Runnable { stopCapture("deadline") }
    private val drawListener = ViewTreeObserver.OnDrawListener {
        if (active) snapshot("draw", lastVsyncNs)
    }
    private val frame = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            scheduled = false
            if (!active || disposed) return
            if (System.nanoTime() >= deadlineMonoNs || capped || ioError != null) {
                stopCapture(if (capped) "fileLimit" else if (ioError != null) "ioError" else "deadline")
                return
            }
            frameIndex++
            lastVsyncNs = frameTimeNanos
            textureProbe?.refresh()
            snapshot("vsync", frameTimeNanos)
            scheduled = true
            Choreographer.getInstance().postFrameCallback(this)
        }
    }

    init { channel.setMethodCallHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "configure" -> {
                    configure()
                    result.success(info())
                }
                "clock" -> result.success(clock())
                "arm" -> {
                    check(configured) { "Call configure before arm" }
                    @Suppress("UNCHECKED_CAST")
                    source = (call.argument<Map<String, Any?>>("source") ?: emptyMap()).toMap()
                    arm(call.argument<String>("reason") ?: "unspecified", call.argument<Number>("durationMs")?.toLong() ?: 20_000L)
                    result.success(info())
                }
                "mark" -> {
                    if (active) textureProbe?.refresh()
                    @Suppress("UNCHECKED_CAST")
                    event(call.argument<String>("name") ?: "mark", call.argument<Map<String, Any?>>("data") ?: emptyMap())
                    result.success(null)
                }
                "stop" -> {
                    stopCapture("explicit")
                    flush { result.success(info()) }
                }
                "status" -> result.success(info())
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error("playback_trace", error.toString(), null)
        }
    }

    private fun configure() {
        check(!disposed) { "Diagnostics has been disposed" }
        if (configured) return
        val destination = File(activity.getExternalFilesDir(null) ?: activity.filesDir, "playback-diagnostics")
        check(destination.isDirectory || destination.mkdirs()) { "Cannot create diagnostics directory" }
        directory = destination
        file = File(destination, "native-${Process.myPid()}-${System.currentTimeMillis()}.jsonl")
        workerThread = HandlerThread("PlaybackTraceIO").also { it.start() }
        worker = Handler(workerThread!!.looper)
        // Opening/encoding/writing are done on this background thread only.
        worker!!.post {
            try { writer = file!!.bufferedWriter() } catch (error: Exception) { failIo(error) }
        }
        configured = true
        Log.i(TAG, "configured file=${file!!.absolutePath}")
    }

    private fun clock(): Map<String, Any?> = mapOf(
        "monoNs" to System.nanoTime(), "bootNs" to SystemClock.elapsedRealtimeNanos(),
        "utcMs" to System.currentTimeMillis(), "pid" to Process.myPid(),
    )

    private fun info(): Map<String, Any?> = clock() + mapOf(
        "directory" to directory?.absolutePath, "filePath" to file?.absolutePath,
        "configured" to configured, "active" to active, "deadlineMonoNs" to deadlineMonoNs,
        "written" to written.get(), "pending" to pending.get(), "dropped" to dropped.get(),
        "bytes" to bytes.get(), "fileLimit" to capped, "ioError" to ioError,
    )

    private fun arm(reason: String, durationMs: Long) {
        check(!disposed && !capped && ioError == null) { "Diagnostics unavailable: ${info()}" }
        val duration = durationMs.coerceIn(1_000L, MAX_DURATION_MS)
        deadlineMonoNs = System.nanoTime() + duration * 1_000_000L
        if (!active) {
            active = true
            frameIndex = 0L
            observer = activity.window.decorView.viewTreeObserver.also { it.addOnDrawListener(drawListener) }
            installMetrics()
            textureProbe?.start()
        }
        main.removeCallbacks(endCapture)
        main.postDelayed(endCapture, duration)
        event("trace.arm", mapOf(
            "reason" to reason, "durationMs" to duration,
            "sdk" to Build.VERSION.SDK_INT, "package" to activity.packageName,
            "observationBoundary" to "View/window geometry and optional Flutter-consumed video texture metadata; compositor latch/present fences and actual video buffer dimensions are not observed",
        ))
        snapshot("arm", lastVsyncNs)
        if (!scheduled) {
            scheduled = true
            Choreographer.getInstance().postFrameCallback(frame)
        }
    }

    private fun installMetrics() {
        if (Build.VERSION.SDK_INT < 24) return
        val listener = Window.OnFrameMetricsAvailableListener { _, supplied, dropCount ->
            if (active) {
                // The platform reuses FrameMetrics after this callback.
                val metrics = FrameMetrics(supplied)
                val values = mutableMapOf<String, Any?>(
                    "reportedDropped" to dropCount,
                    "intendedVsyncNs" to metrics.getMetric(FrameMetrics.INTENDED_VSYNC_TIMESTAMP),
                    "vsyncNs" to metrics.getMetric(FrameMetrics.VSYNC_TIMESTAMP),
                    "unknownDelayNs" to metrics.getMetric(FrameMetrics.UNKNOWN_DELAY_DURATION),
                    "inputNs" to metrics.getMetric(FrameMetrics.INPUT_HANDLING_DURATION),
                    "layoutMeasureNs" to metrics.getMetric(FrameMetrics.LAYOUT_MEASURE_DURATION),
                    "drawNs" to metrics.getMetric(FrameMetrics.DRAW_DURATION),
                    "syncNs" to metrics.getMetric(FrameMetrics.SYNC_DURATION),
                    "commandIssueNs" to metrics.getMetric(FrameMetrics.COMMAND_ISSUE_DURATION),
                    "swapBuffersNs" to metrics.getMetric(FrameMetrics.SWAP_BUFFERS_DURATION),
                    "totalNs" to metrics.getMetric(FrameMetrics.TOTAL_DURATION),
                    "firstDraw" to metrics.getMetric(FrameMetrics.FIRST_DRAW_FRAME),
                    "scope" to "Android window renderer; not Flutter external texture present",
                )
                if (Build.VERSION.SDK_INT >= 31) {
                    values["gpuNs"] = metrics.getMetric(FrameMetrics.GPU_DURATION)
                    values["deadlineNs"] = metrics.getMetric(FrameMetrics.DEADLINE)
                }
                event("window.frameMetrics", values)
            }
        }
        try {
            activity.window.addOnFrameMetricsAvailableListener(listener, worker)
            metricsListener = listener
        } catch (error: Exception) {
            event("window.frameMetricsUnavailable", mapOf("error" to error.toString()))
        }
    }

    fun lifecycle(name: String, data: Map<String, Any?> = emptyMap()) {
        event("activity.$name", data)
    }

    private fun snapshot(reason: String, vsyncNs: Long) {
        if (!active || capped) return
        val began = System.nanoTime()
        try {
            val root = activity.window.decorView
            val views = ArrayList<Map<String, Any?>>()
            fun visit(view: View, depth: Int) {
                // Include parents as well as surfaces: a parent can apply the
                // offset, scale, visibility or clipping while a child stays still.
                views.add(viewState(view, depth))
                if (view is SurfaceView) observe(view)
                if (view is ViewGroup) for (index in 0 until view.childCount) visit(view.getChildAt(index), depth + 1)
            }
            visit(root, 0)
            val bounds = if (Build.VERSION.SDK_INT >= 30) rect(activity.windowManager.currentWindowMetrics.bounds) else null
            event("window.geometry", mapOf(
                "reason" to reason, "vsyncNs" to vsyncNs, "sampleFrame" to frameIndex,
                "windowBounds" to bounds, "configuration" to activity.resources.configuration.toString(),
                "density" to activity.resources.displayMetrics.density,
                "insets" to root.rootWindowInsets?.toString(), "focus" to activity.hasWindowFocus(),
                "inPip" to (Build.VERSION.SDK_INT >= 26 && activity.isInPictureInPictureMode),
                "views" to views, "collectionDurationNs" to System.nanoTime() - began,
            ))
        } catch (error: Exception) {
            event("trace.collectionError", mapOf("reason" to reason, "error" to error.toString()))
        }
    }

    private fun viewState(view: View, depth: Int): Map<String, Any?> {
        val window = IntArray(2)
        val screen = IntArray(2)
        view.getLocationInWindow(window)
        view.getLocationOnScreen(screen)
        val visible = Rect()
        val hasVisible = view.getGlobalVisibleRect(visible)
        val data = mutableMapOf<String, Any?>(
            "id" to System.identityHashCode(view), "class" to view.javaClass.name, "depth" to depth,
            "parent" to System.identityHashCode(view.parent),
            "width" to view.width, "height" to view.height,
            "measuredWidth" to view.measuredWidth, "measuredHeight" to view.measuredHeight,
            "left" to view.left, "top" to view.top, "right" to view.right, "bottom" to view.bottom,
            "windowX" to window[0], "windowY" to window[1], "screenX" to screen[0], "screenY" to screen[1],
            "visibleRect" to if (hasVisible) rect(visible) else null,
            "visibility" to view.visibility, "windowVisibility" to view.windowVisibility,
            "shown" to view.isShown, "attached" to view.isAttachedToWindow, "alpha" to view.alpha,
            "translationX" to view.translationX, "translationY" to view.translationY, "translationZ" to view.translationZ,
            "scaleX" to view.scaleX, "scaleY" to view.scaleY, "pivotX" to view.pivotX, "pivotY" to view.pivotY,
            "rotation" to view.rotation, "matrix" to view.matrix.toShortString(), "clip" to view.clipBounds?.let { rect(it) },
            "scrollX" to view.scrollX, "scrollY" to view.scrollY, "elevation" to view.elevation,
            "padding" to listOf(view.paddingLeft, view.paddingTop, view.paddingRight, view.paddingBottom),
            "layoutRequested" to view.isLayoutRequested, "layerType" to view.layerType,
        )
        if (view is ViewGroup) {
            data["clipChildren"] = view.clipChildren
            data["clipToPadding"] = view.clipToPadding
        }
        if (view is SurfaceView) {
            data["surfaceId"] = System.identityHashCode(view.holder.surface)
            data["surfaceValid"] = view.holder.surface.isValid
            data["surfaceFrame"] = rect(view.holder.surfaceFrame)
            data["surfaceRole"] = if (view.javaClass.name.contains("Flutter")) "Flutter root output" else "Android SurfaceView"
        }
        if (view is TextureView) {
            data["available"] = view.isAvailable
            data["surfaceTextureObjectId"] = view.surfaceTexture?.let { System.identityHashCode(it) }
            data["textureMatrix"] = view.getTransform(null).toShortString()
            // No setSurfaceTextureListener or setOnFrameAvailableListener: those
            // belong to the renderer and replacing them changes playback.
        }
        return data
    }

    private fun observe(view: SurfaceView) {
        if (observed.containsKey(view)) return
        val id = System.identityHashCode(view)
        val callback = object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) = event("surface.created", surface(holder) + mapOf("view" to id))
            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = event(
                "surface.changed", surface(holder) + mapOf("view" to id, "format" to format, "width" to width, "height" to height),
            )
            override fun surfaceDestroyed(holder: SurfaceHolder) = event("surface.destroyed", surface(holder) + mapOf("view" to id))
        }
        observed[view] = callback
        view.holder.addCallback(callback)
    }

    private fun surface(holder: SurfaceHolder): Map<String, Any?> = mapOf(
        "surfaceId" to System.identityHashCode(holder.surface), "valid" to holder.surface.isValid,
        "holderFrame" to rect(holder.surfaceFrame),
    )

    private fun rect(value: Rect): Map<String, Int> = mapOf(
        "left" to value.left, "top" to value.top, "right" to value.right, "bottom" to value.bottom,
        "width" to value.width(), "height" to value.height(),
    )

    private fun event(name: String, data: Map<String, Any?> = emptyMap()) {
        if (!configured || !active || disposed) return
        if (capped || ioError != null) {
            dropped.incrementAndGet()
            return
        }
        if (pending.incrementAndGet() > MAX_PENDING) {
            pending.decrementAndGet()
            dropped.incrementAndGet()
            return
        }
        val record = clock() + mapOf(
            "stream" to "android", "seq" to sequence.incrementAndGet(), "event" to name,
            "sourceHint" to source, "data" to data, "droppedBefore" to dropped.get(),
        )
        worker?.post {
            try {
                if (capped || ioError != null) { dropped.incrementAndGet(); return@post }
                val line = JSONObject(record).toString() + "\n"
                val length = line.toByteArray(Charsets.UTF_8).size
                if (bytes.get() + length > MAX_FILE_BYTES) {
                    capped = true
                    writer?.write(JSONObject(mapOf("event" to "trace.fileLimit", "monoNs" to System.nanoTime(), "limit" to MAX_FILE_BYTES)).toString() + "\n")
                    writer?.flush()
                    dropped.incrementAndGet()
                    return@post
                }
                writer?.write(line)
                bytes.addAndGet(length.toLong())
                val count = written.incrementAndGet()
                val now = System.nanoTime()
                if (count % 64L == 0L || now - lastFlushNs >= 1_000_000_000L) {
                    writer?.flush()
                    lastFlushNs = now
                }
            } catch (error: Exception) { failIo(error) }
            finally { pending.decrementAndGet() }
        }
    }

    private fun failIo(error: Exception) {
        if (ioError == null) Log.e(TAG, "Trace write failed", error)
        ioError = error.toString()
    }

    private fun stopCapture(reason: String) {
        if (!active) return
        event("trace.stop", mapOf("reason" to reason, "dropped" to dropped.get()))
        textureProbe?.stop()
        active = false
        scheduled = false
        main.removeCallbacks(endCapture)
        Choreographer.getInstance().removeFrameCallback(frame)
        observer?.takeIf { it.isAlive }?.removeOnDrawListener(drawListener)
        observer = null
        if (Build.VERSION.SDK_INT >= 24) metricsListener?.let { activity.window.removeOnFrameMetricsAvailableListener(it) }
        metricsListener = null
        observed.forEach { (view, callback) -> view.holder.removeCallback(callback) }
        observed.clear()
        flush()
    }

    private fun flush(then: (() -> Unit)? = null) {
        val target = worker
        if (target == null) { then?.invoke(); return }
        target.post {
            try { writer?.flush() } catch (error: Exception) { failIo(error) }
            if (then != null) main.post(then)
        }
    }

    fun dispose() {
        if (disposed) return
        stopCapture("destroy")
        disposed = true
        channel.setMethodCallHandler(null)
        worker?.post {
            try { writer?.close() } catch (error: Exception) { failIo(error) }
            writer = null
            workerThread?.quitSafely()
        }
    }
}
