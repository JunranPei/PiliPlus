package com.personal.piliplus

import android.app.Activity
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.TextView
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.dash.DashMediaSource
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.ui.PlayerView
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.concurrent.Executors

/** Standalone Media3 playback probe; the Flutter/mpv path remains unchanged. */
class Media3ProbeActivity : Activity() {
    private val startedAt = SystemClock.elapsedRealtime()
    private val executor = Executors.newSingleThreadExecutor()
    private var player: ExoPlayer? = null
    private lateinit var root: FrameLayout

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.i(TAG, "probe.begin")
        root = FrameLayout(this)
        setContentView(root)
        showMessage("Media3 正在准备播放…")
        val bvid = intent.getStringExtra(EXTRA_BVID)
            ?: intent.data?.getQueryParameter(EXTRA_BVID)
            ?: DEFAULT_BVID
        val cid = intent.getLongExtra(EXTRA_CID, -1L).takeIf { it > 0L }
            ?: intent.data?.getQueryParameter(EXTRA_CID)?.toLongOrNull()
            ?: DEFAULT_CID
        executor.execute {
            runCatching { prepareMedia(bvid, cid) }
                .onFailure { error -> runOnUiThread { showMessage("Media3 播放失败：${error.message}") } }
        }
    }

    private fun prepareMedia(bvid: String, cid: Long) {
        val endpoint = "https://api.bilibili.com/x/player/playurl?fnval=4048&fnver=0&fourk=1" +
            "&bvid=${URLEncoder.encode(bvid, Charsets.UTF_8.name())}&cid=$cid"
        val connection = (URL(endpoint).openConnection() as HttpURLConnection).apply {
            connectTimeout = 10_000
            readTimeout = 15_000
            requestMethod = "GET"
            setRequestProperty("User-Agent", USER_AGENT)
            setRequestProperty("Referer", "https://www.bilibili.com/video/$bvid")
        }
        val body = connection.inputStream.bufferedReader().use { it.readText() }
        connection.disconnect()
        Log.i(TAG, "source.api.done elapsedMs=${SystemClock.elapsedRealtime() - startedAt}")
        val data = JSONObject(body).getJSONObject("data")
        val dash = data.getJSONObject("dash")
        val video = dash.getJSONArray("video").getJSONObject(0)
        val audio = dash.getJSONArray("audio").getJSONObject(0)
        val manifest = buildManifest(dash, video, audio)
        val file = File(cacheDir, "media3-probe-$cid.mpd")
        file.writeText(manifest)
        Log.i(TAG, "source.mpd.done elapsedMs=${SystemClock.elapsedRealtime() - startedAt}")
        runOnUiThread { attachPlayer(file) }
    }

    private fun attachPlayer(manifest: File) {
        val httpFactory = DefaultHttpDataSource.Factory()
            .setConnectTimeoutMs(10_000)
            .setReadTimeoutMs(15_000)
            .setDefaultRequestProperties(
                mapOf("User-Agent" to USER_AGENT, "Referer" to "https://www.bilibili.com")
            )
        val dataSourceFactory = DefaultDataSource.Factory(this, httpFactory)
        val source = DashMediaSource.Factory(dataSourceFactory)
            .createMediaSource(
                MediaItem.Builder()
                    .setUri(manifest.toURI().toString())
                    .setMimeType(MimeTypes.APPLICATION_MPD)
                    .build(),
            )
        val exo = ExoPlayer.Builder(this).build().also { candidate ->
            candidate.setMediaSource(source)
            candidate.addListener(object : androidx.media3.common.Player.Listener {
                override fun onRenderedFirstFrame() {
                    Log.i(TAG, "firstFrame elapsedMs=${SystemClock.elapsedRealtime() - startedAt}")
                }

                override fun onPlayerError(error: PlaybackException) {
                    showMessage("Media3 播放失败：${error.errorCodeName}")
                }
            })
            candidate.prepare()
            candidate.playWhenReady = true
        }
        player = exo
        root.removeAllViews()
        root.addView(
            PlayerView(this).apply {
                useController = true
                player = exo
                layoutParams = ViewGroup.LayoutParams(-1, -1)
            },
        )
    }

    private fun showMessage(message: String) {
        root.removeAllViews()
        root.addView(TextView(this).apply { text = message; textSize = 18f })
    }

    override fun onDestroy() {
        player?.release()
        executor.shutdownNow()
        super.onDestroy()
    }

    companion object {
        private const val TAG = "Media3Probe"
        private const val EXTRA_BVID = "bvid"
        private const val EXTRA_CID = "cid"
        private const val DEFAULT_BVID = "BV1GJ411x7h7"
        private const val DEFAULT_CID = 137649199L
        private const val USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"

        private fun buildManifest(dash: JSONObject, video: JSONObject, audio: JSONObject): String {
            val duration = dash.optInt("duration", 0)
            return """
                <?xml version="1.0" encoding="UTF-8"?>
                <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" profiles="urn:mpeg:dash:profile:isoff-on-demand:2011" type="static" minBufferTime="PT1.5S" mediaPresentationDuration="PT${duration}S">
                  <Period start="PT0S">
                    ${representation(video, "video", "video/mp4", "video_${video.optInt("id")}")}
                    ${representation(audio, "audio", "audio/mp4", "audio_${audio.optInt("id")}")}
                  </Period>
                </MPD>
            """.trimIndent()
        }

        private fun representation(item: JSONObject, contentType: String, mime: String, id: String): String {
            val base = item.optString("baseUrl", item.optString("base_url"))
            val segment = item.optJSONObject("SegmentBase") ?: item.optJSONObject("segment_base")
            val init = segment?.optString("Initialization", segment.optString("initialization")).orEmpty()
            val index = segment?.optString("indexRange", segment.optString("index_range")).orEmpty()
            val codec = xml(item.optString("codecs"))
            val size = if (contentType == "video") " width=\"${item.optInt("width")}\" height=\"${item.optInt("height")}\"" else ""
            return "<AdaptationSet contentType=\"$contentType\" mimeType=\"$mime\"><Representation id=\"$id\" mimeType=\"$mime\" codecs=\"$codec\"$size><BaseURL>${xml(base)}</BaseURL><SegmentBase indexRange=\"${xml(index)}\"><Initialization range=\"${xml(init)}\" /></SegmentBase></Representation></AdaptationSet>"
        }

        private fun xml(value: String): String = value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")
    }
}
