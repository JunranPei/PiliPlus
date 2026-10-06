package com.personal.piliplus

import android.view.Surface
import androidx.annotation.Keep

@Keep
object PipBufferGeometry {
    init { System.loadLibrary("pip_buffer_geometry") }
    @JvmStatic external fun resize(surface: Surface, width: Int, height: Int): Int
}
