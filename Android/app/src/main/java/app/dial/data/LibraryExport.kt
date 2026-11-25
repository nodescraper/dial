package app.dial.data

import java.io.ByteArrayOutputStream
import java.time.LocalDate
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/**
 * Your library as spreadsheets: artists.csv, albums.csv and tracks.csv, zipped into one file to save or share.
 * UTF-8 with a byte order mark, so Excel shows accented names correctly; Numbers and Google Sheets read it too.
 * The same three files and columns as iOS LibraryExport.
 */
object LibraryExport {
    data class Counts(val artists: Int = 0, val albums: Int = 0, val tracks: Int = 0)
    data class Made(val name: String, val zip: ByteArray, val counts: Counts)

    /** Builds the zip in memory and returns it with a file name, with how many of each went in. */
    suspend fun make(client: JellyfinClient): Made {
        val songs = client.songsWithGenres()
        val date = LocalDate.now().toString() // "2026-11-25"
        val name = "Dial Library $date"
        val (artists, albums, tracks, counts) = tables(songs)
        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { zip ->
            zip.putNextEntry(ZipEntry("artists.csv"))
            zip.write(csv(listOf("Artist", "Albums", "Tracks"), artists))
            zip.closeEntry()
            zip.putNextEntry(ZipEntry("albums.csv"))
            zip.write(csv(listOf("Album Artist", "Album", "Year", "Tracks", "Length"), albums))
            zip.closeEntry()
            zip.putNextEntry(ZipEntry("tracks.csv"))
            zip.write(csv(listOf("Album Artist", "Album", "Disc", "Track", "Title", "Artists", "Year", "Length"), tracks))
            zip.closeEntry()
        }
        return Made(name, out.toByteArray(), counts)
    }

    // MARK: Tables

    private fun albumArtist(song: Item): String =
        ArtistNames.display(song.albumArtist ?: song.albumArtists?.firstOrNull()?.name ?: song.artists?.firstOrNull() ?: "Unknown artist")

    private fun tables(songs: List<Item>): Tables {
        val sorted = songs.sortedWith(compareBy(
            { albumArtist(it).lowercase() }, { (it.album ?: "").lowercase() },
            { it.discNumber ?: 1 }, { it.indexNumber ?: 0 }))

        val tracks = sorted.map { song ->
            listOf(albumArtist(song), song.album ?: "", song.discNumber?.toString() ?: "", song.indexNumber?.toString() ?: "",
                song.name, song.artistLine, song.productionYear?.toString() ?: "", length(song.durationMs / 1000.0))
        }

        // Albums in the order their songs came, each once.
        val albumOrder = ArrayList<String>()
        val albumSongs = HashMap<String, MutableList<Item>>()
        for (song in sorted) {
            val key = song.albumId ?: "${albumArtist(song)}|${song.album ?: ""}"
            if (key !in albumSongs) albumOrder += key
            albumSongs.getOrPut(key) { ArrayList() } += song
        }
        val albums = albumOrder.mapNotNull { key ->
            val list = albumSongs[key] ?: return@mapNotNull null
            val first = list.firstOrNull() ?: return@mapNotNull null
            listOf(albumArtist(first), first.album ?: "", list.mapNotNull { it.productionYear }.firstOrNull()?.toString() ?: "",
                list.size.toString(), length(list.sumOf { it.durationMs / 1000.0 }))
        }

        // Artists by album artist, the way the Library lists them.
        val artistOrder = ArrayList<String>()
        val artistAlbums = HashMap<String, MutableSet<String>>()
        val artistTracks = HashMap<String, Int>()
        val artistNames = HashMap<String, String>()
        for (song in sorted) {
            val name = albumArtist(song)
            val key = ArtistNames.key(name)
            if (key !in artistNames) {
                artistOrder += key
                artistNames[key] = name
                artistAlbums[key] = HashSet()
                artistTracks[key] = 0
            }
            artistTracks[key] = (artistTracks[key] ?: 0) + 1
            artistAlbums[key]?.add(song.albumId ?: song.album ?: "")
        }
        val artists = artistOrder.map { key ->
            listOf(artistNames[key] ?: "", (artistAlbums[key]?.size ?: 0).toString(), (artistTracks[key] ?: 0).toString())
        }

        return Tables(artists, albums, tracks, Counts(artists.size, albums.size, tracks.size))
    }

    private data class Tables(val artists: List<List<String>>, val albums: List<List<String>>,
                              val tracks: List<List<String>>, val counts: Counts)

    /** "3:45", or "1:02:07" for an hour or more. */
    private fun length(seconds: Double): String {
        val total = seconds.toInt()
        val (h, m, s) = Triple(total / 3600, total % 3600 / 60, total % 60)
        return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
    }

    private fun csv(header: List<String>, rows: List<List<String>>): ByteArray {
        fun field(text: String) = if (text.any { it == ',' || it == '"' || it == '\n' || it == '\r' })
            "\"" + text.replace("\"", "\"\"") + "\"" else text
        val lines = (listOf(header) + rows).joinToString("\r\n") { row -> row.joinToString(",") { field(it) } } + "\r\n"
        return byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte()) + lines.toByteArray(Charsets.UTF_8)
    }
}
