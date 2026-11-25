package app.dial.data

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** A playlist read from a file: Spotify's data download, an Exportify CSV, or "Artist - Title" lines. */
data class ImportedList(val name: String, val source: String, val songs: List<Song>, val playCounts: Map<Song, Int>? = null) {
    data class Song(val title: String, val artist: String)
}

object PlaylistFiles {
    fun read(name: String, text: String): List<ImportedList> {
        val trimmed = text.trimStart()
        if (trimmed.startsWith("{") || trimmed.startsWith("[")) return runCatching { fromJson(trimmed) }.getOrDefault(emptyList())
        if (name.endsWith(".csv", ignoreCase = true)) return fromCsv(text, name.substringBeforeLast('.'))
        return fromText(text, name.substringBeforeLast('.'))
    }

    private fun JsonObject.str(key: String) = (this[key] as? kotlinx.serialization.json.JsonPrimitive)?.contentOrNull

    private fun fromJson(text: String): List<ImportedList> {
        val root = JellyfinJson.parseToJsonElement(text)
        if (root is JsonObject && root["playlists"] is JsonArray) {
            return root["playlists"]!!.jsonArray.mapNotNull { p ->
                val playlist = p.jsonObject
                val songs = (playlist["items"] as? JsonArray ?: JsonArray(emptyList())).mapNotNull { item ->
                    val track = item.jsonObject["track"] as? JsonObject ?: return@mapNotNull null
                    val title = track.str("trackName") ?: return@mapNotNull null
                    ImportedList.Song(title, track.str("artistName") ?: return@mapNotNull null)
                }
                if (songs.isEmpty()) null else ImportedList(playlist.str("name") ?: "Playlist", "Spotify playlist", songs)
            }
        }
        if (root is JsonObject && root["tracks"] is JsonArray) {
            val songs = root["tracks"]!!.jsonArray.mapNotNull { t ->
                val o = t.jsonObject
                ImportedList.Song(o.str("track") ?: return@mapNotNull null, o.str("artist") ?: return@mapNotNull null)
            }
            return if (songs.isEmpty()) emptyList() else listOf(ImportedList("Liked Songs", "Spotify library", songs))
        }
        if (root is JsonArray) {
            val counts = mutableMapOf<ImportedList.Song, Int>()
            for (play in root) {
                val o = play as? JsonObject ?: continue
                val title = o.str("master_metadata_track_name") ?: o.str("trackName") ?: continue
                val artist = o.str("master_metadata_album_artist_name") ?: o.str("artistName") ?: continue
                val played = (o["ms_played"] ?: o["msPlayed"])?.jsonPrimitive?.intOrNull ?: 0
                if (played < 30_000) continue // a real listen, not a skip
                val song = ImportedList.Song(title, artist)
                counts[song] = (counts[song] ?: 0) + 1
            }
            return if (counts.isEmpty()) emptyList() else listOf(topList(counts))
        }
        return emptyList()
    }

    fun topList(counts: Map<ImportedList.Song, Int>): ImportedList {
        val top = counts.entries.sortedByDescending { it.value }.take(500).map { it.key }
        return ImportedList("Your Spotify Top ${top.size}", "Spotify listening history", top, counts)
    }

    private fun fromCsv(text: String, name: String): List<ImportedList> {
        val rows = parseCsv(text)
        val header = rows.firstOrNull()?.map { it.lowercase() } ?: return emptyList()
        val title = header.indexOfFirst { it.contains("track name") || it == "title" || it == "name" }
        val artist = header.indexOfFirst { it.contains("artist") }
        if (title < 0 || artist < 0) return fromText(text, name)
        val songs = rows.drop(1).mapNotNull { row ->
            if (row.size <= maxOf(title, artist)) null
            else ImportedList.Song(row[title], row[artist].split(',', ';').first().trim())
        }
        return if (songs.isEmpty()) emptyList() else listOf(ImportedList(name, "CSV file", songs))
    }

    private fun fromText(text: String, name: String): List<ImportedList> {
        val songs = text.lines().mapNotNull { line ->
            val parts = line.split(" - ")
            if (parts.size < 2) null else ImportedList.Song(parts.drop(1).joinToString(" - ").trim(), parts[0].trim())
        }
        return if (songs.isEmpty()) emptyList() else listOf(ImportedList(name, "Song list", songs))
    }

    private fun parseCsv(text: String): List<List<String>> {
        val rows = mutableListOf<List<String>>()
        var row = mutableListOf<String>()
        val field = StringBuilder()
        var quoted = false
        for (c in text) {
            when {
                c == '"' -> quoted = !quoted
                c == ',' && !quoted -> { row += field.toString(); field.clear() }
                (c == '\n') && !quoted -> {
                    row += field.toString().trimEnd('\r'); field.clear()
                    if (row.any { it.isNotEmpty() }) rows += row
                    row = mutableListOf()
                }
                else -> field.append(c)
            }
        }
        row += field.toString()
        if (row.any { it.isNotEmpty() }) rows += row
        return rows
    }
}

/** Finds an imported song in your library by title and artist. */
object LibraryMatcher {
    fun key(text: String): String {
        var clean = text.lowercase()
            .replace(Regex("\\s*[\\(\\[][^\\)\\]]*[\\)\\]]"), "")
            .replace(Regex("\\s+-\\s+.*(remaster|version|edit|mix|live).*$"), "")
        clean = ArtistNames.key(clean)
        return clean.filter { it.isLetterOrDigit() }
    }

    suspend fun find(song: ImportedList.Song, client: JellyfinClient): Item? {
        val candidates = runCatching { client.search(song.title) }.getOrDefault(emptyList()).filter { it.isSong }
        val wantedTitle = key(song.title)
        val wantedArtist = ArtistNames.key(ArtistNames.primary(song.artist))
        fun sameArtist(item: Item) = (listOf(item.albumArtistLine, item.artistLine) + (item.artists ?: emptyList()))
            .any { ArtistNames.key(ArtistNames.primary(it)) == wantedArtist || ArtistNames.key(it).contains(wantedArtist) }
        return candidates.firstOrNull { key(it.name) == wantedTitle && sameArtist(it) }
            ?: candidates.firstOrNull { sameArtist(it) && (key(it.name).contains(wantedTitle) || wantedTitle.contains(key(it.name))) }
    }
}
