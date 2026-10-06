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
    private var active = false
    private var handoff: PipFrameHandoff? = null
    private var heldSurface: io.flutter.embedding.android.FlutterSurfaceView? = null
    val frameRequest: Map<String, Any>? get() =
        if (Build.VERSION.SDK_INT >= 33) handoff?.request?.state() else null

    fun warmUpWhenReady() {
        if (Build.VERSION.SDK_INT < 33) return
        fun find(view: View): io.flutter.embedding.android.FlutterSurfaceView? {
            if (view is io.flutter.embedding.android.FlutterSurfaceView) return view
            if (view is android.view.ViewGroup) for (index in 0 until view.childCount) {
                find(view.getChildAt(index))?.let { return it }
            }
            return null
        }
        val original = find(flutter) ?: return
        val renderer = original.attachedRenderer ?: return
        fun warmUp() {
            postOnAnimation {
                if (!isAttachedToWindow || handoff != null || locked) return@postOnAnimation
                try {
                    heldSurface = original
                    handoff = PipFrameHandoff(this, original, renderer,
                        { name, data -> report("handoff.$name") { data } }, changed,
                        { if (locked && width < normalWidth * .9 && height < normalHeight * .9) crop else null },
                        { if (active) prepareHandoff() }, ::restoredVideoDestination)
                    handoff?.resize(width, height, false)
                } catch (error: Exception) {
                    report("handoff.setupFailed") { mapOf("error" to error.toString()) }
                }
            }
        }
        if (renderer.isDisplayingFlutterUi) warmUp()
        else renderer.addIsDisplayingFlutterUiListener(object : io.flutter.embedding.engine.renderer.FlutterUiDisplayListener {
            override fun onFlutterUiDisplayed() { renderer.removeIsDisplayingFlutterUiListener(this); warmUp() }
            override fun onFlutterUiNoLongerDisplayed() {}
        })
    }

    fun active(value: Boolean) {
        active = value
        if (value) prepareHandoff()
    }

    private fun prepareHandoff() {
        if (Build.VERSION.SDK_INT < 33 || !active || !locked || exiting ||
            width >= normalWidth * .9 || height >= normalHeight * .9) return
        val expectedWidth = width
        val expectedHeight = height
        // Require consecutive settled layout frames, rather than a fixed delay.
        postOnAnimation {
            if (!active || !locked || exiting || width != expectedWidth || height != expectedHeight ||
                width >= normalWidth * .9 || height >= normalHeight * .9) return@postOnAnimation
            try {
                if (handoff == null) {
                    fun surface(view: View): io.flutter.embedding.android.FlutterSurfaceView? {
                        if (view is io.flutter.embedding.android.FlutterSurfaceView) return view
                        if (view is android.view.ViewGroup) for (index in 0 until view.childCount) {
                            surface(view.getChildAt(index))?.let { return it }
                        }
                        return null
                    }
                    val original = surface(flutter) ?: return@postOnAnimation
                    heldSurface = original
                    val renderer = original.attachedRenderer ?: return@postOnAnimation
                    handoff = PipFrameHandoff(this, original, renderer,
                        { name, data -> report("handoff.$name") { data } }, changed,
                        { if (locked && width < normalWidth * .9 && height < normalHeight * .9) crop else null },
                        {
                            if (active) prepareHandoff()
                        }, ::restoredVideoDestination)
                }
                val bridge = handoff ?: return@postOnAnimation
                if (!bridge.started) {
                    // Freeze only the old SurfaceView's geometry. This lets us
                    // go directly to the small buffer, without rendering an
                    // extra full-page ImageReader buffer first.
                    bridge.resize(width, height, true)
                } else if (bridge.hasFrame) {
                    bridge.resize(width, height, true)
                }
            } catch (error: Exception) {
                report("handoff.setupFailed") { mapOf("error" to error.toString()) }
            }
        }
    }

    fun dispose() {
        if (Build.VERSION.SDK_INT >= 33) handoff?.dispose()
    }

    private fun restoredVideoDestination(): Rect? {
        val source = crop ?: return null
        if (active || normalWidth <= 0 || normalHeight <= 0 ||
            min(width, height) < min(normalWidth, normalHeight) * .9 ||
            maxOf(width, height) < maxOf(normalWidth, normalHeight) * .9) return null
        return Rect(
            source.left * width / normalWidth, source.top * height / normalHeight,
            source.right * width / normalWidth, source.bottom * height / normalHeight)
    }

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
        active = false
        exiting = true
        requestLayout()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        if (Build.VERSION.SDK_INT >= 33 && handoff?.started == true) {
            // Flutter's content-size listener mutates SurfaceView LayoutParams.
            // Override those while its OLD buffer remains visible, BEFORE the
            // child is measured. Once the new buffer is visible, release it.
            heldSurface?.layoutParams?.apply {
                width = if (locked) normalWidth else View.MeasureSpec.getSize(widthMeasureSpec)
                height = if (locked) normalHeight else View.MeasureSpec.getSize(heightMeasureSpec)
            }
        }
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
            if (Build.VERSION.SDK_INT >= 33 && handoff?.started == true) {
                handoff?.resize(width, height, false)
            }
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
        if (Build.VERSION.SDK_INT >= 33) {
            handoff?.geometry()
            if (!reduced && handoff?.started == true && !locked) handoff?.resize(width, height, false)
        }
        prepareHandoff()
    }

    override fun onApplyWindowInsets(insets: WindowInsets): WindowInsets {
        val result = super.onApplyWindowInsets(insets)
        post {
            releaseIfRestored()
            if (Build.VERSION.SDK_INT >= 33 && handoff?.started == true) {
                if (active) {
                    // Mode/insets callbacks can precede the window resize.
                    // Never label a full-window scene as the small PiP scene.
                    handoff?.refreshMetrics()
                    prepareHandoff()
                }
                else if (!locked) handoff?.resize(width, height, false)
            }
        }
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
