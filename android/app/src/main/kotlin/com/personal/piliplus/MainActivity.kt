package com.personal.piliplus

import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.view.WindowManager.LayoutParams
import com.ryanheise.audioservice.AudioServiceActivity

class MainActivity : AudioServiceActivity() {
    private var pipCoordinator: PipCoordinator? = null
    private var playbackDiagnostics: PlaybackDiagnostics? = null


    override fun configureFlutterEngine(flutterEngine: io.flutter.embedding.engine.FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pipCoordinator = PipCoordinator(this, flutterEngine.dartExecutor.binaryMessenger)
        playbackDiagnostics = PlaybackDiagnostics(this, flutterEngine.dartExecutor.binaryMessenger, flutterEngine)
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
        playbackDiagnostics?.dispose()
        playbackDiagnostics = null
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
}
