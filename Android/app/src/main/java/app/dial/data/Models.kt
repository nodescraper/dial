package app.dial.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** Reads Jellyfin's JSON, ignoring the many fields Dial doesn't use. */
val JellyfinJson = Json {
    ignoreUnknownKeys = true
    explicitNulls = false
    coerceInputValues = true
}

@Serializable
data class NameId(
    @SerialName("Name") val name: String = "",
    @SerialName("Id") val id: String = "",
)

@Serializable
data class UserData(
    @SerialName("IsFavorite") val isFavorite: Boolean? = null,
    @SerialName("PlayCount") val playCount: Int? = null,
    /** 0 to 10; Dial shows it as 0 to 5 stars. */
    @SerialName("Rating") val rating: Double? = null,
    @SerialName("LastPlayedDate") val lastPlayedDate: String? = null,
)

@Serializable
data class MediaStream(
    @SerialName("Type") val type: String? = null,
    @SerialName("Codec") val codec: String? = null,
    @SerialName("BitRate") val bitRate: Int? = null,
    @SerialName("SampleRate") val sampleRate: Int? = null,
    @SerialName("BitDepth") val bitDepth: Int? = null,
    @SerialName("Channels") val channels: Int? = null,
)

@Serializable
data class MediaSource(
    @SerialName("Container") val container: String? = null,
    @SerialName("Bitrate") val bitrate: Int? = null,
    @SerialName("Size") val size: Long? = null,
    @SerialName("MediaStreams") val streams: List<MediaStream>? = null,
)

/** Anything in the library: a song, album, artist, playlist or genre. */
@Serializable
data class Item(
    @SerialName("Id") val id: String,
    @SerialName("Name") val name: String = "",
    @SerialName("Type") val type: String? = null,
    @SerialName("Album") val album: String? = null,
    @SerialName("AlbumId") val albumId: String? = null,
    @SerialName("AlbumArtist") val albumArtist: String? = null,
    @SerialName("AlbumArtists") val albumArtists: List<NameId>? = null,
    @SerialName("ArtistItems") val artistItems: List<NameId>? = null,
    @SerialName("Artists") val artists: List<String>? = null,
    @SerialName("RunTimeTicks") val runTimeTicks: Long? = null,
    @SerialName("ProductionYear") val productionYear: Int? = null,
    @SerialName("IndexNumber") val indexNumber: Int? = null,
    @SerialName("ParentIndexNumber") val discNumber: Int? = null,
    @SerialName("UserData") val userData: UserData? = null,
    @SerialName("ImageTags") val imageTags: Map<String, String>? = null,
    @SerialName("AlbumPrimaryImageTag") val albumImageTag: String? = null,
    @SerialName("Overview") val overview: String? = null,
    @SerialName("Genres") val genres: List<String>? = null,
    @SerialName("MediaSources") val mediaSources: List<MediaSource>? = null,
    @SerialName("ProviderIds") val providerIds: Map<String, String>? = null,
    @SerialName("PremiereDate") val premiereDate: String? = null,
    @SerialName("DateCreated") val dateCreated: String? = null,
    @SerialName("Studios") val studios: List<NameId>? = null,
    @SerialName("Path") val path: String? = null,
    @SerialName("PlaylistItemId") val playlistItemId: String? = null,
    /** Decibels to reach Jellyfin's loudness target, for volume leveling. */
    @SerialName("NormalizationGain") val normalizationGain: Double? = null,
) {
    val isSong: Boolean get() = type == null || type == "Audio"

    /**
     * A playlist file that came with your music (a .m3u in an album folder, like "Play Me" or "00.Info"), rather than one
     * made in Jellyfin. Jellyfin can't delete these; they go away when the file does. Same rule as on iPhone and Mac.
     */
    val isPlaylistFile: Boolean
        get() {
            val where = path?.lowercase() ?: return false
            if (type != "Playlist") return false
            if ("/data/playlists/" in where || "\\data\\playlists\\" in where) return false
            return listOf(".m3u", ".m3u8", ".pls", ".wpl", ".xspf", ".zpl").any { where.endsWith(it) }
        }
    val durationMs: Long get() = (runTimeTicks ?: 0L) / 10_000L

    /** "Post Malone, Quavo", or the album artist when there's no list. */
    val artistLine: String
        get() = artists?.takeIf { it.isNotEmpty() }?.joinToString(", ")
            ?.let(ArtistNames::display)
            ?: artistItems?.takeIf { it.isNotEmpty() }?.joinToString(", ") { it.name }
            ?: albumArtist?.let(ArtistNames::display) ?: ""

    val albumArtistLine: String
        get() = albumArtist ?: albumArtists?.firstOrNull()?.name ?: artistLine

    /** Whose picture to show: the item's own, or its album's cover for songs. */
    val imageItemId: String
        get() = if (imageTags?.containsKey("Primary") == true || albumId == null) id else albumId

    /** "FLAC", "MP3" and so on. */
    val formatLabel: String?
        get() = mediaSources?.firstOrNull()?.container?.uppercase()

    val isLossless: Boolean
        get() = formatLabel?.lowercase() in setOf("flac", "alac", "wav", "aiff", "aif", "ape", "wv", "dsf", "dff")

    private val audioStream get() = mediaSources?.firstOrNull()?.streams?.firstOrNull { it.type == "Audio" }

    /** Apple-style quality badges: Lossless or Hi-Res Lossless (or the format), Surround, and the exact quality. */
    val qualityBadges: List<String>
        get() {
            val result = mutableListOf<String>()
            val stream = audioStream
            if (isLossless) {
                val hiRes = (stream?.sampleRate ?: 0) > 48_000 || (stream?.bitDepth ?: 16) > 16
                result += if (hiRes) "Hi-Res Lossless" else "Lossless"
            } else formatLabel?.let { result += it }
            if ((stream?.channels ?: 2) > 2) result += "Surround"
            qualityLabel?.let { result += it }
            return result
        }

    /** "44.1 kHz / 16-bit" for lossless files, "320 kbps" for compressed ones. */
    val qualityLabel: String?
        get() {
            val audio = mediaSources?.firstOrNull()?.streams?.firstOrNull { it.type == "Audio" } ?: return null
            val rate = audio.sampleRate
            val depth = audio.bitDepth
            return when {
                rate != null && depth != null -> "%.1f kHz / %d-bit".format(rate / 1000.0, depth).replace(".0 kHz", " kHz")
                audio.bitRate != null -> "${audio.bitRate / 1000} kbps"
                else -> null
            }
        }
}

@Serializable
data class ItemsResponse(@SerialName("Items") val items: List<Item> = emptyList())

@Serializable
data class AuthUser(@SerialName("Id") val id: String, @SerialName("Name") val name: String = "")

@Serializable
data class AuthResult(@SerialName("AccessToken") val token: String, @SerialName("User") val user: AuthUser)

/** Library sections, for the Library tab. */
enum class LibrarySection(val title: String) {
    Playlists("Playlists"), Artists("Artists"), Albums("Albums"), Songs("Songs"), Favorites("Favorites"),
    Downloaded("Downloaded"), Wishlist("Wishlist")
}

/** "Post Malone feat. 2 Chainz" → "Post Malone". */
object ArtistNames {
    private val separators = listOf(" feat. ", " feat ", " ft. ", " ft ", " featuring ", " with ", " (feat. ", " (with ")

    fun primary(name: String): String {
        var result = name
        for (separator in separators) {
            val index = result.indexOf(separator, ignoreCase = true)
            if (index > 0) result = result.substring(0, index)
        }
        // Several artists in one tag ("A; B; C"): the first is the main one.
        val semicolon = result.indexOf(';')
        if (semicolon > 0) result = result.substring(0, semicolon)
        return result.trim()
    }

    /** A credit for reading: "A; B; C" becomes "A, B, C". */
    fun display(credit: String): String =
        if (';' in credit) credit.split(';').map { it.trim() }.filter { it.isNotEmpty() }.joinToString(", ") else credit

    fun key(name: String): String =
        java.text.Normalizer.normalize(name.lowercase(), java.text.Normalizer.Form.NFD)
            .replace(Regex("\\p{M}+"), "").trim()

    /** One entry per main artist, like on iPhone. */
    fun distinct(artists: List<Item>): List<Item> {
        val chosen = LinkedHashMap<String, Item>()
        for (artist in artists) {
            val main = primary(artist.name)
            val key = key(main)
            val existing = chosen[key]
            if (existing == null || (existing.name != primary(existing.name) && artist.name == main)) chosen[key] = artist
        }
        return chosen.values.toList()
    }
}

fun formatTime(ms: Long): String {
    val total = (ms / 1000).coerceAtLeast(0)
    return "%d:%02d".format(total / 60, total % 60)
}

@Serializable
data class QuickConnectState(
    @SerialName("Secret") val secret: String = "",
    @SerialName("Code") val code: String = "",
    @SerialName("Authenticated") val authenticated: Boolean = false,
)

@Serializable
data class LyricLine(
    @SerialName("Text") val text: String = "",
    @SerialName("Start") val start: Long? = null,
) {
    val startMs: Long? get() = start?.let { it / 10_000 }
}

@Serializable
data class LyricsResponse(@SerialName("Lyrics") val lyrics: List<LyricLine> = emptyList())

val Item.musicBrainzId: String? get() = providerIds?.get("MusicBrainzArtist") ?: providerIds?.get("MusicBrainzReleaseGroup")
val Item.releaseGroupId: String? get() = providerIds?.get("MusicBrainzReleaseGroup")
