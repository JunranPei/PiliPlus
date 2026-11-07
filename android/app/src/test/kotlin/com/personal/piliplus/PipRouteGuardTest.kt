package com.personal.piliplus

import android.app.Activity
import android.app.Application
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE, application = Application::class)
@GraphicsMode(GraphicsMode.Mode.LEGACY)
class PipRouteGuardTest {
    private class Messenger : BinaryMessenger {
        override fun send(channel: String, message: ByteBuffer?) {}
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {}
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {}
    }
    private class Result : MethodChannel.Result {
        var value: Any? = null
        override fun success(result: Any?) { value = result }
        override fun error(code: String, message: String?, details: Any?) { fail(code) }
        override fun notImplemented() { fail("notImplemented") }
    }
    private fun call(pip: PipCoordinator, method: String, args: Map<String, Any?> = emptyMap()): Any? {
        val result = Result()
        pip.onMethodCall(MethodCall(method, args), result)
        return result.value
    }
    @Test fun homeRejectsLateVideoCommandsAndRouteUpdates() {
        val pip = PipCoordinator(Robolectric.buildActivity(Activity::class.java).setup().get(), Messenger())
        call(pip, "setPlaybackRoute", mapOf("route" to "/videoV", "revision" to 1))
        call(pip, "setPlaybackRoute", mapOf("route" to "/", "revision" to 2))
        // A late playback completion must not re-arm auto entry on Home.
        for (method in listOf("configure", "enter", "updateActions", "setSourceRect")) {
            assertEquals(false, call(pip, method, mapOf("routeRevision" to 1, "autoEnter" to true, "isPlaying" to true)))
        }
        call(pip, "setPlaybackRoute", mapOf("route" to "/videoV", "revision" to 1))
        val state = call(pip, "getState") as Map<*, *>
        assertEquals(false, state["routeAllowed"])
        assertEquals("/", state["route"])
        assertEquals(2, state["routeRevision"])
        pip.onUserLeaveHint()
        assertEquals("idle", (call(pip, "getState") as Map<*, *>)["phase"])
        pip.destroy()
    }
    @Test fun previousVideoCannotControlNewVideo() {
        val pip = PipCoordinator(Robolectric.buildActivity(Activity::class.java).setup().get(), Messenger())
        call(pip, "setPlaybackRoute", mapOf("route" to "/videoV", "revision" to 3))
        assertEquals(false, call(pip, "updateActions", mapOf("routeRevision" to 1, "isPlaying" to true)))
        assertEquals(true, call(pip, "updateActions", mapOf("routeRevision" to 3, "isPlaying" to true)))
        pip.destroy()
    }
}
