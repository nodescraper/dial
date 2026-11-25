package app.dial.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import okhttp3.Request
import java.net.URLEncoder

/** Live internet radio from Radio Browser, a free community directory of stations (same as on iPhone). */
@Serializable
data class Station(
    @SerialName("stationuuid") val id: String,
    @SerialName("name") val name: String = "",
    @SerialName("url_resolved") val streamUrl: String = "",
    @SerialName("favicon") val favicon: String? = null,
    @SerialName("country") val country: String? = null,
    @SerialName("tags") val tags: String? = null,
    @SerialName("codec") val codec: String? = null,
    @SerialName("bitrate") val bitrate: Int? = null,
)


object RadioBrowser {
    private val mirrors = listOf("de1", "nl1", "at1", "fi1").map { "https://$it.api.radio-browser.info" }

    /** Station categories for the Radio tab. */
    val categories = listOf("christmas", "pop", "hip hop", "rock", "dance", "jazz", "chillout", "classical", "news", "80s", "lofi")

    /** Categories that also pull in related tags (stations are labelled "christmas" or "xmas"). */
    private val relatedTags = mapOf("christmas" to listOf("xmas", "christmas music", "holiday"))

    private suspend fun stations(path: String): List<Station> = withContext(Dispatchers.IO) {
        for (mirror in mirrors) {
            val list = runCatching {
                val request = Request.Builder().url("$mirror/json/$path").header("User-Agent", "Dial/0.1").build()
                JellyfinClient.http.newCall(request).execute().use { r ->
                    if (!r.isSuccessful) null else JellyfinJson.decodeFromString(ListSerializer(Station.serializer()), r.body!!.string())
                }
            }.getOrNull() ?: continue
            // Only stations Android can play, once each.
            return@withContext list.filter { it.streamUrl.isNotBlank() && (it.codec ?: "MP3").uppercase() in setOf("MP3", "AAC", "AAC+", "OGG", "OPUS", "FLAC") }
                .distinctBy { it.name.lowercase().trim() }
        }
        emptyList()
    }

    /** A tag with related tags merges them all; stations found under more tags come first. */
    suspend fun byTag(tag: String): List<Station> {
        val related = relatedTags[tag] ?: return byExactTag(tag)
        val lists = kotlinx.coroutines.coroutineScope {
            (listOf(tag) + related).map { t -> async { byExactTag(t) } }.awaitAll()
        }
        val hits = HashMap<String, Int>()
        val ordered = ArrayList<Station>()
        for (list in lists) for (s in list) { if (s.id !in hits) ordered.add(s); hits[s.id] = (hits[s.id] ?: 0) + 1 }
        return ordered.withIndex().sortedWith(compareByDescending<IndexedValue<Station>> { hits[it.value.id] }.thenBy { it.index })
            .map { it.value }.distinctBy { it.name.lowercase().trim() }
    }

    private suspend fun byExactTag(tag: String) = stations("stations/bytag/${URLEncoder.encode(tag, "UTF-8").replace("+", "%20")}?order=clickcount&reverse=true&limit=50&hidebroken=true")
    suspend fun search(name: String) = stations("stations/byname/${URLEncoder.encode(name, "UTF-8").replace("+", "%20")}?order=clickcount&reverse=true&limit=40&hidebroken=true")
}
