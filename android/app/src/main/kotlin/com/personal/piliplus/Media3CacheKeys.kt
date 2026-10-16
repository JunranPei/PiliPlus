package com.personal.piliplus

import java.net.URI
import java.net.URISyntaxException
import java.util.Locale

/** Mirror hosts and signed URLs identify the same immutable Bili VOD file. */
internal class Media3CacheKeys(
    private val existingKeys: () -> Set<String> = { emptySet() },
    private val cachedPrefixBytes: (String) -> Long = { 0L },
) {
    private var aliases: MutableMap<String, String>? = null

    @Synchronized
    fun prepare() {
        if (aliases == null) aliases = buildAliases()
    }

    @Synchronized
    fun key(uri: String, customKey: String? = null): String {
        // DASH supplies the resolved media URL as a custom key. Normalize that
        // URL too, while preserving genuinely application-defined custom keys.
        val candidate = customKey ?: uri
        val canonical = canonical(candidate) ?: return candidate
        prepare()
        val index = checkNotNull(aliases)
        return index.getOrPut(canonical) { canonical }
    }

    private fun buildAliases(): MutableMap<String, String> {
        val candidates = HashMap<String, Pair<String, Long>>()
        for (old in existingKeys()) {
            val identity = if (old.startsWith(PREFIX)) old else canonical(old) ?: continue
            val bytes = cachedPrefixBytes(old)
            val previous = candidates[identity]
            if (previous == null || bytes > previous.second ||
                (bytes == previous.second && old == identity)) {
                candidates[identity] = old to bytes
            }
        }
        return candidates.mapValuesTo(HashMap()) { it.value.first }
    }

    companion object {
        private const val PREFIX = "bilivideo-vod:"
        private val extensions = setOf("m4s", "mp4", "m4a", "m4v")

        fun canonical(value: String): String? {
            if (!value.startsWith("http://", ignoreCase = true) &&
                !value.startsWith("https://", ignoreCase = true)) return null
            val uri = try { URI(value) } catch (_: URISyntaxException) { return null }
            val host = uri.host?.lowercase(Locale.ROOT) ?: return null
            if (!host.endsWith(".bilivideo.com") && !host.endsWith(".bilivideo.cn")) return null
            val path = uri.rawPath ?: return null
            if (!path.startsWith("/upgcxcode/") ||
                path.substringAfterLast('.', "").lowercase(Locale.ROOT) !in extensions) return null
            return PREFIX + path
        }
    }
}
