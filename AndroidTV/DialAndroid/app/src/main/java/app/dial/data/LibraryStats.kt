package app.dial.data

import java.time.Instant
import java.time.LocalDateTime
import java.time.YearMonth
import java.time.ZoneId
import java.time.format.TextStyle
import java.util.Locale

/** One bar, row or tile: a month, a format, an artist, an album… */
data class StatEntry(
    val id: String,
    val name: String,
    val detail: String = "",
    val value: Int = 0,
    val imageItemId: String? = null,
    /** Where a tap goes: "album" or "artist", with its id and name. */
    val routeKind: String? = null,
    val routeId: String? = null,
    val routeName: String = "",
)

/**
 * Your library in numbers: how big it is, how it grew, what quality it's in, what's in it, what you've never
 * played and what's missing from it. The same numbers as iOS LibraryStats.
 */
data class LibraryStats(
    var songs: Int = 0,
    var albums: Int = 0,
    var artists: Int = 0,
    var seconds: Double = 0.0,
    var bytes: Long = 0L,
    /** Songs added in each of the last 12 months, oldest first ("Dec", "Jan"…). */
    var addedByMonth: List<StatEntry> = emptyList(),
    var addedThisMonth: Int = 0,
    var biggestMonth: StatEntry? = null,
    var firstAdded: Instant? = null,
    var formats: List<StatEntry> = emptyList(),
    var lossless: Int = 0,
    var hiRes: Int = 0,
    /** Compressed songs by bitrate, lowest first. */
    var bitrates: List<StatEntry> = emptyList(),
    /** Albums whose files are all compressed and below 256 kbps on average, worst first. */
    var weakestAlbums: List<StatEntry> = emptyList(),
    var decades: List<StatEntry> = emptyList(),
    var genres: List<StatEntry> = emptyList(),
    var topArtists: List<StatEntry> = emptyList(),
    var unplayedSongs: Int = 0,
    var unplayedAlbums: Int = 0,
    var unplayedAlbumList: List<StatEntry> = emptyList(),
    var noCover: Int = 0,
    var noYear: Int = 0,
    var noGenre: Int = 0,
    var songsWithoutMusicBrainz: Int = 0,
    /** Albums with something missing, with what it is (the worst few), and how many there are in all. */
    var problemAlbums: List<StatEntry> = emptyList(),
    var problemAlbumCount: Int = 0,
) {
    val hours: Int get() = (seconds / 3600).toInt()
    val losslessShare: Int get() = if (songs == 0) 0 else (lossless * 100.0 / songs).toInt()
    val unplayedShare: Int get() = if (songs == 0) 0 else (unplayedSongs * 100.0 / songs).toInt()
    val isEmpty: Boolean get() = songs == 0
}

object LibraryStatsEngine {
    /** Nil when the library couldn't be read. */
    suspend fun make(client: JellyfinClient): LibraryStats? {
        val songs = runCatching { client.songsForLibraryStats() }.getOrNull() ?: return null
        val albums = runCatching { client.albumsForLibraryStats() }.getOrDefault(emptyList())

        val stats = LibraryStats()
        stats.songs = songs.size
        stats.albums = albums.size
        stats.seconds = songs.sumOf { it.durationMs / 1000.0 }
        stats.bytes = songs.sumOf { it.mediaSources?.firstOrNull()?.size ?: 0L }

        growth(songs, stats)
        quality(songs, albums, stats)
        erasAndGenres(songs, stats)
        artists(songs, stats)
        unplayed(songs, albums, stats)
        health(songs, albums, stats)
        return stats
    }

    private fun added(item: Item): Instant? {
        val raw = item.dateCreated ?: return null
        runCatching { return Instant.parse(raw) }.getOrNull()
        // Jellyfin sometimes sends no zone ("2023-05-01T12:00:00.0000000"): read it as UTC.
        runCatching { return LocalDateTime.parse(raw.substringBefore('+').substringBefore('Z')).atZone(ZoneId.of("UTC")).toInstant() }.getOrNull()
        return null
    }

    private fun audio(item: Item) = item.mediaSources?.firstOrNull()?.streams?.firstOrNull { it.type == "Audio" }

    private fun bitrateKbps(song: Item): Int? =
        (audio(song)?.bitRate ?: song.mediaSources?.firstOrNull()?.bitrate)?.div(1000)

    private fun decadeName(start: Int) = if (start >= 2000) "${start}s" else "${start % 100}s"

    private fun monthName(month: YearMonth, full: Boolean): String {
        val style = if (full) TextStyle.FULL else TextStyle.SHORT
        val name = month.month.getDisplayName(style, Locale.getDefault())
        return if (full) "$name ${month.year}" else name.replaceFirstChar { it.uppercase() }
    }

    // MARK: Growth

    private fun growth(songs: List<Item>, stats: LibraryStats) {
        val now = YearMonth.now()
        val counts = HashMap<YearMonth, Int>()
        var first: Instant? = null
        for (song in songs) {
            val date = added(song) ?: continue
            if (first == null || date < first) first = date
            val month = YearMonth.from(date.atZone(ZoneId.systemDefault()))
            counts[month] = (counts[month] ?: 0) + 1
        }
        stats.firstAdded = first
        stats.addedThisMonth = counts[now] ?: 0
        stats.addedByMonth = (11 downTo 0).map { back ->
            val month = now.minusMonths(back.toLong())
            StatEntry(id = month.toString(), name = monthName(month, full = false), value = counts[month] ?: 0)
        }
        val biggest = counts.entries.filter { it.value > 0 }.maxByOrNull { it.value }
        if (biggest != null) stats.biggestMonth = StatEntry("biggest", monthName(biggest.key, full = true), value = biggest.value)
    }

    // MARK: Quality

    private fun quality(songs: List<Item>, albums: List<Item>, stats: LibraryStats) {
        val formats = HashMap<String, Int>()
        val buckets = intArrayOf(0, 0, 0, 0) // under 192, 192–255, 256–319, 320 and up
        val lossyByAlbum = HashMap<String, Triple<Int, Int, Boolean>>() // total kbps, count, all lossy
        for (song in songs) {
            formats[song.formatLabel ?: "Other"] = (formats[song.formatLabel ?: "Other"] ?: 0) + 1
            val albumId = song.albumId ?: ""
            val stream = audio(song)
            if (song.isLossless) {
                stats.lossless += 1
                if ((stream?.sampleRate ?: 0) > 48000 || (stream?.bitDepth ?: 0) > 16) stats.hiRes += 1
                val current = lossyByAlbum[albumId]
                lossyByAlbum[albumId] = Triple(current?.first ?: 0, current?.second ?: 0, false)
            } else {
                val kbps = bitrateKbps(song)
                if (kbps != null) {
                    buckets[if (kbps < 192) 0 else if (kbps < 256) 1 else if (kbps < 320) 2 else 3] += 1
                    val current = lossyByAlbum[albumId] ?: Triple(0, 0, true)
                    lossyByAlbum[albumId] = Triple(current.first + kbps, current.second + 1, current.third)
                }
            }
        }
        stats.formats = formats.entries.sortedByDescending { it.value }
            .map { StatEntry(it.key, it.key, value = it.value) }
        val bucketNames = listOf("Under 192 kbps", "192–255 kbps", "256–319 kbps", "320 kbps")
        stats.bitrates = bucketNames.mapIndexed { i, name -> StatEntry(name, name, value = buckets[i]) }
        val names = albums.associateBy { it.id }
        stats.weakestAlbums = lossyByAlbum.entries.mapNotNull { (id, album) ->
            val (total, count, all) = album
            val item = names[id]
            if (!all || count == 0 || item == null) null else item to total / count
        }.filter { it.second < 256 }.sortedBy { it.second }.take(5)
            .map { (album, kbps) ->
                StatEntry(album.id, album.name, "${album.albumArtistLine}, $kbps kbps", kbps,
                    album.id, "album", album.id, album.name)
            }
    }

    // MARK: Eras and genres

    private fun erasAndGenres(songs: List<Item>, stats: LibraryStats) {
        val decades = HashMap<Int, Int>()
        val genres = HashMap<String, Int>()
        for (song in songs) {
            val year = song.productionYear
            if (year != null && year > 1900) {
                val decade = year / 10 * 10
                decades[decade] = (decades[decade] ?: 0) + 1
            }
            val seen = HashSet<String>()
            for (tag in song.genres ?: emptyList()) {
                for (genre in GenreNames.canonical(tag)) {
                    if (seen.add(genre)) genres[genre] = (genres[genre] ?: 0) + 1
                }
            }
        }
        stats.decades = decades.entries.sortedBy { it.key }
            .map { StatEntry(it.key.toString(), decadeName(it.key), value = it.value) }
        stats.genres = genres.entries.sortedByDescending { it.value }.take(8)
            .map { StatEntry(it.key, it.key, value = it.value) }
    }

    // MARK: Biggest artists

    private fun artists(songs: List<Item>, stats: LibraryStats) {
        data class Tally(var id: String?, var name: String, var songs: Int = 0,
                         var albums: MutableSet<String> = HashSet(), var seconds: Double = 0.0)
        val byArtist = HashMap<String, Tally>()
        for (song in songs) {
            val name = ArtistNames.display(song.albumArtist ?: song.albumArtists?.firstOrNull()?.name ?: song.artists?.firstOrNull() ?: "")
            if (name.isEmpty()) continue
            val tally = byArtist.getOrPut(ArtistNames.key(name)) {
                Tally(song.albumArtists?.firstOrNull()?.id ?: song.artistItems?.firstOrNull()?.id, name)
            }
            tally.songs += 1
            song.albumId?.let { tally.albums.add(it) }
            tally.seconds += song.durationMs / 1000.0
        }
        stats.artists = byArtist.size
        stats.topArtists = byArtist.values.sortedByDescending { it.songs }.take(5).map { artist ->
            val time = if (artist.seconds >= 3600) "${(artist.seconds / 3600).toInt()} h" else "${(artist.seconds / 60).toInt()} min"
            val albums = if (artist.albums.size == 1) "1 album" else "${artist.albums.size} albums"
            StatEntry(artist.id ?: artist.name, artist.name, "$albums, $time", artist.songs,
                artist.id, artist.id?.let { "artist" }, artist.id, artist.name)
        }
    }

    // MARK: Unplayed

    private fun played(song: Item) = (song.userData?.playCount ?: 0) > 0 || song.userData?.lastPlayedDate != null

    private fun unplayed(songs: List<Item>, albums: List<Item>, stats: LibraryStats) {
        stats.unplayedSongs = songs.count { !played(it) }
        val playedAlbums = songs.filter(::played).mapNotNull { it.albumId }.toHashSet()
        val untouched = albums.filter { it.id !in playedAlbums }
        stats.unplayedAlbums = untouched.size
        stats.unplayedAlbumList = untouched
            .sortedByDescending { added(it) }
            .take(6)
            .map { StatEntry(it.id, it.name, it.albumArtistLine, imageItemId = it.id, routeKind = "album", routeId = it.id, routeName = it.name) }
    }

    // MARK: Health

    private fun health(songs: List<Item>, albums: List<Item>, stats: LibraryStats) {
        val problems = ArrayList<Pair<Item, List<String>>>()
        for (album in albums) {
            val missing = ArrayList<String>()
            if (album.imageTags?.get("Primary") == null) { stats.noCover += 1; missing += "no cover" }
            if (album.productionYear == null) { stats.noYear += 1; missing += "no year" }
            if ((album.genres ?: emptyList()).isEmpty()) { stats.noGenre += 1; missing += "no genre" }
            if (missing.isNotEmpty()) problems += album to missing
        }
        stats.songsWithoutMusicBrainz = songs.count { song ->
            (song.providerIds ?: emptyMap()).keys.none { it == "MusicBrainzTrack" || it == "MusicBrainzRecording" }
        }
        stats.problemAlbumCount = problems.size
        // The worst first: most things missing, and a missing cover before the rest.
        stats.problemAlbums = problems
            .sortedWith(compareByDescending<Pair<Item, List<String>>> { it.second.size }
                .thenByDescending { if ("no cover" in it.second) 1 else 0 })
            .take(6)
            .map { (album, missing) ->
                val detail = missing.joinToString(", ").replaceFirstChar { it.uppercase() }
                StatEntry(album.id, album.name, detail, imageItemId = album.id, routeKind = "album", routeId = album.id, routeName = album.name)
            }
    }
}
