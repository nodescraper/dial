package app.dial.data

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer

/** Something you want but don't have yet: an album, or a song (with the album it is on). */
@Serializable
data class WishItem(
    val id: String,
    /** "album" or "song". */
    val kind: String,
    val title: String,
    val artist: String,
    /** For songs: the album it is on. */
    val album: String? = null,
    /** The album to open: a MusicBrainz release group id, or a Deezer ("dz-…") or iTunes ("it-…") id. */
    val sourceId: String? = null,
    val cover: String? = null,
    /** When it was added, "2026-11-22T13:25:00Z". */
    val added: String = "",
) {
    val isAlbum get() = kind == "album"

    /** The cover: the one saved with it, or MusicBrainz's cover for its album. */
    val coverUrl: String?
        get() = cover ?: sourceId?.takeIf { !DeezerSearch.isSourceId(it) }
            ?.let { "https://coverartarchive.org/release-group/$it/front-250" }

    companion object {
        /** The same album or song always gets the same id, wherever it was found, so it is never on the list twice. */
        fun id(kind: String, artist: String, title: String): String {
            // FNV-1a over the normalized "artist|title", like on iPhone.
            var hash = 0xcbf29ce484222325UL
            for (byte in (ArtistNames.key(artist) + "|" + ArtistNames.key(title)).toByteArray()) {
                hash = (hash xor (byte.toULong() and 0xFFUL)) * 0x100000001b3UL
            }
            return "$kind-${hash.toString(16)}"
        }

        fun album(artist: String, title: String, sourceId: String? = null, cover: String? = null) =
            WishItem(id("album", artist, title), "album", title, artist,
                sourceId = sourceId?.ifEmpty { null }, cover = cover)

        fun song(artist: String, title: String, album: String? = null, albumSourceId: String? = null, cover: String? = null) =
            WishItem(id("song", artist, title), "song", title, artist, album = album,
                sourceId = albumSourceId?.ifEmpty { null }, cover = cover)
    }
}

/** Your wishlist, kept by the Dial plugin so every device shows the same one. A copy is saved on the device, so the list
 *  shows at once; changes show at once too, and go back if the server says no. */
object Wishlist {
    private lateinit var prefs: android.content.SharedPreferences
    private val _items = MutableStateFlow<List<WishItem>>(emptyList())
    val items: StateFlow<List<WishItem>> = _items

    fun init(context: Context) {
        prefs = context.getSharedPreferences("dial.wishlist", Context.MODE_PRIVATE)
        _items.value = runCatching {
            JellyfinJson.decodeFromString(ListSerializer(WishItem.serializer()), prefs.getString("items", "[]")!!)
        }.getOrDefault(emptyList())
    }

    fun contains(id: String) = _items.value.any { it.id == id }

    suspend fun refresh(client: JellyfinClient) {
        client.dialWishlist()?.let { set(it) }
    }

    suspend fun toggle(item: WishItem, client: JellyfinClient?) {
        if (contains(item.id)) remove(item.id, client) else add(item, client)
    }

    suspend fun add(item: WishItem, client: JellyfinClient?) {
        if (client == null || contains(item.id)) return
        val before = _items.value
        set(listOf(item) + before)
        val fresh = client.dialWishlistAdd(item)
        if (fresh != null) set(fresh) else set(before)
    }

    suspend fun remove(id: String, client: JellyfinClient?) {
        if (client == null) return
        val before = _items.value
        set(before.filterNot { it.id == id })
        val fresh = client.dialWishlistRemove(id)
        if (fresh != null) set(fresh) else set(before)
    }

    private fun set(list: List<WishItem>) {
        _items.value = list
        runCatching { prefs.edit().putString("items", JellyfinJson.encodeToString(ListSerializer(WishItem.serializer()), list)).apply() }
    }
}
