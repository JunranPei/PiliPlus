package com.personal.piliplus

import android.app.Activity
import android.content.pm.ApplicationInfo
import android.os.Build
import android.os.SystemClock
import android.util.Log
import android.view.Choreographer
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import org.json.JSONObject
import java.util.IdentityHashMap

/** Reads state only. No surface switch, frame capture or forced redraw. */
class PipDiagnostics(private val activity: Activity, private val state: () -> Map<String, Any?>) {
    private val enabled = activity.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
    private var sequence = 0L
    private var untilNs = 0L
    private var scheduled = false
    private var disposed = false
    private val observed = IdentityHashMap<SurfaceView, SurfaceHolder.Callback>()
    private val frame = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            scheduled = false
            if (disposed || SystemClock.elapsedRealtimeNanos() > untilNs) return
            event("vsync", mapOf("frameTimeNs" to frameTimeNanos))
            snapshot("vsync", false)
            scheduled = true
            Choreographer.getInstance().postFrameCallback(this)
        }
    }

    fun event(name: String, data: Map<String, Any?> = emptyMap()) {
        if (!enabled || disposed) return
        try {
            writeEvent(name, data)
        } catch (error: Exception) {
            Log.e("PiliPlusPiPTrace", "trace failed: $name", error)
        }
    }

    private fun writeEvent(name: String, data: Map<String, Any?>) {
        val record = JSONObject()
        record.put("utcMs", System.currentTimeMillis())
        record.put("elapsedNs", SystemClock.elapsedRealtimeNanos())
        record.put("seq", ++sequence)
        record.put("event", name)
        record.put("phase", JSONObject(state()))
        record.put("data", JSONObject(data))
        Log.i("PiliPlusPiPTrace", record.toString())
    }

    fun arm(reason: String) {
        if (!enabled || disposed) return
        untilNs = SystemClock.elapsedRealtimeNanos() + 8_000_000_000L
        event("trace.arm", mapOf("reason" to reason, "durationMs" to 8000))
        snapshot(reason, true)
        if (!scheduled) {
            scheduled = true
            Choreographer.getInstance().postFrameCallback(frame)
        }
    }

    fun snapshot(reason: String, allViews: Boolean) {
        if (!enabled || disposed) return
        try {
            readSnapshot(reason, allViews)
        } catch (error: Exception) {
            Log.e("PiliPlusPiPTrace", "snapshot failed: $reason", error)
        }
    }

    private fun readSnapshot(reason: String, allViews: Boolean) {
        val root = activity.window.decorView
        val metrics = if (Build.VERSION.SDK_INT >= 30) activity.windowManager.currentWindowMetrics.bounds.toString() else "legacy"
        event("window", mapOf(
            "reason" to reason, "metrics" to metrics,
            "configuration" to activity.resources.configuration.toString(),
            "displayMetrics" to activity.resources.displayMetrics.toString(),
            "insets" to root.rootWindowInsets?.toString(),
            "windowAttributes" to activity.window.attributes.toString(),
            "inPip" to (Build.VERSION.SDK_INT >= 26 && activity.isInPictureInPictureMode),
            "focus" to activity.hasWindowFocus(),
        ))
        fun visit(view: View, depth: Int) {
            val relevant = view === root || view is SurfaceView || view is TextureView || view.javaClass.name.contains("Flutter")
            if (allViews || relevant) {
                val location = IntArray(2)
                view.getLocationInWindow(location)
                val data = mutableMapOf<String, Any?>(
                    "reason" to reason, "depth" to depth,
                    "id" to System.identityHashCode(view), "class" to view.javaClass.name,
                    "parent" to System.identityHashCode(view.parent),
                    "width" to view.width, "height" to view.height,
                    "measuredWidth" to view.measuredWidth, "measuredHeight" to view.measuredHeight,
                    "left" to view.left, "top" to view.top, "right" to view.right, "bottom" to view.bottom,
                    "windowX" to location[0], "windowY" to location[1],
                    "visibility" to view.visibility, "shown" to view.isShown,
                    "attached" to view.isAttachedToWindow, "alpha" to view.alpha,
                    "translationX" to view.translationX, "translationY" to view.translationY,
                    "scaleX" to view.scaleX, "scaleY" to view.scaleY,
                    "matrix" to view.matrix.toShortString(), "clip" to view.clipBounds?.toString(),
                    "layoutRequested" to view.isLayoutRequested, "layerType" to view.layerType,
                )
                if (view is SurfaceView) {
                    data["surfaceId"] = System.identityHashCode(view.holder.surface)
                    data["surfaceValid"] = view.holder.surface.isValid
                    data["surfaceFrame"] = view.holder.surfaceFrame.toString()
                    if (!observed.containsKey(view)) {
                        val callback = object : SurfaceHolder.Callback {
                            override fun surfaceCreated(holder: SurfaceHolder) = event("rootSurface.created", mapOf("view" to System.identityHashCode(view), "surface" to holder.surface.toString()))
                            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = event("rootSurface.changed", mapOf("view" to System.identityHashCode(view), "format" to format, "width" to width, "height" to height, "surface" to holder.surface.toString()))
                            override fun surfaceDestroyed(holder: SurfaceHolder) = event("rootSurface.destroyed", mapOf("view" to System.identityHashCode(view), "surface" to holder.surface.toString()))
                        }
                        observed[view] = callback
                        view.holder.addCallback(callback)
                    }
                }
                if (view is TextureView) {
                    data["available"] = view.isAvailable
                    data["textureId"] = System.identityHashCode(view.surfaceTexture)
                    data["textureMatrix"] = view.getTransform(null).toShortString()
                }
                event("view", data)
            }
            if (view is ViewGroup) for (index in 0 until view.childCount) visit(view.getChildAt(index), depth + 1)
        }
        visit(root, 0)
    }

    fun dispose() {
        if (!enabled || disposed) return
        event("trace.dispose")
        disposed = true
        Choreographer.getInstance().removeFrameCallback(frame)
        observed.forEach { (view, callback) -> view.holder.removeCallback(callback) }
        observed.clear()
    }
}
