package app.dial.tv

import android.content.Context
import android.widget.Toast
import androidx.compose.foundation.layout.Column
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material3.AlertDialog
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
import app.dial.data.Item
import app.dial.data.ArtistNames
import app.dial.data.DialPlugin
import app.dial.data.WishItem
import app.dial.data.Wishlist
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Whether this account may delete files from the server (checked once when the screen shows). */
@Composable
fun rememberCanDelete(): Boolean {
    val client = tvClient()
    var can by remember { mutableStateOf(false) }
    LaunchedEffect(client) { can = withContext(Dispatchers.IO) { runCatching { client?.canDelete() }.getOrNull() == true } }
    return can
}

/** Runs [delete] off the main thread: [done] when it worked, a short message on screen when it did not. */
fun runDelete(scope: CoroutineScope, context: Context, failure: String, delete: suspend () -> Unit, done: () -> Unit) {
    scope.launch {
        runCatching { withContext(Dispatchers.IO) { delete() } }
            .onSuccess { done() }
            .onFailure { Toast.makeText(context, "$failure: ${it.message}", Toast.LENGTH_LONG).show() }
    }
}

/** "Are you sure?" with the destructive choice in red and Cancel to back out. */
@Composable
fun TvConfirmDialog(title: String, detail: String, action: String, onConfirm: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Text(detail) },
        confirmButton = { TextButton(onClick = onConfirm) { Text(action, color = MaterialTheme.colorScheme.error) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/** A remote-friendly button that asks first, then runs [onDelete] and calls [onDone] when it worked. */
@Composable
fun TvDeleteButton(label: String, question: String, detail: String, onDelete: suspend () -> Unit, onDone: () -> Unit) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var asking by remember { mutableStateOf(false) }
    TvButton(label, Icons.Rounded.Delete, primary = false) { asking = true }
    if (asking) TvConfirmDialog(question, detail, "Delete", onConfirm = {
        asking = false
        runDelete(scope, context, "Couldn’t delete", onDelete, onDone)
    }, onDismiss = { asking = false })
}

/**
 * What you can do to one song, opened by holding Select on it: remove it from the playlist it is in, remove its download,
 * or delete it from the server (only when the server allows it). [onGone] is called when the song has left the list.
 */
@Composable
fun TvSongMenu(song: Item, playlistId: String?, onGone: () -> Unit, onDismiss: () -> Unit) {
    val app = LocalTvApp.current
    val client = tvClient()
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val downloads by app.downloads.records.collectAsState()
    val canDelete = rememberCanDelete()
    val hasPlugin by DialPlugin.present.collectAsState()
    val wishlist by Wishlist.items.collectAsState()
    var asking by remember { mutableStateOf(false) }
    val entry = song.playlistItemId
    val wish = WishItem.song(wishArtistOf(song), song.name, song.album)
    val wished = wishlist.any { it.id == wish.id }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(song.name, maxLines = 2) },
        text = {
            Column {
                if (hasPlugin) TextButton(onClick = {
                    scope.launch { Wishlist.toggle(wish, client) }
                    onDismiss()
                }) { Text(if (wished) "Remove from Wishlist" else "Add to Wishlist") }
                if (playlistId != null && entry != null) TextButton(onClick = {
                    runDelete(scope, context, "Couldn’t remove the song", { client?.removeFromPlaylist(playlistId, listOf(entry)) }, onGone)
                }) { Text("Remove from Playlist") }
                if (downloads.containsKey(song.id)) TextButton(onClick = { app.downloads.delete(song.id); onDismiss() }) { Text("Remove Download") }
                if (canDelete) TextButton(onClick = { asking = true }) { Text("Delete from Server…", color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Close") } },
    )
    if (asking) TvConfirmDialog(
        "Delete “${song.name}” from your server?",
        "This deletes the song from your Jellyfin server, file included. It can’t be undone.",
        "Delete",
        onConfirm = {
            asking = false
            runDelete(scope, context, "Couldn’t delete “${song.name}”", { client?.delete("Items/${song.id}") }, onGone)
        },
        onDismiss = { asking = false },
    )
}
