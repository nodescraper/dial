package app.dial.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Request

/** Lyrics from your server first, then from LRCLIB (a free lyrics database), like on iPhone. */
object Lyrics {
    data class Result(val lines: List<LyricLine>, val fromLrclib: Boolean)

    suspend fun find(track: Item, client: JellyfinClient): Result? {
        client.lyrics(track.id).takeIf { it.isNotEmpty() && !isSpam(it) }?.let { return Result(it, false) }
        return lrclib(track)?.let { Result(it, true) }
    }

    /** Some downloaded files carry an ad where the lyrics should be ("Downloaded from www.musicduty.com"). That is not a lyric. */
    private fun isSpam(lines: List<LyricLine>): Boolean {
        val text = lines.joinToString(" ") { it.text }.lowercase()
        val markers = listOf("downloaded from", "www.", ".com", "http", "free mp3", "mp3 download", "visit ")
        return lines.size <= 6 && markers.any { it in text }
    }

    private fun clean(title: String) = title
        .replace(Regex("\\s*[\\(\\[](feat|ft|with)\\.?\\s[^\\)\\]]*[\\)\\]]", RegexOption.IGNORE_CASE), "")
        .replace(Regex("\\s*[\\(\\[][^\\)\\]]*(remaster|version|edit|deluxe)[^\\)\\]]*[\\)\\]]", RegexOption.IGNORE_CASE), "")
        .trim()

    private suspend fun lrclib(track: Item): List<LyricLine>? = withContext(Dispatchers.IO) {
        val artist = ArtistNames.primary(track.albumArtistLine)
        val title = clean(track.name)
        if (artist.isBlank() || title.isBlank()) return@withContext null
        val exact = "https://lrclib.net/api/get".toHttpUrl().newBuilder()
            .addQueryParameter("artist_name", artist).addQueryParameter("track_name", title)
            .addQueryParameter("album_name", track.album?.let(::clean) ?: "")
            .addQueryParameter("duration", (track.durationMs / 1000).toString()).build()
        get(exact.toString())?.let { (JellyfinJson.parseToJsonElement(it) as? JsonObject)?.let(::lines) }?.let { return@withContext it }
        val search = "https://lrclib.net/api/search".toHttpUrl().newBuilder()
            .addQueryParameter("artist_name", artist).addQueryParameter("track_name", title).build()
        val results = get(search.toString())?.let { JellyfinJson.parseToJsonElement(it) as? JsonArray } ?: return@withContext null
        val length = track.durationMs / 1000.0
        results.map { it.jsonObject }
            .filter { length == 0.0 || kotlin.math.abs((it["duration"]?.jsonPrimitive?.doubleOrNull ?: length) - length) < 8 }
            .sortedByDescending { it["syncedLyrics"]?.jsonPrimitive?.contentOrNull != null }
            .firstNotNullOfOrNull(::lines)
    }

    private fun get(url: String): String? = runCatching {
        val request = Request.Builder().url(url).header("User-Agent", "Dial/0.1").build()
        JellyfinClient.http.newCall(request).execute().use { if (it.isSuccessful) it.body?.string() else null }
    }.getOrNull()

    private fun lines(entry: JsonObject): List<LyricLine>? {
        if (entry["instrumental"]?.jsonPrimitive?.booleanOrNull == true) return null
        entry["syncedLyrics"]?.jsonPrimitive?.contentOrNull?.let { synced -> parseLrc(synced).takeIf { it.isNotEmpty() }?.let { return it } }
        return entry["plainLyrics"]?.jsonPrimitive?.contentOrNull?.lines()?.map { LyricLine(it, null) }
    }

    /** "[01:23.45] words" → a line starting at 83.45 seconds. */
    fun parseLrc(text: String): List<LyricLine> {
        val stamp = Regex("\\[(\\d+):(\\d+(?:\\.\\d+)?)]")
        return text.lines().flatMap { raw ->
            val times = stamp.findAll(raw).map { (it.groupValues[1].toLong() * 60 + it.groupValues[2].toDouble()) }.toList()
            val words = raw.replace(stamp, "").trim()
            times.map { LyricLine(words, (it * 10_000_000).toLong()) }
        }.sortedBy { it.start ?: 0 }
    }
}
