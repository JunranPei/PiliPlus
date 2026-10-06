package com.personal.piliplus

import android.app.Activity
import android.app.Application
import android.content.pm.ApplicationInfo
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE, application = Application::class)
@GraphicsMode(GraphicsMode.Mode.LEGACY)
class PipDiagnosticsTest {
    @Test fun brokenStateProbeCannotEscapeIntoAndroidLifecycle() {
        val controller = Robolectric.buildActivity(Activity::class.java).setup()
        val activity = controller.get()
        activity.applicationInfo.flags = activity.applicationInfo.flags or ApplicationInfo.FLAG_DEBUGGABLE
        val trace = PipDiagnostics(activity) { throw IllegalStateException("broken diagnostic state") }
        trace.event("test")
        trace.snapshot("test", true)
        trace.dispose()
        controller.pause().stop().destroy()
    }
}
