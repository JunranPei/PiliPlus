package com.personal.piliplus

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Diagnostic APK only. DUMP is granted to adb shell, not ordinary apps. */
class DiagnosticControlBridge(private val activity: Activity, private val channel: MethodChannel) : BroadcastReceiver() {
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    init {
        val filter = IntentFilter("com.personal.piliplus.DIAGNOSTIC_CONTROL")
        if (Build.VERSION.SDK_INT >= 33) activity.registerReceiver(this, filter, "android.permission.DUMP", null, Context.RECEIVER_EXPORTED)
        else activity.registerReceiver(this, filter, "android.permission.DUMP", null)
    }
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra("requestId") ?: return
        if (!id.matches(Regex("[a-zA-Z0-9-]{1,64}"))) return
        val command = intent.getStringExtra("command") ?: return
        if (command !in setOf("status", "seek", "play", "pause", "export", "audio-output", "controls", "fullscreen", "pip", "speed")) return
        val args = mapOf("requestId" to id, "command" to command,
            "positionMs" to intent.getLongExtra("positionMs", 0), "value" to intent.getStringExtra("value"))
        val finished = AtomicBoolean(false)
        fun save(status: String, value: Any?) {
            if (io.isShutdown) return
            val record = JSONObject(mapOf("requestId" to id, "command" to command,
                "status" to status, "utcMs" to System.currentTimeMillis(), "result" to value)).toString()
            io.execute {
                val folder = File(activity.getExternalFilesDir(null), "playback-diagnostics").apply { mkdirs() }
                val target = File(folder, "control-$id.json")
                val pending = File(folder, "control-$id.tmp")
                pending.writeText(record)
                check(pending.renameTo(target))
            }
        }
        save("accepted", args)
        main.postDelayed({ if (finished.compareAndSet(false, true)) save("timeout", "Dart did not reply within 15 seconds") }, 15000)
        channel.invokeMethod("cli.command", args, object : MethodChannel.Result {
            override fun success(result: Any?) { if (finished.compareAndSet(false, true)) save("complete", result) }
            override fun error(code: String, message: String?, details: Any?) { if (finished.compareAndSet(false, true)) save("error", mapOf("code" to code, "message" to message)) }
            override fun notImplemented() { if (finished.compareAndSet(false, true)) save("error", "CLI handler unavailable") }
        })
    }
    fun dispose() { activity.unregisterReceiver(this); io.shutdown() }
}
