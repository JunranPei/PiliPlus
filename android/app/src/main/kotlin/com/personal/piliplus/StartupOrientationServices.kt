package com.personal.piliplus

import android.app.Activity
import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** Initializes service discovery only. Never registers a sensor or changes rotation. */
class StartupOrientationServices(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, "com.personal.piliplus/startup_services")
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { action ->
        Thread(action, "PiliSensorServiceWarmup").apply { isDaemon = true }
    }
    private var started = false
    private var disposed = false

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "prepareOrientationServices") {
                result.notImplemented()
            } else if (disposed || started) {
                result.success(mapOf("started" to false))
            } else {
                started = true
                worker.execute {
                    val begin = SystemClock.elapsedRealtimeNanos()
                    val response = try {
                        val manager = activity.getSystemService(Context.SENSOR_SERVICE) as SensorManager
                        val serviceReady = SystemClock.elapsedRealtimeNanos()
                        val sensor = manager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
                        val end = SystemClock.elapsedRealtimeNanos()
                        mapOf(
                            "started" to true,
                            "success" to true,
                            "getServiceMs" to (serviceReady - begin) / 1e6,
                            "getSensorMs" to (end - serviceReady) / 1e6,
                            "totalMs" to (end - begin) / 1e6,
                            "hasAccelerometer" to (sensor != null),
                            "sensorListenerRegistered" to false,
                        )
                    } catch (error: Exception) {
                        mapOf("started" to true, "success" to false,
                            "errorType" to error.javaClass.simpleName)
                    }
                    main.post {
                        if (!disposed) result.success(response)
                    }
                    worker.shutdown()
                }
            }
        }
    }

    fun dispose() {
        disposed = true
        channel.setMethodCallHandler(null)
        // Do not interrupt a system service call. At most one finite task exists;
        // it finishes without sending a reply to a destroyed Flutter engine.
        worker.shutdown()
    }
}
