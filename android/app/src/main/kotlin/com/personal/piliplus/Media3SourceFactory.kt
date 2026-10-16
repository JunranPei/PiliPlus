package com.personal.piliplus

import android.content.Context
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.CacheKeyFactory
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.exoplayer.dash.DashMediaSource
import androidx.media3.exoplayer.source.ConcatenatingMediaSource
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.MergingMediaSource
import org.json.JSONObject
import java.io.File

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
    val headers: Map<String, String> = emptyMap(),
    val segments: List<String> = emptyList(),
)

internal object Media3SourceFactory {
    private var cache: SimpleCache? = null
    private var cacheKeys: Media3CacheKeys? = null

    private fun cache(context: Context): SimpleCache = cache ?: SimpleCache(
        File(context.cacheDir, "media3-cache"),
        LeastRecentlyUsedCacheEvictor(128L * 1024L * 1024L),
        StandaloneDatabaseProvider(context.applicationContext),
    ).also { instance ->
        cache = instance
        cacheKeys = Media3CacheKeys(
            existingKeys = { instance.keys },
            cachedPrefixBytes = { key -> instance.getCachedBytes(key, 0, 1024L * 1024L) },
        )
    }

    fun createSource(context: Context, args: Media3SourceArgs, trace: Media3StartupTrace? = null): MediaSource {
        val http = DefaultHttpDataSource.Factory()
            .setTransferListener(trace)
            .setConnectTimeoutMs(10_000).setReadTimeoutMs(15_000)
            .setDefaultRequestProperties(mapOf(
                "User-Agent" to "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                "Referer" to "https://www.bilibili.com",
            ) + args.headers)
        val sharedCache = cache(context)
        val keyIndex = checkNotNull(cacheKeys)
        val dataSource = CacheDataSource.Factory()
            .setCache(sharedCache)
            .setUpstreamDataSourceFactory(DefaultDataSource.Factory(context, http))
            .setCacheKeyFactory(CacheKeyFactory { spec ->
                keyIndex.key(spec.uri.toString(), spec.key)
            })
            .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
        val videoUrl = args.videoUrl ?: error("videoUrl is required")
        if (!args.videoSegmentBase.isNullOrBlank()) {
            val video = JSONObject().apply {
                put("baseUrl", videoUrl); put("codecs", args.videoCodecs.orEmpty())
                put("width", args.videoWidth); put("height", args.videoHeight)
                put("SegmentBase", JSONObject(args.videoSegmentBase))
            }
            val audio = if (!args.audioUrl.isNullOrBlank() && !args.audioSegmentBase.isNullOrBlank()) JSONObject().apply {
                put("baseUrl", args.audioUrl); put("codecs", args.audioCodecs.orEmpty())
                put("SegmentBase", JSONObject(args.audioSegmentBase))
            } else null
            val manifest = buildManifest(args.durationMs, video, audio)
            val file = File(context.cacheDir, "media3-manifest-${manifest.hashCode()}.mpd")
            if (!file.exists()) file.writeText(manifest)
            return DashMediaSource.Factory(dataSource).createMediaSource(
                MediaItem.Builder().setUri(file.toURI().toString())
                    .setMimeType(MimeTypes.APPLICATION_MPD).build(),
            )
        }
        val factory = DefaultMediaSourceFactory(dataSource)
        if (args.segments.isNotEmpty()) {
            return ConcatenatingMediaSource(false, *args.segments.map {
                factory.createMediaSource(MediaItem.fromUri(it))
            }.toTypedArray())
        }
        val video = factory.createMediaSource(MediaItem.fromUri(videoUrl))
        return if (args.audioUrl.isNullOrBlank()) video else MergingMediaSource(
            video, factory.createMediaSource(MediaItem.fromUri(args.audioUrl)),
        )
    }

    internal fun buildManifest(durationMs: Long, video: JSONObject, audio: JSONObject?): String {
        return """<?xml version="1.0" encoding="UTF-8"?>
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" profiles="urn:mpeg:dash:profile:isoff-on-demand:2011" type="static" minBufferTime="PT0.1S" mediaPresentationDuration="PT${durationMs / 1000.0}S">
            <Period start="PT0S">${representation(video, "video")}${audio?.let { representation(it, "audio") }.orEmpty()}</Period></MPD>""".trimIndent()
    }

    private fun representation(item: JSONObject, type: String): String {
        val base = item.optString("baseUrl", item.optString("base_url"))
        val segment = item.optJSONObject("SegmentBase") ?: item.optJSONObject("segment_base")
        val init = segment?.optString("Initialization", segment.optString("initialization")).orEmpty()
        val index = segment?.optString("indexRange", segment.optString("index_range")).orEmpty()
        val size = if (type == "video") " width=\"${item.optInt("width")}\" height=\"${item.optInt("height")}\"" else ""
        return "<AdaptationSet contentType=\"$type\" mimeType=\"$type/mp4\"><Representation id=\"$type\" codecs=\"${xml(item.optString("codecs"))}\"$size><BaseURL>${xml(base)}</BaseURL><SegmentBase indexRange=\"${xml(index)}\"><Initialization range=\"${xml(init)}\" /></SegmentBase></Representation></AdaptationSet>"
    }

    private fun xml(value: String) = value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")
    fun dispose() { cache?.release(); cache = null; cacheKeys = null }
}
