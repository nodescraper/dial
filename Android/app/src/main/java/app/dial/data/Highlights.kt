package app.dial.data

import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import java.time.Instant
import java.time.temporal.ChronoUnit

/** What a highlight card does: open an album, open a release you don't own yet, or start an artist's radio. */
sealed interface HighlightAction {
    data class Album(val id: String, val name: String) : HighlightAction
    data class PublicAlbum(val pick: PublicMusic.Pick, val artist: String, val artistId: String?) : HighlightAction
    data class ArtistRadio(val id: String, val name: String) : HighlightAction
    /** Opens the Discovery tab (the card made of new-release covers). */
    data object Discovery : HighlightAction
}

/** One card of Home's lead row: it says something true right now ("New from ...", "Recently added", "On repeat"). */
data class Highlight(
    val kind: String,
    val label: String,
    val title: String,
    val subtitle: String,
    val coverItemId: String? = null,
    val coverUrl: String? = null,
    /** The artist whose backdrop and logo fill the card, when they're in your library. */
    val artistId: String? = null,
    /** Cover pictures blended into the card's background, instead of one artist's backdrop. */
    val collage: List<String> = emptyList(),
    val action: HighlightAction,
) { val id get() = kind + title }

/**
 * What Home leads with, chosen in this order from what's true right now (the same as Dial on iPhone and Mac):
 * 1. New from your artists: a fresh release (MusicBrainz) by an artist in your library.
 * 2. Recently added: the newest album, when it arrived in the last two weeks.
 * 3. On repeat: the artist you played most lately.
 * 4. Rediscover: an album you used to play a lot but haven't in months (fills in when one above is missing).
 */
object HighlightBuilder {
    @Volatile var latest: List<Highlight> = emptyList()
        private set
    private var builtAt = 0L

    suspend fun load(client: JellyfinClient, onUpdate: (List<Highlight>) -> Unit) {
        if (latest.isNotEmpty()) onUpdate(latest)
        if (latest.isNotEmpty() && System.currentTimeMillis() - builtAt < 3600_000) return
        val built = build(client)
        if (built.isNotEmpty()) { latest = built; builtAt = System.currentTimeMillis(); onUpdate(built) }
    }

    private suspend fun build(client: JellyfinClient): List<Highlight> {
        val first = listOfNotNull(runCatching { newFromYourArtists(client) }.getOrNull(),
            runCatching { justAdded(client) }.getOrNull(), runCatching { onRepeat(client) }.getOrNull())
        val fill = if (first.size < 3) listOfNotNull(runCatching { rediscover(client) }.getOrNull(),
            runCatching { pickUp(client) }.getOrNull(), runCatching { fromFavorites(client) }.getOrNull()) else emptyList()
        return (first + fill).distinctBy { it.title }.take(3)
    }

    /** New releases from your artists, as one card that leads to Discovery: a blend of their covers. */
    private suspend fun newFromYourArtists(client: JellyfinClient): Highlight? {
        if (!DialPlugin.present.value) return null
        // The saved Discovery page, or (if it was never opened yet) the server's feed.
        var fresh = DiscoveryEngine.latest?.fresh.orEmpty()
        if (fresh.isEmpty()) {
            val made = client.dialDiscovery()
            if (made != null && made.second) fresh = made.first.fresh
        }
        val picks = fresh.distinctBy { it.mbid }
        if (picks.size < 3) return null
        val names = picks.mapNotNull { it.artist?.let(ArtistNames::primary) }.distinct()
        val subtitle = names.take(3).joinToString(", ") + if (names.size > 3) " and more" else ""
        // Some releases have no cover on the Cover Art Archive, or it is slow: check a dozen and keep five that really load,
        // so the card never shows empty squares.
        val candidates = picks.take(14).mapNotNull { it.cover }
        val working = reachable(candidates)
        val covers = (if (working.size >= 3) working else candidates).take(5)
        if (covers.size < 3) return null
        return Highlight("newRelease", "New from your artists", "${picks.size} new releases", subtitle,
            collage = covers, action = HighlightAction.Discovery)
    }

    /** The addresses that answer with a picture, in the order given. */
    private suspend fun reachable(urls: List<String>): List<String> = kotlinx.coroutines.coroutineScope {
        urls.map { url ->
            async(kotlinx.coroutines.Dispatchers.IO) {
                kotlinx.coroutines.withTimeoutOrNull(9_000) {
                    runCatching {
                        JellyfinClient.http.newCall(okhttp3.Request.Builder().url(url).header("User-Agent", "Dial/0.1").build()).execute().use { it.isSuccessful }
                    }.getOrDefault(false)
                } == true
            }
        }.awaitAll().let { ok -> urls.filterIndexed { i, _ -> ok[i] } }
    }

    private suspend fun justAdded(client: JellyfinClient): Highlight? {
        val album = client.recentAlbums(1).firstOrNull() ?: return null
        val added = runCatching { Instant.parse(album.dateCreated) }.getOrNull() ?: return null
        if (ChronoUnit.DAYS.between(added, Instant.now()) > 14) return null
        return Highlight("justAdded", "Recently added", album.name, album.albumArtistLine, coverItemId = album.id,
            artistId = album.albumArtists?.firstOrNull()?.id, action = HighlightAction.Album(album.id, album.name))
    }

    private suspend fun onRepeat(client: JellyfinClient): Highlight? {
        val recent = client.recentlyPlayed(60)
        val byArtist = recent.groupBy { it.albumArtists?.firstOrNull()?.id ?: it.artistItems?.firstOrNull()?.id }
            .filterKeys { it != null }
        val best = byArtist.maxByOrNull { it.value.size } ?: return null
        if (best.value.size < 4) return null
        val song = best.value.first()
        val name = ArtistNames.primary(song.albumArtistLine)
        return Highlight("onRepeat", "On repeat lately", name, "Your most played artist", coverItemId = song.imageItemId,
            artistId = best.key, action = HighlightAction.ArtistRadio(best.key!!, name))
    }

    private suspend fun rediscover(client: JellyfinClient): Highlight? {
        val songs = client.songsMostPlayed(300)
        val cutoff = Instant.now().minus(120, ChronoUnit.DAYS)
        data class Album(val song: Item, var plays: Int, var last: Instant)
        val albums = HashMap<String, Album>()
        for (song in songs) {
            val albumId = song.albumId ?: continue
            val plays = song.userData?.playCount ?: 0
            val last = runCatching { Instant.parse(song.userData?.lastPlayedDate) }.getOrNull() ?: continue
            if (plays < 2) continue
            val current = albums[albumId]
            if (current == null) albums[albumId] = Album(song, plays, last)
            else { current.plays += plays; if (last.isAfter(current.last)) current.last = last }
        }
        val pick = albums.entries.filter { it.value.last.isBefore(cutoff) }.maxByOrNull { it.value.plays } ?: return null
        val song = pick.value.song
        return Highlight("rediscover", "Rediscover", song.album ?: song.name, song.albumArtistLine, coverItemId = pick.key,
            artistId = song.albumArtists?.firstOrNull()?.id, action = HighlightAction.Album(pick.key, song.album ?: ""))
    }

    /** The album you played last, to pick up where you left off. */
    private suspend fun pickUp(client: JellyfinClient): Highlight? {
        val song = client.recentlyPlayed(1).firstOrNull() ?: return null
        val albumId = song.albumId ?: return null
        return Highlight("pickUp", "Pick up where you left off", song.album ?: song.name, song.albumArtistLine, coverItemId = albumId,
            artistId = song.albumArtists?.firstOrNull()?.id, action = HighlightAction.Album(albumId, song.album ?: ""))
    }

    /** One of your favorite albums. */
    private suspend fun fromFavorites(client: JellyfinClient): Highlight? {
        val album = client.favoriteAlbums().randomOrNull() ?: return null
        return Highlight("favorite", "From your favorites", album.name, album.albumArtistLine, coverItemId = album.id,
            artistId = album.albumArtists?.firstOrNull()?.id, action = HighlightAction.Album(album.id, album.name))
    }
}
