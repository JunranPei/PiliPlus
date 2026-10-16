package com.personal.piliplus

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.dash.DashMediaSource
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.MergingMediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.CacheKeyFactory
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.database.StandaloneDatabaseProvider
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.concurrent.Executors

internal data class Media3SourceArgs(
    val bvid: String,
    val cid: Long,
    val videoUrl: String?,
    val audioUrl: String?,
    val videoSegmentBase: String?,
    val audioSegmentBase: String?,
    val videoCodecs: String?,
    val videoWidth: Int,
    val videoHeight: Int,
    val audioCodecs: String?,
    val durationMs: Long,
)

/** Keeps one prepared source alive while the Flutter page is showing its cover. */
internal object Media3PlayerManager {
    private const val TAG = "Media3Manager"
    private const val USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"

    private var preparedKey: String? = null
    private var preparedPlayer: ExoPlayer? = null
    private var mediaCache: SimpleCache? = null
    private val apiExecutor = Executors.newCachedThreadPool()

    @Synchronized
    private fun cache(context: Context): SimpleCache {
        return mediaCache ?: SimpleCache(
            java.io.File(context.cacheDir, "media3-cache"),
            LeastRecentlyUsedCacheEvictor(128L * 1024L * 1024L),
            StandaloneDatabaseProvider(context),
        ).also { mediaCache = it }
    }

    @Synchronized
    fun preload(context: Context, args: Media3SourceArgs) {
        val videoUrl = args.videoUrl?.takeIf { it.isNotBlank() } ?: return
        if (preparedKey == videoUrl && preparedPlayer != null) {
            Log.i(TAG, "preload.reuse")
            return
        }
        preparedPlayer?.release()
        preparedPlayer = null
        preparedKey = null
        val source = createSource(context.applicationContext, args)
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(100, 800, 100, 100)
            .setPrioritizeTimeOverSizeThresholds(true)
            .build()
        preparedPlayer = ExoPlayer.Builder(context.applicationContext)
            .setLoadControl(loadControl)
            .build().also {
            it.setMediaSource(source)
            it.volume = 0f
            it.addListener(object : androidx.media3.common.Player.Listener {
                override fun onRenderedFirstFrame() {
                    Log.i(TAG, "preload.firstFrame")
                    if (preparedPlayer != null) {
                        it.playWhenReady = false
                    }
                }
            })
            it.playWhenReady = true
            it.prepare()
        }
        preparedKey = videoUrl
        Log.i(TAG, "preload.ready")
    }

    fun preloadApi(context: Context, bvid: String, cid: Long) {
        apiExecutor.execute {
            runCatching {
                val endpoint = "https://api.bilibili.com/x/player/playurl?fnval=4048&fnver=0&fourk=1" +
                    "&bvid=${URLEncoder.encode(bvid, Charsets.UTF_8.name())}&cid=$cid"
                val connection = (URL(endpoint).openConnection() as HttpURLConnection).apply {
                    connectTimeout = 3_000
                    readTimeout = 5_000
                    requestMethod = "GET"
                    setRequestProperty("User-Agent", USER_AGENT)
                    setRequestProperty("Referer", "https://www.bilibili.com/video/$bvid")
                }
                val body = connection.inputStream.bufferedReader().use { it.readText() }
                connection.disconnect()
                val data = JSONObject(body).getJSONObject("data")
                val dash = data.getJSONObject("dash")
                val video = dash.getJSONArray("video").getJSONObject(0)
                val audio = dash.optJSONArray("audio")?.optJSONObject(0)
                val args = Media3SourceArgs(
                        bvid = bvid,
                        cid = cid,
                        videoUrl = video.optString("baseUrl", video.optString("base_url")),
                        audioUrl = audio?.optString("baseUrl", audio.optString("base_url")),
                        videoSegmentBase = video.optJSONObject("SegmentBase")?.toString(),
                        audioSegmentBase = audio?.optJSONObject("SegmentBase")?.toString(),
                        videoCodecs = video.optString("codecs"),
                        videoWidth = video.optInt("width"),
                        videoHeight = video.optInt("height"),
                        audioCodecs = audio?.optString("codecs"),
                        durationMs = (dash.optDouble("duration", 0.0) * 1000.0).toLong(),
                    )
                Handler(Looper.getMainLooper()).post { preload(context, args) }
            }.onFailure { Log.w(TAG, "preload.api.failed", it) }
        }
    }

    @Synchronized
    fun take(videoUrl: String): ExoPlayer? {
        if (preparedKey != videoUrl) return null
        val result = preparedPlayer
        preparedPlayer = null
        preparedKey = null
        // Keep the warm surface alive while PlayerView swaps in its visible
        // surface. Releasing it here would reset the decoder on a cold tap.
        result?.volume = 1f
        if (result != null) Log.i(TAG, "preload.take")
        return result
    }

    @Synchronized
    fun peek(): ExoPlayer? = preparedPlayer

    @Synchronized
    fun takeAny(): ExoPlayer? {
        val result = preparedPlayer
        preparedPlayer = null
        preparedKey = null
        result?.volume = 1f
        if (result != null) Log.i(TAG, "preload.takeAny")
        return result
    }

    @Synchronized
    fun clear() {
        preparedPlayer?.release()
        preparedPlayer = null
        preparedKey = null
        mediaCache?.release()
        mediaCache = null
    }

    private fun createSource(context: Context, args: Media3SourceArgs): MediaSource {
        val httpFactory = DefaultHttpDataSource.Factory()
            .setConnectTimeoutMs(10_000)
            .setReadTimeoutMs(15_000)
            .setDefaultRequestProperties(
                mapOf("User-Agent" to USER_AGENT, "Referer" to "https://www.bilibili.com"),
            )
        val upstreamFactory = DefaultDataSource.Factory(context, httpFactory)
        val dataSourceFactory = CacheDataSource.Factory()
            .setCache(cache(context))
            .setUpstreamDataSourceFactory(upstreamFactory)
            .setCacheKeyFactory(
                CacheKeyFactory { dataSpec ->
                    dataSpec.uri.buildUpon().clearQuery().build().toString()
                },
            )
            .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
        val videoUrl = args.videoUrl ?: error("Media3 video URL is missing")
        if (!args.videoSegmentBase.isNullOrBlank()) {
            val video = JSONObject().apply {
                put("baseUrl", videoUrl)
                put("codecs", args.videoCodecs.orEmpty())
                put("width", args.videoWidth)
                put("height", args.videoHeight)
                put("SegmentBase", JSONObject(args.videoSegmentBase))
            }
            val audio = if (!args.audioUrl.isNullOrBlank() && !args.audioSegmentBase.isNullOrBlank()) {
                JSONObject().apply {
                    put("baseUrl", args.audioUrl)
                    put("codecs", args.audioCodecs.orEmpty())
                    put("SegmentBase", JSONObject(args.audioSegmentBase))
                }
            } else {
                null
            }
            val manifest = Media3ProbeActivity.buildManifest(
                JSONObject().put("duration", args.durationMs / 1000.0),
                video,
                audio ?: video,
            )
            val file = File(context.cacheDir, "media3-preload-${SystemClock.elapsedRealtime()}.mpd")
            file.writeText(manifest)
            return DashMediaSource.Factory(dataSourceFactory).createMediaSource(
                MediaItem.Builder()
                    .setUri(file.toURI().toString())
                    .setMimeType(MimeTypes.APPLICATION_MPD)
                    .build(),
            )
        }
        val factory = ProgressiveMediaSource.Factory(dataSourceFactory)
        val video = factory.createMediaSource(MediaItem.fromUri(videoUrl))
        return if (!args.audioUrl.isNullOrBlank()) {
            MergingMediaSource(video, factory.createMediaSource(MediaItem.fromUri(args.audioUrl)))
        } else {
            video
        }
    }
}
