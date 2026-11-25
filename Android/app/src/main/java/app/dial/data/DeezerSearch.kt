package app.dial.data

import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.contentOrNull
import java.net.URLEncoder
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope

/**
 * Search beyond your library, the way music apps do it: Deezer answers artists, albums and songs in a few requests,
 * with photos and covers and no key. When Deezer cannot be reached, iTunes answers albums and songs instead.
 * Each search is saved for a day, so typing the same words again is instant.
 */
object DeezerSearch {
    private const val DAY_MS = 24L * 3600 * 1000

    private fun JsonObject.str(key: String) = (this[key] as? kotlinx.serialization.json.JsonPrimitive)?.contentOrNull
    private fun JsonObject.obj(key: String) = (this[key] as? JsonObject)

    // MARK: Artists and albums

    suspend fun artistsAndAlbums(term: String): List<PublicMusic.Pick> {
        val key = "deezer-artists-albums-v1-" + term.lowercase()
        PublicMusic.cached(key, ListSerializer(PublicMusic.Pick.serializer()), DAY_MS)?.let { return it }
        val (foundArtists, foundAlbums) = coroutineScope {
            val artists = async { items("artist", term, 8) }
            val albums = async { items("album", term, 10) }
            artists.await() to albums.await()
        }
        val picks = if (foundArtists != null || foundAlbums != null) {
            (foundArtists ?: emptyList()).map {
                PublicMusic.Pick("artist", "", it.obj("artist")?.str("name") ?: it.str("name") ?: "",
                    sourceId = "dz-${it.str("id")}", image = it.str("picture_big"))
            } + (foundAlbums ?: emptyList()).map {
                PublicMusic.Pick("album", "", it.str("title") ?: "", it.obj("artist")?.str("name"),
                    coverFile = it.str("cover_big"), sourceId = "dz-${it.str("id")}")
            }
        } else {
            iTunesAlbums(term)
        }
        if (picks.isNotEmpty()) PublicMusic.save(key, ListSerializer(PublicMusic.Pick.serializer()), picks)
        return picks
    }

    // MARK: Songs

    suspend fun songs(term: String): List<PublicMusic.SongPick> {
        val key = "deezer-songs-v2-" + term.lowercase()
        PublicMusic.cached(key, ListSerializer(PublicMusic.SongPick.serializer()), DAY_MS)?.let { return it }
        val tracks = items("track", term, 25)
        val picks = if (tracks != null) {
            tracks.mapNotNull { track ->
                val id = track.str("id") ?: return@mapNotNull null
                val album = track.obj("album")
                PublicMusic.SongPick("dz-$id", track.str("title") ?: return@mapNotNull null,
                    track.obj("artist")?.str("name") ?: "", null, album?.str("title"), null, null,
                    album?.str("id")?.let { "dz-$it" },
                    album?.str("cover_big")?.ifEmpty { null })
            }
        } else {
            iTunesSongs(term)
        }.let { dedupe(it) }
        if (picks.isNotEmpty()) PublicMusic.save(key, ListSerializer(PublicMusic.SongPick.serializer()), picks)
        return picks
    }

    /** The same song from several albums is shown once. */
    private fun dedupe(picks: List<PublicMusic.SongPick>): List<PublicMusic.SongPick> {
        val seen = HashSet<String>()
        return picks.filter { seen.add(ArtistNames.key(it.title) + "|" + ArtistNames.key(it.artist)) }.take(25)
    }

    // MARK: Albums that aren't on MusicBrainz

    /** Whether an album id came from Deezer or iTunes (rather than being a MusicBrainz release group). */
    fun isSourceId(id: String) = id.startsWith("dz-") || id.startsWith("it-")

    /** The songs on a Deezer or iTunes album; null when the lookup failed (try again), empty when it has none. */
    suspend fun tracklist(sourceId: String): List<PublicMusic.Track>? {
        val key = "source-tracks-v1-$sourceId"
        PublicMusic.cached(key, ListSerializer(PublicMusic.Track.serializer()), 30 * DAY_MS)?.let { return it }
        val id = sourceId.drop(3)
        val tracks: List<PublicMusic.Track>? = if (sourceId.startsWith("dz-")) {
            val text = PublicMusic.fetched("https://api.deezer.com/album/$id/tracks?limit=200").body ?: return null
            val rows = runCatching {
                PublicMusicJson.parse(text).jsonObject["data"]?.jsonArray
            }.getOrNull() ?: return null
            rows.mapIndexed { index, row ->
                val o = row.jsonObject
                PublicMusic.Track(o["disk_number"]?.jsonPrimitive?.intOrNull ?: 1,
                    o["track_position"]?.jsonPrimitive?.intOrNull ?: (index + 1),
                    o.str("title") ?: "", (o["duration"]?.jsonPrimitive?.intOrNull ?: 0) * 1000)
            }
        } else {
            val text = PublicMusic.fetched("https://itunes.apple.com/lookup?id=$id&entity=song&limit=200").body ?: return null
            val rows = runCatching { PublicMusicJson.parse(text).jsonObject["results"]?.jsonArray }.getOrNull() ?: return null
            rows.map { it.jsonObject }.filter { it.str("wrapperType") == "track" }.mapIndexedNotNull { index, o ->
                val title = o.str("trackName") ?: return@mapIndexedNotNull null
                PublicMusic.Track(o["discNumber"]?.jsonPrimitive?.intOrNull ?: 1,
                    o["trackNumber"]?.jsonPrimitive?.intOrNull ?: (index + 1),
                    title, o["trackTimeMillis"]?.jsonPrimitive?.intOrNull)
            }
        }
        if (!tracks.isNullOrEmpty()) PublicMusic.save(key, ListSerializer(PublicMusic.Track.serializer()), tracks)
        return tracks
    }

    /** An album's Deezer id ("dz-…"), found by its artist and title, for albums MusicBrainz doesn't know. */
    suspend fun albumSourceId(artist: String, title: String): String? {
        val albums = items("album", "$artist $title", 10) ?: return null
        val wanted = ArtistNames.key(title)
        val wantedArtist = ArtistNames.key(artist)
        val match = albums.firstOrNull {
            ArtistNames.key(it.str("title") ?: "") == wanted && ArtistNames.key(it.obj("artist")?.str("name") ?: "") == wantedArtist
        } ?: albums.firstOrNull { ArtistNames.key(it.str("title") ?: "") == wanted }
        return match?.str("id")?.let { "dz-$it" }
    }

    // MARK: Deezer

    /** The results of one Deezer search; null when Deezer could not answer (an error or no connection), empty when it found nothing. */
    private suspend fun items(kind: String, term: String, limit: Int): List<JsonObject>? {
        val query = URLEncoder.encode(term, "UTF-8")
        val text = PublicMusic.fetched("https://api.deezer.com/search/$kind?q=$query&limit=$limit").body ?: return null
        return runCatching { PublicMusicJson.parse(text).jsonObject["data"]?.jsonArray?.map { it.jsonObject } }.getOrNull()
    }

    // MARK: iTunes (fallback)

    private suspend fun iTunesAlbums(term: String): List<PublicMusic.Pick> {
        val items = iTunes("album", term, 10) ?: return emptyList()
        return items.mapNotNull { item ->
            val id = item["collectionId"]?.jsonPrimitive?.contentOrNull ?: return@mapNotNull null
            PublicMusic.Pick("album", "", item.str("collectionName") ?: return@mapNotNull null, item.str("artistName"),
                coverFile = item.str("artworkUrl100")?.replace("100x100bb", "600x600bb"), sourceId = "it-$id")
        }
    }

    private suspend fun iTunesSongs(term: String): List<PublicMusic.SongPick> {
        val items = iTunes("song", term, 25) ?: return emptyList()
        return items.mapNotNull { item ->
            val id = item["trackId"]?.jsonPrimitive?.contentOrNull ?: return@mapNotNull null
            PublicMusic.SongPick("it-$id", item.str("trackName") ?: return@mapNotNull null,
                item.str("artistName") ?: "", null, item.str("collectionName"), null, null,
                item["collectionId"]?.jsonPrimitive?.contentOrNull?.let { "it-$it" },
                item.str("artworkUrl100")?.replace("100x100bb", "600x600bb"))
        }
    }

    private suspend fun iTunes(entity: String, term: String, limit: Int): List<JsonObject>? {
        val query = URLEncoder.encode(term, "UTF-8")
        val text = PublicMusic.fetched("https://itunes.apple.com/search?term=$query&entity=$entity&limit=$limit").body ?: return null
        return runCatching { PublicMusicJson.parse(text).jsonObject["results"]?.jsonArray?.map { it.jsonObject } }.getOrNull()
    }
}

/** Plain JSON for the discovery sources (Deezer, iTunes): numbers stay numbers, unlike the Jellyfin-tuned parser. */
private object PublicMusicJson {
    val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
    fun parse(text: String) = json.parseToJsonElement(text)
}
