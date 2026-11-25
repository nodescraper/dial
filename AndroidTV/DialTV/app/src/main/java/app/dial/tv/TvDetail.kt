package app.dial.tv

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Shuffle
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.dial.data.ArtistNames
import app.dial.data.DialPlugin
import app.dial.data.GenreNames
import app.dial.data.Item
import app.dial.data.MixCatalog
import app.dial.data.WishItem
import app.dial.data.Wishlist
import app.dial.data.formatTime
import coil3.compose.AsyncImage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** A button for the remote: a label and optionally an icon, with the accent outline when focused. */
@Composable
fun TvButton(label: String, icon: ImageVector? = null, primary: Boolean = true, onClick: () -> Unit) {
    val shape = RoundedCornerShape(Tv.radius)
    val bg = if (primary) Accent else MaterialTheme.colorScheme.surfaceVariant
    val fg = if (primary) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface
    Row(Modifier.tvFocus(shape).clip(shape).background(bg).clickable(onClick = onClick).padding(horizontal = 22.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (icon != null) Icon(icon, null, tint = fg, modifier = Modifier.size(24.dp))
        Text(label, style = MaterialTheme.typography.labelLarge, color = fg)
    }
}

/** A page of songs: the cover, title and buttons on the left; the songs as a list on the right. */
@Composable
private fun TvSongsPage(imageUrl: String?, title: String, subtitle: String?, detail: String?, songs: List<Item>?, numbered: Boolean,
                        playlistId: String? = null, actions: @Composable () -> Unit = {}) {
    val app = LocalTvApp.current
    val nav = LocalTvNav.current
    val playback by app.player.state.collectAsState()
    // Songs taken off here (from the playlist or the server) leave the list at once.
    var gone by remember(songs) { mutableStateOf(emptySet<String>()) }
    var menuSong by remember { mutableStateOf<Item?>(null) }
    val shown = songs?.filter { it.id !in gone }
    Row(Modifier.fillMaxSize().padding(horizontal = Tv.marginX), horizontalArrangement = Arrangement.spacedBy(32.dp)) {
        Column(Modifier.width(260.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            AsyncImage(imageUrl, null, Modifier.size(260.dp).clip(RoundedCornerShape(16.dp)), contentScale = ContentScale.Crop)
            Text(title, style = MaterialTheme.typography.headlineMedium, maxLines = 3, overflow = TextOverflow.Ellipsis)
            if (subtitle != null) Text(subtitle, style = MaterialTheme.typography.titleMedium, color = Accent, maxLines = 1)
            if (detail != null) Text(detail, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        LazyColumn(Modifier.weight(1f).fillMaxHeight(), contentPadding = PaddingValues(vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            // Play and Shuffle are the first thing in the list, so Down from the top bar lands on them and Down again reaches the songs.
            item {
                val ready = !shown.isNullOrEmpty()
                val first = remember { androidx.compose.ui.focus.FocusRequester() }
                LaunchedEffect(Unit) { runCatching { first.requestFocus() } }
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.padding(bottom = 8.dp)) {
                    Box(Modifier.focusRequester(first)) { TvButton("Play", Icons.Rounded.PlayArrow) { if (ready) { app.player.play(shown!!); nav.open(TvRoute.Player) } } }
                    TvButton("Shuffle", Icons.Rounded.Shuffle, primary = false) { if (ready) { app.player.play(shown!!, shuffle = true); nav.open(TvRoute.Player) } }
                    actions()
                }
            }
            itemsIndexed(shown ?: emptyList()) { index, song ->
                val shape = RoundedCornerShape(Tv.radius)
                Row(Modifier.fillMaxWidth().tvFocus(shape).clip(shape)
                    .combinedClickable(onClick = { app.player.play(shown!!, index); nav.open(TvRoute.Player) }, onLongClick = { menuSong = song })
                    .padding(horizontal = 14.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(if (playback.current?.id == song.id) "▶" else "${song.indexNumber ?: index + 1}", style = MaterialTheme.typography.labelLarge,
                        color = if (playback.current?.id == song.id) Accent else MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.width(36.dp))
                    Column(Modifier.weight(1f)) {
                        Text(song.name, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        if (!numbered) Text(song.artistLine, style = MaterialTheme.typography.labelMedium, maxLines = 1,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Text(formatTime(song.durationMs), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
    menuSong?.let { song ->
        TvSongMenu(song, playlistId, onGone = { gone = gone + song.id; menuSong = null }, onDismiss = { menuSong = null })
    }
}

@Composable
fun TvAlbum(id: String, name: String) {
    val client = tvClient()
    val nav = LocalTvNav.current
    val app = LocalTvApp.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    val data = rememberTvLoad(id) { it.details(id) to it.albumTracks(id) }
    val album = data?.first
    val genre = GenreNames.families(album?.genres ?: emptyList()).firstOrNull()
    val canDelete = rememberCanDelete()
    val hasPlugin by DialPlugin.present.collectAsState()
    val wishlist by Wishlist.items.collectAsState()
    TvSongsPage(client?.imageUrl(id, 600), album?.name?.ifEmpty { name } ?: name, album?.albumArtistLine,
        listOfNotNull(genre, album?.productionYear?.toString()).joinToString(" · ").uppercase().ifEmpty { null },
        data?.second, numbered = true, actions = {
            if (hasPlugin && album != null) {
                val title = album.name.ifEmpty { name }
                val wish = WishItem.album(album.albumArtistLine, title)
                val on = wishlist.any { it.id == wish.id }
                TvButton(if (on) "Wishlisted" else "Wishlist", primary = false) {
                    scope.launch { Wishlist.toggle(wish, client) }
                }
            }
            if (canDelete) TvDeleteButton("Delete Album", "Delete this album from your server?",
                "This deletes the album and all its songs from your Jellyfin server, files included. It can’t be undone.",
                onDelete = { client?.delete("Items/$id") }, onDone = { nav.back() })
        })
}

@Composable
fun TvPlaylist(id: String, name: String) {
    val client = tvClient()
    val nav = LocalTvNav.current
    val songs = rememberTvLoad(id) { it.playlistTracks(id) }
    TvSongsPage(client?.imageUrl(id, 600), name, "Playlist", songs?.let { "${it.size} songs" }, songs, numbered = false, playlistId = id, actions = {
        TvDeleteButton("Delete Playlist", "Delete this playlist?", "The songs stay in your library.",
            onDelete = { client?.deletePlaylist(id) }, onDone = { nav.back() })
    })
}

@Composable
fun TvMixtape(id: String) {
    val app = LocalTvApp.current
    val client = tvClient()
    val mixtape = remember(id) { MixCatalog.latest?.let { listOf(it.daily, it.decades, it.genres).flatten().firstOrNull { m -> m.id == id } } }
    var songs by remember(id) { mutableStateOf<List<Item>?>(null) }
    LaunchedEffect(id) {
        val c = app.session.client.value ?: return@LaunchedEffect
        val m = mixtape ?: return@LaunchedEffect
        songs = withContext(Dispatchers.IO) {
            // The daily mixes are fixed for the day; decades and genres are looked up now.
            if (m.tracks.isNotEmpty()) m.tracks.filter { !app.library.isHidden(it.id) }
            else {
                val muse = runCatching { c.audioMuseCanSearch() }.getOrDefault(false)
                MixCatalog.songs(m.recipe, c, muse) { app.library.isHidden(it) }
            }
        }
    }
    TvSongsPage(mixtape?.covers?.firstOrNull()?.let { client?.imageUrl(it, 600) }, mixtape?.title ?: "Mixtape", mixtape?.subtitle,
        songs?.let { "${it.size} songs from your library" } ?: "Picking songs…", songs, numbered = false)
}

@Composable
fun TvArtist(id: String, name: String) {
    val app = LocalTvApp.current
    val nav = LocalTvNav.current
    val client = tvClient()
    val data = rememberTvLoad(id) { it.artistAlbums(id) to it.artistTopSongs(id, 10) }
    LazyColumn(contentPadding = PaddingValues(bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(22.dp)) {
        item {
            Row(Modifier.padding(horizontal = Tv.marginX), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                AsyncImage(client?.imageUrl(id, 400), null, Modifier.size(160.dp).clip(CircleShape), contentScale = ContentScale.Crop)
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(ArtistNames.primary(name), style = MaterialTheme.typography.displayMedium)
                    TvButton("Start Radio", Icons.Rounded.PlayArrow) {
                        app.player.play("$name Radio", radio = true) { c ->
                            val own = c.artistSongs(id, 30).shuffled()
                            (own.take(2) + c.instantMix(id, 30) + own.drop(2)).distinctBy { it.id }
                        }
                        nav.open(TvRoute.Player)
                    }
                }
            }
        }
        item {
            val top = data?.second ?: emptyList()
            TvRow("Top Songs", top) { _, s ->
                CoverCard(s.name, s.album, client?.imageUrl(s.imageItemId, 280)) { app.player.playLike(s); nav.open(TvRoute.Player) }
            }
        }
        item {
            TvRow("Albums", data?.first ?: emptyList()) { _, a ->
                CoverCard(a.name, a.productionYear?.toString(), client?.imageUrl(a.id, 280)) { nav.open(TvRoute.Album(a.id, a.name)) }
            }
        }
    }
}
