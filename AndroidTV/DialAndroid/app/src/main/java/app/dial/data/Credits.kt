package app.dial.data

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Who's on each song: "Post Malone feat. Justin Bieber" credits both, so featured artists get pages.
 * Only marked features count ("feat.", "ft.", "featuring", "with"); "&" splits only between artists
 * known on their own, so "Quavo & Future" is two and "Simon & Garfunkel" one. Same rules as on iPhone.
 */
class Credits {
    data class Entry(val name: String, val songs: List<Item>)

    private val _featured = MutableStateFlow<Map<String, Entry>>(emptyMap())
    val featured: StateFlow<Map<String, Entry>> = _featured
    private var libraryArtists: Map<String, Item> = emptyMap()
    private var known: Set<String> = emptySet()

    suspend fun refresh(client: JellyfinClient) {
        val artists = runCatching { client.artists() }.getOrNull() ?: return
        val songs = runCatching { client.songs() }.getOrNull() ?: return
        // Thousands of songs: work this out away from the thread that draws the screen.
        val result = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) {
            val knownNames = artists.map { ArtistNames.key(it.name) }.toMutableSet()
            for (song in songs) for (name in featuredNames(song, null)) {
                if (!name.contains("&") && !name.lowercase().contains(" and ")) knownNames += ArtistNames.key(name)
            }
            val names = HashMap<String, String>()
            val bySong = HashMap<String, MutableList<Item>>()
            for (song in songs) {
                val main = ArtistNames.key(ArtistNames.primary(song.albumArtistLine))
                for (name in featuredNames(song, knownNames)) {
                    val key = ArtistNames.key(name)
                    if (key == main || key.length < 2) continue
                    names.getOrPut(key) { name }
                    bySong.getOrPut(key) { mutableListOf() } += song
                }
            }
            Triple(knownNames, artists.associateBy { ArtistNames.key(it.name) }, bySong.mapValues { (key, list) -> Entry(names[key] ?: key, list) })
        }
        known = result.first
        libraryArtists = result.second
        _featured.value = result.third
    }

    fun credits(track: Item): List<String> {
        val names = mutableListOf(ArtistNames.primary(track.albumArtistLine))
        for (name in featuredNames(track, known)) if (names.none { ArtistNames.key(it) == ArtistNames.key(name) }) names += name
        return names.filter { it.isNotBlank() }
    }

    /** The library artist with this name, if there is one. */
    fun libraryArtist(name: String): Item? = libraryArtists[ArtistNames.key(name)]

    fun songsFeaturing(name: String): List<Item> = _featured.value[ArtistNames.key(ArtistNames.primary(name))]?.songs ?: emptyList()

    val featuredOnly: List<Entry> get() = _featured.value.filterKeys { it !in libraryArtists }.values.sortedBy { it.name.lowercase() }

    companion object {
        private val featuring = Regex("\\s+(feat\\.?|ft\\.?|featuring|with)\\s+", RegexOption.IGNORE_CASE)
        private val inTitle = Regex("[\\(\\[]\\s*(feat\\.?|ft\\.?|featuring|with)\\s+([^\\)\\]]+)[\\)\\]]", RegexOption.IGNORE_CASE)
        private val joiner = Regex("\\s+(&|and|x)\\s+", RegexOption.IGNORE_CASE)

        fun featuredNames(song: Item, known: Set<String>?): List<String> {
            val main = ArtistNames.key(ArtistNames.primary(song.albumArtistLine))
            val names = mutableListOf<String>()
            for (artist in song.artists ?: emptyList()) {
                // One tag holding several artists ("A; B; C"): each is its own artist.
                if (featuring.containsMatchIn(artist)) names += featuresIn(artist, known) else names += artist.split(';')
            }
            names += featuresIn(song.artistLine, known)
            names += featuresIn(song.albumArtist ?: "", known)
            for (credit in listOf(song.albumArtist ?: "", song.artists?.joinToString("; ") ?: "")) if (';' in credit) names += credit.split(';')
            inTitle.find(song.name)?.let { names += split(it.groupValues[2], known) }
            val seen = mutableSetOf<String>()
            return names.map { ArtistNames.primary(it.trim()) }
                .filter { it.isNotEmpty() && ArtistNames.key(it) != main && seen.add(ArtistNames.key(it)) }
        }

        private fun featuresIn(credit: String, known: Set<String>?): List<String> {
            val match = featuring.find(credit) ?: return emptyList()
            return split(credit.substring(match.range.last + 1), known)
        }

        private fun split(text: String, known: Set<String>?): List<String> {
            val parts = text.replace(featuring, ", ").split(',', ';', '/').map { it.trim() }.filter { it.isNotEmpty() }
            if (known == null) return parts
            return parts.flatMap { part ->
                val pieces = part.split(joiner).map { it.trim() }
                if (pieces.size > 1 && pieces.all { ArtistNames.key(it) in known }) pieces else listOf(part)
            }
        }
    }
}
