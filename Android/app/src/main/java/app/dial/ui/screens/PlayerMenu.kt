package app.dial.ui.screens

import android.widget.Toast
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.QueueMusic
import androidx.compose.material.icons.rounded.Album
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.Equalizer
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.MoreHoriz
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
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.platform.LocalContext
import androidx.media3.common.Player
import app.dial.data.Item
import app.dial.playback.PlaybackState
import app.dial.ui.LocalApp
import app.dial.ui.LocalNavigator
import app.dial.ui.SettingsRoute
import app.dial.ui.songActions
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date

/**
 * The player's "..." menu, with the same choices as on iPhone and Mac: play next, play last, radio, hide, playlist, song info,
 * favorite, download, delete from the server, go to the album or artist, the equalizer and the sleep timer.
 */
@Composable
fun PlayerMoreButton(state: PlaybackState) {
    val app = LocalApp.current
    val navigator = LocalNavigator.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val client = client()
    val actions = songActions()
    val track: Item? = state.current
    var open by remember { mutableStateOf(false) }
    var sleepOpen by remember { mutableStateOf(false) }
    var info by remember { mutableStateOf<Item?>(null) }
    var confirmDelete by remember { mutableStateOf(false) }
    var canDelete by remember { mutableStateOf(false) }
    LaunchedEffect(client) { canDelete = runCatching { client?.canDelete() }.getOrNull() == true }
    val records by app.downloads.records.collectAsState()

    Box {
        IconButton(onClick = { open = true }) {
            Icon(Icons.Rounded.MoreHoriz, "More", tint = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.75f))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            if (track != null) {
                DropdownMenuItem(text = { Text("Play Next") }, leadingIcon = { Icon(Icons.AutoMirrored.Rounded.QueueMusic, null) },
                    onClick = { open = false; actions.onPlayNext(track) })
                DropdownMenuItem(text = { Text("Play Last") }, leadingIcon = { Icon(Icons.Rounded.PlaylistAdd, null) },
                    onClick = { open = false; actions.onAddToQueue(track) })
                DropdownMenuItem(text = { Text("Start Radio") }, leadingIcon = { Icon(Icons.Rounded.Sensors, null) },
                    onClick = { open = false; actions.onRadio(track) })
                val hidden = actions.isHidden(track)
                DropdownMenuItem(text = { Text(if (hidden) "Allow This Song" else "Don’t Play This Song") },
                    leadingIcon = { Icon(if (hidden) Icons.Rounded.Visibility else Icons.Rounded.VisibilityOff, null) },
                    onClick = { open = false; actions.onHide(track) })
                HorizontalDivider()
                DropdownMenuItem(text = { Text("Add to Playlist…") }, leadingIcon = { Icon(Icons.Rounded.PlaylistAdd, null) },
                    onClick = { open = false; actions.onAddToPlaylist(track) })
                DropdownMenuItem(text = { Text("Song Info") }, leadingIcon = { Icon(Icons.Rounded.Info, null) },
                    onClick = { open = false; info = track })
                val favorite = actions.isFavorite(track)
                DropdownMenuItem(text = { Text(if (favorite) "Remove from Favorites" else "Favorite") },
                    leadingIcon = { Icon(if (favorite) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder, null) },
                    onClick = { open = false; actions.onFavorite(track) })
                if (track.id in records) {
                    DropdownMenuItem(text = { Text("Remove Download") }, leadingIcon = { Icon(Icons.Rounded.Delete, null) },
                        onClick = { open = false; app.downloads.delete(track.id) })
                } else {
                    DropdownMenuItem(text = { Text("Download") }, leadingIcon = { Icon(Icons.Rounded.Download, null) },
                        onClick = { open = false; actions.onDownload(track) })
                }
                if (canDelete) {
                    DropdownMenuItem(text = { Text("Delete from Server…", color = MaterialTheme.colorScheme.error) },
                        leadingIcon = { Icon(Icons.Rounded.Delete, null, tint = MaterialTheme.colorScheme.error) },
                        onClick = { open = false; confirmDelete = true })
                }
                HorizontalDivider()
                if (track.albumId != null) {
                    DropdownMenuItem(text = { Text("Go to Album") }, leadingIcon = { Icon(Icons.Rounded.Album, null) },
                        onClick = { open = false; actions.onAlbum(track) })
                }
                actions.credits(track).forEach { name ->
                    DropdownMenuItem(text = { Text("Go to $name") }, leadingIcon = { Icon(Icons.Rounded.Person, null) },
                        onClick = { open = false; actions.onArtist(name) })
                }
                HorizontalDivider()
            }
            DropdownMenuItem(text = { Text(if (state.shuffle) "Shuffle: On" else "Shuffle: Off") },
                leadingIcon = { Icon(Icons.Rounded.Shuffle, null) }, onClick = { open = false; app.player.toggleShuffle() })
            DropdownMenuItem(
                text = { Text(when (state.repeat) { Player.REPEAT_MODE_ONE -> "Repeat: One"; Player.REPEAT_MODE_ALL -> "Repeat: All"; else -> "Repeat: Off" }) },
                leadingIcon = { Icon(if (state.repeat == Player.REPEAT_MODE_ONE) Icons.Rounded.RepeatOne else Icons.Rounded.Repeat, null) },
                onClick = { open = false; app.player.cycleRepeat() })
            DropdownMenuItem(text = { Text(if (state.radio) "Radio: On" else "Radio: Off") },
                leadingIcon = { Icon(Icons.Rounded.Radio, null) }, onClick = { open = false; app.player.toggleRadio() })
            DropdownMenuItem(text = { Text("Equalizer") }, leadingIcon = { Icon(Icons.Rounded.Equalizer, null) },
                onClick = { open = false; navigator.open(SettingsRoute) })
            val sleepLabel = when {
                state.sleepEndsAt != null -> "Sleep Timer: stops at " + DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(state.sleepEndsAt))
                state.sleepAtEndOfSong -> "Sleep Timer: end of song"
                else -> "Sleep Timer"
            }
            DropdownMenuItem(text = { Text(sleepLabel) }, leadingIcon = { Icon(Icons.Rounded.Bedtime, null) },
                onClick = { open = false; sleepOpen = true })
        }
        DropdownMenu(expanded = sleepOpen, onDismissRequest = { sleepOpen = false }) {
            listOf(15 to "15 Minutes", 30 to "30 Minutes", 45 to "45 Minutes", 60 to "1 Hour").forEach { (minutes, label) ->
                DropdownMenuItem(text = { Text(label) }, onClick = { sleepOpen = false; app.player.setSleepTimer(minutes) })
            }
            if (!state.isLive) DropdownMenuItem(text = { Text("End of Song") }, onClick = { sleepOpen = false; app.player.sleepAtEndOfSong() })
            if (state.sleepEndsAt != null || state.sleepAtEndOfSong) {
                HorizontalDivider()
                DropdownMenuItem(text = { Text("Turn Off Timer", color = MaterialTheme.colorScheme.error) },
                    onClick = { sleepOpen = false; app.player.cancelSleepTimer() })
            }
        }
    }

    info?.let { song -> SongInfoDialog(song) { info = null } }
    if (confirmDelete && track != null) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete “${track.name}” from your server?") },
            text = { Text("This deletes the song from your Jellyfin server, file included. It can’t be undone.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmDelete = false
                    scope.launch {
                        val ok = runCatching { client?.delete("Items/${track.id}") }.isSuccess
                        Toast.makeText(context, if (ok) "Deleted from your server" else "Couldn’t delete “${track.name}”", Toast.LENGTH_SHORT).show()
                    }
                }) { Text("Delete", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
        )
    }
}

/** What the file is: format, quality, size and where the song belongs. */
@Composable
private fun SongInfoDialog(song: Item, onDismiss: () -> Unit) {
    val client = client()
    var details by remember(song.id) { mutableStateOf<Item?>(null) }
    LaunchedEffect(song.id) { details = runCatching { client?.details(song.id) }.getOrNull() }
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
