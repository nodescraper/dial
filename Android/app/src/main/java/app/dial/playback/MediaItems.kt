package app.dial.playback

import android.net.Uri
import android.os.Bundle
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import app.dial.data.Item
import app.dial.data.JellyfinClient
import app.dial.data.JellyfinJson
import app.dial.data.Station

/** Turns library items into Media3's items, carrying the original along so screens can show it. */
object MediaItems {
    private const val ITEM_KEY = "dial.item"

    /** Downloaded songs, so they play from the file (and offline). Set by the app at start. */
    var downloadedFile: (String) -> java.io.File? = { null }

    fun song(item: Item, client: JellyfinClient): MediaItem =
        MediaItem.Builder()
            .setMediaId(item.id)
            .setUri(downloadedFile(item.id)?.let { Uri.fromFile(it) } ?: Uri.parse(client.streamUrl(item.id)))
            .setMediaMetadata(
                MediaMetadata.Builder()
                    .setTitle(item.name)
                    .setArtist(item.artistLine)
                    .setAlbumTitle(item.album)
                    .setAlbumArtist(item.albumArtistLine)
                    .setArtworkUri(Uri.parse(client.imageUrl(item.imageItemId)))
                    .setReleaseYear(item.productionYear)
                    .setIsPlayable(true)
                    .setIsBrowsable(false)
                    .setMediaType(MediaMetadata.MEDIA_TYPE_MUSIC)
                    .setExtras(Bundle().apply { putString(ITEM_KEY, JellyfinJson.encodeToString(Item.serializer(), item)) })
                    .build()
            )
            .build()

    /** A folder in Android Auto's browser (albums, playlists, sections). */
    /** How Android Auto lays a folder's children out: a list (text rows) or a grid (covers). */
    enum class Layout(val value: Int) { LIST(1), GRID(2) }

    private fun styleExtras(browsable: Layout?, playable: Layout?, supported: Boolean = false) = Bundle().apply {
        if (supported) putBoolean("android.media.browse.CONTENT_STYLE_SUPPORTED", true)
        browsable?.let { putInt("android.media.browse.CONTENT_STYLE_BROWSABLE_HINT", it.value) }
        playable?.let { putInt("android.media.browse.CONTENT_STYLE_PLAYABLE_HINT", it.value) }
    }

    /** The top of the tree: Android Auto reads the layout hints here and lets each folder choose its own. */
    fun root(): MediaItem = MediaItem.Builder().setMediaId("root").setMediaMetadata(
        MediaMetadata.Builder().setTitle("Dial").setIsPlayable(false).setIsBrowsable(true)
            .setMediaType(MediaMetadata.MEDIA_TYPE_FOLDER_MIXED)
            .setExtras(styleExtras(Layout.LIST, Layout.LIST, supported = true)).build()
    ).build()

    fun folder(id: String, title: String, subtitle: String? = null, artwork: String? = null,
               type: Int = MediaMetadata.MEDIA_TYPE_FOLDER_MIXED, children: Layout = Layout.LIST,
               playableChildren: Layout = Layout.LIST): MediaItem =
        MediaItem.Builder()
            .setMediaId(id)
            .setMediaMetadata(
                MediaMetadata.Builder()
                    .setTitle(title)
                    .setSubtitle(subtitle)
                    .setArtworkUri(artwork?.let(Uri::parse))
                    .setIsPlayable(false)
                    .setIsBrowsable(true)
                    .setMediaType(type)
                    .setExtras(styleExtras(children, playableChildren))
                    .build()
            )
            .build()

    /** A live radio station. */
    fun station(station: Station): MediaItem =
        MediaItem.Builder()
            .setMediaId("station:${station.id}")
            .setUri(station.streamUrl)
            .setMediaMetadata(
                MediaMetadata.Builder()
                    .setTitle(station.name)
                    .setArtist(listOfNotNull(station.country, station.tags?.split(',')?.firstOrNull()).joinToString(" \u00b7 ").ifEmpty { "Live radio" })
                    .setArtworkUri(station.favicon?.takeIf { it.isNotBlank() }?.let(Uri::parse))
                    .setIsPlayable(true).setIsBrowsable(false)
                    .setMediaType(MediaMetadata.MEDIA_TYPE_RADIO_STATION)
                    .setExtras(Bundle().apply { putString(STATION_KEY, JellyfinJson.encodeToString(Station.serializer(), station)) })
                    .build()
            )
            .build()

    private const val STATION_KEY = "dial.station"

    fun station(mediaItem: MediaItem?): Station? {
        val json = mediaItem?.mediaMetadata?.extras?.getString(STATION_KEY) ?: return null
        return runCatching { JellyfinJson.decodeFromString(Station.serializer(), json) }.getOrNull()
    }

    fun item(mediaItem: MediaItem?): Item? {
        val json = mediaItem?.mediaMetadata?.extras?.getString(ITEM_KEY) ?: return null
        return runCatching { JellyfinJson.decodeFromString(Item.serializer(), json) }.getOrNull()
    }
}
