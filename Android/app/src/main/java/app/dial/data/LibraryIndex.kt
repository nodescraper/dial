package app.dial.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.text.Normalizer

/**
 * Every song, album, artist and playlist you have, kept in memory (and refreshed now and then) so search can be forgiving:
 * "end of begg" finds "End of Beginning", "kendric lamar" finds "Kendrick Lamar". Jellyfin's own search only matches exact
 * pieces of text, so Dial also looks through everything itself (the same as on iPhone and Mac).
 */
object LibraryIndex {
    private class Entry(val item: Item, val name: List<String>, val other: List<String>)

    private var entries: List<Entry> = emptyList()
    private var builtAt = 0L
    private var builtFor: String? = null
    private val lock = Mutex()

    /** Items that match all the typed words (allowing small spelling slips), best first, with a score from 0 to 1. */
    suspend fun search(term: String, client: JellyfinClient, limit: Int = 60): List<Pair<Item, Double>> {
        ensure(client)
        val words = tokens(term)
        if (words.isEmpty()) return emptyList()
        return withContext(Dispatchers.Default) {
            entries.mapNotNull { e -> score(words, e.name, e.other)?.let { e.item to it } }
                .sortedByDescending { it.second }.take(limit)
        }
    }

    private suspend fun ensure(client: JellyfinClient) {
        val key = client.server
        lock.withLock {
            val fresh = builtFor == key && entries.isNotEmpty() && System.currentTimeMillis() - builtAt < 10 * 60_000
            if (fresh) return
            // Stale: answer with what there is, rebuild only when there is nothing at all.
            if (builtFor == key && entries.isNotEmpty()) { builtAt = System.currentTimeMillis() - 9 * 60_000 }
            val built = coroutineScope {
                val songs = async { runCatching { client.songs(40000) }.getOrDefault(emptyList()) }
                val albums = async { runCatching { client.albumsForBrowsing(5000) }.getOrDefault(emptyList()) }
                val artists = async { runCatching { client.artists() }.getOrDefault(emptyList()) }
                val playlists = async { runCatching { client.playlists() }.getOrDefault(emptyList()) }
                songs.await() + albums.await() + artists.await() + playlists.await()
            }
            if (built.isNotEmpty()) {
                entries = withContext(Dispatchers.Default) {
                    built.map { Entry(it, tokens(it.name), tokens(listOfNotNull(it.artistLine, it.albumArtist, it.album).joinToString(" "))) }
                }
                builtFor = key
                builtAt = System.currentTimeMillis()
            }
        }
    }

    // MARK: Matching

    fun tokens(text: String): List<String> =
        Normalizer.normalize(text, Normalizer.Form.NFD).replace(Regex("\\p{Mn}+"), "").lowercase()
            .split(Regex("[^\\p{L}\\p{N}]+")).filter { it.isNotEmpty() }

    /** null when a typed word matches nothing; otherwise how well they all match (title words count more than artist or album). */
    private fun score(words: List<String>, name: List<String>, other: List<String>): Double? {
        var total = 0.0
        for (word in words) {
            var best = 0.0
            for (token in name) best = maxOf(best, match(word, token))
            if (best < 1) for (token in other) best = maxOf(best, match(word, token) * 0.85)
            if (best == 0.0) return null
            total += best
        }
        val coverage = minOf(words.size, name.size).toDouble() / maxOf(name.size, 1)
        return total / words.size * 0.85 + coverage * 0.15
    }

    /** 1 for the same word, a little less for the start of a longer one, and for a small spelling slip. */
    private fun match(word: String, token: String): Double {
        if (word == token) return 1.0
        if (token.startsWith(word)) return 0.9
        if (word.length >= 3 && token.contains(word)) return 0.7
        if (word.length < 3) return 0.0
        val allowed = if (word.length >= 7) 2 else if (word.length >= 4) 1 else 0
        if (allowed == 0) return 0.0
        // A slip in the typed word compared with the same length of the start of the token ("begg" ~ "begi"nning), or the whole token.
        val d = minOf(distance(word, token.take(word.length)), distance(word, token))
        return if (d <= allowed) 0.6 - 0.1 * d else 0.0
    }

    private fun distance(a: String, b: String): Int {
        if (a.isEmpty()) return b.length
        if (b.isEmpty()) return a.length
        var previous = IntArray(b.length + 1) { it }
        for (i in 1..a.length) {
            val current = IntArray(b.length + 1)
            current[0] = i
            for (j in 1..b.length) {
                current[j] = minOf(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + if (a[i - 1] == b[j - 1]) 0 else 1)
            }
            previous = current
        }
        return previous[b.length]
    }
}

/** How well an item matches what was typed: exact first, then starts-with, contains, every word, and near misses in spelling. */
object SearchRanking {
    fun normalize(text: String) = Normalizer.normalize(text, Normalizer.Form.NFD).replace(Regex("\\p{Mn}+"), "").lowercase().filter { it.isLetterOrDigit() }

    fun score(item: Item, term: String): Double {
        val wanted = normalize(term)
        if (wanted.isEmpty()) return 0.0
        val name = normalize(item.name)
        val artist = normalize(item.albumArtist ?: item.artistLine)
        var best: Double = when {
            name == wanted -> 100.0
            name.startsWith(wanted) -> 85.0
            name.contains(wanted) -> 70.0
            (artist + name).contains(wanted) || (name + artist).contains(wanted) -> 60.0
            else -> {
                val words = term.split(" ").map { normalize(it) }.filter { it.isNotEmpty() }
                val hay = "$name $artist"
                val hits = words.count { hay.contains(it) }
                maxOf(if (words.isEmpty()) 0.0 else 50.0 * hits / words.size, 45 * similarity(name, wanted))
            }
        }
        best += when (item.type) { "MusicArtist" -> 3.0; "MusicAlbum" -> 2.0; else -> 0.0 }
        return best
    }

    private fun similarity(a: String, b: String): Double {
        val x = a.take(40); val y = b.take(40)
        if (x.isEmpty() || y.isEmpty()) return 0.0
        var previous = IntArray(y.length + 1) { it }
        for (i in 1..x.length) {
            val current = IntArray(y.length + 1)
            current[0] = i
            for (j in 1..y.length) current[j] = minOf(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + if (x[i - 1] == y[j - 1]) 0 else 1)
            previous = current
        }
        return 1 - previous[y.length].toDouble() / maxOf(x.length, y.length)
    }
}
