package com.personal.piliplus

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

class Media3CacheKeysTest {
    private val path = "/upgcxcode/73/39/42154853973/42154853973-1-30080.m4s"
    private val first = "https://upos-sz-estgcos.bilivideo.com$path"
    private val mirror = "https://upos-sz-mirrorcos.bilivideo.com$path"

    @Test fun signedMirrorUrlsShareOneFile() {
        val keys = Media3CacheKeys()
        assertEquals(keys.key("$first?deadline=1&upsig=old"), keys.key("$mirror?deadline=2&upsig=new"))
        assertEquals(keys.key(first), keys.key("http://upos-sz-mirror.bilivideo.cn$path"))
    }

    @Test fun differentVideosAndRepresentationsNeverShareAKey() {
        val keys = Media3CacheKeys()
        assertNotEquals(keys.key(first), keys.key(first.replace("30080", "30112")))
        assertNotEquals(keys.key(first), keys.key(first.replace("42154853973", "42154853974")))
        assertNotEquals(keys.key(first), keys.key(first.replace(".m4s", ".m4a")))
    }

    @Test fun dashResolvedUrlKeysAreNormalizedButApplicationKeysArePreserved() {
        val keys = Media3CacheKeys()
        assertEquals(keys.key(first), keys.key(mirror, "$mirror?deadline=2&upsig=new"))
        assertEquals("explicit-media-id", keys.key(mirror, "explicit-media-id"))
    }

    @Test fun liveAndUnrelatedUrlsKeepTheirEntireIdentity() {
        val keys = Media3CacheKeys()
        for (url in listOf(
            "https://live.bilivideo.com/live/stream.m3u8?token=one",
            "https://example.com$path?token=one",
            "https://evilbilivideo.com$path?token=one",
            "https://upos.bilivideo.com.evil.test$path?token=one",
            "file:///upgcxcode/test.m4s",
        )) assertEquals(url, keys.key(url))
    }

    @Test fun existingDownloadedSpansAreReusedAcrossMirrors() {
        val scans = AtomicInteger()
        val keys = Media3CacheKeys(
            existingKeys = { scans.incrementAndGet(); setOf(first, mirror) },
            cachedPrefixBytes = { if (it == first) 2317L else 1024L * 1024L },
        )
        assertEquals(mirror, keys.key("$first?fresh=true"))
        assertEquals(mirror, keys.key("https://new.bilivideo.cn$path?fresh=other"))
        assertEquals(1, scans.get())
    }

    @Test fun canonicalEntriesSurviveReopeningTheCache() {
        val canonical = Media3CacheKeys().key(first)
        val keys = Media3CacheKeys({ setOf(first, canonical) }, { 4096L })
        assertEquals(canonical, keys.key(mirror))
    }

    @Test fun parallelAudioVideoRequestsBuildTheAliasIndexOnce() {
        val scans = AtomicInteger()
        val keys = Media3CacheKeys({ scans.incrementAndGet(); setOf(first) }, { 10000L })
        val executor = Executors.newFixedThreadPool(2)
        try {
            val futures = executor.invokeAll(List(20) { Callable { keys.key(mirror) } })
            futures.forEach { assertEquals(first, it.get()) }
            assertEquals(1, scans.get())
        } finally { executor.shutdownNow() }
    }
}
