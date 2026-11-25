package app.dial.data

import java.time.Instant
import java.time.temporal.ChronoUnit

/** What a highlight card does: open an album, open a release you don't own yet, or start an artist's radio. */
sealed interface HighlightAction {
    data class Album(val id: String, val name: String) : HighlightAction
    data class PublicAlbum(val pick: PublicMusic.Pick, val artist: String, val artistId: String?) : HighlightAction
    data class ArtistRadio(val id: String, val name: String) : HighlightAction
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

    private suspend fun newFromYourArtists(client: JellyfinClient): Highlight? {
        val fresh = PublicMusic.freshReleases()
        val artists = client.artists()
        val albums = client.albumsForBrowsing(1500)
        val owned = Owned(artists, albums)
        val pick = fresh.firstOrNull { owned.artistOf(it) != null } ?: return null
        val artist = owned.artistOf(pick) ?: return null
        val name = ArtistNames.primary(artist.name)
        val yours = owned.album(pick)
        return if (yours != null) Highlight("newRelease", "New from $name", pick.title, name, coverItemId = yours.id, artistId = artist.id,
            action = HighlightAction.Album(yours.id, yours.name))
        else Highlight("newRelease", "New from $name", pick.title, name, coverUrl = pick.cover, artistId = artist.id,
            action = HighlightAction.PublicAlbum(pick, name, artist.id))
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
