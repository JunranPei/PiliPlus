package com.personal.piliplus

import android.app.Application
import android.app.Activity
import android.graphics.Rect
import android.view.View
import android.os.Looper
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Robolectric
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE, application = Application::class)
@GraphicsMode(GraphicsMode.Mode.LEGACY)
class PipRenderHostTest {
    private val source = Rect(0, 24, 400, 249)

    private fun layout(host: View, width: Int, height: Int) {
        host.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY))
        host.layout(0, 0, width, height)
    }

    @Test fun enteringBeforeResizeAcceptsNullClip() {
        val view = View(RuntimeEnvironment.getApplication())
        val events = mutableListOf<Map<String, Any?>>()
        val host = PipRenderHost(view.context, view, { _, data -> events.add(data) }, {})
        layout(host, 400, 900)
        assertTrue(host.enter(source))
        // Actual crash path: ENTERING has arrived but window is still normal.
        layout(host, 400, 900)
        assertTrue(host.locked)
        assertNull(view.clipBounds)
        assertNull(events.last()["clip"])
        assertEquals(1f, view.scaleX, 0f)
    }

    @Test fun pipMeasuresSameChildAtNormalSizeAndFitsFrozenSource() {
        val view = View(RuntimeEnvironment.getApplication())
        val host = PipRenderHost(view.context, view, { _, _ -> }, {})
        layout(host, 400, 900)
        host.enter(source)
        layout(host, 228, 128)
        assertSame(view, host.getChildAt(0))
        assertEquals(400, view.measuredWidth)
        assertEquals(900, view.measuredHeight)
        assertEquals(source, view.clipBounds)
        assertEquals(128f / 225, view.scaleX, .0001f)
        assertEquals(-24 * view.scaleX, view.translationY, .0001f)
        assertTrue(view.translationX >= 0)
    }

    @Test fun exitHoldsSmallBoundsAndReleasesOnRestoredRotatedWindow() {
        val view = View(RuntimeEnvironment.getApplication())
        var released = 0
        val host = PipRenderHost(view.context, view, { _, _ -> }, { released++ })
        // View.post queues work until attachment. Exercise the real attached
        // lifecycle rather than a detached fixture whose post never runs.
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        activity.setContentView(host)
        shadowOf(Looper.getMainLooper()).idle()
        layout(host, 400, 900)
        val location = IntArray(2)
        view.getLocationInWindow(location)
        host.enter(Rect(source).apply { offset(location[0], location[1]) })
        layout(host, 228, 128)
        host.exit()
        layout(host, 228, 128)
        assertTrue(host.locked)
        assertEquals(0, released)
        layout(host, 900, 400)
        assertFalse(host.locked)
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(1, released)
        assertNull(view.clipBounds)
        assertEquals(1f, view.scaleX, 0f)
        layout(host, 900, 400)
        assertEquals(900, view.measuredWidth)
        assertEquals(400, view.measuredHeight)
    }

    @Test fun brokenDiagnosticDeliveryDoesNotAbortEntryLayoutOrExit() {
        val view = View(RuntimeEnvironment.getApplication())
        val host = PipRenderHost(view.context, view,
            { _, _ -> throw IllegalStateException("simulated diagnostic failure") }, {})
        layout(host, 400, 900)
        assertFalse(host.enter(null))
        assertTrue(host.enter(source))
        layout(host, 400, 900)
        layout(host, 228, 128)
        host.exit()
        layout(host, 400, 900)
        assertFalse(host.locked)
    }
}
