package com.personal.piliplus

import android.content.Context
import android.graphics.Rect
import android.os.Build
import android.view.View
import android.view.WindowInsets
import android.widget.FrameLayout
import kotlin.math.min

/** Keeps Flutter's render buffer unchanged while the Activity enters PiP.
 * Only this Android view hierarchy applies the video crop; Dart keeps its
 * original page geometry. There is no bitmap, player or Surface replacement.
 */
class PipRenderHost(
    context: Context,
    private val flutter: View,
    private val reportEvent: (String, Map<String, Any?>) -> Unit,
    private val changed: () -> Unit,
) : FrameLayout(context) {
    var locked = false
        private set
    private var exiting = false
    private var normalWidth = 0
    private var normalHeight = 0
    private var normalTopInset = 0
    private var normalBottomInset = 0
    private var normalBarsVisible = 0
    private var crop: Rect? = null

    init {
        clipChildren = true
        clipToPadding = true
        setBackgroundColor(android.graphics.Color.BLACK)
        addView(flutter, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
    }

    fun enter(source: Rect?): Boolean {
        if (locked) { exiting = false; return true }
        if (source == null || source.isEmpty || flutter.width <= 0 || flutter.height <= 0) {
            report("rejected") { mapOf("source" to source?.toString()) }
            return false
        }
        normalWidth = flutter.width
        normalHeight = flutter.height
        val location = IntArray(2)
        flutter.getLocationInWindow(location)
        crop = Rect(source).apply { offset(-location[0], -location[1]) }
        @Suppress("DEPRECATION")
        normalTopInset = rootWindowInsets?.systemWindowInsetTop ?: 0
        @Suppress("DEPRECATION")
        normalBottomInset = rootWindowInsets?.systemWindowInsetBottom ?: 0
        if (Build.VERSION.SDK_INT >= 30) {
            normalBarsVisible = barsVisible(rootWindowInsets)
        }
        locked = true
        exiting = false
        report("locked") { mapOf("buffer" to "${normalWidth}x$normalHeight", "crop" to crop?.toString()) }
        requestLayout()
        return true
    }

    fun exit() {
        if (!locked) return
        exiting = true
        requestLayout()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        if (!locked) {
            super.onMeasure(widthMeasureSpec, heightMeasureSpec)
            return
        }
        setMeasuredDimension(View.MeasureSpec.getSize(widthMeasureSpec), View.MeasureSpec.getSize(heightMeasureSpec))
        flutter.measure(
            View.MeasureSpec.makeMeasureSpec(normalWidth, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(normalHeight, View.MeasureSpec.EXACTLY),
        )
    }

    override fun onLayout(changedBounds: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        if (!locked) {
            super.onLayout(changedBounds, left, top, right, bottom)
            return
        }
        flutter.layout(0, 0, normalWidth, normalHeight)
        val reduced = width < normalWidth * .9 && height < normalHeight * .9
        val source = crop!!
        if (reduced) {
            val scale = min(width.toFloat() / source.width(), height.toFloat() / source.height())
            flutter.pivotX = 0f
            flutter.pivotY = 0f
            flutter.scaleX = scale
            flutter.scaleY = scale
            flutter.translationX = (width - source.width() * scale) / 2f - source.left * scale
            flutter.translationY = (height - source.height() * scale) / 2f - source.top * scale
            flutter.clipBounds = source
        } else {
            resetTransform()
            releaseIfRestored()
        }
        report("layout") { mapOf(
            "host" to "${width}x$height", "buffer" to "${flutter.width}x${flutter.height}",
            "locked" to locked, "exiting" to exiting, "reduced" to reduced,
            "scale" to flutter.scaleX, "x" to flutter.translationX, "y" to flutter.translationY,
            "clip" to flutter.clipBounds?.toString(),
        ) }
    }

    override fun onApplyWindowInsets(insets: WindowInsets): WindowInsets {
        val result = super.onApplyWindowInsets(insets)
        post { releaseIfRestored() }
        return result
    }

    private fun releaseIfRestored() {
        if (!locked || !exiting || min(width, height) < min(normalWidth, normalHeight) * .9 ||
            maxOf(width, height) < maxOf(normalWidth, normalHeight) * .9) return
        val insets = rootWindowInsets
        @Suppress("DEPRECATION")
        val top = insets?.systemWindowInsetTop ?: 0
        @Suppress("DEPRECATION")
        val bottom = insets?.systemWindowInsetBottom ?: 0
        // Do not expose the intermediate zero-inset full-window frame to Dart.
        if (Build.VERSION.SDK_INT >= 30) {
            if (barsVisible(insets) != normalBarsVisible) return
        } else if (top != normalTopInset || bottom != normalBottomInset) return
        locked = false
        exiting = false
        resetTransform()
        report("released") { mapOf("host" to "${width}x$height", "top" to top, "bottom" to bottom) }
        // View.layout clears FORCE_LAYOUT after onLayout returns. Requesting
        // another measurement inside that callback can therefore be lost,
        // leaving the frozen child size cached on a rotated exit.
        post {
            flutter.requestLayout()
            requestLayout()
            changed()
        }
    }

    private fun resetTransform() {
        flutter.scaleX = 1f
        flutter.scaleY = 1f
        flutter.translationX = 0f
        flutter.translationY = 0f
        flutter.clipBounds = null
    }

    private fun report(name: String, data: () -> Map<String, Any?>) {
        // Protect both data collection and delivery. A diagnostic-only null
        // or broken writer must never abort Android's layout traversal.
        try {
            reportEvent(name, data())
        } catch (error: Exception) {
            android.util.Log.e("PiliPlusPiPTrace", "renderHost trace failed: $name", error)
        }
    }

    @androidx.annotation.RequiresApi(30)
    private fun barsVisible(insets: WindowInsets?): Int =
        (if (insets?.isVisible(WindowInsets.Type.statusBars()) == true) 1 else 0) or
            (if (insets?.isVisible(WindowInsets.Type.navigationBars()) == true) 2 else 0)
}
