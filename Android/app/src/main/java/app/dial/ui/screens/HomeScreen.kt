@file:OptIn(ExperimentalMaterial3Api::class)

package app.dial.ui.screens

import kotlinx.coroutines.async
import app.dial.ui.components.Ghost
import app.dial.ui.LibraryRoute
import androidx.compose.material.icons.rounded.Search
import androidx.compose.foundation.layout.widthIn
import app.dial.data.HighlightBuilder
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.Sensors
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.aspectRatio
import app.dial.ui.components.focusHighlight
import app.dial.data.MixCatalog
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Logout
import androidx.compose.material.icons.rounded.Shuffle
import androidx.compose.material.icons.rounded.Devices
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.Speaker
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import kotlinx.coroutines.launch
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.carousel.HorizontalMultiBrowseCarousel
import androidx.compose.material3.carousel.rememberCarouselState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.dial.data.Item
import app.dial.ui.AlbumRoute
import app.dial.ui.LocalApp
import app.dial.ui.LocalNavigator
import app.dial.ui.components.Artwork
import app.dial.ui.components.Shelf
import app.dial.ui.components.SongRow
import app.dial.ui.components.Spacing
import app.dial.ui.components.Tile
import app.dial.ui.components.black
import app.dial.ui.components.bold
import app.dial.ui.songActions
import app.dial.ui.SettingsRoute
import app.dial.ui.components.OfflineBanner
import app.dial.ui.components.SectionTitle

private data class HomeData(val added: List<Item>, val played: List<Item>, val favorites: List<Item>)

@Composable
fun HomeScreen() {
    val app = LocalApp.current
    val navigator = LocalNavigator.current
    val playback by app.player.state.collectAsState()
    val actions = songActions()
    val load = rememberLoad(Unit) { client ->
        kotlinx.coroutines.coroutineScope {
            val added = async { client.recentAlbums(10) }
            val played = async { client.recentlyPlayed(12) }
            val favorites = async { client.favoriteAlbums() }
            HomeData(added.await(), played.await(), favorites.await())
        }
    }
    val client = client()
    val offline by app.connectivity.offline.collectAsState()
    val records by app.downloads.records.collectAsState()
    val downloaded = remember(records) { records.values.map { it.item }.sortedBy { it.albumArtistLine + it.album + (it.indexNumber ?: 0) } }
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    // The lead row: cards that each say something (new from your artists, recently added, on repeat...).
    var highlights by remember { mutableStateOf(HighlightBuilder.latest) }
    // False until the highlights have been tried once: the hero shows a ghost card instead of jumping between cards.
    var highlightsSettled by remember { mutableStateOf(false) }
    androidx.compose.runtime.LaunchedEffect(client) {
        val c = client ?: return@LaunchedEffect
        try { HighlightBuilder.load(c) { if (it != highlights) highlights = it } } finally { highlightsSettled = true }
    }
    // The same mixtapes as on Radio, starting with what was shown last time.
    var mixtapes by remember { mutableStateOf(MixCatalog.latest?.highlights() ?: emptyList()) }
    androidx.compose.runtime.LaunchedEffect(client) {
        val c = client ?: return@LaunchedEffect
        val muse = runCatching { c.audioMuseCanSearch() }.getOrDefault(false)
        MixCatalog.load(c, muse) { val picked = it.highlights(); if (picked != mixtapes) mixtapes = picked }
    }

    // Offline there is one thing to show: what is on this phone. Everything else needs the server.
    if (offline) {
        LazyColumn(contentPadding = PaddingValues(vertical = Spacing.l), verticalArrangement = Arrangement.spacedBy(Spacing.l)) {
            item { OfflineBanner(downloaded.size) { scope.launch { app.connectivity.check() } } }
            if (downloaded.isEmpty()) item {
                Column(Modifier.fillMaxWidth().padding(horizontal = Spacing.xl, vertical = Spacing.section), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("Nothing downloaded", style = MaterialTheme.typography.titleLarge.bold())
                    Text("Download albums or playlists while you are online to listen without a connection.",
                        style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center, modifier = Modifier.padding(top = Spacing.s))
                }
            }
            itemsIndexed(downloaded) { index, song ->
                SongRow(song, client?.imageUrl(song.imageItemId, 160), playback.current?.id == song.id,
                    onClick = { app.player.playLike(song) }, actions = actions)
            }
        }
        return
    }

    LoadContent(load) { data ->
        LazyColumn(contentPadding = PaddingValues(bottom = Spacing.section), verticalArrangement = Arrangement.spacedBy(Spacing.xl)) {
            item {
                Row(Modifier.fillMaxWidth().padding(start = Spacing.l, end = Spacing.s, top = Spacing.l),
                    verticalAlignment = Alignment.CenterVertically) {
                    Text("Home", style = MaterialTheme.typography.displaySmall.bold(), modifier = Modifier.weight(1f))
                    var devices by remember { mutableStateOf(false) }
                    IconButton(onClick = { devices = true }) {
                        Icon(if (playback.isRemote) Icons.Rounded.Speaker else Icons.Rounded.Devices, "Devices",
                            tint = if (playback.isRemote) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface)
                    }
                    if (devices) DevicesSheet { devices = false }
                    IconButton(onClick = { navigator.open(SettingsRoute) }) {
                        Icon(Icons.Rounded.Settings, "Settings")
                    }
                }
            }
            if (offline) {
                item { OfflineBanner(downloaded.size) { scope.launch { app.connectivity.check() } } }
                if (downloaded.isNotEmpty()) item {
                    Column {
                        SectionTitle("Downloaded")
                        downloaded.take(12).forEachIndexed { index, song ->
                            SongRow(song, client?.imageUrl(song.imageItemId, 160), playback.current?.id == song.id,
                                onClick = { app.player.playLike(song) }, actions = actions)
                        }
                    }
                }
            }
            if (highlights.isNotEmpty()) item { HighlightsRow(highlights) }
            else if (!highlightsSettled || data.added.isEmpty()) item {
                // A ghost card in the hero's shape, the next one peeking in.
                androidx.compose.foundation.lazy.LazyRow(
                    contentPadding = PaddingValues(horizontal = Spacing.l, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(Spacing.m),
                    userScrollEnabled = false) {
                    items(2) {
                        Ghost(Modifier.widthIn(max = 720.dp).fillParentMaxWidth(0.88f).aspectRatio(16f / 9f).clip(RoundedCornerShape(16.dp)))
                    }
                }
            }
            else if (data.added.isNotEmpty()) {
                item {
                    // Until the highlights are ready: the newest albums, big, the next one peeking in.
                    androidx.compose.foundation.lazy.LazyRow(
                        contentPadding = PaddingValues(horizontal = Spacing.l, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
                        items(data.added.take(3)) { album ->
                            Box(Modifier.widthIn(max = 720.dp).fillParentMaxWidth(0.88f).aspectRatio(16f / 9f).clip(RoundedCornerShape(16.dp))
                                .focusHighlight(RoundedCornerShape(16.dp))
                                .clickable { navigator.open(AlbumRoute(album.id, album.name)) }) {
                                Artwork(client?.imageUrl(album.id, 800), Modifier.fillMaxSize(), RoundedCornerShape(16.dp))
                                Box(Modifier.fillMaxSize().background(
                                    Brush.verticalGradient(0.5f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.78f))))
                                Column(Modifier.align(Alignment.BottomStart).padding(Spacing.l)) {
                                    Text("Just added", style = MaterialTheme.typography.labelMedium, color = Color.White.copy(alpha = 0.8f))
                                    Text(album.name, style = MaterialTheme.typography.titleLarge, color = Color.White,
                                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    Text(album.albumArtistLine, style = MaterialTheme.typography.bodyMedium, color = Color.White.copy(alpha = 0.85f),
                                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                                }
                            }
                        }
                    }
                }
            }
            if (data.played.isNotEmpty()) {
                item {
                    // Columns of four songs that scroll sideways, the next column peeking in.
                    Column(verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                        SectionTitle("Recently Played")
                        androidx.compose.foundation.lazy.LazyRow(
                            contentPadding = PaddingValues(horizontal = Spacing.l), horizontalArrangement = Arrangement.spacedBy(Spacing.l)) {
                            items(data.played.chunked(4).size) { column ->
                                Column(Modifier.widthIn(max = 560.dp).fillParentMaxWidth(0.88f)) {
                                    data.played.chunked(4)[column].forEachIndexed { row, song ->
                                        SongRow(song, client?.imageUrl(song.imageItemId, 160), playback.current?.id == song.id,
                                            onClick = { app.player.playLike(song) }, actions = actions)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            item {
                Shelf("Stations", listOf("mix", "favorites"), key = { it }) { which ->
                    val mix = which == "mix"
                    Column(Modifier.width(150.dp).focusHighlight(RoundedCornerShape(12.dp)).clickable {
                        app.player.play(if (mix) "Your Mix" else "Favorites Mix", radio = true) { c ->
                            val seed = (if (mix) c.randomSongs(1).firstOrNull() else c.favoriteSongs().randomOrNull()) ?: return@play emptyList()
                            listOf(seed) + c.instantMix(seed.id, 30).filter { it.id != seed.id }
                        }
                    }) {
                        Box(Modifier.fillMaxWidth().aspectRatio(1f).clip(RoundedCornerShape(12.dp)).background(Brush.linearGradient(
                            if (mix) listOf(Color(0xFFE8742C), Color(0xFFA8401A)) else listOf(Color(0xFFC2455E), Color(0xFF6E2A6E)))),
                            contentAlignment = Alignment.Center) {
                            Icon(if (mix) Icons.Rounded.Sensors else Icons.Rounded.Favorite, null, tint = Color.White.copy(alpha = 0.9f),
                                modifier = Modifier.size(48.dp))
                        }
                        Text(if (mix) "Your Mix" else "Favorites Mix", style = MaterialTheme.typography.titleSmall, maxLines = 1,
                            modifier = Modifier.padding(top = Spacing.s))
                        Text(if (mix) "Your whole library" else "Songs you love", style = MaterialTheme.typography.bodySmall, maxLines = 1,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
            if (mixtapes.isNotEmpty()) {
                item { Shelf("Mixtapes", mixtapes, key = { it.id }) { MixtapeTile(it) } }
            }
            if (data.added.isNotEmpty()) {
                item {
                    Shelf("Recently Added", data.added, key = { it.id }) { album ->
                        Tile(album.name, album.albumArtistLine, client?.imageUrl(album.id), 150.dp,
                            onClick = { navigator.open(AlbumRoute(album.id, album.name)) }, jewelCase = true)
                    }
                }
            }
            if (data.favorites.isNotEmpty()) {
                item {
                    Shelf("Favorite Albums", data.favorites, key = { it.id }) { album ->
                        Tile(album.name, album.albumArtistLine, client?.imageUrl(album.id), 150.dp,
                            onClick = { navigator.open(AlbumRoute(album.id, album.name)) }, jewelCase = true)
                    }
                }
            }
        }
    }
}
