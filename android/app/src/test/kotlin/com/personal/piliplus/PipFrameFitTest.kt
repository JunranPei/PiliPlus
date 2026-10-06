package com.personal.piliplus

import android.app.Application
import android.graphics.Rect
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE, application = Application::class)
@GraphicsMode(GraphicsMode.Mode.LEGACY)
class PipFrameFitTest {
    @Test fun largeVideoRegionShrinksButMatchingSmallImageNeedsNoCompression() {
        val large = PipFrameFit.calculate(1080, 2401, 598, 336, Rect(0, 63, 1080, 670))
        assertEquals(336f / 607, large.scale, .00001f)
        assertEquals(-63 * large.scale, large.y, .00001f)
        val small = PipFrameFit.calculate(598, 337, 598, 336)
        assertEquals(1f, small.scale, 0f)
        assertEquals(Rect(0, 0, 598, 336), small.crop)
        assertEquals(0f, small.x, 0f)
        assertEquals(0f, small.y, 0f)
    }

    @Test fun smallFrameOnReturnFillsOriginalVideoRegionInsteadOfWholePage() {
        val target = Rect(0, 63, 1080, 670)
        val fit = PipFrameFit.calculate(598, 337, 1080, 2400, destination = target)
        assertEquals(1080f / 598, fit.scale, .0001f)
        assertTrue(fit.y >= 63)
        assertTrue(fit.y + 336 * fit.scale <= 670.001f)
    }
}
