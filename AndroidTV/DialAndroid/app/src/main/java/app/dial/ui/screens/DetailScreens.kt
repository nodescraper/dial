package app.dial.ui.screens

import androidx.compose.foundation.background
import androidx.compose.ui.unit.sp
import app.dial.data.GenreNames
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.QueueMusic
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.DownloadDone
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Radio
import androidx.compose.material.icons.rounded.Shuffle
import androidx.compose.material3.Button
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import app.dial.data.ArtistNames
import app.dial.data.musicBrainzId
import app.dial.data.Item
import app.dial.ui.AlbumRoute
import app.dial.ui.ArtistRoute
import app.dial.ui.LocalApp
import app.dial.ui.LocalNavigator
import app.dial.ui.components.ArtistShape
import app.dial.ui.components.Artwork
import app.dial.ui.components.SectionTitle
import app.dial.ui.components.Shelf
import app.dial.ui.components.SongRow
import app.dial.ui.components.Spacing
import app.dial.ui.components.Tile
import app.dial.ui.components.black
import app.dial.ui.songActions
import app.dial.data.PublicMusic
import app.dial.ui.components.ArtistTile

/** The big picture, title and Play / Shuffle buttons at the top of a page. */
@Composable
fun DetailHeader(imageUrl: String?, shape: Shape, title: String, subtitle: String?, onSubtitle: (() -> Unit)?,
                         detail: String?, onPlay: () -> Unit, onShuffle: () -> Unit, third: (@Composable () -> Unit)? = null,
                         badges: List<String> = emptyList(),
                         placeholder: ImageVector = Icons.Rounded.PlayArrow) {
    Column(Modifier.fillMaxWidth().padding(horizontal = Spacing.l), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
        Artwork(imageUrl, Modifier.size(240.dp), shape, placeholder)
        Spacer(Modifier.size(Spacing.s))
        Text(title, style = MaterialTheme.typography.headlineMedium.black(), textAlign = TextAlign.Center)
        if (subtitle != null) {
            Text(subtitle, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary,
                modifier = if (onSubtitle != null) Modifier.clickable(onClick = onSubtitle) else Modifier)
        }
        if (detail != null) {
            Text(detail, style = MaterialTheme.typography.labelMedium.copy(letterSpacing = 0.6.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold),
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (badges.isNotEmpty()) {
            Row(horizontalArrangement = Arrangement.spacedBy(Spacing.xs)) {
                badges.forEach { badge ->
                    Text(badge, style = MaterialTheme.typography.labelSmall.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.Bold),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.background(MaterialTheme.colorScheme.surfaceContainerHigh, androidx.compose.foundation.shape.CircleShape)
                            .padding(horizontal = 8.dp, vertical = 3.dp))
                }
            }
        }
        // Play and Shuffle side by side, like Material's button groups.
        Row(Modifier.padding(top = Spacing.s), horizontalArrangement = Arrangement.spacedBy(Spacing.s),
            verticalAlignment = Alignment.CenterVertically) {
            Button(onClick = onPlay, modifier = Modifier.width(130.dp)) {
                Icon(Icons.Rounded.PlayArrow, null); Spacer(Modifier.width(Spacing.xs)); Text("Play")
            }
            FilledTonalButton(onClick = onShuffle, modifier = Modifier.width(130.dp)) {
                Icon(Icons.Rounded.Shuffle, null); Spacer(Modifier.width(Spacing.xs)); Text("Shuffle")
            }
            third?.invoke()
        }
    }
}

@Composable
fun AlbumScreen(id: String, name: String) {
    val app = LocalApp.current
    val navigator = LocalNavigator.current
    val client = client()
    val playback by app.player.state.collectAsState()
    val favorites by app.library.favorites.collectAsState()
    val actions = songActions()
    val load = rememberLoad(id) { c -> c.details(id) to c.albumTracks(id) }
    Column(Modifier.fillMaxSize()) {
        PageTopBar("")
        LoadContent(load) { (album, tracks) ->
            LazyColumn(contentPadding = PaddingValues(bottom = Spacing.section)) {
                item {
                    val artistId = album.albumArtists?.firstOrNull()?.id
                    DetailHeader(
                        imageUrl = client?.imageUrl(id, 800), shape = RoundedCornerShape(16.dp),
                        title = album.name.ifEmpty { name }, subtitle = album.albumArtistLine,
                        onSubtitle = artistId?.let { aid -> { navigator.open(ArtistRoute(aid, album.albumArtistLine)) } },
                        // "HIP-HOP · 2019", with the genre grouped by meaning (Reggaeton and Trap Latino are Latin).
                        detail = listOfNotNull(GenreNames.families(album.genres ?: emptyList()).firstOrNull(),
                            album.productionYear?.toString()).joinToString(" \u00b7 ").uppercase().ifEmpty { null },
                        badges = tracks.firstOrNull()?.qualityBadges ?: emptyList(),
                        onPlay = { app.player.play(tracks) }, onShuffle = { app.player.play(tracks, shuffle = true) },
                        third = {
                            val favorite = album.id in favorites
                            FilledTonalIconButton(onClick = { app.library.toggleFavorite(album) }) {
                                Icon(if (favorite) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder,
                                    if (favorite) "Remove from Favorites" else "Favorite")
                            }
                            val records by app.downloads.records.collectAsState()
                            val all = tracks.all { it.id in records }
                            FilledTonalIconButton(onClick = { client?.let { app.downloads.download(tracks, it) } }, enabled = !all) {
                                Icon(if (all) Icons.Rounded.DownloadDone else Icons.Rounded.Download, if (all) "Downloaded" else "Download album")
                            }
                        },
                    )
                    Spacer(Modifier.size(Spacing.l))
                }
                itemsIndexed(tracks, key = { _, t -> t.id }) { index, track ->
                    SongRow(track, null, playback.current?.id == track.id, onClick = { app.player.play(tracks, index) },
                        actions = actions, numbered = true)
                }
                // Apple-style details: release date, songs and minutes, label, format and size.
                item {
                    Column(Modifier.fillMaxWidth().padding(horizontal = Spacing.l, vertical = Spacing.m)) {
                        val muted = MaterialTheme.colorScheme.onSurfaceVariant
                        val style = MaterialTheme.typography.bodySmall
                        releaseDate(album.premiereDate)?.let { Text(it, style = style, color = muted) }
                        val minutes = (tracks.sumOf { it.durationMs } / 60000.0).toInt()
                        Text(if (minutes > 0) "${tracks.size} songs, $minutes minutes" else "${tracks.size} songs", style = style, color = muted)
                        album.studios?.firstOrNull()?.name?.let { Text("\u2117 ${album.productionYear ?: ""} $it".replace("  ", " "), style = style, color = muted) }
                        val bytes = tracks.sumOf { it.mediaSources?.firstOrNull()?.size ?: 0L }
                        if (bytes > 0) Text("${tracks.firstOrNull()?.formatLabel ?: ""} \u00b7 ${"%.0f MB".format(bytes / 1_000_000.0)}", style = style, color = muted)
                    }
                }
            }
        }
    }
}

private fun releaseDate(text: String?): String? = runCatching {
    java.time.OffsetDateTime.parse(text).toLocalDate().format(java.time.format.DateTimeFormatter.ofLocalizedDate(java.time.format.FormatStyle.LONG))
}.getOrNull()

private data class ArtistData(val artist: Item, val top: List<Item>, val albums: List<Item>,
                              val releases: List<PublicMusic.Release>, val similar: List<Item>)

@Composable
fun ArtistScreen(id: String, name: String) {
    val app = LocalApp.current
    val navigator = LocalNavigator.current
    val client = client()
    val playback by app.player.state.collectAsState()
    val actions = songActions()
    val load = rememberLoad(id) { c ->
        val artist = c.details(id)
        val releases = artist.musicBrainzId?.let { PublicMusic.discography(it) } ?: emptyList()
        val similar = runCatching { PublicMusic.similarInLibrary(artist, c.artists()) }.getOrDefault(emptyList())
        ArtistData(artist, c.artistTopSongs(id), c.artistAlbums(id), releases, similar)
    }
    val featured by app.credits.featured.collectAsState()
    Column(Modifier.fillMaxSize()) {
        PageTopBar("")
        LoadContent(load) { data ->
            LazyColumn(contentPadding = PaddingValues(bottom = Spacing.section), verticalArrangement = Arrangement.spacedBy(Spacing.l)) {
                item {
                    DetailHeader(
                        imageUrl = client?.imageUrl(id, 800), shape = ArtistShape,
                        title = ArtistNames.primary(data.artist.name.ifEmpty { name }), subtitle = null, onSubtitle = null,
                        detail = data.artist.genres?.take(3)?.joinToString(", "),
                        onPlay = { app.player.play(data.top) }, onShuffle = { app.player.play(data.top, shuffle = true) },
                        third = {
                            FilledTonalIconButton(onClick = { app.player.startRadio(data.artist) }) {
                                Icon(Icons.Rounded.Radio, "Artist radio")
                            }
                        },
                    )
                }
                if (data.top.isNotEmpty()) {
                    item { SectionTitle("Top Songs") }
                    itemsIndexed(data.top.take(5), key = { _, t -> t.id }) { index, song ->
                        SongRow(song, client?.imageUrl(song.imageItemId, 160), playback.current?.id == song.id,
                            onClick = { app.player.play(data.top, index) }, actions = actions)
                    }
                }
                item {
                    Discography(data.albums, data.releases, ArtistNames.primary(data.artist.name), id)
                }
                val featuredOn = featured[ArtistNames.key(ArtistNames.primary(data.artist.name))]?.songs ?: emptyList()
                if (featuredOn.isNotEmpty()) {
                    item { SectionTitle("Featured On") }
                    itemsIndexed(featuredOn.take(10), key = { _, t -> "f-${t.id}" }) { index, song ->
                        SongRow(song, client?.imageUrl(song.imageItemId, 160), playback.current?.id == song.id,
                            onClick = { app.player.play(featuredOn, index) }, actions = actions)
                    }
                }
                if (data.similar.isNotEmpty()) {
                    item {
                        Shelf("Similar Artists", data.similar, key = { it.id }) { other ->
                            ArtistTile(ArtistNames.primary(other.name), client?.imageUrl(other.id), 120.dp) {
                                navigator.open(ArtistRoute(other.id, other.name))
                            }
                        }
                    }
                }
            }
        }
    }
}
