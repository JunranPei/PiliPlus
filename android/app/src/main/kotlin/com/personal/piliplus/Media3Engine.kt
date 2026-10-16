package com.personal.piliplus

import android.content.Context
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.PixelCopy
import android.view.Surface
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.text.CueGroup
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.ByteArrayOutputStream

/** A Media3 player renders into a persistent Flutter texture, below the original UI. */
internal class Media3Engine(
    private val context: Context,
    private val engine: FlutterEngine,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "com.personal.piliplus/media3")
    private val handler = Handler(Looper.getMainLooper())
    private val exporter = NativeWebpExporter(channel, handler)
    private val sessions = mutableMapOf<Int, Session>()
    private var idleSession: Session? = null

    init {
        channel.setMethodCallHandler(this)
        // Prepare the retained decoder while the existing Flutter page/API loads.
        // This local frame never enters the UI or accesses the network.
        idleSession = Session(0).apply { warm() }
    }

    private inner class Session(var id: Int) {
        val texture: TextureRegistry.SurfaceTextureEntry = engine.renderer.createSurfaceTexture()
        val surface = Surface(texture.surfaceTexture())
        val player = ExoPlayer.Builder(context.applicationContext)
            .setRenderersFactory(RetainedRenderersFactory(context.applicationContext)
                .setEnableDecoderFallback(true))
            .setLoadControl(DefaultLoadControl.Builder()
                .setBufferDurationsMs(5_000, 30_000, 100, 1_000)
                .setPrioritizeTimeOverSizeThresholds(true)
                .build())
            .build()
        var sourceId = 0
        var sourceArgs: Media3SourceArgs? = null
        var startedAt = 0L
        var sourceListener: Player.Listener? = null
        var startupTrace: Media3StartupTrace? = null
        @Volatile var firstOutput = false
        var firstFrame = false
        var released = false
        var lastLogSecond = -1L
        val tick = object : Runnable {
            override fun run() {
                if (released) return
                sendState()
                handler.postDelayed(this, 100L)
            }
        }

        init {
            texture.surfaceTexture().setDefaultBufferSize(1920, 1080)
            player.setVideoSurface(surface)
            // Keep decoder resources across page changes; source replacement
            // reuses this player and texture instead of recreating the output.
            player.setForegroundMode(true)
            player.setVideoFrameMetadataListener { presentationUs, releaseNs, _, _ ->
                if (!firstOutput) {
                    firstOutput = true
                    startupTrace?.mark("video.firstOutput", "presentationUs=$presentationUs releaseDelayMs=${(releaseNs - System.nanoTime()) / 1_000_000}")
                    val trace = startupTrace
                    val queuedAt = SystemClock.elapsedRealtime()
                    handler.post {
                        trace?.mark("main.afterVideoOutput", "queueDelayMs=${SystemClock.elapsedRealtime() - queuedAt}")
                    }
                }
            }
            handler.post(tick)
        }

        fun warm() {
            val begin = SystemClock.elapsedRealtime()
            sourceListener = object : Player.Listener {
                override fun onRenderedFirstFrame() {
                    if (id != 0 || sourceId != 0) return
                    handler.postDelayed({
                        if (id == 0 && sourceId == 0) {
                            park()
                            Log.i("Media3Playback", "warmReady elapsedMs=${SystemClock.elapsedRealtime() - begin}")
                        }
                    }, 100)
                }
                override fun onPlayerError(error: PlaybackException) {
                    if (id == 0 && sourceId == 0) park()
                }
            }.also(player::addListener)
            player.setMediaItem(MediaItem.fromUri("asset:///media3-warmup.mp4"))
            player.prepare()
        }

        fun event(type: String, data: Map<String, Any?> = emptyMap()) {
            if (released) return
            channel.invokeMethod(type, mapOf("playerId" to id, "sourceId" to sourceId) + data)
        }

        fun sendState() {
            val format = player.videoFormat
            event("state", mapOf(
                "positionMs" to player.currentPosition.coerceAtLeast(0),
                "durationMs" to player.duration.coerceAtLeast(0),
                "bufferedPositionMs" to player.bufferedPosition.coerceAtLeast(0),
                "playWhenReady" to player.playWhenReady,
                "buffering" to (player.playbackState == Player.STATE_BUFFERING),
                "ended" to (player.playbackState == Player.STATE_ENDED),
                "speed" to player.playbackParameters.speed.toDouble(),
                "width" to (format?.width?.coerceAtLeast(0) ?: 0),
                "height" to (format?.height?.coerceAtLeast(0) ?: 0),
            ))
            val second = player.currentPosition / 1000L
            if (sourceId > 0 && second != lastLogSecond) {
                lastLogSecond = second
                Log.i("Media3Playback", "id=$id source=$sourceId positionMs=${player.currentPosition} state=${player.playbackState} playWhenReady=${player.playWhenReady} bufferMs=${player.totalBufferedDuration}")
            }
        }

        fun open(call: MethodCall) {
            startedAt = SystemClock.elapsedRealtime()
            sourceListener?.let(player::removeListener)
            startupTrace?.let(player::removeAnalyticsListener)
            player.stop()
            sourceId = call.argument<Number>("sourceId")!!.toInt()
            startupTrace = Media3StartupTrace(id, sourceId, startedAt).also {
                player.addAnalyticsListener(it)
                it.mark("open")
            }
            firstFrame = false
            firstOutput = false
            call.argument<Number>("volume")?.let { player.volume = it.toFloat().coerceIn(0f, 1f) }
            call.argument<Number>("speed")?.let { player.setPlaybackSpeed(it.toFloat()) }
            call.argument<Boolean>("videoEnabled")?.let { enabled ->
                player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
                    .setTrackTypeDisabled(C.TRACK_TYPE_VIDEO, !enabled).build()
            }
            startupTrace?.mark("source.options", "volume=${player.volume} speed=${player.playbackParameters.speed} video=${!player.trackSelectionParameters.disabledTrackTypes.contains(C.TRACK_TYPE_VIDEO)}")
            sourceArgs = Media3SourceArgs(
                bvid = call.argument<String>("bvid") ?: "",
                cid = call.argument<Number>("cid")?.toLong() ?: 0L,
                videoUrl = call.argument<String>("videoUrl"),
                audioUrl = call.argument<String>("audioUrl"),
                videoSegmentBase = call.argument<String>("videoSegmentBase"),
                audioSegmentBase = call.argument<String>("audioSegmentBase"),
                videoCodecs = call.argument<String>("videoCodecs"),
                audioCodecs = call.argument<String>("audioCodecs"),
                videoWidth = call.argument<Number>("videoWidth")?.toInt() ?: 0,
                videoHeight = call.argument<Number>("videoHeight")?.toInt() ?: 0,
                durationMs = call.argument<Number>("durationMs")?.toLong() ?: 0L,
                headers = call.argument<Map<String, String>>("headers") ?: emptyMap(),
                segments = call.argument<List<String>>("segments") ?: emptyList(),
            )
            Log.i("Media3Playback", "open id=$id source=$sourceId cid=${sourceArgs!!.cid} codec=${sourceArgs!!.videoCodecs}")
            val generation = sourceId
            sourceListener = object : Player.Listener {
                override fun onVideoSizeChanged(videoSize: VideoSize) {
                    if (generation != sourceId) return
                    startupTrace?.mark("surface.resize.begin", "size=${videoSize.width}x${videoSize.height}")
                    texture.surfaceTexture().setDefaultBufferSize(videoSize.width.coerceAtLeast(1), videoSize.height.coerceAtLeast(1))
                    startupTrace?.mark("surface.resize.end")
                    sendState()
                }

                override fun onRenderedFirstFrame() {
                    if (generation != sourceId || firstFrame) return
                    firstFrame = true
                    sendState()
                    val elapsed = SystemClock.elapsedRealtime() - startedAt
                    Log.i("Media3Playback", "firstFrame id=$id source=$sourceId elapsedMs=$elapsed")
                    startupTrace?.firstFrame()
                    event("firstFrame", mapOf("elapsedMs" to elapsed))
                }

                override fun onPlaybackStateChanged(playbackState: Int) {
                    if (generation == sourceId) {
                        Log.i("Media3Playback", "stateChange id=$id source=$sourceId state=$playbackState positionMs=${player.currentPosition} bufferMs=${player.totalBufferedDuration}")
                        sendState()
                    }
                }
                override fun onPlayWhenReadyChanged(ready: Boolean, reason: Int) {
                    if (generation != sourceId) return
                    Log.i("Media3Playback", "intent id=$id source=$sourceId playWhenReady=$ready reason=$reason")
                    sendState()
                }
                override fun onPlayerError(error: PlaybackException) {
                    if (generation != sourceId) return
                    event("error", mapOf("code" to error.errorCodeName, "message" to error.message))
                    Log.e("Media3Playback", "error id=$id source=$sourceId code=${error.errorCodeName}")
                }
                override fun onCues(cueGroup: CueGroup) {
                    if (generation != sourceId) return
                    event("subtitle", mapOf("text" to cueGroup.cues.mapNotNull { it.text }.joinToString("\n")))
                }
            }.also(player::addListener)
            startupTrace?.mark("source.build.begin")
            val source = Media3SourceFactory.createSource(context, sourceArgs!!, startupTrace)
            startupTrace?.mark("source.build.end")
            player.setMediaSource(source, call.argument<Number>("positionMs")?.toLong() ?: 0L)
            startupTrace?.mark("source.set")
            player.playWhenReady = call.argument<Boolean>("play") == true
            player.prepare()
            startupTrace?.mark("prepare.command")
        }

        fun screenshot(result: MethodChannel.Result) {
            val format = player.videoFormat
            if (format == null || format.width < 1 || format.height < 1) {
                result.success(null)
                return
            }
            val bitmap = Bitmap.createBitmap(format.width, format.height, Bitmap.Config.ARGB_8888)
            PixelCopy.request(surface, bitmap, { status ->
                if (status == PixelCopy.SUCCESS) {
                    val bytes = ByteArrayOutputStream()
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, bytes)
                    result.success(bytes.toByteArray())
                } else result.success(null)
                bitmap.recycle()
            }, handler)
        }

        fun release() {
            released = true
            handler.removeCallbacks(tick)
            player.clearVideoSurface()
            player.release()
            surface.release()
            texture.release()
        }

        fun park() {
            player.pause()
            // Stop network loading while preserving the foreground decoder.
            player.stop()
            handler.removeCallbacks(tick)
            sourceListener?.let(player::removeListener)
            sourceListener = null
        }

        fun activate(playerId: Int) {
            sourceListener?.let(player::removeListener)
            sourceListener = null
            id = playerId
            sourceId = 0
            lastLogSecond = -1L
            player.setPlaybackSpeed(1f)
            player.volume = 1f
            player.repeatMode = Player.REPEAT_MODE_OFF
            player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
                .setTrackTypeDisabled(C.TRACK_TYPE_VIDEO, false)
                .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true).build()
            handler.post(tick)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            if (call.method == "exportWebp") { exporter.export(call, result); return }
            if (call.method == "cancelExport") {
                exporter.cancel(call.argument<Number>("exportId")!!.toInt())
                result.success(null)
                return
            }
            val id = call.argument<Number>("playerId")?.toInt()
                ?: error("playerId is required")
            if (call.method == "create") {
                val session = sessions.getOrPut(id) {
                    idleSession?.also {
                        idleSession = null
                        it.activate(id)
                        Log.i("Media3Playback", "reuse id=$id texture=${it.texture.id()}")
                    } ?: Session(id).also {
                        Log.i("Media3Playback", "create id=$id texture=${it.texture.id()}")
                    }
                }
                result.success(mapOf("textureId" to session.texture.id()))
                return
            }
            val session = sessions[id] ?: error("Media3 player $id does not exist")
            val generation = call.argument<Number>("sourceId")?.toInt()
            if (generation != null && generation != session.sourceId &&
                call.method != "open" && call.method != "release") {
                result.success(null)
                return
            }
            val player = session.player
            when (call.method) {
                "open" -> session.open(call)
                "play" -> player.play()
                "pause" -> player.pause()
                "stop" -> player.stop()
                "seek" -> {
                    val position = call.argument<Number>("positionMs")!!.toLong().coerceAtLeast(0)
                    player.seekTo(position)
                    Log.i("Media3Playback", "seek id=$id source=${session.sourceId} positionMs=$position")
                }
                "setSpeed" -> {
                    val speed = call.argument<Number>("speed")!!.toFloat()
                    player.setPlaybackSpeed(speed)
                    Log.i("Media3Playback", "speed id=$id source=${session.sourceId} value=$speed")
                }
                "setVolume" -> player.volume = call.argument<Number>("volume")!!.toFloat()
                "setVideoEnabled" -> player.trackSelectionParameters = player.trackSelectionParameters
                    .buildUpon().setTrackTypeDisabled(C.TRACK_TYPE_VIDEO, call.argument<Boolean>("enabled") != true).build()
                "setRepeat" -> player.repeatMode = if (call.argument<Boolean>("repeat") == true) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
                "setTextEnabled" -> player.trackSelectionParameters = player.trackSelectionParameters
                    .buildUpon().setTrackTypeDisabled(C.TRACK_TYPE_TEXT, call.argument<Boolean>("enabled") != true).build()
                "screenshot" -> { session.screenshot(result); return }
                "release" -> {
                    sessions.remove(id)
                    session.park()
                    idleSession?.release()
                    idleSession = session
                }
                else -> { result.notImplemented(); return }
            }
            result.success(null)
        } catch (error: Exception) {
            result.error("MEDIA3_ERROR", error.message, null)
        }
    }

    fun dispose() {
        exporter.dispose()
        channel.setMethodCallHandler(null)
        sessions.values.forEach { it.release() }
        sessions.clear()
        idleSession?.release()
        idleSession = null
        Media3SourceFactory.dispose()
    }
}
