package app.dial.tv

import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.QueueMusic
import androidx.compose.material.icons.rounded.Album
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.PlaylistAdd
import androidx.compose.material.icons.rounded.Radio
import androidx.compose.material.icons.rounded.Repeat
import androidx.compose.material.icons.rounded.RepeatOne
import androidx.compose.material.icons.rounded.Sensors
import androidx.compose.material.icons.rounded.Shuffle
import androidx.compose.material.icons.rounded.Visibility
import androidx.compose.material.icons.rounded.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.media3.common.Player
import app.dial.data.Item
import app.dial.data.formatTime
import app.dial.data.DialPlugin
import app.dial.data.WishItem
import app.dial.data.Wishlist
import app.dial.playback.PlaybackState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.DateFormat
import java.util.Date

private enum class MenuPage { Main, Sleep, Playlists, NewPlaylist }

/**
 * The player's "more" panel on a TV: the same choices as the phone's "..." menu. Opens on the right, like the queue.
 * [track] is null for a live station, which has no song to act on.
 */
@Composable
fun TvPlayerMenu(track: Item?, state: PlaybackState, onClose: () -> Unit) {
    val app = LocalTvApp.current
    val nav = LocalTvNav.current
    val client = tvClient()
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val favorites by app.library.favorites.collectAsState()
    val hidden by app.library.hidden.collectAsState()
    val downloads by app.downloads.records.collectAsState()
    val hasPlugin by DialPlugin.present.collectAsState()
    val wishlist by Wishlist.items.collectAsState()
    val canDelete = rememberCanDelete()
    var page by remember { mutableStateOf(MenuPage.Main) }
    var info by remember { mutableStateOf<Item?>(null) }
    var confirmDelete by remember { mutableStateOf(false) }
    var playlists by remember { mutableStateOf<List<Item>?>(null) }
    var newName by remember { mutableStateOf("") }
    // The first choice of the main page is selected when the panel opens, so the remote works straight away.
    val first = remember { androidx.compose.ui.focus.FocusRequester() }
    LaunchedEffect(Unit) { kotlinx.coroutines.delay(150); runCatching { first.requestFocus() } }

    // Back leaves a sub-page first; from the main page it closes the panel (the player handles that).
    BackHandler(enabled = page != MenuPage.Main) { page = MenuPage.Main }
    LaunchedEffect(page) {
        if (page == MenuPage.Playlists && playlists == null) {
            playlists = withContext(Dispatchers.IO) { runCatching { client?.playlists() }.getOrNull() ?: emptyList() }
        }
    }

    fun tell(message: String) = Toast.makeText(context, message, Toast.LENGTH_SHORT).show()

    Column(Modifier.fillMaxHeight().width(420.dp).background(MaterialTheme.colorScheme.surface.copy(alpha = 0.96f)).padding(20.dp)) {
        Text(when (page) {
            MenuPage.Main -> "More"
            MenuPage.Sleep -> "Sleep Timer"
            MenuPage.Playlists -> "Add to Playlist"
            MenuPage.NewPlaylist -> "New Playlist"
        }, style = MaterialTheme.typography.headlineMedium, modifier = Modifier.padding(bottom = 12.dp))

        when (page) {
            MenuPage.Main -> LazyColumn(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                if (track != null) {
                    item { MenuRow(Icons.AutoMirrored.Rounded.QueueMusic, "Play Next", focus = first) { app.player.playNext(listOf(track)); onClose() } }
                    item { MenuRow(Icons.Rounded.PlaylistAdd, "Play Last") { app.player.addToQueue(listOf(track)); onClose() } }
                    item { MenuRow(Icons.Rounded.Sensors, "Start Radio") { app.player.startRadio(track); onClose() } }
                    val isHidden = track.id in hidden
                    item { MenuRow(if (isHidden) Icons.Rounded.Visibility else Icons.Rounded.VisibilityOff, if (isHidden) "Allow This Song" else "Don’t Play This Song") {
                        app.library.setHidden(track.id, !isHidden); onClose()
                    } }
                    item { MenuRow(Icons.Rounded.PlaylistAdd, "Add to Playlist…") { page = MenuPage.Playlists } }
                    item { MenuRow(Icons.Rounded.Info, "Song Info") { info = track } }
                    if (hasPlugin) {
                        val wish = WishItem.song(wishArtistOf(track), track.name, track.album)
                        val wished = wishlist.any { it.id == wish.id }
                        item { MenuRow(if (wished) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder,
                            if (wished) "Remove from Wishlist" else "Add to Wishlist") {
                            scope.launch { Wishlist.toggle(wish, client) }; onClose()
                        } }
                    }
                    val isFavorite = track.id in favorites
                    item { MenuRow(if (isFavorite) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder, if (isFavorite) "Remove from Favorites" else "Favorite") {
                        app.library.toggleFavorite(track); onClose()
                    } }
                    if (track.id in downloads) {
                        item { MenuRow(Icons.Rounded.Delete, "Remove Download") { app.downloads.delete(track.id); onClose() } }
                    } else {
                        item { MenuRow(Icons.Rounded.Download, "Download") { client?.let { app.downloads.download(listOf(track), it) }; onClose() } }
                    }
                    if (canDelete) {
                        item { MenuRow(Icons.Rounded.Delete, "Delete from Server…", danger = true) { confirmDelete = true } }
                    }
                    track.albumId?.let { albumId ->
                        item { MenuRow(Icons.Rounded.Album, "Go to Album") { nav.open(TvRoute.Album(albumId, track.album ?: "")); onClose() } }
                    }
                    // Only artists in your library have a page on the TV; featured artists have none here.
                    app.credits.credits(track).forEach { name ->
                        app.credits.libraryArtist(name)?.let { artist ->
                            item { MenuRow(Icons.Rounded.Person, "Go to $name") { nav.open(TvRoute.Artist(artist.id, artist.name)); onClose() } }
                        }
                    }
                }
                item { MenuRow(Icons.Rounded.Shuffle, if (state.shuffle) "Shuffle: On" else "Shuffle: Off", focus = if (track == null) first else null) { app.player.toggleShuffle(); onClose() } }
                item {
                    MenuRow(if (state.repeat == Player.REPEAT_MODE_ONE) Icons.Rounded.RepeatOne else Icons.Rounded.Repeat,
                        when (state.repeat) { Player.REPEAT_MODE_ONE -> "Repeat: One"; Player.REPEAT_MODE_ALL -> "Repeat: All"; else -> "Repeat: Off" }) {
                        app.player.cycleRepeat(); onClose()
                    }
                }
                item { MenuRow(Icons.Rounded.Radio, if (state.radio) "Radio: On" else "Radio: Off") { app.player.toggleRadio(); onClose() } }
                item {
                    val label = when {
                        state.sleepEndsAt != null -> "Sleep Timer: stops at " + DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(state.sleepEndsAt))
                        state.sleepAtEndOfSong -> "Sleep Timer: end of song"
                        else -> "Sleep Timer"
                    }
                    MenuRow(Icons.Rounded.Bedtime, label) { page = MenuPage.Sleep }
                }
            }

            MenuPage.Sleep -> LazyColumn(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                item { MenuRow(Icons.AutoMirrored.Rounded.ArrowBack, "Back") { page = MenuPage.Main } }
                items(listOf(15 to "15 Minutes", 30 to "30 Minutes", 45 to "45 Minutes", 60 to "1 Hour")) { (minutes, label) ->
                    MenuRow(Icons.Rounded.Bedtime, label) { app.player.setSleepTimer(minutes); onClose() }
                }
                if (!state.isLive) item { MenuRow(Icons.Rounded.Bedtime, "End of Song") { app.player.sleepAtEndOfSong(); onClose() } }
                if (state.sleepEndsAt != null || state.sleepAtEndOfSong) {
                    item { MenuRow(Icons.Rounded.Bedtime, "Turn Off Timer", danger = true) { app.player.cancelSleepTimer(); onClose() } }
                }
            }

            MenuPage.Playlists -> LazyColumn(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                item { MenuRow(Icons.AutoMirrored.Rounded.ArrowBack, "Back") { page = MenuPage.Main } }
                item { MenuRow(Icons.Rounded.PlaylistAdd, "New Playlist…") { newName = ""; page = MenuPage.NewPlaylist } }
                val list = playlists
                if (list == null) {
                    item { Text("Loading…", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(12.dp)) }
                }
                items(list ?: emptyList()) { playlist ->
                    MenuRow(Icons.Rounded.PlaylistAdd, playlist.name) {
                        val id = track?.id ?: return@MenuRow
                        scope.launch {
                            runCatching { withContext(Dispatchers.IO) { client?.addToPlaylist(playlist.id, listOf(id)) } }
                                .onSuccess { tell("Added to ${playlist.name}") }
                                .onFailure { tell("Couldn’t add the song: ${it.message}") }
                        }
                        onClose()
                    }
                }
            }

            MenuPage.NewPlaylist -> Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                OutlinedTextField(newName, { newName = it }, singleLine = true, placeholder = { Text("Name") },
                    shape = RoundedCornerShape(Tv.radius), modifier = Modifier.fillMaxWidth())
                TvButton("Create", primary = true) {
                    val name = newName.trim()
                    val id = track?.id
                    if (name.isNotEmpty() && id != null) {
                        scope.launch {
                            runCatching { withContext(Dispatchers.IO) { client?.createPlaylist(name, listOf(id)) } }
                                .onSuccess { tell("Added to $name") }
                                .onFailure { tell("Couldn’t create the playlist: ${it.message}") }
                        }
                        onClose()
                    }
                }
                TvButton("Back", primary = false) { page = MenuPage.Playlists }
            }
        }
    }

    info?.let { song -> TvSongInfo(song) { info = null } }
    if (confirmDelete && track != null) {
        TvConfirmDialog(
            "Delete “${track.name}” from your server?",
            "This deletes the song from your Jellyfin server, file included. It can’t be undone.",
            "Delete",
            onConfirm = {
                confirmDelete = false
                runDelete(scope, context, "Couldn’t delete “${track.name}”", { client?.delete("Items/${track.id}") }, onClose)
            },
            onDismiss = { confirmDelete = false },
        )
    }
}

/** One choice in the panel: an icon and a label, outlined when focused. */
@Composable
private fun MenuRow(icon: ImageVector, label: String, danger: Boolean = false, focus: androidx.compose.ui.focus.FocusRequester? = null, onClick: () -> Unit) {
    val shape = RoundedCornerShape(Tv.radius)
    val tint = if (danger) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface
    val place = if (focus != null) Modifier.focusRequester(focus) else Modifier
    Row(place.fillMaxWidth().tvFocus(shape).clip(shape).clickable(onClick = onClick).padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(24.dp))
        Text(label, style = MaterialTheme.typography.bodyLarge, color = tint, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** What the file is: format, quality, size and where the song belongs. */
@Composable
private fun TvSongInfo(song: Item, onDismiss: () -> Unit) {
    val client = tvClient()
    var details by remember(song.id) { mutableStateOf<Item?>(null) }
    LaunchedEffect(song.id) { details = withContext(Dispatchers.IO) { runCatching { client?.details(song.id) }.getOrNull() } }
    val item = details ?: song
    val size = item.mediaSources?.firstOrNull()?.size
    val rows = listOfNotNull(
        "Title" to item.name,
        "Artist" to item.artistLine,
        item.album?.let { "Album" to it },
        item.productionYear?.let { "Year" to it.toString() },
        item.formatLabel?.let { "Format" to it },
        item.qualityLabel?.let { "Quality" to it },
        size?.let { "Size" to String.format("%.1f MB", it / 1_000_000.0) },
        "Length" to formatTime(item.durationMs),
    )
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Song Info") },
        text = {
            Column {
                rows.forEach { (label, value) ->
                    Text(label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(value, style = MaterialTheme.typography.bodyLarge)
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
    )
}
