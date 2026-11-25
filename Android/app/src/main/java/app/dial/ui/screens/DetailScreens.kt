package app.dial.ui.screens

import androidx.compose.runtime.setValue
import app.dial.data.Follows
import kotlinx.coroutines.launch
import androidx.compose.material.icons.rounded.NotificationsActive
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.draw.alpha
import androidx.compose.foundation.lazy.items
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.layout.Box
import app.dial.data.formatTime
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
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
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
import app.dial.data.WishItem
import app.dial.ui.components.ArtistTile
import app.dial.ui.components.JewelCase

/** The big picture, title and Play / Shuffle buttons at the top of a page. */
@Composable
fun DetailHeader(imageUrl: String?, shape: Shape, title: String, subtitle: String?, onSubtitle: (() -> Unit)?,
                         detail: String?, onPlay: () -> Unit, onShuffle: () -> Unit, third: (@Composable () -> Unit)? = null,
                         badges: List<String> = emptyList(),
                         placeholder: ImageVector = Icons.Rounded.PlayArrow,
                         jewelCase: Boolean = false) {
    Column(Modifier.fillMaxWidth().padding(horizontal = Spacing.l), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
        if (jewelCase) JewelCase(imageUrl, Modifier.width(240.dp))
        else Artwork(imageUrl, Modifier.size(240.dp), shape, placeholder)
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

@OptIn(ExperimentalFoundationApi::class)
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
        AlbumTopBar()
        LoadContent(load) { (album, tracks) ->
            // Songs the album should have according to MusicBrainz but your library doesn't.
            val gaps by androidx.compose.runtime.produceState(PublicMusic.Gaps(emptyList(), emptyMap()), album.id, tracks.size) {
                value = PublicMusic.missingTracks(album, tracks)
            }
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
                        jewelCase = true,
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
                // Your songs and the ones you don't have in one list, in the album's track order; missing ones faded.
                val rows: List<Pair<Item?, PublicMusic.Track?>> = run {
                    fun disc(t: Item) = gaps.positions[t.id]?.first ?: t.discNumber ?: 1
                    fun number(t: Item) = gaps.positions[t.id]?.second ?: t.indexNumber ?: 9999
                    (tracks.map { Triple(disc(it), number(it), it to null as PublicMusic.Track?) } +
                        gaps.missing.map { Triple(it.disc, it.number, null as Item? to it as PublicMusic.Track?) })
                        .sortedWith(compareBy({ it.first }, { it.second })).map { it.third }
                }
                items(rows.size, key = { i -> rows[i].first?.id ?: "gap-${rows[i].second?.disc}-${rows[i].second?.number}" }) { i ->
                    val track = rows[i].first
                    val gap = rows[i].second
                    if (track != null) {
                        SongRow(track, null, playback.current?.id == track.id,
                            onClick = { app.player.play(tracks, tracks.indexOfFirst { it.id == track.id }.coerceAtLeast(0)) },
                            actions = actions, numbered = true)
                    } else if (gap != null) {
                        // The same row as a song you own (number, title, artist, time), faded and not playable.
                        var gapMenu by remember { mutableStateOf(false) }
                        Box(Modifier.fillMaxWidth().combinedClickable(onClick = {}, onLongClick = { gapMenu = true })) {
                            Row(Modifier.fillMaxWidth().padding(horizontal = Spacing.l, vertical = Spacing.s).alpha(0.4f),
                                verticalAlignment = Alignment.CenterVertically) {
                                Box(Modifier.width(32.dp), contentAlignment = Alignment.CenterStart) {
                                    Text("${gap.number}", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                                Column(Modifier.weight(1f).padding(horizontal = Spacing.m)) {
                                    Text(gap.title, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis,
                                        color = MaterialTheme.colorScheme.onSurface)
                                    Text(album.albumArtistLine, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                                Text(formatTime((gap.lengthMs ?: 0).toLong()), style = MaterialTheme.typography.labelMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = Spacing.s))
                                Spacer(Modifier.width(48.dp))
                            }
                            DropdownMenu(expanded = gapMenu, onDismissRequest = { gapMenu = false }) {
                                WishlistMenuItem(WishItem.song(album.albumArtistLine, gap.title, album.name)) { gapMenu = false }
                            }
                        }
                    }
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
                              val releases: List<PublicMusic.Release>, val similar: List<Item>,
                              val popular: List<PublicMusic.TopTrack> = emptyList(), val songs: List<Item> = emptyList())

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
        val popular = artist.musicBrainzId?.let { PublicMusic.topTracks(it) } ?: emptyList()
        val songs = if (popular.isEmpty()) emptyList() else runCatching { c.artistSongs(id, 500) }.getOrDefault(emptyList())
        ArtistData(artist, c.artistTopSongs(id), c.artistAlbums(id), releases, similar, popular, songs)
    }
    val featured by app.credits.featured.collectAsState()
    val followed by Follows.artists.collectAsState()
    val followScope = androidx.compose.runtime.rememberCoroutineScope()
    var followId by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf<String?>(null) }
    Column(Modifier.fillMaxSize()) {
        // Follow (instead of a heart): new releases of a followed artist are announced.
        PageTopBar("") {
            val ready = (load as? Load.Ready)?.value
            if (ready != null) {
                val display = ArtistNames.primary(ready.artist.name.ifEmpty { name })
                val on = followed.any { it.id == (followId ?: ready.artist.musicBrainzId) }
                androidx.compose.material3.TextButton(onClick = {
                    followScope.launch {
                        val mbid = followId ?: ready.artist.musicBrainzId ?: PublicMusic.artistMbid(display)
                        if (mbid != null) { followId = mbid; Follows.toggleFollow(mbid, display) }
                    }
                }) {
                    Icon(if (on) Icons.Rounded.NotificationsActive else Icons.Rounded.Notifications, null, Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(if (on) "Following" else "Follow")
                }
            }
        }
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
                if (data.popular.isNotEmpty()) item {
                    PopularSongs(data.popular, ArtistNames.primary(data.artist.name.ifEmpty { name }), data.songs) { list, index -> list.getOrNull(index)?.let { app.player.playLike(it) } }
                }
                if (data.top.isNotEmpty()) {
                    item { SectionTitle(if (data.popular.isEmpty()) "Top Songs" else "Your Top Songs") }
                    itemsIndexed(data.top.take(5), key = { _, t -> t.id }) { index, song ->
                        SongRow(song, client?.imageUrl(song.imageItemId, 160), playback.current?.id == song.id,
                            onClick = { app.player.playLike(song) }, actions = actions)
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
                            onClick = { app.player.playLike(song) }, actions = actions)
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
