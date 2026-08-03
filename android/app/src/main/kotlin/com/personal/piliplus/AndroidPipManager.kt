package com.personal.piliplus

import android.app.PictureInPictureParams
import android.app.PictureInPictureUiState
import android.app.RemoteAction
import android.content.ComponentName
import android.content.pm.PackageManager
import android.graphics.Rect
import android.graphics.drawable.Icon
import android.media.session.PlaybackState
import android.os.Build
import android.util.Log
import android.util.Rational
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.max

/**
 * Android PiP state and parameters.
 *
 * The system owns the visual transition. Flutter only supplies the current
 * player bounds and hides non-video UI when Android announces that the enter
 * animation has started. In particular, this class deliberately does not copy
 * or overlay Flutter frames: synchronous TextureView snapshots introduce a
 * second hand-off at the end of the system animation and visibly stall video.
 */
class AndroidPipManager(
    private val activity: MainActivity,
    flutterEngine: FlutterEngine,
) : MethodChannel.MethodCallHandler {
    private enum class Phase(val wireValue: String) {
        IDLE("idle"),
        ENTERING("entering"),
        ACTIVE("active"),
    }

    private val channel = MethodChannel(
        flutterEngine.dartExecutor.binaryMessenger,
        CHANNEL_NAME,
    )
    private val available = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
        activity.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    private var phase = Phase.IDLE
    private var generation = 0
    private var sourceRect: Rect? = null

    // Keep the entry bounds unchanged while the task is a PiP window. Bounds
    // reported from the already-small task are not a valid full-window exit
    // target and caused black bars when the PiP was expanded again.
    private var transitionSourceRect: Rect? = null

    private var aspectRatio = Rational(16, 9)
    private var isLive = false
    private var isPlaying = false
    private var autoEnter = false

    init {
        channel.setMethodCallHandler(this)
        trace("created available=$available sdk=${Build.VERSION.SDK_INT}")
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(available)
            "configure" -> {
                if (!available) {
                    result.success(false)
                    return
                }
                updateConfiguration(call)
                result.success(applyParams("configure"))
            }
            "setSourceRect" -> {
                updateSourceRect(call)
                if (available && phase == Phase.IDLE && autoEnter) {
                    applyParams("setSourceRect")
                }
                result.success(null)
            }
            "enter" -> result.success(enterManually())
            "disableAutoEnter" -> {
                disableAutoEnter()
                result.success(null)
            }
            "updateActions" -> {
                isLive = call.argument<Boolean>("isLive") ?: isLive
                isPlaying = call.argument<Boolean>("isPlaying") ?: isPlaying
                if (available && phase != Phase.IDLE) {
                    applyParams("updateActions")
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun updateConfiguration(call: MethodCall) {
        val width = max(1, call.argument<Int>("videoWidth") ?: 16)
        val height = max(1, call.argument<Int>("videoHeight") ?: 9)
        aspectRatio = constrainedRatio(width, height)
        isLive = call.argument<Boolean>("isLive") ?: false
        isPlaying = call.argument<Boolean>("isPlaying") ?: false
        autoEnter = call.argument<Boolean>("autoEnter") == true
        updateSourceRect(call)
        trace(
            "configuration ratio=${aspectRatio.numerator}:${aspectRatio.denominator} " +
                "auto=$autoEnter live=$isLive playing=$isPlaying source=$sourceRect",
        )
    }

    private fun updateSourceRect(call: MethodCall) {
        val left = call.argument<Int>("left")
        val top = call.argument<Int>("top")
        val width = call.argument<Int>("width")
        val height = call.argument<Int>("height")
        sourceRect = if (left != null && top != null && width != null && height != null &&
            left >= 0 && top >= 0 && width > 0 && height > 0
        ) {
            Rect(left, top, left + width, top + height)
        } else {
            null
        }
        trace(
            "sourceRect=$sourceRect phase=${phase.wireValue} " +
                "frozen=${transitionSourceRect != null}",
        )
    }

    private fun constrainedRatio(width: Int, height: Int): Rational {
        val ratio = width.toDouble() / height.toDouble()
        if (ratio < MIN_ASPECT || ratio > MAX_ASPECT) {
            return if (height > width) Rational(9, 16) else Rational(16, 9)
        }
        return Rational(width, height)
    }

    private fun buildParams(enableAutoEnter: Boolean = autoEnter): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(aspectRatio)

        // Android 12+ reuses this value for the exit animation. Never replace
        // it with the coordinates of a resized PiP task.
        (transitionSourceRect ?: sourceRect)?.let(builder::setSourceRectHint)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder
                .setAutoEnterEnabled(enableAutoEnter && isPlaying)
                .setSeamlessResizeEnabled(true)
        }
        buildActions()?.let(builder::setActions)
        return builder.build()
    }

    private fun applyParams(reason: String): Boolean {
        if (!available) return false
        return try {
            activity.setPictureInPictureParams(buildParams())
            trace(
                "paramsApplied reason=$reason phase=${phase.wireValue} " +
                    "hint=${transitionSourceRect ?: sourceRect}",
            )
            true
        } catch (error: Throwable) {
            trace("paramsFailed reason=$reason error=$error", error)
            false
        }
    }

    private fun buildActions(): List<RemoteAction>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return null
        val receiver: ComponentName = MediaHelper.getMediaButtonReceiverComponent(activity)
            ?: return null
        val actions = ArrayList<RemoteAction>(3)
        if (!isLive) {
            remoteAction(
                receiver,
                R.drawable.ic_player_rewind_10s,
                "ACTION_REWIND",
                PlaybackState.ACTION_REWIND.toInt(),
            )?.let(actions::add)
        }
        remoteAction(
            receiver,
            if (isPlaying) R.drawable.ic_player_pause else R.drawable.ic_player_play,
            if (isPlaying) "ACTION_PAUSE" else "ACTION_PLAY",
            if (isPlaying) PlaybackState.ACTION_PAUSE.toInt() else PlaybackState.ACTION_PLAY.toInt(),
        )?.let(actions::add)
        if (!isLive) {
            remoteAction(
                receiver,
                R.drawable.ic_player_fast_forward_10s,
                "ACTION_FAST_FORWARD",
                PlaybackState.ACTION_FAST_FORWARD.toInt(),
            )?.let(actions::add)
        }
        return actions
    }

    private fun remoteAction(
        receiver: ComponentName,
        iconResource: Int,
        title: String,
        action: Int,
    ): RemoteAction? {
        val pendingIntent = MediaHelper.buildMediaButtonPendingIntent(activity, receiver, action)
            ?: return null
        return RemoteAction(
            Icon.createWithResource(activity, iconResource),
            title,
            title,
            pendingIntent,
        )
    }

    private fun enterManually(): Boolean {
        if (!available || phase != Phase.IDLE) return false
        autoEnter = false
        beginEnter("manual")
        return try {
            val entered = activity.enterPictureInPictureMode(buildParams(enableAutoEnter = false))
            trace("manualEnter result=$entered")
            if (!entered) finishExit("manualRejected")
            entered
        } catch (error: Throwable) {
            trace("manualEnter failed error=$error", error)
            finishExit("manualException")
            false
        }
    }

    fun onUserLeaveHint() {
        trace("userLeaveHint auto=$autoEnter playing=$isPlaying phase=${phase.wireValue}")
        if (!available || !autoEnter || !isPlaying || phase != Phase.IDLE) return
        beginEnter("userLeaveHint")
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            try {
                val entered = activity.enterPictureInPictureMode(buildParams(enableAutoEnter = false))
                trace("legacyAutoEnter result=$entered")
                if (!entered) finishExit("legacyAutoRejected")
            } catch (error: Throwable) {
                trace("legacyAutoEnter failed error=$error", error)
                finishExit("legacyAutoException")
            }
        }
    }

    fun onPictureInPictureUiStateChanged(pipState: PictureInPictureUiState) {
        if (Build.VERSION.SDK_INT >= 35 && pipState.isTransitioningToPip) {
            trace("uiState transitioningToPip=true")
            beginEnter("uiState")
        }
    }

    fun onPictureInPictureModeChanged(inPictureInPictureMode: Boolean) {
        trace("modeChanged inPip=$inPictureInPictureMode phase=${phase.wireValue}")
        if (inPictureInPictureMode) {
            if (phase == Phase.IDLE) beginEnter("modeChangedFallback")
            setPhase(Phase.ACTIVE, "modeChanged")
        } else {
            finishExit("modeChanged")
        }
    }

    private fun beginEnter(reason: String) {
        if (phase != Phase.IDLE) return
        generation += 1
        transitionSourceRect = sourceRect?.let(::Rect)
        setPhase(Phase.ENTERING, reason)
        trace("enterBounds generation=$generation rect=$transitionSourceRect")
    }

    private fun finishExit(reason: String) {
        if (phase == Phase.IDLE) return
        transitionSourceRect = null
        setPhase(Phase.IDLE, reason)
    }

    private fun disableAutoEnter() {
        autoEnter = false
        isPlaying = false
        if (available && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            applyParams("disableAutoEnter")
        }
    }

    private fun setPhase(newPhase: Phase, reason: String) {
        if (phase == newPhase) return
        val previous = phase
        phase = newPhase
        trace("phase ${previous.wireValue}->${newPhase.wireValue} reason=$reason generation=$generation")
        channel.invokeMethod(
            "stateChanged",
            mapOf(
                "phase" to newPhase.wireValue,
                "generation" to generation,
                "reason" to reason,
            ),
        )
    }

    fun destroy() {
        trace("destroy")
        channel.setMethodCallHandler(null)
    }

    private fun trace(message: String, error: Throwable? = null) {
        if (error == null) {
            Log.d(TAG, "[PIP_NATIVE] $message")
        } else {
            Log.e(TAG, "[PIP_NATIVE] $message", error)
        }
    }

    companion object {
        private const val CHANNEL_NAME = "com.personal.piliplus/pip"
        private const val TAG = "PiliPlusPiP"
        private const val MIN_ASPECT = 1.0 / 2.39
        private const val MAX_ASPECT = 2.39
    }
}
