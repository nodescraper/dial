package app.dial.data

import android.content.Context
import android.content.SharedPreferences
import android.util.Xml
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Request
import org.xmlpull.v1.XmlPullParser
import java.io.File
import java.net.URLEncoder
import java.text.Normalizer
import java.time.LocalDate
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit

/** An upcoming concert by an artist in your library. */
@Serializable
data class Concert(val id: String, val artist: String, val name: String, val date: String, val venue: String, val city: String,
                   val url: String, val image: String? = null)

/** An artist you play, with the MusicBrainz id Discovery looks them up by. */
@Serializable
data class DiscoveryArtist(val name: String, val mbid: String)

@Serializable
data class FanGroup(val seed: String, val picks: List<PublicMusic.Pick>)

/** Everything on the Discovery page, saved so it opens instantly and refreshed a part at a time. */
@Serializable
data class DiscoveryFeed(
    /** Recent albums and EPs by artists in your library. */
    val fresh: List<PublicMusic.Pick> = emptyList(),
    /** Albums, EPs and singles with a release date still ahead, soonest first. */
    val upcoming: List<PublicMusic.Pick> = emptyList(),
    /** Who the fans of the artists you play most also play. */
    val fans: List<FanGroup> = emptyList(),
    val concerts: List<Concert> = emptyList(),
    /** True while concerts are being looked up, so the page can show it is working. */
    val concertsLoading: Boolean = false,
    /** True while the people recommendations are being looked up. */
    val fansLoading: Boolean = false,
    /** How many of your artists have been looked through, out of how many. */
    val scanned: Int = 0,
    val total: Int = 0,
    val coreAt: Long = 0,
    val concertsAt: Long = 0,
    /** The artists you play most. Kept, so the server is not asked for them every time: renewed once a day. */
    val artists: List<DiscoveryArtist> = emptyList(),
    val artistsAt: Long = 0,
    /** When the last pass over the discographies started, so a half-finished one is not begun again within ten minutes. */
    val coreRunAt: Long = 0,
    /** Whether the plugin has concerts switched on (so the row shows a loader while the feed is on its way). */
    val concertsEnabled: Boolean = true,
    /** True while the feed is being fetched from the server (never kept between launches). */
    val loading: Boolean = false,
) {
    val isEmpty get() = fresh.isEmpty() && fans.isEmpty() && concerts.isEmpty()
}

/**
 * Builds the Discovery page from your library and the open music databases (the same as on iPhone and Mac). It is for people
 * who chose their own music: nothing global or random, only what concerns the artists you own.
 *
 * Caching: the page always shows what was saved last, at once, and the refresh happens quietly in the background, starting
 * soon after the app opens ([prefetch]), not when the tab is opened. Every part has its own schedule: concerts every twelve hours, your artist list and the rest once a day. MusicBrainz allows one request a second, so each artist's discography
 * is saved and renewed every three days, and no more than a dozen are renewed in one go (all of them the very first time).
 */
object DiscoveryEngine {
    private const val HOUR = 3600_000L
    private const val CONCERTS_MAX_AGE = 12 * HOUR
    private const val CORE_MAX_AGE = 24 * HOUR
    private const val ARTIST_LIMIT = 40
    /** A saved discography is shown whatever its age, and renewed in the background once it is this old. */
    private const val DISCOGRAPHY_MAX_AGE = 3 * 24 * HOUR
    private const val BATCH_SIZE = 12
    private const val CORE_RUN_GAP = 10 * 60_000L

    private lateinit var file: File
    private lateinit var prefs: SharedPreferences
    @Volatile var latest: DiscoveryFeed? = null
        private set

    fun init(context: Context) {
        file = File(context.cacheDir, "discovery-v1.json")
        prefs = context.getSharedPreferences("dial.discovery", Context.MODE_PRIVATE)
        latest = runCatching { JellyfinJson.decodeFromString(DiscoveryFeed.serializer(), file.readText()) }.getOrNull()?.copy(loading = false)
        // Concerts are now found by exact act match; ones saved before that (which could include tribute shows) are dropped once.
        if (!prefs.getBoolean("concertsExact", false)) {
            latest = latest?.copy(concerts = emptyList(), concertsAt = 0, concertsLoading = false)
            prefs.edit().putBoolean("concertsExact", true).apply()
        }
    }

    // Concerts are optional: they need a free Ticketmaster key, and with one the names of your most played artists are sent there.
    var ticketmasterKey: String
        get() = prefs.getString("tmKey", "")!!
        set(value) { prefs.edit().putString("tmKey", value.trim()).apply(); latest = latest?.copy(concertsAt = 0) }
    var city: String
        get() = prefs.getString("city", "")!!
        set(value) { prefs.edit().putString("city", value.trim()).apply(); latest = latest?.copy(concertsAt = 0) }
    var country: String
        get() = prefs.getString("country", "")!!
        set(value) { prefs.edit().putString("country", value.trim()).apply(); latest = latest?.copy(concertsAt = 0) }
    val concertsEnabled get() = ticketmasterKey.isNotBlank()

    /** Forgets everything Discovery saved (the page is rebuilt next time it opens). */
    fun clearCache() {
        latest = null
        runCatching { file.delete() }
        PublicMusic.clearDiscographies()
    }

    private fun save(feed: DiscoveryFeed) {
        latest = feed
        runCatching { file.writeText(JellyfinJson.encodeToString(DiscoveryFeed.serializer(), feed)) }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var job: Job? = null
    /** Whoever asked last gets the updates, so leaving the page and coming back while it is working picks it up again. */
    @Volatile private var listener: ((DiscoveryFeed) -> Unit)? = null

    /** What is in your library, as a check for "do I have this album", built from the album list. */
    private suspend fun ownership(client: JellyfinClient): (PublicMusic.Pick) -> Boolean {
        val albums = runCatching { client.albumsForBrowsing(3000) }.getOrDefault(emptyList())
        val withArtist = albums.map { LibraryMatcher.key(it.name) + "|" + ArtistNames.key(ArtistNames.primary(it.albumArtistLine)) }.toHashSet()
        val titles = albums.map { LibraryMatcher.key(it.name) }.toHashSet()
        return { pick ->
            val title = LibraryMatcher.key(pick.title)
            pick.artist?.let { "$title|${ArtistNames.key(ArtistNames.primary(it))}" in withArtist } ?: (title in titles)
        }
    }

    /** Brings Discovery up to date in the background, without a page asking for it: called soon after the app opens and when it
     *  comes back, so the page is already fresh when you get to it. Cheap when nothing is out of date. */
    fun prefetch(client: JellyfinClient) {
        if (job?.isActive == true) return
        job = scope.launch { run(client, ownership(client), false) }
    }

    /** Refreshes whatever is out of date (or everything, when [force] is set), calling [onUpdate] on the main thread as parts arrive. */
    fun refresh(client: JellyfinClient, isOwned: (PublicMusic.Pick) -> Boolean, force: Boolean, onUpdate: ((DiscoveryFeed) -> Unit)?) {
        if (onUpdate != null) listener = onUpdate
        if (job?.isActive == true) return
        job = scope.launch { run(client, isOwned, force) }
    }

    private suspend fun run(client: JellyfinClient, isOwned: (PublicMusic.Pick) -> Boolean, force: Boolean) {
        var feed = latest ?: DiscoveryFeed()
        suspend fun publish() {
            save(feed)
            val snapshot = feed
            withContext(Dispatchers.Main) { listener?.invoke(snapshot) }
        }
        // The server's Dial plugin makes the feed; the app only fetches it. Without the plugin there is no Discovery.
        if (true) {
            if (!DialPlugin.check(client)) return
            feed = feed.copy(loading = true)
            publish()
            var waited = 0
            while (true) {
                val result = client.dialDiscovery() ?: break
                if (result.second) {
                    val made = result.first
                    feed = feed.copy(fresh = made.fresh, upcoming = made.upcoming, artists = made.artists.ifEmpty { feed.artists },
                        fans = made.fans.map { FanGroup(it.seedName, it.picks) }, concerts = made.concerts, concertsEnabled = made.concertsEnabled)
                    break
                }
                // The very first feed takes the server a couple of minutes: keep asking, then try again later.
                if (++waited > 18) break
                delay(10_000)
            }
            feed = feed.copy(loading = false)
            publish()
            Follows.reconcile(feed)
            return
        }
        val now = System.currentTimeMillis()
        val concertsDue = concertsEnabled && (force || now - feed.concertsAt > CONCERTS_MAX_AGE)
        // A pass over the discographies is not started again within ten minutes, even if it is not finished.
        val coreDue = (force || now - feed.coreAt > CORE_MAX_AGE || feed.fresh.isEmpty()) && (force || now - feed.coreRunAt > CORE_RUN_GAP)
        if (!concertsEnabled && feed.concerts.isNotEmpty()) { feed = feed.copy(concerts = emptyList()); publish() }
        if (!(concertsDue || coreDue)) return

        // Your artists: kept from last time, renewed once a day.
        if (force || feed.artists.isEmpty() || now - feed.artistsAt > CORE_MAX_AGE) {
            val found = topArtists(client)
            if (found.isNotEmpty()) {
                feed = feed.copy(artists = found.map { DiscoveryArtist(it.name, it.mbid) }, artistsAt = now)
                publish()
            }
        }
        val artists = feed.artists.map { LibraryArtist(it.name, it.mbid) }

        // Concerts do not wait for the slow part.
        if (concertsDue) {
            feed = feed.copy(concertsLoading = true)
            publish()
            feed = feed.copy(concerts = fetchConcerts(artists.take(25).map { it.name }), concertsLoading = false, concertsAt = now)
            publish()
        }
        if (!coreDue || artists.isEmpty()) return

        feed = feed.copy(coreRunAt = System.currentTimeMillis(), fansLoading = true)
        // 1. Everything already known is shown at once, whatever its age.
        val byArtist = HashMap<String, List<PublicMusic.Pick>>()
        val needs = mutableListOf<LibraryArtist>()
        for (artist in artists) {
            val saved = PublicMusic.savedDiscography(artist.mbid)
            if (saved != null) {
                byArtist[artist.mbid] = newReleases(saved.first, artist, isOwned)
                if (saved.second > DISCOGRAPHY_MAX_AGE) needs += artist
            } else needs += artist
        }
        fun rebuild() { feed = feed.copy(fresh = byArtist.values.flatten().sortedByDescending { it.releaseDate ?: "${it.year ?: 0}" }) }
        rebuild()
        // 2. The ones not looked at for a while are renewed, a dozen at a time (all of them the very first time).
        val batch = needs.take(if (byArtist.isEmpty()) artists.size else BATCH_SIZE)
        feed = feed.copy(total = batch.size, scanned = 0)
        publish()
        batch.forEachIndexed { index, artist ->
            byArtist[artist.mbid] = newReleases(PublicMusic.discography(artist.mbid, DISCOGRAPHY_MAX_AGE), artist, isOwned)
            feed = feed.copy(scanned = index + 1)
            // The page fills in as it goes.
            if (index % 3 == 2 || index == batch.lastIndex) { rebuild(); publish() }
        }
        feed = feed.copy(fans = fans(artists), fansLoading = false, total = 0, scanned = 0,
            // Everything renewed: done for the day. Otherwise the next pass takes the next dozen.
            coreAt = if (needs.size <= batch.size) System.currentTimeMillis() else feed.coreAt)
        publish()
    }

    // MARK: Your artists

    private class LibraryArtist(val name: String, val mbid: String)

    /** The artists you play most that Jellyfin knows a MusicBrainz id for, most played first. */
    private suspend fun topArtists(client: JellyfinClient): List<LibraryArtist> {
        val played = runCatching { client.songsSorted("PlayCount", limit = 600) }.getOrDefault(emptyList())
            .filter { (it.userData?.playCount ?: 0) > 0 }
        val artists = runCatching { client.artists() }.getOrDefault(emptyList())
        val mbidByKey = artists.mapNotNull { a -> a.musicBrainzId?.let { ArtistNames.key(a.name) to it } }.toMap()
        val weight = HashMap<String, Pair<String, Double>>()
        for (song in played) {
            val name = ArtistNames.primary(song.albumArtist ?: song.artistLine)
            val key = ArtistNames.key(name)
            weight[key] = name to ((weight[key]?.second ?: 0.0) + minOf(song.userData?.playCount ?: 0, 30))
        }
        val ranked = weight.entries.sortedByDescending { it.value.second }
            .mapNotNull { (key, entry) -> mbidByKey[key]?.let { LibraryArtist(entry.first, it) } }
        if (ranked.size >= 10) return ranked.take(ARTIST_LIMIT)
        // Not much listening yet: the rest of your artists fill in.
        val result = ranked.toMutableList()
        val seen = result.map { it.mbid }.toHashSet()
        for (artist in artists) {
            if (result.size >= ARTIST_LIMIT) break
            val mbid = artist.musicBrainzId ?: continue
            if (seen.add(mbid)) result += LibraryArtist(ArtistNames.primary(artist.name), mbid)
        }
        return result
    }

    // MARK: New releases and missing albums

    private fun ageInDays(release: PublicMusic.Release): Long? {
        val date = release.date
        if (date == null || date.length < 4) return release.year?.let { if (it >= LocalDate.now().year) 0L else 10_000L }
        val full = when (date.length) { 4 -> "$date-01-01"; 7 -> "$date-01"; else -> date.take(10) }
        val parsed = runCatching { LocalDate.parse(full) }.getOrNull() ?: return null
        return ChronoUnit.DAYS.between(parsed, LocalDate.now())
    }

    /** What is new in an artist's discography that you don't have yet: recent albums and EPs, and singles while they are fresh. */
    private fun newReleases(releases: List<PublicMusic.Release>, artist: LibraryArtist, isOwned: (PublicMusic.Pick) -> Boolean): List<PublicMusic.Pick> {
        val fresh = mutableListOf<PublicMusic.Pick>()
        for (release in releases) {
            val age = ageInDays(release)?.takeIf { it >= 0 } ?: continue
            val recent = when (release.kind) { "album", "ep" -> age <= 150; "single" -> age <= 60; else -> false }
            if (!recent) continue
            val pick = PublicMusic.Pick("album", release.id, release.title, artist.name, artist.mbid, release.year, emptyList(), release.date)
            if (!isOwned(pick)) fresh += pick
        }
        return fresh
    }

    /** For the three artists you play most: who their fans also listen to (ListenBrainz), not counting what you own. */
    private suspend fun fans(artists: List<LibraryArtist>): List<FanGroup> {
        val seeds = artists.take(3)
        val used = artists.map { it.mbid }.toHashSet()
        return seeds.map { seed -> seed to PublicMusic.similarArtists(seed.mbid) }.mapNotNull { (seed, similar) ->
            val picks = similar.filter { used.add(it.mbid) }.take(12).map { PublicMusic.Pick("artist", it.mbid, it.name) }
            if (picks.isEmpty()) null else FanGroup(seed.name, picks)
        }
    }

    // MARK: Concerts

    private fun normalize(text: String) = Normalizer.normalize(text, Normalizer.Form.NFD).replace(Regex("\\p{M}+"), "").lowercase()
        .replace(Regex("[^\\p{L}\\p{N}]+"), " ").trim()

    private fun JsonObject.s(key: String) = (this[key] as? kotlinx.serialization.json.JsonPrimitive)?.contentOrNull

    private fun getJson(url: String): JsonObject? = runCatching {
        JellyfinClient.http.newCall(Request.Builder().url(url).build()).execute().use { if (it.isSuccessful) it.body?.string() else null }
    }.getOrNull()?.let { runCatching { JellyfinJson.parseToJsonElement(it).jsonObject }.getOrNull() }

    /** The act's Ticketmaster id, remembered ("" = no act of that exact name, remembered for a month). Null: not answered, try again later. */
    private fun attractionId(name: String, key: String, ids: MutableMap<String, String>): String? {
        val remembered = normalize(name)
        ids[remembered]?.let { return it.ifEmpty { null } }
        val url = "https://app.ticketmaster.com/discovery/v2/attractions.json?apikey=${URLEncoder.encode(key, "UTF-8")}" +
            "&keyword=${URLEncoder.encode(name, "UTF-8")}&classificationName=music&size=8"
        val root = getJson(url) ?: return null
        val found = (root["_embedded"]?.jsonObject?.get("attractions") as? JsonArray)?.map { it.jsonObject }
            ?.firstOrNull { normalize(it.s("name") ?: "") == remembered }
        val id = found?.s("id") ?: ""
        ids[remembered] = id
        return id.ifEmpty { null }
    }

    /**
     * Upcoming concerts from Ticketmaster's Discovery API. It needs the free key from Settings. It is exact on purpose: a search for
     * "Queen" also finds tribute and symphonic shows. So each artist is first looked up as an act on Ticketmaster (the name must match
     * exactly; tribute acts are separate acts with other names) and only that act's own events are asked for. The act ids are
     * remembered, so later refreshes need one request per artist.
     */
    private suspend fun fetchConcerts(artists: List<String>): List<Concert> = withContext(Dispatchers.IO) {
        val key = ticketmasterKey
        if (key.isBlank()) return@withContext emptyList()
        // The remembered ids are renewed once a month.
        if (System.currentTimeMillis() - prefs.getLong("tmIdsAt", 0L) > 30L * 24 * HOUR) {
            prefs.edit().remove("tmIds").putLong("tmIdsAt", System.currentTimeMillis()).apply()
        }
        val ids = (prefs.getString("tmIds", "") ?: "").lines().mapNotNull { line -> line.split("\t").takeIf { it.size == 2 }?.let { it[0] to it[1] } }
            .toMap().toMutableMap()
        val concerts = mutableListOf<Concert>()
        for (name in artists) {
            val attraction = attractionId(name, key, ids)
            if (attraction == null) { delay(250); continue }
            val city = city
            val country = country
            val url = "https://app.ticketmaster.com/discovery/v2/events.json?apikey=${URLEncoder.encode(key, "UTF-8")}&attractionId=$attraction&size=5&sort=date,asc" +
                (if (city.isNotBlank()) "&city=${URLEncoder.encode(city, "UTF-8")}" else "") +
                (if (country.length == 2) "&countryCode=${country.uppercase()}" else "")
            val events = getJson(url)?.get("_embedded")?.jsonObject?.get("events") as? JsonArray
            events?.forEach { element ->
                val e = element.jsonObject
                val id = e.s("id") ?: return@forEach
                val title = e.s("name") ?: return@forEach
                val link = e.s("url") ?: return@forEach
                val day = e["dates"]?.jsonObject?.get("start")?.jsonObject?.s("localDate") ?: return@forEach
                val venue = (e["_embedded"]?.jsonObject?.get("venues") as? JsonArray)?.firstOrNull()?.jsonObject
                // The best picture for a card: a wide one, around 640 pixels.
                val pictures = (e["images"] as? JsonArray)?.map { it.jsonObject } ?: emptyList()
                val best = pictures.filter { it.s("ratio") == "16_9" }.minByOrNull { Math.abs((it.s("width")?.toIntOrNull() ?: 0) - 640) } ?: pictures.firstOrNull()
                concerts += Concert(id, name, title, day, venue?.s("name") ?: "", venue?.get("city")?.jsonObject?.s("name") ?: "", link, best?.s("url"))
            }
            delay(250)
        }
        prefs.edit().putString("tmIds", ids.entries.joinToString("\n") { "${it.key}\t${it.value}" }).apply()
        concerts.distinctBy { it.id }.sortedBy { it.date }
    }
}
