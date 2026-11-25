package app.dial.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.QueueMusic
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import app.dial.data.Item
import app.dial.data.JellyfinClient
import app.dial.ui.components.SongRow
import app.dial.ui.LocalApp
import app.dial.ui.components.Spacing
import app.dial.ui.songActions
import kotlinx.coroutines.launch

/** A playlist: its songs, and the things you do to a playlist of your own: rename, delete, take songs out, move them. */
@Composable
fun PlaylistScreen(id: String, name: String) {
    val app = LocalApp.current
    val client = client()
    val playback by app.player.state.collectAsState()
    val back = LocalBack.current
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    // Bumped after every change, so the list is read again from the server.
    var version by remember { mutableStateOf(0) }
    var title by remember(id) { mutableStateOf(name) }
    var renaming by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf(false) }
    val load = rememberLoad(id to version) { it.playlistTracks(id) }
    val baseActions = songActions()

    fun tell(message: String) = android.widget.Toast.makeText(context, message, android.widget.Toast.LENGTH_SHORT).show()
    fun change(failure: String, block: suspend (JellyfinClient) -> Unit) {
        val c = app.session.client.value ?: return
        scope.launch {
            runCatching { block(c) }.onFailure { tell("$failure: ${it.message}") }
            version++
        }
    }

    Column(Modifier.fillMaxSize()) {
        PlaylistTopBar(title, back, onRename = { renaming = true }, onDelete = { deleting = true })
        LoadContent(load) { tracks ->
            fun move(song: Item, by: Int) {
                val index = tracks.indexOfFirst { it.playlistItemId == song.playlistItemId }
                val entry = song.playlistItemId
                if (index < 0 || entry == null || index + by !in tracks.indices) return
                change("Couldn\u2019t move the song") { it.movePlaylistItem(id, entry, index + by) }
            }
            val actions = baseActions.copy(
                onRemoveFromPlaylist = { song ->
                    song.playlistItemId?.let { entry -> change("Couldn\u2019t remove the song") { it.removeFromPlaylist(id, listOf(entry)) } }
                },
                onMoveUp = { move(it, -1) },
                onMoveDown = { move(it, 1) },
            )
            LazyColumn(contentPadding = PaddingValues(bottom = Spacing.section)) {
                item {
                    DetailHeader(client?.imageUrl(id, 800), RoundedCornerShape(28.dp), title, "${tracks.size} songs", null, null,
                        onPlay = { app.player.play(tracks) }, onShuffle = { app.player.play(tracks, shuffle = true) },
                        placeholder = Icons.AutoMirrored.Rounded.QueueMusic)
                    Spacer(Modifier.size(Spacing.l))
                }
                itemsIndexed(tracks, key = { i, t -> t.playlistItemId ?: "${t.id}-$i" }) { index, track ->
                    SongRow(track, client?.imageUrl(track.imageItemId, 160), playback.current?.id == track.id,
                        onClick = { app.player.play(tracks, index) }, actions = actions)
                }
            }
        }
    }

    if (renaming) {
        var text by remember { mutableStateOf(title) }
        AlertDialog(
            onDismissRequest = { renaming = false },
            title = { Text("Rename Playlist") },
            text = { OutlinedTextField(text, { text = it }, singleLine = true) },
            confirmButton = {
                TextButton(onClick = {
                    val trimmed = text.trim()
                    renaming = false
                    if (trimmed.isNotEmpty()) {
                        val c = app.session.client.value ?: return@TextButton
                        scope.launch {
                            runCatching { c.renamePlaylist(id, trimmed) }
                                .onSuccess { title = trimmed; app.library.refresh() }
                                .onFailure { tell("Couldn\u2019t rename the playlist: ${it.message}") }
                        }
                    }
                }) { Text("Rename") }
            },
            dismissButton = { TextButton(onClick = { renaming = false }) { Text("Cancel") } },
        )
    }
    if (deleting) {
        AlertDialog(
            onDismissRequest = { deleting = false },
            title = { Text("Delete this playlist?") },
            text = { Text("The songs stay in your library.") },
            confirmButton = {
                TextButton(onClick = {
                    deleting = false
                    val c = app.session.client.value ?: return@TextButton
                    scope.launch {
                        runCatching { c.deletePlaylist(id) }
                            .onSuccess { app.library.refresh(); back() }
                            .onFailure { tell("Couldn\u2019t delete the playlist: ${it.message}") }
                    }
                }) { Text("Delete") }
            },
            dismissButton = { TextButton(onClick = { deleting = false }) { Text("Cancel") } },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PlaylistTopBar(title: String, back: () -> Unit, onRename: () -> Unit, onDelete: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    TopAppBar(
        title = { Text("") },
        navigationIcon = { IconButton(onClick = back) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, "Back") } },
        actions = {
            Box {
                IconButton(onClick = { menu = true }) { Icon(Icons.Rounded.MoreVert, "More") }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text("Rename\u2026") }, onClick = { menu = false; onRename() })
                    DropdownMenuItem(text = { Text("Delete Playlist") }, onClick = { menu = false; onDelete() })
                }
            }
        },
    )
}

/** Picks a playlist to add a song to, or makes a new one with it. */
@Composable
fun AddToPlaylistDialog(song: Item, onDismiss: () -> Unit) {
    val app = LocalApp.current
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var playlists by remember { mutableStateOf<List<Item>?>(null) }
    var naming by remember { mutableStateOf(false) }
    var newName by remember { mutableStateOf("") }
    LaunchedEffect(Unit) { playlists = runCatching { app.session.client.value?.playlists() }.getOrNull() ?: emptyList() }

    fun tell(message: String) = android.widget.Toast.makeText(context, message, android.widget.Toast.LENGTH_SHORT).show()
    fun add(block: suspend (JellyfinClient) -> Unit, done: String) {
        val c = app.session.client.value ?: return
        scope.launch {
            runCatching { block(c) }.onSuccess { tell(done) }.onFailure { tell("Couldn\u2019t add the song: ${it.message}") }
            app.library.refresh()
        }
        onDismiss()
    }

    if (naming) {
        AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text("New Playlist") },
            text = { OutlinedTextField(newName, { newName = it }, singleLine = true, placeholder = { Text("Name") }) },
            confirmButton = {
                TextButton(onClick = {
                    val trimmed = newName.trim()
                    if (trimmed.isNotEmpty()) add({ it.createPlaylist(trimmed, listOf(song.id)) }, "Added to $trimmed")
                }) { Text("Create") }
            },
            dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
        )
        return
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Add to Playlist") },
        text = {
            LazyColumn {
                item {
                    ListItem(headlineContent = { Text("New Playlist\u2026") }, leadingContent = { Icon(Icons.Rounded.Add, null) },
                        modifier = Modifier.fillMaxWidth().clickable { naming = true })
                }
                itemsIndexed(playlists ?: emptyList(), key = { i, p -> "${p.id}#$i" }) { _, playlist ->
                    ListItem(headlineContent = { Text(playlist.name, maxLines = 1) },
                        modifier = Modifier.fillMaxWidth().clickable { add({ it.addToPlaylist(playlist.id, listOf(song.id)) }, "Added to ${playlist.name}") })
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
