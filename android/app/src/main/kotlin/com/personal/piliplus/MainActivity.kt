package com.personal.piliplus

import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.view.WindowManager.LayoutParams
import com.ryanheise.audioservice.AudioServiceActivity

class MainActivity : AudioServiceActivity() {
    private var pipCoordinator: PipCoordinator? = null


    override fun configureFlutterEngine(flutterEngine: io.flutter.embedding.engine.FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pipCoordinator = PipCoordinator(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (AndroidHelper.isFoldable) {
            AndroidHelper.ToDart.onConfigurationChanged?.run()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
    }

    override fun onDestroy() {
        pipCoordinator?.destroy()
        pipCoordinator = null
        // AudioService owns the FlutterEngine used by this Activity. Stopping
        // it here can race FlutterActivity's detach on devices which reclaim
        // background activities aggressively, leaving a destroyed cached
        // engine behind for the next launcher tap. The plugin will unbind and
        // stop the service itself when playback is inactive.
        super.onDestroy()
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        pipCoordinator?.onUserLeaveHint()
    }

    override fun onResume() {
        super.onResume()
        pipCoordinator?.onResume()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration?) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pipCoordinator?.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
    }

    override fun onPictureInPictureUiStateChanged(state: android.app.PictureInPictureUiState) {
        super.onPictureInPictureUiStateChanged(state)
        pipCoordinator?.onPictureInPictureUiStateChanged(state)
    }
}
