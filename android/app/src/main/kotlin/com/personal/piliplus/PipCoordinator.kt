package com.personal.piliplus

import android.app.Activity
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.ComponentName
import android.content.res.Configuration
import android.graphics.Rect
import android.graphics.drawable.Icon
import android.media.session.PlaybackState
import android.os.Build
import android.util.Log
import android.view.View
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The one owner of Android PiP state.
 *
 * Flutter only supplies playback metadata and a source rectangle.  The
 * Activity owns the actual transition and reports every native lifecycle
 * callback back through the channel, so a Dart widget never has to infer PiP
 * state from AppLifecycleState or a second JNI call.
 */
class PipCoordinator(
    private val activity: Activity,
    messenger: io.flutter.plugin.common.BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    companion object {
        private const val TAG = "PiliPlusPiP"
        const val CHANNEL = "com.personal.piliplus/pip_v2"
        private const val MIN_RATIO = 1.0 / 2.39
        private const val MAX_RATIO = 2.39
    }

    private enum class Phase { IDLE, ENTERING, ACTIVE }

    private val channel = MethodChannel(messenger, CHANNEL)
    private var phase = Phase.IDLE
    private var generation = 0L
    private var aspectWidth = 16
    private var aspectHeight = 9
    private var isLive = false
    private var isPlaying = false
    private var autoEnterRequested = false
    // onUserLeaveHint is also delivered when the user opens Recent Apps. Keep
    // playback alive while auto-enter is armed, but do not expose PiP geometry
    // to Flutter until SystemUI confirms the actual PiP transition.
    private var autoEnterPending = false
    private var sourceRect: Rect? = null
    private var entrySourceRect: Rect? = null
    private var destroyed = false
    private var renderHost: PipRenderHost? = null
    private val diagnostics = PipDiagnostics(activity) { stateMap() + mapOf(
        "sourceRect" to sourceRect?.toString(), "entryRect" to entrySourceRect?.toString(),
        "ratio" to "$aspectWidth:$aspectHeight", "playing" to isPlaying,
        "autoEnter" to autoEnterRequested,
    ) }
    private val rootLayoutListener = View.OnLayoutChangeListener { view, left, top, right, bottom,
                                                                  oldLeft, oldTop, oldRight, oldBottom ->
        val bounds = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            activity.windowManager.currentWindowMetrics.bounds
        } else {
            Rect(0, 0, activity.resources.displayMetrics.widthPixels, activity.resources.displayMetrics.heightPixels)
        }
        Log.i(
            TAG,
            "rootLayout new=${right - left}x${bottom - top}@($left,$top) " +
                "old=${oldRight - oldLeft}x${oldBottom - oldTop}@($oldLeft,$oldTop) " +
                "view=${view.width}x${view.height} metrics=${bounds.width()}x${bounds.height()} " +
                "phase=${phase.name.lowercase()} inPip=${activity.isInPictureInPictureMode}",
        )
        diagnostics.event("root.layout", mapOf("new" to "$left,$top,$right,$bottom", "old" to "$oldLeft,$oldTop,$oldRight,$oldBottom"))
        diagnostics.snapshot("root.layout", true)
    }

    init {
        channel.setMethodCallHandler(this)
        activity.window.decorView.addOnLayoutChangeListener(rootLayoutListener)
        Log.i(TAG, "created api=${Build.VERSION.SDK_INT}")
    }

    fun installRenderHost() {
        if (renderHost != null) return
        fun find(view: View): io.flutter.embedding.android.FlutterView? {
            if (view is io.flutter.embedding.android.FlutterView) return view
            if (view is android.view.ViewGroup) for (index in 0 until view.childCount) {
                find(view.getChildAt(index))?.let { return it }
            }
            return null
        }
        val flutter = find(activity.window.decorView) ?: return
        val parent = flutter.parent as? android.view.ViewGroup ?: return
        val index = parent.indexOfChild(flutter)
        val params = flutter.layoutParams
        parent.removeView(flutter)
        val host = PipRenderHost(activity, flutter,
            { name, data -> diagnostics.event("renderHost.$name", data) },
            { channel.invokeMethod("stateChanged", stateMap("render-host-changed")) },
        )
        renderHost = host
        parent.addView(host, index, params)
        host.warmUpWhenReady()
        diagnostics.event("renderHost.installed")
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        diagnostics.event("channel.receive", mapOf("method" to call.method, "arguments" to call.arguments.toString()))
        if (destroyed) {
            result.error("PIP_DESTROYED", "PiP coordinator is no longer attached", null)
            return
        }
        when (call.method) {
            "getState" -> result.success(stateMap())
            "configure" -> {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                    !activity.packageManager.hasSystemFeature("android.software.picture_in_picture")
                ) {
                    result.success(false)
                    return
                }
                configure(call.arguments as? Map<*, *>)
                result.success(true)
            }
            "setSourceRect" -> {
                // Layout callbacks from the shrinking window must not replace
                // the rectangle Android uses to crop the entry animation.
                if (phase == Phase.IDLE && renderHost?.locked != true) {
                    sourceRect = parseRect(call.arguments)
                    entrySourceRect = sourceRect?.let(::Rect)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) applyParams()
                    Log.d(TAG, "sourceRect=$sourceRect phase=idle")
                }
                result.success(true)
            }
            "enter" -> result.success(enter("dart-manual"))
            "updateActions" -> {
                val args = call.arguments as? Map<*, *>
                isLive = args?.bool("isLive") ?: isLive
                isPlaying = args?.bool("isPlaying") ?: isPlaying
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) applyParams()
                result.success(true)
            }
            "disableAutoEnter" -> {
                autoEnterRequested = false
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) applyParams()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun configure(args: Map<*, *>?) {
        val width = args?.int("width") ?: 16
        val height = args?.int("height") ?: 9
        val ratio = width.toDouble() / height.toDouble().coerceAtLeast(1.0)
        if (ratio < MIN_RATIO || ratio > MAX_RATIO) {
            if (height > width) {
                aspectWidth = 9
                aspectHeight = 16
            } else {
                aspectWidth = 16
                aspectHeight = 9
            }
        } else {
            aspectWidth = width.coerceAtLeast(1)
            aspectHeight = height.coerceAtLeast(1)
        }
        isLive = args?.bool("isLive") ?: false
        isPlaying = args?.bool("isPlaying") ?: false
        autoEnterRequested = args?.bool("autoEnter") ?: false
        if (phase == Phase.IDLE && renderHost?.locked != true) {
            parseRect(args?.get("sourceRect"))?.let { sourceRect = it }
            entrySourceRect = sourceRect?.let(::Rect)
        }
        applyParams()
        Log.d(
            TAG,
            "configure ratio=$aspectWidth:$aspectHeight auto=$autoEnterRequested playing=$isPlaying rect=$sourceRect",
        )
    }

    private fun enter(reason: String): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        if (phase == Phase.ACTIVE || phase == Phase.ENTERING) return true
        if (!isPlaying) {
            Log.w(TAG, "reject enter while paused")
            return false
        }
        // This path is used for an explicit/manual request (and for the
        // pre-Android-12 fallback). Do not leave the automatic-enter flag
        // armed after the same gesture has already requested PiP.
        autoEnterRequested = false
        setAutoEnterPending(false, "manual-enter")
        entrySourceRect = sourceRect?.let(::Rect)
        setPhase(Phase.ENTERING, reason)
        return try {
            // Manual entry must not leave auto-enter armed for the same gesture.
            val accepted = activity.enterPictureInPictureMode(buildParams(false))
            if (!accepted) {
                setPhase(Phase.IDLE, "native-rejected")
            }
            Log.i(TAG, "enter accepted=$accepted generation=$generation")
            accepted
        } catch (error: Throwable) {
            Log.e(TAG, "enter failed", error)
            setPhase(Phase.IDLE, "native-error")
            false
        }
    }

    private fun applyParams() {
        diagnostics.event("params.apply")
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            activity.setPictureInPictureParams(buildParams(autoEnterRequested && isPlaying))
        } catch (error: Throwable) {
            Log.w(TAG, "setPictureInPictureParams failed", error)
        }
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun buildParams(autoEnter: Boolean): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(android.util.Rational(aspectWidth, aspectHeight))
        val rect = (if (phase != Phase.IDLE) entrySourceRect else sourceRect)
        rect?.let { builder.setSourceRectHint(Rect(it)) }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setSeamlessResizeEnabled(true)
            builder.setAutoEnterEnabled(autoEnter)
        }
        setActions(builder)
        return builder.build()
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun setActions(builder: PictureInPictureParams.Builder) {
        val receiver: ComponentName = MediaHelper.getMediaButtonReceiverComponent(activity) ?: return
        val actions = ArrayList<RemoteAction>(3)
        if (!isLive) actions += remoteAction(receiver, R.drawable.ic_player_rewind_10s, "Rewind", PlaybackState.ACTION_REWIND)
        actions += remoteAction(
            receiver,
            if (isPlaying) R.drawable.ic_player_pause else R.drawable.ic_player_play,
            if (isPlaying) "Pause" else "Play",
            if (isPlaying) PlaybackState.ACTION_PAUSE else PlaybackState.ACTION_PLAY,
        )
        if (!isLive) actions += remoteAction(receiver, R.drawable.ic_player_fast_forward_10s, "Fast forward", PlaybackState.ACTION_FAST_FORWARD)
        builder.setActions(actions)
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun remoteAction(
        receiver: ComponentName,
        iconRes: Int,
        title: String,
        action: Long,
    ): RemoteAction {
        val pendingIntent = MediaHelper.buildMediaButtonPendingIntent(activity, receiver, action.toInt())
            ?: throw IllegalStateException("media button PendingIntent unavailable")
        return RemoteAction(Icon.createWithResource(activity, iconRes), title, title, pendingIntent)
    }

    fun onUserLeaveHint() {
        diagnostics.arm("userLeaveHint")
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            !autoEnterRequested ||
            !isPlaying ||
            phase != Phase.IDLE
        ) {
            return
        }

        // Mark the transition before Activity.onPause reaches Flutter.  The
        // player uses this phase to avoid its delayed background pause.  On
        // Android 12+ the system performs the actual transition itself when
        // auto-enter is armed, so calling enterPictureInPictureMode here would
        // race that system gesture.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            enter("legacy-user-leave")
        } else {
            setAutoEnterPending(true, "user-leave-pending")
            Log.i(TAG, "auto-enter pending api=${Build.VERSION.SDK_INT}")
        }
    }

    fun onResume() {
        diagnostics.arm("resume")
        setAutoEnterPending(false, "resume")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            phase == Phase.ENTERING &&
            !activity.isInPictureInPictureMode
        ) {
            entrySourceRect = null
            setPhase(Phase.IDLE, "resume-without-pip")
            applyParams()
        }
    }

    @RequiresApi(Build.VERSION_CODES.O)
    fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration?) {
        diagnostics.arm("modeChanged:$isInPictureInPictureMode")
        diagnostics.event("mode.callback", mapOf("active" to isInPictureInPictureMode, "config" to newConfig.toString()))
        if (isInPictureInPictureMode) {
            setAutoEnterPending(false, "mode-active")
            setPhase(Phase.ACTIVE, "mode-changed")
            AndroidHelper.isPipMode = true
        } else {
            setAutoEnterPending(false, "mode-exited")
            setPhase(Phase.IDLE, "mode-changed")
            sourceRect = null
            entrySourceRect = null
            AndroidHelper.isPipMode = false
        }
    }

    @RequiresApi(Build.VERSION_CODES.VANILLA_ICE_CREAM)
    fun onPictureInPictureUiStateChanged(state: android.app.PictureInPictureUiState) {
        diagnostics.arm("uiStateChanged")
        diagnostics.event("ui.callback", mapOf("state" to state.toString(), "transitioning" to state.isTransitioningToPip))
        // Ui-state callbacks can arrive late or out of order around the
        // WindowManager resize. Once mode-changed has reported ACTIVE, a late
        // transition callback must not send Dart back through ENTERING and
        // apply the entry geometry a second time.
        if (state.isTransitioningToPip && phase == Phase.IDLE) {
            setAutoEnterPending(false, "ui-transition")
            entrySourceRect = sourceRect?.let(::Rect)
            setPhase(Phase.ENTERING, "ui-transition")
        }
    }

    private fun setPhase(next: Phase, reason: String) {
        diagnostics.event("phase.request", mapOf("next" to next.name, "reason" to reason))
        if (phase == next && reason != "ui-transition") return
        if (next != Phase.IDLE) {
            renderHost?.enter(entrySourceRect ?: sourceRect)
        } else {
            renderHost?.exit()
        }
        phase = next
        renderHost?.active(next == Phase.ACTIVE)
        generation += 1
        val bounds = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            activity.windowManager.currentWindowMetrics.bounds
        } else {
            Rect(0, 0, activity.resources.displayMetrics.widthPixels, activity.resources.displayMetrics.heightPixels)
        }
        Log.i(
            TAG,
            "phase=${phase.name.lowercase()} generation=$generation reason=$reason " +
                "activity=${activity.window.decorView.width}x${activity.window.decorView.height} " +
                "metrics=${bounds.width()}x${bounds.height()} inPip=${activity.isInPictureInPictureMode}",
        )
        channel.invokeMethod("stateChanged", stateMap(reason))
    }

    private fun setAutoEnterPending(value: Boolean, reason: String) {
        if (autoEnterPending == value) return
        autoEnterPending = value
        Log.i(TAG, "autoEnterPending=$value reason=$reason")
        channel.invokeMethod("stateChanged", stateMap(reason))
    }

    private fun stateMap(reason: String? = null): Map<String, Any?> = mapOf(
        "phase" to phase.name.lowercase(),
        "generation" to generation,
        "reason" to reason,
        "isInPip" to (phase == Phase.ACTIVE),
        "autoEnterPending" to autoEnterPending,
        "renderHostLocked" to (renderHost?.locked ?: false),
        "frameRequest" to renderHost?.frameRequest,
    )

    private fun parseRect(value: Any?): Rect? {
        val map = value as? Map<*, *> ?: return null
        val left = map.int("left") ?: return null
        val top = map.int("top") ?: return null
        val width = map.int("width") ?: return null
        val height = map.int("height") ?: return null
        if (width <= 0 || height <= 0) return null
        val bounds = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            activity.windowManager.currentWindowMetrics.bounds
        } else {
            Rect(0, 0, activity.resources.displayMetrics.widthPixels, activity.resources.displayMetrics.heightPixels)
        }
        val clampedLeft = left.coerceIn(0, bounds.width() - 1)
        val clampedTop = top.coerceIn(0, bounds.height() - 1)
        val right = (clampedLeft + width).coerceIn(clampedLeft + 1, bounds.width())
        val bottom = (clampedTop + height).coerceIn(clampedTop + 1, bounds.height())
        return Rect(clampedLeft, clampedTop, right, bottom)
    }

    private fun Map<*, *>.int(key: String): Int? = (get(key) as? Number)?.toInt()
    private fun Map<*, *>.bool(key: String): Boolean? = get(key) as? Boolean

    fun destroy() {
        diagnostics.dispose()
        if (destroyed) return
        destroyed = true
        renderHost?.dispose()
        activity.window.decorView.removeOnLayoutChangeListener(rootLayoutListener)
        channel.setMethodCallHandler(null)
        Log.i(TAG, "destroyed")
    }

    fun traceLifecycle(name: String, config: Configuration? = null) {
        diagnostics.arm(name)
        diagnostics.event("activity.$name", mapOf("configuration" to config.toString()))
    }
}
