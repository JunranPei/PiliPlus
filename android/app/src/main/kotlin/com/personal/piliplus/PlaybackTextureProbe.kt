package com.personal.piliplus

import android.os.SystemClock
import android.view.Surface
import com.alexmercerind.media_kit_video.MediaKitVideoPlugin
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.view.TextureRegistry
import java.lang.reflect.Field
import java.util.IdentityHashMap
import java.util.concurrent.atomic.AtomicLong

/**
 * Observes images consumed by Flutter's existing SurfaceTexture wrapper.
 *
 * This never acquires a buffer, renders, changes size, or replaces the producer's
 * onFrameAvailable callback. A consumed image is not a display-present fence.
 * Source hints describe the active request, not an independently proven identity
 * of pixels in that image. SurfaceTexture timestamps keep their producer's time
 * base; they must not be subtracted from nanoTime without a verified mapping.
 */
class PlaybackTextureProbe(
    private val engine: FlutterEngine,
    private val emit: (String, Map<String, Any?>) -> Unit,
    private val sourceHint: () -> Map<String, Any?> = { emptyMap() },
) {
    private val attached = IdentityHashMap<TextureRegistry.SurfaceTextureEntry, Observation>()
    private val reflectedFields = mutableMapOf<Class<*>, MutableMap<String, Field>>()
    private val reportedErrors = mutableSetOf<String>()
    private val consumedSequence = AtomicLong()
    @Volatile private var active = false
    @Volatile private var requestContext: Map<String, Any?> = emptyMap()

    /** Main thread only; caller owns the bounded diagnostic interval. */
    fun start() {
        active = true
        refresh()
    }

    /** Main thread only. Installs each entry once and discovers later players. */
    fun refresh() {
        if (!active) return
        try {
            requestContext = sourceHint().toMap()
            val plugin = engine.plugins.get(MediaKitVideoPlugin::class.java) ?: return
            val manager = field(plugin, "videoOutputManager").get(plugin) ?: return
            val lock = field(manager, "lock").get(manager) ?: return
            val outputs = synchronized(lock) {
                @Suppress("UNCHECKED_CAST")
                val map = field(manager, "videoOutputs").get(manager) as Map<Long, Any>
                map.entries.map { it.key to it.value }
            }
            val present = java.util.Collections.newSetFromMap(
                IdentityHashMap<TextureRegistry.SurfaceTextureEntry, Boolean>(),
            )
            for ((handle, output) in outputs) {
                val entry = field(output, "surfaceTextureEntry").get(output)
                    as TextureRegistry.SurfaceTextureEntry
                present.add(entry)
                if (!attached.containsKey(entry)) attach(handle, output, entry)
            }
            attached.keys.toList().filter { it !in present }.forEach { detach(it) }
        } catch (error: Exception) {
            reportError("discover", error)
        }
    }

    private fun attach(handle: Long, output: Any, entry: TextureRegistry.SurfaceTextureEntry) {
        // Reading the old callback is mandatory. If this implementation changes,
        // decline observation rather than replace a callback we cannot preserve.
        val listenerField = field(entry, "frameConsumedListener")
        val previous = listenerField.get(entry) as TextureRegistry.OnFrameConsumedListener?
        val observation = Observation(handle, output, entry, listenerField, previous)
        val listener = TextureRegistry.OnFrameConsumedListener {
            try {
                previous?.onFrameConsumed()
            } finally {
                if (active && observation.enabled) observation.consumed()
            }
        }
        observation.listener = listener
        var installed = false
        try {
            entry.setOnFrameConsumedListener(listener)
            installed = true
            if (listenerField.get(entry) !== listener) {
                throw IllegalStateException("SurfaceTexture entry did not retain consumed observer")
            }
            attached[entry] = observation
        } catch (error: Exception) {
            observation.enabled = false
            if (installed) {
                // Attachment and verification are synchronous on the main
                // thread. Recover from a verification-read failure too.
                val stillOurs = try { listenerField.get(entry) === listener }
                    catch (_: Exception) { true }
                if (stillOurs) try { entry.setOnFrameConsumedListener(previous) }
                    catch (_: Exception) { /* Original exception remains useful. */ }
            }
            throw error
        }
        safeEmit("texture.observerAttached", mapOf(
            "handle" to handle,
            "textureId" to entry.id(),
            "entryIdentity" to System.identityHashCode(entry),
            "textureIdentity" to System.identityHashCode(entry.surfaceTexture()),
            "previousListener" to (previous != null),
            "actualBufferSizeAvailable" to false,
            "timestampMeaning" to "producer-defined; latest image acquired by Flutter",
            "presentationFence" to false,
        ))
    }

    /** Main thread only. Never overwrite a replacement installed by somebody else. */
    fun stop() {
        active = false
        attached.keys.toList().forEach { detach(it) }
    }

    private fun detach(entry: TextureRegistry.SurfaceTextureEntry) {
        val observation = attached.remove(entry) ?: return
        observation.enabled = false
        try {
            val ours = observation.listenerField.get(entry) === observation.listener
            if (ours) entry.setOnFrameConsumedListener(observation.previous)
            safeEmit("texture.observerDetached", mapOf(
                "handle" to observation.handle,
                "textureId" to entry.id(),
                "restoredPreviousListener" to ours,
            ))
        } catch (error: Exception) {
            reportError("detach", error)
        }
    }

    private inner class Observation(
        val handle: Long,
        private val output: Any,
        private val entry: TextureRegistry.SurfaceTextureEntry,
        val listenerField: Field,
        val previous: TextureRegistry.OnFrameConsumedListener?,
    ) {
        lateinit var listener: TextureRegistry.OnFrameConsumedListener
        @Volatile var enabled = true
        private val surfaceField = field(output, "surface")
        private val widField = field(output, "wid")
        private val texture = entry.surfaceTexture()
        private var previousTimestamp: Long? = null

        /** Raster thread: copy metadata only; the owner asynchronously writes it. */
        fun consumed() {
            try {
                val callbackNs = System.nanoTime()
                val elapsedNs = SystemClock.elapsedRealtimeNanos()
                val timestamp = texture.timestamp
                val matrix = FloatArray(16)
                texture.getTransformMatrix(matrix)
                val surface = surfaceField.get(output) as Surface?
                val wid = widField.getLong(output)
                val previousTime = previousTimestamp
                previousTimestamp = timestamp
                safeEmit("texture.consumed", mapOf(
                    "consumedSequence" to consumedSequence.incrementAndGet(),
                    "callbackMonoNs" to callbackNs,
                    "callbackElapsedNs" to elapsedNs,
                    "textureTimestampNs" to timestamp,
                    "timestampDeltaNs" to previousTime?.let { timestamp - it },
                    "sameTimestampAsPrevious" to (previousTime == timestamp),
                    "textureTransform" to matrix.toList(),
                    "handle" to handle,
                    "textureId" to entry.id(),
                    "textureIdentity" to System.identityHashCode(texture),
                    "surfaceIdentity" to surface?.let { System.identityHashCode(it) },
                    "surfaceValid" to surface?.isValid,
                    "wid" to wid,
                    "surfaceIdentitySampling" to "current output fields; not per-buffer provenance",
                    "actualBufferSize" to null,
                    "presentationFence" to false,
                    "threadId" to Thread.currentThread().id,
                    "requestContext" to requestContext,
                ))
            } catch (error: Exception) {
                // No diagnostic failure may interrupt the render thread.
                safeEmit("texture.readError", mapOf("type" to error.javaClass.name))
            }
        }
    }

    private fun reportError(stage: String, error: Exception) {
        val key = "$stage:${error.javaClass.name}:${error.message}"
        if (reportedErrors.add(key)) safeEmit("texture.observerUnavailable", mapOf(
            "stage" to stage, "type" to error.javaClass.name,
            "message" to error.message, "consumedFramesAvailable" to false,
        ))
    }

    private fun safeEmit(name: String, data: Map<String, Any?>) {
        try { emit(name, data) } catch (_: Exception) { /* Diagnostics only. */ }
    }

    private fun field(instance: Any, name: String): Field {
        val fields = reflectedFields.getOrPut(instance.javaClass) { mutableMapOf() }
        fields[name]?.let { return it }
        var type: Class<*>? = instance.javaClass
        while (type != null) {
            try {
                return type.getDeclaredField(name).also {
                    it.isAccessible = true
                    fields[name] = it
                }
            } catch (_: NoSuchFieldException) {
                type = type.superclass
            }
        }
        throw NoSuchFieldException("${instance.javaClass.name}.$name")
    }
}
