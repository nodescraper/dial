package app.dial.data

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import okhttp3.Request
import java.io.File
import java.net.URLEncoder

/**
 * Free, open music data, the same as on iPhone: MusicBrainz (discographies, tracklists), the Cover Art Archive
 * (covers), ListenBrainz (similar artists) and Wikidata / Wikimedia Commons (artist photos). Saved for a week.
 */
object PublicMusic {
    @Serializable
    data class Release(val id: String, val title: String, val year: Int?, val kind: String, val date: String? = null,
                       /** A direct link to the cover file, for releases found on Deezer or iTunes (they have no Cover Art Archive entry). */
                       val coverFile: String? = null) {
        val cover: String get() = coverFile ?: "https://coverartarchive.org/release-group/$id/front-250"
        val largeCover: String get() = coverFile ?: "https://coverartarchive.org/release-group/$id/front-500"
    }

    @Serializable
    data class Track(val disc: Int, val number: Int, val title: String, val lengthMs: Int?)

    @Serializable
    data class Similar(val mbid: String, val name: String, val score: Double)

    private lateinit var folder: File
    private val gate = Mutex()
    private var lastMusicBrainz = 0L
    private const val USER_AGENT = "Dial/0.1 ( https://github.com/ )"

    fun init(context: Context) {
        folder = File(context.cacheDir, "public").apply { mkdirs() }
    }

    /** What a lookup answered: the text, and whether it failed for a hiccup (worth asking again) rather than being "not there". */
    class Fetched(val body: String?, val failed: Boolean)

    /**
     * One request that tries again when the answer is a hiccup (rate limit, server busy, timeout, no connection) and stops at
     * once when it is final (404: it isn't there).
     */
    private suspend fun fetchChecked(url: String, musicBrainz: Boolean = false): Fetched = withContext(Dispatchers.IO) {
        var failed = false
        for (attempt in 0 until 3) {
            if (musicBrainz) gate.withLock {
                // MusicBrainz asks for about one request per second.
                val wait = 1100 - (System.currentTimeMillis() - lastMusicBrainz)
                if (wait > 0) delay(wait)
                lastMusicBrainz = System.currentTimeMillis()
            }
            var pause = 1500L * (attempt + 1)
            val answer = runCatching {
                val request = Request.Builder().url(url).header("User-Agent", USER_AGENT).header("Accept", "application/json").build()
                JellyfinClient.http.newCall(request).execute().use { r ->
                    Triple(r.code, if (r.isSuccessful) r.body?.string() else null, r.header("Retry-After")?.toLongOrNull())
                }
            }.getOrNull()
            if (answer != null) {
                val (code, body, retryAfter) = answer
                if (code == 200 && body != null) return@withContext Fetched(body, false)
                if (code in listOf(400, 401, 403, 404, 410)) return@withContext Fetched(null, false)
                if (retryAfter != null) pause = (retryAfter * 1000).coerceIn(1000, 8000)
            }
            failed = true
            if (attempt < 2) delay(pause)
        }
        Fetched(null, failed)
    }

    private suspend fun fetch(url: String, musicBrainz: Boolean = false): String? = fetchChecked(url, musicBrainz).body

    /** One request for the discovery sources beyond MusicBrainz (Deezer, iTunes): the body, and whether an empty answer means a hiccup. */
    internal suspend fun fetched(url: String): Fetched = fetchChecked(url)

    internal fun <T> cached(key: String, serializer: KSerializer<T>, maxAgeMs: Long = 7L * 24 * 3600 * 1000): T? {
        val file = File(folder, "$key.json")
        if (!file.exists() || System.currentTimeMillis() - file.lastModified() > maxAgeMs) return null
        return runCatching { JellyfinJson.decodeFromString(serializer, file.readText()) }.getOrNull()
    }

    internal fun <T> save(key: String, serializer: KSerializer<T>, value: T) {
        runCatching { File(folder, "$key.json").writeText(JellyfinJson.encodeToString(serializer, value)) }
    }

    // MARK: Genres of artists with no tags

    /** Genres the MusicBrainz community gave an artist, by name, saved for 90 days. With `fetch` off, only what is saved. */
    suspend fun artistGenres(name: String, fetch: Boolean = true): List<String>? {
        val key = "mb-artist-genres-" + ArtistNames.key(name).replace(Regex("[^a-z0-9]+"), "-").trim('-')
        cached(key, ListSerializer(String.serializer()), maxAgeMs = 90L * 24 * 3600 * 1000)?.let { return it }
        if (!fetch) return null
        val query = URLEncoder.encode("artist:\"$name\"", "UTF-8")
        val text = fetch("https://musicbrainz.org/ws/2/artist?query=$query&limit=1&fmt=json", musicBrainz = true) ?: return null
        val top = runCatching { JellyfinJson.parseToJsonElement(text).jsonObject["artists"]?.jsonArray?.firstOrNull()?.jsonObject }.getOrNull()
        val score = top?.get("score")?.jsonPrimitive?.intOrNull ?: 0
        if (top == null || score < 90) { save(key, ListSerializer(String.serializer()), emptyList()); return emptyList() }
        fun tags(field: String) = top[field]?.jsonArray?.mapNotNull { tag ->
            val o = tag.jsonObject
            o["name"]?.jsonPrimitive?.contentOrNull?.let { it to (o["count"]?.jsonPrimitive?.intOrNull ?: 0) }
        } ?: emptyList()
        val names = (tags("genres") + tags("tags")).sortedByDescending { it.second }.take(6).map { it.first }
        save(key, ListSerializer(String.serializer()), names)
        return names
    }

    // MARK: Discography

    /** Forgets the saved discographies (they are looked up again, one a second, next time they are needed). */
    fun clearDiscographies() {
        folder.listFiles()?.filter { it.name.startsWith("mb-discography-") }?.forEach { runCatching { it.delete() } }
    }

    /** A saved discography whatever its age, and how old it is in milliseconds (null if this artist has never been looked up). */
    fun savedDiscography(artistMbid: String): Pair<List<Release>, Long>? {
        val file = File(folder, "mb-discography-v2-$artistMbid.json")
        if (!file.exists()) return null
        val releases = runCatching { JellyfinJson.decodeFromString(ListSerializer(Release.serializer()), file.readText()) }.getOrNull() ?: return null
        return releases to (System.currentTimeMillis() - file.lastModified())
    }

    suspend fun discography(artistMbid: String, maxAgeMs: Long = 7L * 24 * 3600 * 1000): List<Release> {
        val key = "mb-discography-v2-$artistMbid"
        cached(key, ListSerializer(Release.serializer()), maxAgeMs)?.let { return it }
        // If MusicBrainz cannot be reached, the old copy is better than nothing.
        val old = savedDiscography(artistMbid)?.first
        val releases = mutableListOf<Release>()
        var offset = 0
        while (offset < 300) {
            val text = fetch("https://musicbrainz.org/ws/2/release-group?artist=$artistMbid&limit=100&offset=$offset&fmt=json", true) ?: break
            val root = JellyfinJson.parseToJsonElement(text).jsonObject
            val groups = root["release-groups"]?.jsonArray ?: break
            for (group in groups) {
                val g = group.jsonObject
                val secondary = (g["secondary-types"] as? JsonArray)?.map { it.jsonPrimitive.content.lowercase() } ?: emptyList()
                if (secondary.any { it in setOf("interview", "audiobook", "spokenword", "dj-mix", "demo") }) continue
                val kind = when {
                    "compilation" in secondary -> "compilation"
                    "live" in secondary -> "live"
                    else -> when (g["primary-type"]?.jsonPrimitive?.contentOrNull?.lowercase()) {
                        "album" -> "album"; "ep" -> "ep"; "single" -> "single"; else -> "other"
                    }
                }
                val year = g["first-release-date"]?.jsonPrimitive?.contentOrNull?.take(4)?.toIntOrNull()
                releases += Release(g["id"]!!.jsonPrimitive.content, g["title"]?.jsonPrimitive?.content ?: "", year, kind,
                    g["first-release-date"]?.jsonPrimitive?.contentOrNull)
            }
            offset += 100
            if (offset >= (root["release-group-count"]?.jsonPrimitive?.int ?: 0)) break
        }
        val sorted = releases.sortedByDescending { it.year ?: 0 }
        if (sorted.isNotEmpty()) save(key, ListSerializer(Release.serializer()), sorted)
        return if (sorted.isEmpty()) old ?: emptyList() else sorted
    }

    suspend fun tracklist(releaseGroupId: String): List<Track> = tracklistChecked(releaseGroupId).first

    /** The songs, and whether the list is empty because the lookup failed (try again) rather than MusicBrainz having none. */
    suspend fun tracklistChecked(releaseGroupId: String): Pair<List<Track>, Boolean> {
        // Albums found on Deezer or iTunes (not on MusicBrainz) get their songs from there.
        if (DeezerSearch.isSourceId(releaseGroupId)) {
            val tracks = DeezerSearch.tracklist(releaseGroupId)
            return (tracks ?: emptyList()) to (tracks == null)
        }
        val key = "mb-tracks-$releaseGroupId"
        cached(key, ListSerializer(Track.serializer()), 30L * 24 * 3600 * 1000)?.let { return it to false }
        var failed = false
        // The official editions first; if there are none (promos, unlabelled releases), any edition with songs.
        for (filter in listOf("&status=official", "")) {
            val answer = fetchChecked("https://musicbrainz.org/ws/2/release?release-group=$releaseGroupId&inc=recordings$filter&limit=25&fmt=json", true)
            if (answer.failed) failed = true
            val text = answer.body ?: continue
            val releases = runCatching { JellyfinJson.parseToJsonElement(text).jsonObject["releases"]?.jsonArray }.getOrNull() ?: continue
            // The earliest edition, as the album first came out, among those with songs.
            val release = releases.map { it.jsonObject }
                .filter { (it["media"] as? JsonArray)?.isNotEmpty() == true }
                .minByOrNull { it["date"]?.jsonPrimitive?.contentOrNull ?: "9999" } ?: continue
            val tracks = release["media"]!!.jsonArray.flatMapIndexed { disc, medium ->
                val m = medium.jsonObject
                val position = m["position"]?.jsonPrimitive?.intOrNull ?: (disc + 1)
                (m["tracks"] as? JsonArray ?: JsonArray(emptyList())).mapIndexed { index, track ->
                    val t = track.jsonObject
                    Track(position, t["number"]?.jsonPrimitive?.contentOrNull?.toIntOrNull() ?: (index + 1),
                        t["title"]?.jsonPrimitive?.content ?: "", t["length"]?.jsonPrimitive?.intOrNull)
                }
            }
            if (tracks.isNotEmpty()) { save(key, ListSerializer(Track.serializer()), tracks); return tracks to false }
        }
        // Nothing is saved for a miss, so the next visit asks again.
        return emptyList<Track>() to failed
    }

    /** Songs on the album that you don't have: the official edition closest to what you own, minus songs whose title matches one of yours. */
    class Gaps(val missing: List<Track>, val positions: Map<String, Pair<Int, Int>>)

    suspend fun missingTracks(album: Item, owned: List<Item>): Gaps {
        val none = Gaps(emptyList(), emptyMap())
        if (owned.isEmpty()) return none
        val artist = ArtistNames.primary(album.albumArtistLine)
        var groupId = album.releaseGroupId
        if (groupId == null) {
            val key = "mb-group-" + normalized(artist) + "-" + normalized(album.name)
            groupId = cached(key, String.serializer(), 30L * 24 * 3600 * 1000)
            if (groupId == null) {
                val query = URLEncoder.encode("releasegroup:\"${album.name}\" AND artist:\"$artist\" AND primarytype:album", "UTF-8")
                val text = fetch("https://musicbrainz.org/ws/2/release-group?query=$query&limit=1&fmt=json", true)
                val top = text?.let { runCatching { JellyfinJson.parseToJsonElement(it).jsonObject["release-groups"]?.jsonArray?.firstOrNull()?.jsonObject }.getOrNull() }
                val score = top?.get("score")?.jsonPrimitive?.intOrNull ?: 100
                if (top != null && score >= 90 && normalized(top["title"]?.jsonPrimitive?.contentOrNull ?: "") == normalized(album.name)) {
                    groupId = top["id"]?.jsonPrimitive?.contentOrNull
                    if (groupId != null) save(key, String.serializer(), groupId)
                }
            }
        }
        if (groupId == null) return none
        val editions = editionTracks(groupId)
        val have = owned.size
        fun cost(e: List<Track>) = if (e.size >= have) e.size - have else (have - e.size) * 3 + 1000
        val edition = editions.minByOrNull { cost(it) } ?: return none
        fun same(a: String, b: String) = a == b || (a.length > 5 && b.length > 5 && (a.startsWith(b) || b.startsWith(a)))
        val free = owned.map { it to normalized(it.name) }.toMutableList()
        val missing = mutableListOf<Track>()
        val positions = mutableMapOf<String, Pair<Int, Int>>()
        for (track in edition) {
            val title = normalized(track.title)
            val at = if (title.isEmpty()) -1 else free.indexOfFirst { same(it.second, title) }
            if (at >= 0) { positions[free[at].first.id] = track.disc to track.number; free.removeAt(at) } else missing += track
        }
        return Gaps(missing, positions)
    }

    /** A title with the extras removed ("(Remastered 2011)", "feat. X", punctuation, case), for comparing songs. */
    fun normalized(title: String): String {
        var text = title.lowercase()
        text = text.replace(Regex("\\([^)]*\\)|\\[[^\\]]*\\]"), "")
        for (marker in listOf(" feat.", " feat ", " ft.", " - remaster", " - live")) {
            val at = text.indexOf(marker)
            if (at >= 0) text = text.substring(0, at)
        }
        return text.filter { it.isLetterOrDigit() }
    }

    private suspend fun editionTracks(groupId: String): List<List<Track>> {
        val key = "mb-editions-$groupId"
        cached(key, ListSerializer(ListSerializer(Track.serializer())), 30L * 24 * 3600 * 1000)?.let { return it }
        val text = fetch("https://musicbrainz.org/ws/2/release?release-group=$groupId&inc=recordings&status=official&limit=25&fmt=json", true)
            ?: return emptyList()
        val releases = JellyfinJson.parseToJsonElement(text).jsonObject["releases"]?.jsonArray ?: return emptyList()
        val editions = releases.mapNotNull { release ->
            val media = release.jsonObject["media"] as? JsonArray ?: return@mapNotNull null
            val tracks = media.flatMapIndexed { disc, medium ->
                val m = medium.jsonObject
                val position = m["position"]?.jsonPrimitive?.intOrNull ?: (disc + 1)
                (m["tracks"] as? JsonArray ?: JsonArray(emptyList())).mapIndexed { index, track ->
                    val t = track.jsonObject
                    Track(position, t["number"]?.jsonPrimitive?.contentOrNull?.toIntOrNull() ?: (index + 1),
                        t["title"]?.jsonPrimitive?.content ?: "", t["length"]?.jsonPrimitive?.intOrNull)
                }
            }
            tracks.ifEmpty { null }
        }
        if (editions.isNotEmpty()) save(key, ListSerializer(ListSerializer(Track.serializer())), editions)
        return editions
    }

    // MARK: What the world plays (ListenBrainz)

    /** One of an artist's most played songs worldwide. */
    @Serializable
    data class TopTrack(val id: String, val title: String, val album: String? = null, val listens: Int = 0, val lengthMs: Int? = null)

    /** An artist's most listened songs across everyone on ListenBrainz, most played first (repeats of a title folded together). Saved for three days. */
    suspend fun topTracks(artistMbid: String): List<TopTrack> {
        val key = "lb-top-tracks-$artistMbid"
        cached(key, ListSerializer(TopTrack.serializer()), 3L * 24 * 3600 * 1000)?.let { return it }
        val text = fetch("https://api.listenbrainz.org/1/popularity/top-recordings-for-artist/$artistMbid") ?: return emptyList()
        val rows = runCatching { JellyfinJson.parseToJsonElement(text).jsonArray }.getOrNull() ?: return emptyList()
        val seen = HashSet<String>()
        val tracks = mutableListOf<TopTrack>()
        for (row in rows) {
            val o = row as? JsonObject ?: continue
            val title = o.s("recording_name") ?: continue
            val id = o.s("recording_mbid") ?: continue
            if (!seen.add(normalized(title))) continue
            tracks += TopTrack(id, title, o.s("release_name"), o["total_listen_count"]?.jsonPrimitive?.intOrNull ?: 0, o["length"]?.jsonPrimitive?.intOrNull)
            if (tracks.size >= 15) break
        }
        if (tracks.isNotEmpty()) save(key, ListSerializer(TopTrack.serializer()), tracks)
        return tracks
    }

    // MARK: Links and covers the Cover Art Archive does not have

    /** The album's page on Spotify when MusicBrainz has the link (many releases do not); null otherwise. Saved for a month. */
    suspend fun spotifyAlbumUrl(releaseGroupId: String): String? {
        val key = "spotify-link-$releaseGroupId"
        val file = File(folder, "$key.json")
        if (file.exists()) {
            val age = System.currentTimeMillis() - file.lastModified()
            val saved = runCatching { JellyfinJson.decodeFromString(String.serializer(), file.readText()) }.getOrNull()
            if (saved != null && (if (saved.isEmpty()) age < 3L * 24 * 3600 * 1000 else age < 30L * 24 * 3600 * 1000)) return saved.ifEmpty { null }
        }
        val answer = fetchChecked("https://musicbrainz.org/ws/2/release-group/$releaseGroupId?inc=url-rels&fmt=json", true)
        val link = answer.body?.let { text ->
            runCatching {
                JellyfinJson.parseToJsonElement(text).jsonObject["relations"]?.jsonArray?.mapNotNull {
                    it.jsonObject["url"]?.jsonObject?.get("resource")?.jsonPrimitive?.contentOrNull
                }?.firstOrNull { it.contains("open.spotify.com/album") }
            }.getOrNull()
        }
        if (!answer.failed) save(key, String.serializer(), link ?: "")
        return link
    }

    /** Where else a release group's cover can come from: iTunes' public search, matched by artist and title. Saved for a month. */
    suspend fun alternativeCover(releaseGroupId: String): String? {
        val key = "cover-alt-$releaseGroupId"
        val file = File(folder, "$key.json")
        if (file.exists()) {
            val age = System.currentTimeMillis() - file.lastModified()
            val saved = runCatching { JellyfinJson.decodeFromString(String.serializer(), file.readText()) }.getOrNull()
            if (saved != null && (if (saved.isEmpty()) age < 2L * 24 * 3600 * 1000 else age < 30L * 24 * 3600 * 1000)) return saved.ifEmpty { null }
        }
        val group = fetch("https://musicbrainz.org/ws/2/release-group/$releaseGroupId?inc=artists&fmt=json", true)
            ?.let { runCatching { JellyfinJson.parseToJsonElement(it).jsonObject }.getOrNull() } ?: return null
        val title = group["title"]?.jsonPrimitive?.contentOrNull ?: return null
        val artist = (group["artist-credit"] as? JsonArray)?.firstOrNull()?.jsonObject?.get("name")?.jsonPrimitive?.contentOrNull ?: ""
        val term = URLEncoder.encode("$artist $title", "UTF-8")
        val found = fetch("https://itunes.apple.com/search?term=$term&entity=album&limit=8")?.let {
            runCatching { JellyfinJson.parseToJsonElement(it).jsonObject["results"]?.jsonArray }.getOrNull()
        }?.map { it.jsonObject }
        val wantedTitle = normalized(title)
        val wantedArtist = normalized(artist)
        val match = found?.firstOrNull {
            normalized(it["collectionName"]?.jsonPrimitive?.contentOrNull ?: "") == wantedTitle &&
                normalized(it["artistName"]?.jsonPrimitive?.contentOrNull ?: "").contains(wantedArtist.take(6))
        } ?: found?.firstOrNull {
            normalized(it["collectionName"]?.jsonPrimitive?.contentOrNull ?: "").startsWith(wantedTitle) &&
                normalized(it["artistName"]?.jsonPrimitive?.contentOrNull ?: "") == wantedArtist
        }
        val url = match?.get("artworkUrl100")?.jsonPrimitive?.contentOrNull?.replace("100x100bb", "600x600bb")
        save(key, String.serializer(), url ?: "")
        return url
    }

    /** A song you may not have, with the album it is on (when known). */
    @Serializable
    data class SongPick(val id: String, val title: String, val artist: String, val artistMbid: String?, val album: String?,
                        val releaseGroupId: String? = null, val year: Int? = null,
                        /** The album's Deezer or iTunes id ("dz-…", "it-…"), so it opens without a lookup. */
                        val albumSourceId: String? = null,
                        val albumCover: String? = null)

    /** Songs beyond your library, for the Songs filter of search (Deezer, with iTunes when Deezer cannot be reached). */
    suspend fun searchSongs(term: String): List<SongPick> = DeezerSearch.songs(term)

    // MARK: Similar artists

    suspend fun similarArtists(artistMbid: String): List<Similar> {
        val key = "lb-similar-$artistMbid"
        cached(key, ListSerializer(Similar.serializer()))?.let { return it }
        val algorithm = "session_based_days_7500_session_300_contribution_5_threshold_10_limit_100_filter_True_skip_30"
        val text = fetch("https://labs.api.listenbrainz.org/similar-artists/json?artist_mbids=$artistMbid&algorithm=$algorithm") ?: return emptyList()
        val rows = runCatching { JellyfinJson.parseToJsonElement(text).jsonArray }.getOrNull() ?: return emptyList()
        val similar = rows.mapNotNull { row ->
            val o = row as? JsonObject ?: return@mapNotNull null
            val mbid = o["artist_mbid"]?.jsonPrimitive?.contentOrNull ?: return@mapNotNull null
            if (mbid == artistMbid) null
            else Similar(mbid, o["name"]?.jsonPrimitive?.content ?: "", o["score"]?.jsonPrimitive?.doubleOrNull ?: 0.0)
        }.sortedByDescending { it.score }
        if (similar.isNotEmpty()) save(key, ListSerializer(Similar.serializer()), similar)
        return similar
    }

    /** Similar artists that are in your library. */
    suspend fun similarInLibrary(artist: Item, library: List<Item>): List<Item> {
        val mbid = artist.musicBrainzId ?: return emptyList()
        val byMbid = library.filter { it.musicBrainzId != null }.associateBy { it.musicBrainzId!! }
        val byName = library.associateBy { ArtistNames.key(it.name) }
        return similarArtists(mbid).take(40).mapNotNull { byMbid[it.mbid] ?: byName[ArtistNames.key(it.name)] }
            .filter { it.id != artist.id }.distinctBy { it.id }.take(15)
    }

    // MARK: Discovery: charts, fresh releases, genres, search (ListenBrainz and MusicBrainz)

    /** Something to discover: an artist or an album, with its MusicBrainz id. */
    @Serializable
    data class Pick(val kind: String, val mbid: String, val title: String, val artist: String? = null,
                    val artistMbid: String? = null, val year: Int? = null, val tags: List<String> = emptyList(),
                    /** "2026-10-31" (or less exact), for telling what is new. */
                    val releaseDate: String? = null,
                    /** The artist's photo, when the plugin has one. */
                    val image: String? = null,
                    /** The Deezer or iTunes id, for results found there (they have no MusicBrainz id until one is looked up by name). */
                    val sourceId: String? = null,
                    /** A direct link to the cover file, when the source knows it (faster and more reliable than a lookup). */
                    val coverFile: String? = null) {
        val isArtist get() = kind == "artist"
        /** The id to open: the MusicBrainz id, or the Deezer/iTunes id for results found there. */
        val releaseId get() = if (mbid.isNotEmpty()) mbid else sourceId ?: ""
        /** A stable key for lists: Deezer and iTunes results have no MusicBrainz id. */
        val listId get() = if (mbid.isNotEmpty()) mbid else sourceId ?: "$kind-$title-$artist"
        val cover get() = coverFile ?: if (mbid.isEmpty()) null
            else "https://coverartarchive.org/release-group/$mbid/front-250"
        /** Found on Deezer or iTunes, it has no MusicBrainz id: its page opens by that source's id instead. */
        val release get() = Release(releaseId, title, year, "album", coverFile = coverFile)
    }

    private fun JsonObject.s(key: String) = (this[key] as? kotlinx.serialization.json.JsonPrimitive)?.contentOrNull
    private fun JsonObject.firstOf(key: String) = (this[key] as? JsonArray)?.firstOrNull()?.jsonPrimitive?.contentOrNull

    suspend fun popularArtists(): List<Pick> {
        cached("lb-top-artists", ListSerializer(Pick.serializer()), 12L * 3600 * 1000)?.let { return it }
        val text = fetch("https://api.listenbrainz.org/1/stats/sitewide/artists?range=week&count=40") ?: return emptyList()
        val rows = runCatching { JellyfinJson.parseToJsonElement(text).jsonObject["payload"]!!.jsonObject["artists"]!!.jsonArray }.getOrNull() ?: return emptyList()
        val picks = rows.mapNotNull { r -> val o = r.jsonObject
            val mbid = o.s("artist_mbid") ?: o.firstOf("artist_mbids") ?: return@mapNotNull null
            Pick("artist", mbid, o.s("artist_name") ?: return@mapNotNull null) }
        if (picks.isNotEmpty()) save("lb-top-artists", ListSerializer(Pick.serializer()), picks)
        return picks
    }

    suspend fun popularAlbums(): List<Pick> {
        cached("lb-top-albums", ListSerializer(Pick.serializer()), 12L * 3600 * 1000)?.let { return it }
        val text = fetch("https://api.listenbrainz.org/1/stats/sitewide/release-groups?range=week&count=40") ?: return emptyList()
        val rows = runCatching { JellyfinJson.parseToJsonElement(text).jsonObject["payload"]!!.jsonObject["release_groups"]!!.jsonArray }.getOrNull() ?: return emptyList()
        val picks = rows.mapNotNull { r -> val o = r.jsonObject
            Pick("album", o.s("release_group_mbid") ?: return@mapNotNull null, o.s("release_group_name") ?: return@mapNotNull null,
                o.s("artist_name"), o.firstOf("artist_mbids")) }
        if (picks.isNotEmpty()) save("lb-top-albums", ListSerializer(Pick.serializer()), picks)
        return picks
    }

    suspend fun freshReleases(): List<Pick> {
        cached("lb-fresh", ListSerializer(Pick.serializer()), 12L * 3600 * 1000)?.let { return it }
        val text = fetch("https://api.listenbrainz.org/1/explore/fresh-releases/?days=21&sort=release_date&past=true&future=false") ?: return emptyList()
        val rows = runCatching { JellyfinJson.parseToJsonElement(text).jsonObject["payload"]!!.jsonObject["releases"]!!.jsonArray }.getOrNull() ?: return emptyList()
        val picks = rows.mapNotNull { r -> val o = r.jsonObject
            val type = o.s("release_group_primary_type")?.lowercase()
            if (type != null && type != "album" && type != "ep") return@mapNotNull null
            Pick("album", o.s("release_group_mbid") ?: return@mapNotNull null, o.s("release_name") ?: return@mapNotNull null,
                o.s("artist_credit_name"), o.firstOf("artist_mbids"), o.s("release_date")?.take(4)?.toIntOrNull(),
                (o["release_tags"] as? JsonArray)?.map { it.jsonPrimitive.content.lowercase() } ?: emptyList())
        }.distinctBy { it.mbid }.reversed()
        if (picks.isNotEmpty()) save("lb-fresh", ListSerializer(Pick.serializer()), picks)
        return picks
    }

    suspend fun artistsTagged(genre: String): List<Pick> {
        val key = "mb-genre-" + genre.replace(" ", "-")
        cached(key, ListSerializer(Pick.serializer()))?.let { return it }
        val query = URLEncoder.encode("tag:\"$genre\"", "UTF-8")
        val text = fetch("https://musicbrainz.org/ws/2/artist?query=$query&limit=40&fmt=json", true) ?: return emptyList()
        val picks = (JellyfinJson.parseToJsonElement(text).jsonObject["artists"] as? JsonArray ?: JsonArray(emptyList())).mapNotNull { r ->
            val o = r.jsonObject; Pick("artist", o.s("id") ?: return@mapNotNull null, o.s("name") ?: return@mapNotNull null, tags = listOf(genre)) }
        if (picks.isNotEmpty()) save(key, ListSerializer(Pick.serializer()), picks)
        return picks
    }

    /** Artists and albums anywhere that match a search, for results beyond your library (Deezer, with iTunes when Deezer cannot be reached). */
    suspend fun search(term: String): List<Pick> = DeezerSearch.artistsAndAlbums(term)

    /** An artist's MusicBrainz id, found by name (null when MusicBrainz has no clear match or cannot be reached). */
    suspend fun artistMbid(name: String): String? = findArtist(name)

    /** An album's MusicBrainz release group id, found by its artist and title (null when there is no clear match). */
    suspend fun releaseGroupId(artist: String, title: String): String? {
        val key = "mb-rg-for-" + ArtistNames.key(artist).replace(Regex("[^a-z0-9]+"), "-") + "-" +
            ArtistNames.key(title).replace(Regex("[^a-z0-9]+"), "-")
        cached(key, String.serializer(), 30L * 24 * 3600 * 1000)?.let { return it.ifEmpty { null } }
        val query = URLEncoder.encode("releasegroup:\"${title.replace("\"", "")}\" AND artist:\"${artist.replace("\"", "")}\"", "UTF-8")
        val text = fetch("https://musicbrainz.org/ws/2/release-group?query=$query&limit=5&fmt=json", musicBrainz = true)
        val first = text?.let { runCatching { JellyfinJson.parseToJsonElement(it).jsonObject["release-groups"]?.jsonArray }.getOrNull() }
            ?.map { it.jsonObject }
            ?.firstOrNull { (it["score"]?.jsonPrimitive?.intOrNull ?: 0) >= 90 && ArtistNames.key(it.s("title") ?: "") == ArtistNames.key(title) }
        val id = first?.s("id") ?: ""
        save(key, String.serializer(), id)
        return id.ifEmpty { null }
    }

    // MARK: Artist photos (Wikidata and Wikimedia Commons, through MusicBrainz)

    /** An artist's photo by MusicBrainz id: MusicBrainz links to Wikidata, which names a photo on Wikimedia Commons. */
    suspend fun artistImage(mbid: String? = null, name: String): String? {
        val id = mbid ?: findArtist(name) ?: return null
        val key = "photo-$id"
        cached(key, String.serializer(), 30L * 24 * 3600 * 1000)?.let { return it.ifEmpty { null } }
        val text = fetch("https://musicbrainz.org/ws/2/artist/$id?inc=url-rels&fmt=json", true) ?: return null
        val relations = (JellyfinJson.parseToJsonElement(text).jsonObject["relations"] as? JsonArray) ?: JsonArray(emptyList())
        val wikidata = relations.map { it.jsonObject }.firstOrNull { it["type"]?.jsonPrimitive?.contentOrNull == "wikidata" }
            ?.get("url")?.jsonObject?.get("resource")?.jsonPrimitive?.contentOrNull
        val entity = wikidata?.substringAfterLast('/')
        val file = entity?.let { fetch("https://www.wikidata.org/wiki/Special:EntityData/$it.json") }?.let { json ->
            runCatching {
                JellyfinJson.parseToJsonElement(json).jsonObject["entities"]!!.jsonObject[entity]!!.jsonObject["claims"]!!
                    .jsonObject["P18"]!!.jsonArray[0].jsonObject["mainsnak"]!!.jsonObject["datavalue"]!!.jsonObject["value"]!!
                    .jsonPrimitive.content
            }.getOrNull()
        }
        val photo = file?.let { "https://commons.wikimedia.org/wiki/Special:FilePath/" + URLEncoder.encode(it.replace(' ', '_'), "UTF-8").replace("+", "%20") + "?width=400" }
        save(key, String.serializer(), photo ?: "") // remembered either way, for a month
        return photo
    }

    /** The MusicBrainz id for an artist name. */
    private suspend fun findArtist(name: String): String? {
        val key = "mbid-for-" + ArtistNames.key(name).replace(Regex("[^a-z0-9]+"), "-")
        cached(key, String.serializer(), 30L * 24 * 3600 * 1000)?.let { return it.ifEmpty { null } }
        val query = URLEncoder.encode("artist:\"$name\"", "UTF-8")
        val text = fetch("https://musicbrainz.org/ws/2/artist?query=$query&limit=1&fmt=json", true) ?: return null
        val first = JellyfinJson.parseToJsonElement(text).jsonObject["artists"]?.jsonArray?.firstOrNull()?.jsonObject
        val id = first?.takeIf { ArtistNames.key(it["name"]?.jsonPrimitive?.content ?: "") == ArtistNames.key(name) }
            ?.get("id")?.jsonPrimitive?.contentOrNull
        save(key, String.serializer(), id ?: "")
        return id
    }
}
