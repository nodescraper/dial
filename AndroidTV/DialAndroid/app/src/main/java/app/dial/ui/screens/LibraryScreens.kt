package app.dial.ui.screens

import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Search
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.focus.focusRequester
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.QueueMusic
import androidx.compose.material.icons.rounded.Album
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.Column
import app.dial.data.ArtistNames
import app.dial.data.LibrarySection
import app.dial.ui.AlbumRoute
import app.dial.ui.ArtistRoute
import app.dial.ui.LocalApp
import app.dial.ui.LocalNavigator
import app.dial.ui.PlaylistRoute
import app.dial.ui.SectionRoute
import app.dial.ui.components.Artwork
import app.dial.ui.components.ArtistTile
import app.dial.ui.components.EmptyMessage
import app.dial.ui.components.SongRow
import app.dial.ui.components.Spacing
import app.dial.ui.components.Tile
import app.dial.ui.components.black
import app.dial.ui.songActions
import app.dial.data.PublicMusic
import app.dial.ui.FeaturedArtistRoute
import app.dial.ui.ImportRoute
import app.dial.ui.components.SectionTitle

private val LibrarySection.icon: ImageVector
    get() = when (this) {
        LibrarySection.Playlists -> Icons.AutoMirrored.Rounded.QueueMusic
        LibrarySection.Artists -> Icons.Rounded.Person
        LibrarySection.Albums -> Icons.Rounded.Album
        LibrarySection.Songs -> Icons.Rounded.MusicNote
        LibrarySection.Favorites -> Icons.Rounded.Favorite
        LibrarySection.Downloaded -> Icons.Rounded.Download
    }

/** The Library: a big search bar for everything you own (and a little beyond), and under it your library. */
@Composable
fun LibraryScreen() {
    var query by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf("") }
    val focus = remember { androidx.compose.ui.focus.FocusRequester() }
    val request by SearchFocus.request.collectAsState()
    // The search icon on Home puts the cursor here, even when this page is only just opening.
    androidx.compose.runtime.LaunchedEffect(request) {
        if (SearchFocus.pending) {
            SearchFocus.pending = false
            kotlinx.coroutines.delay(350) // after the tab has switched
            runCatching { focus.requestFocus() }
        }
    }
    Column(Modifier.fillMaxSize()) {
        Text("Library", style = MaterialTheme.typography.displaySmall.black(), modifier = Modifier.padding(start = Spacing.l, top = Spacing.l))
        androidx.compose.material3.TextField(
            value = query, onValueChange = { query = it }, singleLine = true,
            placeholder = { Text("Search your library", style = MaterialTheme.typography.titleMedium) },
            textStyle = MaterialTheme.typography.titleMedium,
            leadingIcon = { Icon(androidx.compose.material.icons.Icons.Rounded.Search, null) },
            trailingIcon = {
                if (query.isNotEmpty()) IconButton(onClick = { query = "" }) { Icon(androidx.compose.material.icons.Icons.Rounded.Close, "Clear search") }
            },
            shape = RoundedCornerShape(22.dp),
            colors = androidx.compose.material3.TextFieldDefaults.colors(focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent),
            modifier = Modifier.fillMaxWidth().height(64.dp).padding(horizontal = Spacing.l).padding(top = Spacing.xs).focusRequester(focus),
        )
        if (query.trim().length >= 2) LibrarySearchResults(query) else LibraryContent()
    }
}

@Composable
private fun LibraryContent() {
    val navigator = LocalNavigator.current
    val client = client()
    val recent = rememberLoad(Unit) { it.recentAlbums(12) }
    LazyVerticalGrid(GridCells.Adaptive(150.dp), contentPadding = PaddingValues(bottom = Spacing.section),
        horizontalArrangement = Arrangement.spacedBy(Spacing.m), verticalArrangement = Arrangement.spacedBy(Spacing.l)) {
        LibrarySection.entries.forEach { section ->
            item(span = { GridItemSpan(maxLineSpan) }) {
                ListItem(
                    headlineContent = { Text(section.title, style = MaterialTheme.typography.titleMedium) },
                    leadingContent = { Icon(section.icon, null, tint = MaterialTheme.colorScheme.primary) },
                    modifier = Modifier.clickable { navigator.open(SectionRoute(section.name)) },
                )
            }
        }
        item(span = { GridItemSpan(maxLineSpan) }) {
            ListItem(
                headlineContent = { Text("Import Playlists", style = MaterialTheme.typography.titleMedium) },
                leadingContent = { Icon(Icons.Rounded.MusicNote, null, tint = MaterialTheme.colorScheme.primary) },
                modifier = Modifier.clickable { navigator.open(ImportRoute) },
            )
        }
        (recent as? Load.Ready)?.value?.takeIf { it.isNotEmpty() }?.let { albums ->
            item(span = { GridItemSpan(maxLineSpan) }) {
                SectionTitle("Recently Added", Modifier.padding(top = Spacing.l))
            }
            items(albums, key = { it.id }) { album ->
                Tile(album.name, album.albumArtistLine, client?.imageUrl(album.id), 150.dp,
                    onClick = { navigator.open(AlbumRoute(album.id, album.name)) },
                    modifier = Modifier.padding(horizontal = Spacing.s))
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PageTopBar(title: String) {
    val back = LocalBack.current
    TopAppBar(title = { Text(title) }, navigationIcon = {
        IconButton(onClick = back) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, "Back") }
    })
}

/** Goes back one page. */
val LocalBack = androidx.compose.runtime.staticCompositionLocalOf<() -> Unit> { {} }

@Composable
fun LibrarySectionScreen(section: LibrarySection) {
    val app = LocalApp.current
    val navigator = LocalNavigator.current
    val client = client()
    val playback by app.player.state.collectAsState()
    val actions = songActions()
    val load = rememberLoad(section) { c ->
        when (section) {
            LibrarySection.Playlists -> c.playlists()
            LibrarySection.Artists -> c.artists()
            LibrarySection.Albums -> c.albums()
            LibrarySection.Songs -> c.songs()
            LibrarySection.Favorites -> c.favoriteSongs()
            LibrarySection.Downloaded -> app.downloads.records.value.values.map { it.item }
                .sortedBy { it.albumArtistLine + (it.album ?: "") + (it.indexNumber ?: 0) }
        }
    }
    Column(Modifier.fillMaxSize()) {
        PageTopBar(section.title)
        LoadContent(load) { items ->
            if (items.isEmpty()) {
                EmptyMessage("Nothing here yet", "Add music to your Jellyfin library, then come back.")
                return@LoadContent
            }
            when (section) {
                LibrarySection.Albums, LibrarySection.Artists -> LazyVerticalGrid(
                    GridCells.Adaptive(150.dp), contentPadding = PaddingValues(Spacing.l),
                    horizontalArrangement = Arrangement.spacedBy(Spacing.m), verticalArrangement = Arrangement.spacedBy(Spacing.l),
                ) {
                    items(items, key = { it.id }) { item ->
                        if (section == LibrarySection.Artists) {
                            ArtistTile(ArtistNames.primary(item.name), client?.imageUrl(item.id), 150.dp) {
                                navigator.open(ArtistRoute(item.id, item.name))
                            }
                        } else {
                            Tile(item.name, item.albumArtistLine, client?.imageUrl(item.id), 150.dp,
                                onClick = { navigator.open(AlbumRoute(item.id, item.name)) })
                        }
                    }
                    if (section == LibrarySection.Artists) {
                        val featuredOnly = app.credits.featuredOnly
                        if (featuredOnly.isNotEmpty()) {
                            item(span = { GridItemSpan(maxLineSpan) }) {
                                SectionTitle("Featured Artists", Modifier.padding(top = Spacing.l))
                            }
                            items(featuredOnly, key = { "featured-" + it.name }) { entry ->
                                FeaturedTile(entry.name, entry.songs.size)
                            }
                        }
                    }
                }
                LibrarySection.Playlists -> LazyColumn {
                    items(items, key = { it.id }) { playlist ->
                        ListItem(
                            headlineContent = { Text(playlist.name) },
                            leadingContent = {
                                Artwork(client?.imageUrl(playlist.id, 160), Modifier.size(56.dp), RoundedCornerShape(12.dp),
                                    Icons.AutoMirrored.Rounded.QueueMusic)
                            },
                            modifier = Modifier.clickable { navigator.open(PlaylistRoute(playlist.id, playlist.name)) },
                        )
                    }
                }
                else -> LazyColumn(contentPadding = PaddingValues(bottom = Spacing.section)) {
                    itemsIndexed(items, key = { _, it -> it.id }) { index, song ->
                        SongRow(song, client?.imageUrl(song.imageItemId, 160), playback.current?.id == song.id,
                            onClick = { app.player.play(items, index) }, actions = actions)
                    }
                }
            }
        }
    }
}

/** An artist who only appears as a feature, with a public photo. */
@Composable
private fun FeaturedTile(name: String, count: Int) {
    val navigator = LocalNavigator.current
    var photo by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf<String?>(null) }
    androidx.compose.runtime.LaunchedEffect(name) { photo = PublicMusic.artistImage(name = name) }
    Column {
        ArtistTile(name, photo, 150.dp) { navigator.open(FeaturedArtistRoute(name)) }
        Text(if (count == 1) "On 1 song" else "On $count songs", style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.align(androidx.compose.ui.Alignment.CenterHorizontally))
    }
}
