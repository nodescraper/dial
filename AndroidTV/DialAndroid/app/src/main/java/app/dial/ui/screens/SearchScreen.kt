package app.dial.ui.screens

import app.dial.data.MixCatalog
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import app.dial.data.LibraryMatcher
import app.dial.data.ArtistNames
import app.dial.data.Item
import app.dial.ui.AlbumRoute
import app.dial.ui.ArtistRoute
import app.dial.ui.LocalApp
import app.dial.ui.LocalNavigator
import app.dial.ui.components.ArtistTile
import app.dial.ui.components.EmptyMessage
import app.dial.ui.components.Loading
import app.dial.ui.components.SectionTitle
import app.dial.ui.components.Shelf
import app.dial.ui.components.SongRow
import app.dial.ui.components.Spacing
import app.dial.ui.components.Tile
import app.dial.ui.components.black
import app.dial.ui.songActions
import kotlinx.coroutines.delay
import app.dial.ui.PlaylistRoute

@Composable
/** What you search in your library: songs, albums, artists and playlists, and artists and albums beyond it. */
fun LibrarySearchResults(query: String) {
    val app = LocalApp.current
    val navigator = LocalNavigator.current
    val client = client()
    val playback by app.player.state.collectAsState()
    val actions = songActions()
    var results by remember { mutableStateOf<List<Item>?>(null) }
    var searching by remember { mutableStateOf(false) }

    LaunchedEffect(query) {
        val term = query.trim()
        if (term.length < 2) { results = null; return@LaunchedEffect }
        delay(300) // wait until typing pauses
        searching = true
        results = runCatching { client?.search(term) }.getOrNull() ?: emptyList()
        searching = false
    }

    Column(Modifier.fillMaxSize()) {
        var scope by rememberSaveable { mutableStateOf("All") }
        run {
            // Narrow the results to one kind.
            androidx.compose.foundation.lazy.LazyRow(contentPadding = PaddingValues(horizontal = Spacing.l, vertical = Spacing.s),
                horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
                items(listOf("All", "Songs", "Albums", "Artists", "Playlists").size) { i ->
                    val option = listOf("All", "Songs", "Albums", "Artists", "Playlists")[i]
                    androidx.compose.material3.FilterChip(selected = scope == option, onClick = { scope = option },
                        label = { Text(option) })
                }
            }
        }
        val found = results?.filter { !(it.type == "Playlist" && MixCatalog.isGenerated(it.name)) }?.filter { item ->
            when (scope) {
                "Songs" -> item.type == "Audio"
                "Albums" -> item.type == "MusicAlbum"
                "Artists" -> item.type == "MusicArtist"
                "Playlists" -> item.type == "Playlist"
                else -> true
            }
        }
        when {
            searching && found == null -> Loading()
            found == null -> Loading()
            found.isEmpty() -> LazyColumn(contentPadding = PaddingValues(top = Spacing.l)) {
                item { EmptyMessage("Not in your library", "Nothing in your library matches \u201c${query.trim()}\u201d.", Modifier.height(160.dp)) }
                item { BeyondLibrary(query.trim(), emptySet()) }
            }
            else -> {
                val artists = found.filter { it.type == "MusicArtist" }
                val albums = found.filter { it.type == "MusicAlbum" }
                val songs = found.filter { it.type == "Audio" }
                val playlists = found.filter { it.type == "Playlist" }
                LazyColumn(contentPadding = PaddingValues(top = Spacing.l, bottom = Spacing.section),
                    verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
                    if (artists.isNotEmpty()) item {
                        Shelf("Artists", artists, key = { it.id }) { artist ->
                            ArtistTile(ArtistNames.primary(artist.name), client?.imageUrl(artist.id), 110.dp) {
                                navigator.open(ArtistRoute(artist.id, artist.name))
                            }
                        }
                    }
                    if (albums.isNotEmpty()) item {
                        Shelf("Albums", albums, key = { it.id }) { album ->
                            Tile(album.name, album.albumArtistLine, client?.imageUrl(album.id), 140.dp,
                                onClick = { navigator.open(AlbumRoute(album.id, album.name)) })
                        }
                    }
                    if (playlists.isNotEmpty()) item {
                        Shelf("Playlists", playlists, key = { it.id }) { playlist ->
                            Tile(playlist.name, null, client?.imageUrl(playlist.id), 140.dp,
                                onClick = { navigator.open(PlaylistRoute(playlist.id, playlist.name)) })
                        }
                    }
                    if (songs.isNotEmpty()) {
                        item { SectionTitle("Songs") }
                        itemsIndexed(songs, key = { _, s -> s.id }) { index, song ->
                            SongRow(song, client?.imageUrl(song.imageItemId, 160), playback.current?.id == song.id,
                                onClick = { app.player.play(songs, index) }, actions = actions)
                        }
                    }
                    if (scope != "Songs" && scope != "Playlists") item {
                        BeyondLibrary(query.trim(), (results ?: emptyList()).map { LibraryMatcher.key(it.name) }.toSet())
                    }
                }
            }
        }
    }
}
