package com.personal.piliplus

import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.view.WindowManager.LayoutParams
import android.view.MotionEvent
import com.ryanheise.audioservice.AudioServiceActivity

class MainActivity : AudioServiceActivity() {
    private var pipCoordinator: PipCoordinator? = null
    private var playbackDiagnostics: PlaybackDiagnostics? = null
    private var startupOrientationServices: StartupOrientationServices? = null
    private var startupCodecRegistry: StartupCodecRegistry? = null


    override fun configureFlutterEngine(flutterEngine: io.flutter.embedding.engine.FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pipCoordinator = PipCoordinator(this, flutterEngine.dartExecutor.binaryMessenger)
        playbackDiagnostics = PlaybackDiagnostics(this, flutterEngine.dartExecutor.binaryMessenger, flutterEngine)
        startupOrientationServices = StartupOrientationServices(this, flutterEngine.dartExecutor.binaryMessenger)
        startupCodecRegistry = StartupCodecRegistry(flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        pipCoordinator?.traceLifecycle("configurationChanged", newConfig)
        playbackDiagnostics?.lifecycle("configurationChanged", mapOf("configuration" to newConfig.toString()))
        if (AndroidHelper.isFoldable) {
            AndroidHelper.ToDart.onConfigurationChanged?.run()
        }
    }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        playbackDiagnostics?.observeTouch(event)
        return super.dispatchTouchEvent(event)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // AudioServiceActivity creates its cached engine without Activity shell
        // arguments. Opt into this fixed diagnostic flag before that engine is
        // created; only the profile manifest authorizes it.
        if (intent.getBooleanExtra("trace-skia", false)) {
            val info = packageManager.getApplicationInfo(
                packageName, android.content.pm.PackageManager.GET_META_DATA)
            if (info.metaData?.getBoolean("com.personal.piliplus.StartupTraceAllowed") == true) {
                val loader = io.flutter.FlutterInjector.instance().flutterLoader()
                loader.startInitialization(applicationContext)
                loader.ensureInitializationComplete(applicationContext,
                    arrayOf("--trace-skia", "--endless-trace-buffer"))
                android.util.Log.i("PiliPlaybackTrace", "profile full Skia tracing initialized before audio engine")
            }
        }
        super.onCreate(savedInstanceState)
        pipCoordinator?.installRenderHost()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
    }

    override fun onDestroy() {
        startupCodecRegistry?.dispose()
        startupCodecRegistry = null
        startupOrientationServices?.dispose()
        startupOrientationServices = null
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
