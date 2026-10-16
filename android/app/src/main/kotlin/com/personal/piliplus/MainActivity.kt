package com.personal.piliplus

import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.view.MotionEvent
import android.view.WindowManager.LayoutParams
import android.view.WindowInsets
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.media3.common.PlaybackException
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private var pipCoordinator: PipCoordinator? = null
    private var playbackDiagnostics: PlaybackDiagnostics? = null
    private var media3Channel: MethodChannel? = null
    private var media3Overlay: PlayerView? = null
    private var media3OverlayPlayer: ExoPlayer? = null
    private var media3OverlayKey: String? = null


    override fun configureFlutterEngine(flutterEngine: io.flutter.embedding.engine.FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pipCoordinator = PipCoordinator(this, flutterEngine.dartExecutor.binaryMessenger)
        playbackDiagnostics = PlaybackDiagnostics(this, flutterEngine.dartExecutor.binaryMessenger, flutterEngine)
        media3Channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MEDIA3_CHANNEL).also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method == "preloadApi") {
                    val bvid = call.argument<String>("bvid")
                    val cid = call.argument<Number>("cid")?.toLong()
                    if (bvid.isNullOrBlank() || cid == null || cid <= 0L) {
                        result.error("INVALID_ARGUMENT", "bvid and cid are required", null)
                        return@setMethodCallHandler
                    }
                    Media3PlayerManager.preloadApi(this, bvid, cid)
                    result.success(null)
                    return@setMethodCallHandler
                }
                if (call.method != "launch" && call.method != "preload") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val args = readMedia3Args(call)
                if (args == null) {
                    result.error("INVALID_ARGUMENT", "bvid and cid are required", null)
                    return@setMethodCallHandler
                }
                if (call.method == "preload") {
                    Media3PlayerManager.preload(this, args)
                    Media3PlayerManager.peek()?.let {
                        showWarmMedia3Overlay(it, args.videoUrl, args.videoWidth, args.videoHeight)
                    }
                } else {
                    if (media3OverlayPlayer != null && media3Overlay != null) {
                        revealWarmMedia3Overlay()
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    val reused = args.videoUrl?.let { Media3PlayerManager.take(it) }
                        ?: Media3PlayerManager.takeAny()
                    if (reused != null) {
                        if (media3OverlayPlayer === reused && media3Overlay != null) {
                            media3Overlay?.alpha = 1f
                            media3Overlay?.isClickable = true
                            media3Overlay?.isEnabled = true
                            reused.volume = 1f
                            reused.playWhenReady = true
                            android.util.Log.i("Media3Overlay", "reveal")
                        } else {
                            showMedia3Overlay(reused, args.videoWidth, args.videoHeight)
                        }
                    } else {
                        startActivity(Intent(this, Media3ProbeActivity::class.java).apply {
                            putExtra("bvid", args.bvid)
                            putExtra("cid", args.cid)
                            putExtra("video_url", args.videoUrl)
                            putExtra("audio_url", args.audioUrl)
                            putExtra("video_segment_base", args.videoSegmentBase)
                            putExtra("audio_segment_base", args.audioSegmentBase)
                            putExtra("video_codecs", args.videoCodecs)
                            putExtra("video_width", args.videoWidth)
                            putExtra("video_height", args.videoHeight)
                            putExtra("audio_codecs", args.audioCodecs)
                            putExtra("duration_ms", args.durationMs)
                        })
                    }
                }
                result.success(null)
            }
        }
    }

    private fun showMedia3Overlay(player: ExoPlayer, videoWidth: Int, videoHeight: Int) {
        closeMedia3Overlay()
        val view = PlayerView(this).apply {
            useController = false
            this.player = player
            setBackgroundColor(android.graphics.Color.BLACK)
            alpha = 1f
            isClickable = false
            isFocusable = false
            isEnabled = false
        }
        player.addListener(object : androidx.media3.common.Player.Listener {
            override fun onRenderedFirstFrame() {
                android.util.Log.i("Media3Overlay", "firstFrame")
            }

            override fun onPlayerError(error: PlaybackException) {
                android.util.Log.e("Media3Overlay", "playbackError=${error.errorCodeName}")
                closeMedia3Overlay()
            }
        })
        addContentView(view, videoLayoutParams(videoWidth, videoHeight))
        media3Overlay = view
        media3OverlayPlayer = player
        media3OverlayKey = null
        player.playWhenReady = true
    }

    private fun showWarmMedia3Overlay(
        player: ExoPlayer,
        key: String?,
        videoWidth: Int,
        videoHeight: Int,
    ) {
        if (media3OverlayPlayer === player && media3Overlay != null) return
        closeMedia3Overlay()
        val view = PlayerView(this).apply {
            useController = false
            this.player = player
            alpha = 0.01f
            isClickable = false
            isFocusable = false
            isEnabled = false
            setBackgroundColor(android.graphics.Color.TRANSPARENT)
        }
        addContentView(view, videoLayoutParams(videoWidth, videoHeight))
        media3Overlay = view
        media3OverlayPlayer = player
        media3OverlayKey = key
    }

    private fun videoLayoutParams(videoWidth: Int, videoHeight: Int): FrameLayout.LayoutParams {
        val metrics = resources.displayMetrics
        val width = metrics.widthPixels
        val ratio = if (videoWidth > 0 && videoHeight > 0) {
            videoHeight.toFloat() / videoWidth.toFloat()
        } else {
            9f / 16f
        }
        val height = (width * ratio).toInt().coerceAtMost(metrics.heightPixels)
        val topInset = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.decorView.rootWindowInsets?.getInsets(WindowInsets.Type.statusBars())?.top ?: 0
        } else {
            resources.getIdentifier("status_bar_height", "dimen", "android")
                .takeIf { it > 0 }
                ?.let(resources::getDimensionPixelSize) ?: 0
        }
        return FrameLayout.LayoutParams(-1, height).apply {
            topMargin = topInset
        }
    }

    private fun revealWarmMedia3Overlay() {
        val view = media3Overlay ?: return
        val player = media3OverlayPlayer ?: return
        media3OverlayKey?.let { Media3PlayerManager.take(it) }
        view.alpha = 1f
        view.isClickable = true
        view.isEnabled = true
        player.volume = 1f
        player.playWhenReady = true
        android.util.Log.i("Media3Overlay", "reveal.touch")
    }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        if (media3Overlay?.alpha != null &&
            media3Overlay!!.alpha < 1f &&
            event.action == MotionEvent.ACTION_UP &&
            event.y < 800f
        ) {
            revealWarmMedia3Overlay()
            return true
        }
        return super.dispatchTouchEvent(event)
    }

    private fun closeMedia3Overlay() {
        media3Overlay?.let { (it.parent as? ViewGroup)?.removeView(it) }
        media3Overlay = null
        media3OverlayPlayer?.release()
        media3OverlayPlayer = null
        media3OverlayKey = null
    }

    override fun onBackPressed() {
        if (media3Overlay != null) {
            closeMedia3Overlay()
            return
        }
        super.onBackPressed()
    }

    private fun readMedia3Args(call: io.flutter.plugin.common.MethodCall): Media3SourceArgs? {
        val bvid = call.argument<String>("bvid") ?: return null
        val cid = call.argument<Number>("cid")?.toLong()?.takeIf { it > 0L } ?: return null
        return Media3SourceArgs(
            bvid = bvid,
            cid = cid,
            videoUrl = call.argument<String>("videoUrl"),
            audioUrl = call.argument<String>("audioUrl"),
            videoSegmentBase = call.argument<String>("videoSegmentBase"),
            audioSegmentBase = call.argument<String>("audioSegmentBase"),
            videoCodecs = call.argument<String>("videoCodecs"),
            videoWidth = call.argument<Number>("videoWidth")?.toInt() ?: 0,
            videoHeight = call.argument<Number>("videoHeight")?.toInt() ?: 0,
            audioCodecs = call.argument<String>("audioCodecs"),
            durationMs = call.argument<Number>("durationMs")?.toLong() ?: 0L,
        )
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        pipCoordinator?.traceLifecycle("configurationChanged", newConfig)
        playbackDiagnostics?.lifecycle("configurationChanged", mapOf("configuration" to newConfig.toString()))
        if (AndroidHelper.isFoldable) {
            AndroidHelper.ToDart.onConfigurationChanged?.run()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pipCoordinator?.installRenderHost()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
    }

    override fun onDestroy() {
        closeMedia3Overlay()
        Media3PlayerManager.clear()
        playbackDiagnostics?.dispose()
        playbackDiagnostics = null
        media3Channel?.setMethodCallHandler(null)
        media3Channel = null
        pipCoordinator?.destroy()
        pipCoordinator = null
        stopService(Intent(this, com.ryanheise.audioservice.AudioService::class.java))
        super.onDestroy()
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        pipCoordinator?.onUserLeaveHint()
        playbackDiagnostics?.lifecycle("userLeaveHint")
    }

    override fun onResume() {
        super.onResume()
        pipCoordinator?.onResume()
        playbackDiagnostics?.lifecycle("resume")
    }

    override fun onPause() {
        pipCoordinator?.traceLifecycle("pause")
        playbackDiagnostics?.lifecycle("pause")
        super.onPause()
    }

    override fun onStop() {
        pipCoordinator?.traceLifecycle("stop")
        playbackDiagnostics?.lifecycle("stop")
        super.onStop()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        pipCoordinator?.traceLifecycle("focus:$hasFocus")
        playbackDiagnostics?.lifecycle("focus", mapOf("hasFocus" to hasFocus))
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration?) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pipCoordinator?.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        playbackDiagnostics?.lifecycle("pipMode", mapOf("active" to isInPictureInPictureMode, "configuration" to newConfig.toString()))
    }

    override fun onPictureInPictureUiStateChanged(state: android.app.PictureInPictureUiState) {
        super.onPictureInPictureUiStateChanged(state)
        pipCoordinator?.onPictureInPictureUiStateChanged(state)
    }

    companion object {
        private const val MEDIA3_CHANNEL = "com.personal.piliplus/media3"
    }
}
