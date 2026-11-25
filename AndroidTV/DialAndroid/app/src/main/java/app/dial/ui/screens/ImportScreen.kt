package app.dial.ui.screens

import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.PlaylistAdd
import androidx.compose.material3.Button
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.LocalContext
import app.dial.data.ImportedList
import app.dial.data.Item
import app.dial.data.LibraryMatcher
import app.dial.data.PlaylistFiles
import app.dial.ui.LocalApp
import app.dial.ui.components.SectionTitle
import app.dial.ui.components.SongRow
import app.dial.ui.components.Spacing
import app.dial.ui.songActions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Bring in playlists from Spotify (or a song list) and turn them into playlists of the songs you have. */
@Composable
fun ImportScreen() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var lists by remember { mutableStateOf<List<ImportedList>>(emptyList()) }
    var chosen by remember { mutableStateOf<ImportedList?>(null) }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris: List<Uri> ->
        scope.launch {
            val found = withContext(Dispatchers.IO) {
                uris.flatMap { uri ->
                    val name = context.contentResolver.query(uri, null, null, null, null)?.use { c ->
                        val index = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (c.moveToFirst() && index >= 0) c.getString(index) else null
                    } ?: "Playlist"
                    val text = context.contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() } ?: ""
                    PlaylistFiles.read(name, text)
                }
            }
            // Listening history comes in several files: combine them into one top list.
            val histories = found.mapNotNull { it.playCounts }
            val others = found.filter { it.playCounts == null }
            lists = if (histories.isEmpty()) others else {
                val combined = mutableMapOf<ImportedList.Song, Int>()
                histories.forEach { h -> h.forEach { (song, n) -> combined[song] = (combined[song] ?: 0) + n } }
                listOf(PlaylistFiles.topList(combined)) + others
            }
        }
    }

    chosen?.let { list ->
        androidx.activity.compose.BackHandler { chosen = null }
        ImportMatch(list)
        return
    }

    Column(Modifier.fillMaxSize()) {
        PageTopBar("Import Playlists")
        LazyColumn(contentPadding = PaddingValues(bottom = Spacing.section)) {
            item {
                Column(Modifier.padding(Spacing.l), verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
                    Text("Choose files from Spotify\u2019s data download, an Exportify CSV, or a text file with one \u201cArtist - Title\u201d per line. Dial finds those songs in your library and can save them as a playlist.",
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Button(onClick = { picker.launch(arrayOf("application/json", "text/*", "text/csv", "text/comma-separated-values")) }) {
                        Icon(Icons.Rounded.Folder, null); Spacer(Modifier.width(Spacing.xs)); Text("Choose Files")
                    }
                    Text("To get your Spotify data: spotify.com, Account, Privacy settings, request your data. Playlist1.json has your playlists, YourLibrary.json your liked songs, and the StreamingHistory files your most played songs.",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            if (lists.isNotEmpty()) item { SectionTitle("Found") }
            itemsIndexed(lists, key = { index, _ -> "list-$index" }) { _, list ->
                ListItem(headlineContent = { Text(list.name) },
                    supportingContent = { Text("${list.songs.size} songs, ${list.source}") },
                    modifier = Modifier.clickable { chosen = list })
            }
        }
    }
}

@Composable
private fun ImportMatch(list: ImportedList) {
    val app = LocalApp.current
    val client = client()
    val playback by app.player.state.collectAsState()
    val actions = songActions()
    val matched = remember { mutableStateListOf<Item>() }
    val missing = remember { mutableStateListOf<ImportedList.Song>() }
    var checked by remember { mutableIntStateOf(0) }
    var name by remember { mutableStateOf(list.name) }
    var saved by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val done = checked >= list.songs.size

    LaunchedEffect(list) {
        val c = client ?: return@LaunchedEffect
        list.songs.chunked(4).forEach { batch ->
            val results = coroutineScope { batch.map { async { it to LibraryMatcher.find(it, c) } }.awaitAll() }
            results.forEach { (song, item) ->
                if (item != null) { if (matched.none { it.id == item.id }) matched += item } else missing += song
            }
            checked += batch.size
        }
    }

    Column(Modifier.fillMaxSize()) {
        PageTopBar(list.name)
        LazyColumn(contentPadding = PaddingValues(bottom = Spacing.section)) {
            item {
                Column(Modifier.padding(Spacing.l), verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
                    LinearProgressIndicator(progress = { checked.toFloat() / list.songs.size.coerceAtLeast(1) }, Modifier.fillMaxWidth())
                    Text(if (done) "Found ${matched.size} of ${list.songs.size} songs in your library."
                         else "Looking through your library\u2026 $checked of ${list.songs.size}",
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                    if (done && matched.isNotEmpty()) {
                        OutlinedTextField(name, { name = it }, label = { Text("Playlist name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                        Row(horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
                            Button(onClick = {
                                scope.launch { runCatching { client?.createPlaylist(name.trim(), matched.map { it.id }) }.onSuccess { saved = true } }
                            }, enabled = !saved && name.isNotBlank()) {
                                Icon(Icons.Rounded.PlaylistAdd, null); Spacer(Modifier.width(Spacing.xs))
                                Text(if (saved) "Saved to Your Playlists" else "Save as Playlist")
                            }
                            FilledTonalButton(onClick = { app.player.play(matched.toList()) }) {
                                Icon(Icons.Rounded.PlayArrow, null); Spacer(Modifier.width(Spacing.xs)); Text("Play")
                            }
                        }
                    }
                }
            }
            if (matched.isNotEmpty()) item { SectionTitle("In Your Library") }
            itemsIndexed(matched, key = { _, s -> s.id }) { index, song ->
                SongRow(song, client?.imageUrl(song.imageItemId, 160), playback.current?.id == song.id,
                    onClick = { app.player.play(matched.toList(), index) }, actions = actions)
            }
            if (done && missing.isNotEmpty()) {
                item { SectionTitle("Not in Your Library", Modifier.padding(top = Spacing.l)) }
                itemsIndexed(missing.toList(), key = { index, _ -> "missing-$index" }) { _, song ->
                    ListItem(headlineContent = { Text(song.title) }, supportingContent = { Text(song.artist) }, modifier = Modifier.alpha(0.6f))
                }
            }
        }
    }
}
