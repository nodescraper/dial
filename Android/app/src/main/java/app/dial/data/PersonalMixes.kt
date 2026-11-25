package app.dial.data

import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope

/** What Dial knows about how you listen, gathered once for the day's mixtapes (the same as on iPhone and Mac). */
class Listening(
    val favoriteIds: Set<String>,
    val plays: Map<String, Int>,
    val lastPlayed: Map<String, java.time.Instant>,
    /** Played in the last three days, and in the last thirty (from Playback Reporting, when it is installed). */
    val recent3: Set<String>,
    val recent30: Set<String>,
    /** Your most played songs, and your favorites. */
    val played: List<Item>,
    val favorites: List<Item>,
) {
    fun isKnown(id: String) = id in favoriteIds || (plays[id] ?: 0) > 0

    /** Whether you played it within the last [days] days. */
    fun heard(id: String, days: Int): Boolean {
        if (days <= 3 && id in recent3) return true
        if (days <= 30 && id in recent30) return true
        return lastPlayed[id]?.isAfter(java.time.Instant.now().minusSeconds(days * 86400L)) == true
    }

    /** How much a song means to you: how much you play it, and whether you marked it. */
    fun weight(id: String): Double = minOf((plays[id] ?: 0).toDouble(), 30.0) / 30 + if (id in favoriteIds) 0.5 else 0.0

    companion object {
        suspend fun load(client: JellyfinClient): Listening {
            val played = runCatching { client.songsSorted("PlayCount", limit = 600) }.getOrDefault(emptyList()).filter { (it.userData?.playCount ?: 0) > 0 }
            val favorites = runCatching { client.favoriteSongs() }.getOrDefault(emptyList())
            val plays = HashMap<String, Int>()
            val last = HashMap<String, java.time.Instant>()
            for (song in played) {
                plays[song.id] = song.userData?.playCount ?: 0
                song.userData?.lastPlayedDate?.let { text -> runCatching { java.time.Instant.parse(text) }.getOrNull()?.let { last[song.id] = it } }
            }
            // Playback Reporting knows more recent plays than the server's own counters.
            for ((id, count) in ListeningHistory.topSongs(client, 90, 300)) plays[id] = maxOf(plays[id] ?: 0, count)
            return Listening(favorites.map { it.id }.toSet(), plays, last, ListeningHistory.recentlyPlayed(client, 72),
                ListeningHistory.recentlyPlayed(client, 24 * 30), played, favorites)
        }
    }
}
