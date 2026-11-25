package app.dial.data

import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import android.content.Context
import kotlinx.serialization.Serializable
import java.io.File

/** What a mixtape holds: songs of these decades and genres (and by these artists), or songs that sound a certain way. */
@Serializable
data class MixRecipe(
    val decades: List<Int> = emptyList(),
    val genres: List<String> = emptyList(),
    /** Artists whose albums count as these genres, so a whole album lands in it even when only some songs are tagged. */
    val artistIds: List<String> = emptyList(),
    /** A sound to describe to AudioMuse. */
    val sound: String? = null,
    /** For a genre mixtape: the genre as you'd say it. A song belongs to it only if its first (main) genre tag is that genre. */
    val family: String? = null,
    val length: Int = 500,
)

/** A named, ready-made mix, shown as four covers under a color wash. */
@Serializable
data class Mixtape(
    val id: String,
    val title: String,
    val subtitle: String,
    val recipe: MixRecipe,
    /** Two colors, as "#RRGGBB". */
    val palette: List<String>,
    /** Album ids for the collage. */
    val covers: List<String> = emptyList(),
    /** The songs, when they are fixed (the daily mixes); empty means they are looked up when opened. */
    val tracks: List<Item> = emptyList(),
)

@Serializable
data class MixSections(
    /** The daily mixes: the moods your library fits best, a fixed set of songs for the day. */
    val daily: List<Mixtape> = emptyList(),
    /** Decades and genres are plain filters, listed from the server (no songs picked ahead). */
    val decades: List<Mixtape> = emptyList(),
    val genres: List<Mixtape> = emptyList(),
    /** The day the daily mixes were made, like "2026-11-05". */
    val day: String = "",
) {
    val isEmpty get() = daily.isEmpty() && decades.isEmpty() && genres.isEmpty()

    /** What Home shows. */
    fun highlights(count: Int = 10): List<Mixtape> = daily.take(count)
}

/**
 * Daily mixes, like Spotify's: the moods your library fits best, each a fixed set of songs for the day, made once a day
 * from AudioMuse's sound search and the same on every device. Decades and genres are only filters: a list from the server,
 * with the songs looked up when you open one.
 */
object MixCatalog {
    class Mood(val id: String, val title: String, val subtitle: String, val sound: String, val palette: List<String>)

    val moods = listOf(
        Mood("chill", "Chill", "Relaxed and laid back", "relaxed chill laid back mellow", listOf("#21787A", "#8FCC9E")),
        Mood("feelgood", "Feel Good", "Happy and sunny", "happy cheerful sunny feel good", listOf("#F28C33", "#F2CC59")),
        Mood("energy", "Energy", "Upbeat and powerful", "energetic upbeat powerful fast", listOf("#BF3333", "#F29933")),
        Mood("party", "Party", "Danceable, all night", "danceable party groove club", listOf("#8C2680", "#4073E6")),
        Mood("latenight", "Late Night", "Dark and smooth", "late night dark smooth atmospheric", listOf("#1A1A40", "#664D99")),
        Mood("focus", "Focus", "Calm, few words", "calm instrumental ambient focus", listOf("#293D73", "#6B8CCC")),
        Mood("romantic", "Romantic", "Tender and soulful", "romantic tender soulful love", listOf("#99264D", "#E6737F")),
        Mood("heartbreak", "Heartbreak", "Sad and emotional", "sad melancholic emotional heartbreak ballad", listOf("#333859", "#737FA6")),
        Mood("workout", "Workout", "Hard and fast", "intense aggressive hard fast workout", listOf("#2B1A1A", "#C2412D")),
        Mood("roadtrip", "Road Trip", "Driving and anthemic", "driving anthemic upbeat road trip", listOf("#E3683F", "#3C6E9E")),
        Mood("summer", "Summer", "Bright and tropical", "summer tropical sunny bright", listOf("#F4C95D", "#2E9E8F")),
        Mood("rainy", "Rainy Day", "Mellow and grey", "rainy mellow acoustic soft melancholic", listOf("#4A5568", "#9AA7B8")),
        Mood("groove", "Groove", "Funky, with bass", "funky groovy bass rhythm", listOf("#A8401A", "#E8742C")),
        Mood("dinner", "Dinner Party", "Smooth and warm", "smooth jazzy warm sophisticated", listOf("#5C3A21", "#D9A066")),
        Mood("sleep", "Sleep", "Soft and quiet", "ambient soft quiet sleep peaceful", listOf("#0F1A2E", "#3A4F7A")),
    )

    private val palettes = listOf(
        listOf("#8C3380", "#F28066"), listOf("#264D99", "#59BFD9"), listOf("#99401A", "#F2B24D"), listOf("#26665A", "#99D98C"),
        listOf("#592633", "#D95966"), listOf("#333366", "#8C73D9"), listOf("#80592A", "#D9BF80"), listOf("#1F4D73", "#E8742C"),
    )

    private fun palette(seed: Int) = palettes[Math.abs(seed) % palettes.size]

    fun decadeName(decade: Int) = if (decade >= 2000) "${decade}s" else "${decade % 100}s"

    private const val DAILY_COUNT = 8
    private const val DAILY_SONGS = 40

    // The "-v3" marks the mixtape kinds and picking in use; mixtapes saved with an older tag are replaced.
    private fun today() = java.time.LocalDate.now().toString() + "-v3"

    // MARK: Saved copy

    private lateinit var file: File
    /** What was last built, kept in memory so screens start with it instead of drawing empty. */
    @Volatile var latest: MixSections? = null
        private set

    fun init(context: Context) {
        file = File(context.cacheDir, "mixtapes-v11.json")
        latest = runCatching { JellyfinJson.decodeFromString(MixSections.serializer(), file.readText()) }.getOrNull()
    }

    private fun save(sections: MixSections) {
        latest = sections
        runCatching { file.writeText(JellyfinJson.encodeToString(MixSections.serializer(), sections)) }
    }

    /** One build at a time: Home and Radio asking together wait for the first instead of each doing it. */
    private val buildLock = kotlinx.coroutines.sync.Mutex()

    /** Saved mixes right away; made again once a day. The filters are ready in a moment, the daily mixes a little later. */
    suspend fun load(client: JellyfinClient, audioMuse: Boolean, onUpdate: (MixSections) -> Unit) {
        val first = latest
        if (first != null && !first.isEmpty) {
            onUpdate(first)
            if (first.day == today()) return
        }
        buildLock.withLock {
            // Someone else may have finished it while we waited.
            val saved = latest
            if (saved != null && !saved.isEmpty && saved.day == today()) { onUpdate(saved); return }
            val (decades, genres) = buildFilters(client)
            // The made-for-you mixtapes come with the Dial plugin: without it there are none.
            val plugin = DialPlugin.check(client)
            val before = if (plugin) saved?.daily ?: emptyList() else emptyList()
            onUpdate(MixSections(before, decades, genres, saved?.day ?: ""))
            val daily = if (plugin) dailyMixtapes(client, audioMuse) else emptyList()
            // If the mixes could not be made (the server was busy), try again next time instead of calling today done.
            val day = if (plugin && daily.isEmpty()) saved?.day ?: "" else today()
            val built = MixSections(daily.ifEmpty { before }, decades, genres, day)
            if (built.isEmpty) return
            onUpdate(built)
            save(built)
        }
    }

    // MARK: Shared through the server

    /**
     * Each mixtape is saved on the server as a playlist named "Dial Mixtape 11 · Chill · Relaxed and laid back · 2026-11-05-v3"
     * (rank, title, line under it, day), so the first device to make today's mixtapes does the work and every other device, and
     * any other Jellyfin app, just reads them. Mixes made from your listening (Daily Mix, On Repeat, Rewind, Deep Cuts, Time
     * Capsule) are made on iPhone and Mac, which know your listening; they take ranks 1 to 9 and this app only shows them.
     * Moods start at rank 11. Dial keeps these playlists out of its own playlist lists.
     */
    const val PLAYLIST_PREFIX = "Dial Mixtape "

    /** Playlists that are not yours: Dial's shared mixtapes, and the ones AudioMuse's clustering makes on its own (it ends their names with "_automatic"). */
    fun isGenerated(name: String) = name.startsWith(PLAYLIST_PREFIX) || name.lowercase().contains("_automatic")
    private const val SEPARATOR = " \u00B7 "
    private const val MOOD_RANK_START = 11

    private class Parsed(val rank: Int, val title: String, val subtitle: String, val day: String)

    private fun parse(name: String): Parsed? {
        if (!name.startsWith(PLAYLIST_PREFIX)) return null
        val parts = name.removePrefix(PLAYLIST_PREFIX).split(SEPARATOR)
        val rank = parts.firstOrNull()?.toIntOrNull() ?: return null
        // The first version of the name had no line under the title.
        return when (parts.size) { 4 -> Parsed(rank, parts[1], parts[2], parts[3]); 3 -> Parsed(rank, parts[1], "", parts[2]); else -> null }
    }

    internal val personalPalettes = mapOf(
        "Daily Mix 1" to listOf("#A8401A", "#E8742C"), "Daily Mix 2" to listOf("#1F4D73", "#59BFD9"), "Daily Mix 3" to listOf("#99401A", "#F2B24D"),
        "Daily Mix 4" to listOf("#26665A", "#99D98C"), "On Repeat" to listOf("#C2412D", "#2B1A1A"), "Rewind" to listOf("#8C3380", "#F28066"),
        "Deep Cuts" to listOf("#333366", "#8C73D9"), "Time Capsule" to listOf("#80592A", "#D9BF80"),
    )

    /** Made-for-you mixes first, then the moods. */
    private fun ordered(list: List<Mixtape>) = list.sortedBy { if (it.id.startsWith("daily-")) 1 else 0 }

    /** Today's mixtapes as the server has them (empty if no device has made them yet), and the ids of older ones to clean up. */
    private suspend fun fromServer(client: JellyfinClient): Pair<List<Mixtape>, List<String>> {
        val all = runCatching { client.allPlaylists() }.getOrNull() ?: return emptyList<Mixtape>() to emptyList()
        val mine = all.mapNotNull { item -> parse(item.name)?.let { item to it } }
        val current = mine.filter { it.second.day == today() }.sortedBy { it.second.rank }
        val stale = mine.filter { it.second.day != today() }.map { it.first.id }
        val loaded = kotlinx.coroutines.coroutineScope {
            current.map { (item, info) ->
                async {
                    val songs = runCatching { client.playlistTracks(item.id) }.getOrDefault(emptyList())
                    if (songs.size < 12) return@async null
                    val mood = moods.firstOrNull { it.title == info.title }
                    val id = mood?.let { "daily-${it.id}" } ?: ("mix-" + info.title.lowercase().filter { c -> c.isLetterOrDigit() })
                    info.rank to Mixtape(id, info.title, info.subtitle.ifEmpty { mood?.subtitle ?: "" },
                        mood?.let { MixRecipe(sound = it.sound) } ?: MixRecipe(),
                        mood?.palette ?: personalPalettes[info.title] ?: palette(info.title.sumOf { c -> c.code }),
                        songs.map { it.imageItemId }.distinct().take(4), songs)
                }
            }.awaitAll().filterNotNull()
        }
        return ordered(loaded.sortedBy { it.first }.map { it.second }) to stale
    }

    /** The songs that were in these playlists (yesterday's mixtapes), so today's can rest them. */
    private suspend fun songIds(playlistIds: List<String>, client: JellyfinClient): Set<String> = kotlinx.coroutines.coroutineScope {
        playlistIds.take(24).map { id -> async { runCatching { client.playlistTracks(id) }.getOrDefault(emptyList()).map { it.id } } }
            .awaitAll().flatten().toSet()
    }

    /** Saves mixtapes as playlists: the ones made from your listening first (ranks 1 to 9), then the moods (from 11). */
    private suspend fun publish(personal: List<Mixtape>, moodMixes: List<Mixtape>, client: JellyfinClient) {
        suspend fun save(mix: Mixtape, rank: Int) {
            val subtitle = mix.subtitle.replace(SEPARATOR, ", ")
            runCatching { client.createPlaylist("$PLAYLIST_PREFIX$rank$SEPARATOR${mix.title}$SEPARATOR$subtitle$SEPARATOR${today()}", mix.tracks.map { it.id }) }
        }
        personal.forEachIndexed { index, mix -> save(mix, index + 1) }
        moodMixes.forEachIndexed { index, mix -> save(mix, MOOD_RANK_START + index) }
    }

    /** Today's mixtapes: another device's if it has made them, and whatever is still missing made now and saved for the others. */
    private suspend fun dailyMixtapes(client: JellyfinClient, audioMuse: Boolean): List<Mixtape> {
        var shared = fromServer(client).let { (mixes, stale) -> mixes.filter { it.id.startsWith("daily-") } to stale }
        // With the Dial plugin, the server makes the made-for-you mixtapes (the same on every device).
        val made = client.dialMixtapes()
        if (!made.isNullOrEmpty()) {
            val fromPlugin = made.mapNotNull { m ->
                val songs = runCatching { client.items(m.trackIds) }.getOrDefault(emptyList())
                if (songs.size < 12) null else Mixtape(m.id, m.title, m.subtitle, MixRecipe(),
                    m.palette.ifEmpty { personalPalettes[m.title] ?: listOf("#333366", "#8C73D9") }, m.coverIds, songs)
            }
            if (fromPlugin.isNotEmpty()) shared = ordered(fromPlugin + shared.first.filter { it.id.startsWith("daily-") }) to shared.second
        }
        // Made-for-you mixtapes come only from the Dial plugin; the apps never make them. Only the moods may be made here.
        val hasMoods = shared.first.any { it.id.startsWith("daily-") }
        if (hasMoods || !audioMuse) {
            shared.second.forEach { runCatching { client.delete("Items/$it") } }
            return shared.first
        }
        // The mood mixtapes are missing and this device can make them. Yesterday's songs rest for a day.
        val avoid = songIds(shared.second, client)
        shared.second.forEach { runCatching { client.delete("Items/$it") } }
        val listening = Listening.load(client)
        var moodMixes = buildDaily(client, listening, avoid)
        if (moodMixes.isEmpty()) return shared.first
        // Someone may have finished while this one was working: use theirs, so every device matches.
        val again = fromServer(client)
        if (again.first.any { it.id.startsWith("daily-") }) moodMixes = emptyList()
        publish(emptyList(), moodMixes, client)
        return ordered(again.first + moodMixes)
    }

    // MARK: Filters

    /**
     * Decades and genres are plain filters, there at once: the server lists the years and genres it has (one small request
     * each, nothing counted or sampled) and the songs are only looked up when you open one.
     */
    private suspend fun buildFilters(client: JellyfinClient): Pair<List<Mixtape>, List<Mixtape>> {
        // The decades the library has music from, newest first. If the server cannot list its years, none are made up.
        val starts = runCatching { client.libraryYears() }.getOrDefault(emptyList()).filter { it >= 1900 }.map { it / 10 * 10 }.toSet()
        val decades = starts.sortedDescending().map { decade ->
            Mixtape("decade-$decade", "The ${decadeName(decade)}", "$decade to ${decade + 9}", MixRecipe(decades = listOf(decade)), palette(decade / 10))
        }
        // Only genres your songs really have (a song counts for the first genre on it), grouped by meaning
        // ("Hip-Hop", "hip hop", "Rap/Hip Hop" together); the well-known ones first. Jellyfin also lists tags that sit
        // only on artists or on songs you no longer have, and those would open empty.
        val songs = runCatching { client.songsWithGenres() }.getOrDefault(emptyList())
        val tagsByFamily = HashMap<String, MutableSet<String>>()
        val counts = HashMap<String, Int>()
        for (song in songs) {
            val tag = song.genres?.firstOrNull() ?: continue
            for (family in GenreNames.canonical(tag)) {
                tagsByFamily.getOrPut(family) { mutableSetOf() }.add(tag)
                counts[family] = (counts[family] ?: 0) + 1
            }
        }
        val known = listOf("pop", "hip", "rock", "r&b", "electronic", "dance", "jazz", "soul", "latin", "classical", "country", "folk",
            "metal", "indie", "reggae", "blues", "funk", "alternative")
        fun rank(family: String) = known.indexOfFirst { family.lowercase().contains(it) }.let { if (it < 0) known.size else it }
        val genres = counts.keys.sortedWith(compareBy({ rank(it) }, { -(counts[it] ?: 0) }, { it })).map { family ->
            Mixtape("genre-$family", family, "Genre", MixRecipe(genres = (tagsByFamily[family] ?: emptySet()).sorted(), family = family),
                palette(family.sumOf { it.code }))
        }
        return decades to genres
    }

    // MARK: Daily mixes

    /** A number from 0 to 1 that is the same for the same day and song on every device. */
    internal fun noise(id: String, day: String, salt: String): Double {
        var hash = -3750763034362895579L // the FNV offset basis
        for (byte in (salt + day + id).toByteArray(Charsets.UTF_8)) hash = (hash xor (byte.toLong() and 0xFF)) * 1099511628211L
        return java.lang.Long.remainderUnsigned(hash, 1000L) / 1000.0
    }

    private suspend fun buildDaily(client: JellyfinClient, listening: Listening, avoid: Set<String>): List<Mixtape> = kotlinx.coroutines.coroutineScope {
        val day = today()
        // Every mood is searched; the ones this library fits best become the day's mixes.
        val searched = moods.map { mood ->
            async { mood to runCatching { client.songsMatchingScored(mood.sound, 120) }.getOrDefault(emptyList()) }
        }.awaitAll().filter { it.second.size >= 12 }
        fun fit(songs: List<Pair<Item, Double?>>): Double? {
            val top = songs.take(20).mapNotNull { it.second }
            return if (top.size >= 8) top.average() else null
        }
        val fits = searched.map { fit(it.second) }
        val ranked = if (fits.isNotEmpty() && fits.all { it != null }) searched.zip(fits).sortedByDescending { it.second }.map { it.first } else searched

        val taken = HashSet<String>()
        val mixes = mutableListOf<Mixtape>()
        for ((mood, songs) in ranked) {
            if (mixes.size >= DAILY_COUNT) break
            val values = songs.mapNotNull { it.second }
            val low = values.minOrNull() ?: 0.0
            val span = (values.maxOrNull() ?: 0.0) - low
            // Closeness leads; the day's chance and a rest for yesterday's songs make each day different.
            fun score(song: Pair<Item, Double?>): Double =
                (song.second?.let { if (span > 0) (it - low) / span else 0.5 } ?: 0.5) + 0.2 * noise(song.first.id, day, mood.id) -
                    (if (song.first.id in avoid) 0.25 else 0.0)
            // The closest 80 of the 120 found, without what you played in the last days or an earlier mixtape has.
            val candidates = songs.take(80).filter { it.first.id !in taken && !listening.heard(it.first.id, 3) }.sortedByDescending(::score)
            // Your library is music you chose, so this brings back what you have not heard in a while: some songs you play
            // now, more that you loved and forgot, and some you own but never played.
            val current = candidates.filter { listening.isKnown(it.first.id) && listening.heard(it.first.id, 30) }
            val forgotten = candidates.filter { listening.isKnown(it.first.id) && !listening.heard(it.first.id, 60) }
            val unplayed = candidates.filter { !listening.isKnown(it.first.id) }
            var picks = current.take(DAILY_SONGS * 3 / 10) + forgotten.take(DAILY_SONGS * 4 / 10) + unplayed.take(DAILY_SONGS * 3 / 10)
            if (picks.size < DAILY_SONGS) {
                val have = picks.map { it.first.id }.toSet()
                picks = picks + candidates.filter { it.first.id !in have }.take(DAILY_SONGS - picks.size)
            }
            if (picks.size < 12) continue
            val ordered = spaced(picks.map { it.first }.sortedBy { noise(it.id, day, "order") })
            taken += ordered.map { it.id }
            mixes += Mixtape("daily-${mood.id}", mood.title, mood.subtitle, MixRecipe(sound = mood.sound), mood.palette,
                ordered.map { it.imageItemId }.distinct().take(4), ordered)
        }
        mixes
    }

    // MARK: Songs inside a mixtape

    /** Every song in your library that fits the recipe, shuffled, the same artist never twice in a row. */
    suspend fun songs(recipe: MixRecipe, client: JellyfinClient, audioMuse: Boolean, isHidden: (String) -> Boolean): List<Item> {
        val years = recipe.decades.flatMap { (it..it + 9).toList() }
        val pool = mutableListOf<Item>()
        // How closely each song fits the sound asked for (from AudioMuse), scaled 0 to 1.
        val fit = HashMap<String, Double>()
        if (recipe.sound != null && audioMuse) {
            val scored = runCatching { client.songsMatchingScored(recipe.sound, 300) }.getOrDefault(emptyList())
            pool += scored.map { it.first }
            val values = scored.mapNotNull { it.second }
            val low = values.minOrNull()
            val high = values.maxOrNull()
            if (low != null && high != null && high > low) {
                for ((item, value) in scored) if (value != null) fit[item.id] = (value - low) / (high - low)
            }
        } else {
            // A decade: every song from its albums, not only the few songs that carry the year themselves.
            val found0 = if (recipe.genres.isEmpty() && years.isNotEmpty()) runCatching { client.songsFromYears(years, 1500) }.getOrDefault(emptyList())
            else runCatching { client.songsByGenres(recipe.genres, years, if (recipe.family == null) 600 else 1200) }.getOrDefault(emptyList())
            // A song tagged with several genres is in the first one only, so "Rock" is rock, not everything that mentions it.
            val family = recipe.family
            pool += if (family == null) found0 else found0.filter { song -> song.genres?.firstOrNull()?.let { family in GenreNames.canonical(it) } == true }
            if (recipe.artistIds.isNotEmpty()) pool += runCatching { client.songsByAlbumArtists(recipe.artistIds, years, 400) }.getOrDefault(emptyList())
        }
        val seen = HashSet<String>()
        val songs = pool.filter { seen.add(it.id) && !isHidden(it.id) }
        if (fit.isEmpty()) return spaced(songs.shuffled().take(recipe.length))
        // For a sound, how well it fits matters as much as whether you know it; a mood is its closest songs.
        fun score(i: Item): Double {
            val plays = minOf((i.userData?.playCount ?: 0).toDouble(), 30.0) / 30 + if (i.userData?.isFavorite == true) 0.5 else 0.0
            val wanted = 0.55 // like the iPhone's mood mixes: a lean toward songs you know
            val preference = wanted * plays + (1 - wanted) * (1 - plays)
            return 0.55 * (fit[i.id] ?: 0.0) + 0.45 * preference + Math.random() * 0.2
        }
        return spaced(songs.sortedByDescending(::score).take(minOf(recipe.length, 150)).shuffled())
    }

    internal fun spaced(songs: List<Item>): List<Item> {
        val remaining = songs.toMutableList()
        val result = mutableListOf<Item>()
        fun key(i: Item) = ArtistNames.key(ArtistNames.primary(i.albumArtist ?: i.artistLine))
        while (remaining.isNotEmpty()) {
            val last = result.lastOrNull()?.let(::key)
            val index = remaining.indexOfFirst { key(it) != last }.let { if (it < 0) 0 else it }
            result += remaining.removeAt(index)
        }
        return result
    }
}
