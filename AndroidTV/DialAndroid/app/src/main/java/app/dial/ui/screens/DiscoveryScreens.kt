package app.dial.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Album
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Shuffle
import androidx.compose.material3.Button
import androidx.compose.material3.FilledTonalButton
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
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ColorMatrix
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.dial.data.ArtistNames
import app.dial.data.Item
import app.dial.data.LibraryMatcher
import app.dial.data.PublicMusic
import app.dial.data.formatTime
import app.dial.data.releaseGroupId
import app.dial.ui.AlbumRoute
import app.dial.ui.ArtistRoute
import app.dial.ui.DecadeRoute
import app.dial.ui.GenreRoute
import app.dial.ui.LocalApp
import app.dial.ui.LocalNavigator
import app.dial.ui.PublicAlbumRoute
import app.dial.ui.components.ArtistShape
import app.dial.ui.components.Artwork
import app.dial.ui.components.EmptyMessage
import app.dial.ui.components.SectionTitle
import app.dial.ui.components.SongRow
import app.dial.ui.components.Spacing
import app.dial.ui.components.Tile
import app.dial.ui.components.black
import app.dial.ui.components.bold
import app.dial.ui.components.focusHighlight
import app.dial.ui.songActions
import coil3.compose.AsyncImage
import app.dial.data.JellyfinClient
import app.dial.ui.components.ArtistShapeIcon

// MARK: - Discography

/** An artist's releases grouped by kind, newest first. Yours open; the rest are faded and open a tracklist. */
@Composable
fun Discography(library: List<Item>, releases: List<PublicMusic.Release>, artist: String, artistId: String?) {
    val navigator = LocalNavigator.current
    val client = client()
    var onlyMine by remember { mutableStateOf(true) }
    data class Entry(val key: String, val title: String, val year: Int?, val kind: String, val album: Item?, val release: PublicMusic.Release?)

    val unmatched = library.toMutableList()
    val entries = mutableListOf<Entry>()
    for (release in releases) {
        val match = unmatched.indexOfFirst { it.releaseGroupId == release.id || LibraryMatcher.key(it.name) == LibraryMatcher.key(release.title) }
        val album = if (match >= 0) unmatched.removeAt(match) else null
        if (onlyMine && library.isNotEmpty() && album == null) continue
        entries += Entry(release.id, album?.name ?: release.title, album?.productionYear ?: release.year, release.kind, album, release)
    }
    unmatched.forEach { entries += Entry(it.id, it.name, it.productionYear, "album", it, null) }
    entries.sortByDescending { it.year ?: 0 }
    if (entries.isEmpty()) return

    Column(verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        SectionTitle("Discography") {
            if (releases.isNotEmpty()) {
                androidx.compose.material3.FilterChip(selected = onlyMine, onClick = { onlyMine = !onlyMine },
                    label = { Text("In Library") })
            }
        }
        listOf("Albums" to setOf("album", "other"), "Singles & EPs" to setOf("single", "ep"),
            "Live" to setOf("live"), "Compilations" to setOf("compilation")).forEach { (title, kinds) ->
            val items = entries.filter { it.kind in kinds }
            if (items.isNotEmpty()) {
                Text(title, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = Spacing.l))
                LazyRow(contentPadding = PaddingValues(horizontal = Spacing.l), horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
                    items(items, key = { it.key }) { entry ->
                        val year = entry.year?.toString()
                        if (entry.album != null) {
                            Tile(entry.title, year, client?.imageUrl(entry.album.id), 150.dp,
                                onClick = { navigator.open(AlbumRoute(entry.album.id, entry.album.name)) })
                        } else {
                            Column(Modifier.width(150.dp).focusHighlight().clickable {
                                entry.release?.let { navigator.open(PublicAlbumRoute(it.id, it.title, it.year, artist, artistId)) }
                            }) {
                                FadedCover(entry.release?.cover, Modifier.fillMaxWidth().aspectRatio(1f))
                                Text(entry.title, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
                                    modifier = Modifier.padding(top = Spacing.s).alpha(0.6f))
                                if (year != null) Text(year, style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                }
            }
        }
    }
}

/** A cover in grey, for releases you don't have. */
@Composable
fun FadedCover(url: String?, modifier: Modifier = Modifier, corner: Int = 16) {
    Box(modifier.clip(RoundedCornerShape(corner.dp)).background(MaterialTheme.colorScheme.surfaceContainerHigh)) {
        AsyncImage(model = url, contentDescription = null, contentScale = ContentScale.Crop,
            colorFilter = ColorFilter.colorMatrix(ColorMatrix().apply { setToSaturation(0f) }),
            modifier = Modifier.fillMaxSize().alpha(0.45f))
        Icon(Icons.Rounded.Album, null, tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.25f),
            modifier = Modifier.align(Alignment.Center).size(40.dp))
    }
}

// MARK: - Album you don't have

@Composable
fun PublicAlbumScreen(route: PublicAlbumRoute) {
    val app = LocalApp.current
    val navigator = LocalNavigator.current
    val client = client()
    val load = rememberLoad(route.releaseGroupId) { c ->
        val tracks = PublicMusic.tracklist(route.releaseGroupId)
        // Songs from it you have elsewhere (a single, a compilation, a deluxe edition).
        val yours = route.artistId?.let { runCatching { c.artistSongs(it, 500) }.getOrNull() } ?: emptyList()
        val byTitle = yours.groupBy { LibraryMatcher.key(it.name) }.mapValues { it.value.first() }
        tracks to tracks.associate { "${it.disc}-${it.number}" to byTitle[LibraryMatcher.key(it.title)] }
    }
    androidx.compose.foundation.layout.Column(Modifier.fillMaxSize()) {
        PageTopBar("")
        LoadContent(load) { (tracks, owned) ->
            val playable = tracks.mapNotNull { owned["${it.disc}-${it.number}"] }
            LazyColumn(contentPadding = PaddingValues(bottom = Spacing.section)) {
                item {
                    Column(Modifier.fillMaxWidth().padding(Spacing.l), horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                        FadedCover(PublicMusic.Release(route.releaseGroupId, route.title, route.year, "album").largeCover,
                            Modifier.size(240.dp), corner = 28)
                        Text(route.title, style = MaterialTheme.typography.headlineMedium.black(), textAlign = TextAlign.Center,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(route.artist, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.clickable(enabled = route.artistId != null) {
                                route.artistId?.let { navigator.open(ArtistRoute(it, route.artist)) }
                            })
                        Text(listOfNotNull(route.year?.toString(), "Not in your library").joinToString(", "),
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        if (playable.isNotEmpty()) {
                            Button(onClick = { app.player.play(playable) }) {
                                Icon(Icons.Rounded.PlayArrow, null); Spacer(Modifier.width(Spacing.xs))
                                Text(if (playable.size == 1) "Play the 1 Song You Have" else "Play the ${playable.size} Songs You Have")
                            }
                        }
                    }
                }
                if (tracks.isEmpty()) item { EmptyMessage("No tracklist", "MusicBrainz doesn\u2019t have the songs on this release.") }
                val discs = tracks.map { it.disc }.distinct()
                discs.forEach { disc ->
                    if (discs.size > 1) item { SectionTitle("Disc $disc", Modifier.padding(top = Spacing.l)) }
                    items(tracks.filter { it.disc == disc }, key = { "${it.disc}-${it.number}" }) { track ->
                        val song = owned["${track.disc}-${track.number}"]
                        Row(Modifier.fillMaxWidth()
                            .then(if (song != null) Modifier.focusHighlight(RoundedCornerShape(12.dp)).clickable {
                                app.player.play(playable, playable.indexOf(song).coerceAtLeast(0))
                            } else Modifier)
                            .padding(horizontal = Spacing.l, vertical = Spacing.m)
                            .alpha(if (song != null) 1f else 0.45f),
                            verticalAlignment = Alignment.CenterVertically) {
                            Text("${track.number}", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.width(32.dp))
                            Column(Modifier.weight(1f)) {
                                Text(track.title, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                if (song?.album != null) Text("In your library on ${song.album}", style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.primary, maxLines = 1)
                            }
                            track.lengthMs?.let { Text(formatTime(it.toLong()), style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant) }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Featured artist

@Composable
fun FeaturedArtistScreen(name: String) {
    val app = LocalApp.current
    val client = client()
    val playback by app.player.state.collectAsState()
    val featured by app.credits.featured.collectAsState()
    val songs = remember(featured) { app.credits.songsFeaturing(name) }
    val actions = songActions()
    var photo by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(name) { photo = PublicMusic.artistImage(name = name) }
    androidx.compose.foundation.layout.Column(Modifier.fillMaxSize()) {
        PageTopBar("")
        LazyColumn(contentPadding = PaddingValues(bottom = Spacing.section)) {
            item {
                Column(Modifier.fillMaxWidth().padding(Spacing.l), horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                    Artwork(photo, Modifier.size(220.dp), ArtistShape, ArtistShapeIcon)
                    Text(name, style = MaterialTheme.typography.headlineMedium.black(), textAlign = TextAlign.Center)
                    Text(if (songs.size == 1) "Featured on 1 song in your library" else "Featured on ${songs.size} songs in your library",
                        style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Row(horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
                        Button(onClick = { app.player.play(songs) }, enabled = songs.isNotEmpty()) {
                            Icon(Icons.Rounded.PlayArrow, null); Spacer(Modifier.width(Spacing.xs)); Text("Play")
                        }
                        FilledTonalButton(onClick = { app.player.play(songs, shuffle = true) }, enabled = songs.isNotEmpty()) {
                            Icon(Icons.Rounded.Shuffle, null); Spacer(Modifier.width(Spacing.xs)); Text("Shuffle")
                        }
                    }
                }
            }
            if (songs.isNotEmpty()) item { SectionTitle("Featured On") }
            itemsIndexed(songs, key = { _, s -> s.id }) { index, song ->
                SongRow(song, client?.imageUrl(song.imageItemId, 160), playback.current?.id == song.id,
                    onClick = { app.player.play(songs, index) }, actions = actions)
            }
        }
    }
}

// MARK: - Browse categories (Search before you type)

data class BrowseCategory(val key: String, val title: String, val subtitle: String, val covers: List<String>, val route: Any)

/** Genres and decades from your library, each a collage of your own covers. */
@Composable
fun BrowseCategories(columnsMin: androidx.compose.ui.unit.Dp = 160.dp) {
    val navigator = LocalNavigator.current
    val client = client()
    val load = rememberLoad("browse") { c ->
        val albums = c.albumsForBrowsing()
        val genres = c.genres()
        val byGenre = mutableMapOf<String, MutableList<String>>()
        albums.forEach { a -> a.genres?.forEach { g -> byGenre.getOrPut(g) { mutableListOf() } += a.id } }
        val genreTiles = byGenre.filter { it.value.size >= 2 }.entries.sortedByDescending { it.value.size }.take(12).mapNotNull { (name, ids) ->
            val genre = genres.firstOrNull { it.name.equals(name, ignoreCase = true) } ?: return@mapNotNull null
            BrowseCategory("g-${genre.id}", genre.name, "${ids.size} albums", ids.take(4), GenreRoute(genre.id, genre.name))
        }
        val byDecade = albums.filter { (it.productionYear ?: 0) > 1900 }.groupBy { it.productionYear!! / 10 * 10 }
        val decadeTiles = byDecade.entries.sortedByDescending { it.key }.map { (start, list) ->
            BrowseCategory("d-$start", decadeName(start), "${list.size} albums", list.take(4).map { it.id }, DecadeRoute(start))
        }
        genreTiles to decadeTiles
    }
    (load as? Load.Ready)?.value?.let { (genres, decades) ->
        Column(verticalArrangement = Arrangement.spacedBy(Spacing.xl)) {
            listOf("Genres" to genres, "Decades" to decades).forEach { (title, tiles) ->
                if (tiles.isNotEmpty()) {
                    SectionTitle(title)
                    tiles.chunked(2).forEach { pair ->
                        Row(Modifier.padding(horizontal = Spacing.l), horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
                            pair.forEach { tile ->
                                CategoryCollage(tile, client, Modifier.weight(1f)) { navigator.open(tile.route) }
                            }
                            if (pair.size == 1) Spacer(Modifier.weight(1f))
                        }
                    }
                }
            }
        }
    }
}

fun decadeName(start: Int) = if (start >= 2000) "${start}s" else "${start.toString().takeLast(2)}s"

@Composable
private fun CategoryCollage(tile: BrowseCategory, client: JellyfinClient?, modifier: Modifier, onClick: () -> Unit) {
    val shape = RoundedCornerShape(20.dp)
    Box(modifier.aspectRatio(1.5f).focusHighlight(shape).clip(shape).clickable(onClick = onClick)) {
        Column(Modifier.fillMaxSize()) {
            listOf(0, 2).forEach { row ->
                Row(Modifier.weight(1f)) {
                    listOf(0, 1).forEach { col ->
                        val id = tile.covers.getOrNull((row + col) % tile.covers.size.coerceAtLeast(1))
                        AsyncImage(model = id?.let { client?.imageUrl(it, 200) }, contentDescription = null,
                            contentScale = ContentScale.Crop, modifier = Modifier.weight(1f).fillMaxSize())
                    }
                }
            }
        }
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.15f), Color.Black.copy(alpha = 0.7f)))))
        Column(Modifier.align(Alignment.BottomStart).padding(Spacing.m)) {
            Text(tile.title, style = MaterialTheme.typography.titleMedium.bold(), color = Color.White, maxLines = 1)
            Text(tile.subtitle, style = MaterialTheme.typography.bodySmall, color = Color.White.copy(alpha = 0.8f))
        }
    }
}

// MARK: - Genre and decade pages

@Composable
fun CategoryScreen(genre: GenreRoute?, decade: Int?) {
    val app = LocalApp.current
    val navigator = LocalNavigator.current
    val client = client()
    val title = genre?.name ?: decade?.let { if (it >= 2000) "The ${it}s" else "The ${decadeName(it)}" } ?: ""
    val years = decade?.let { (it..it + 9).toList() } ?: emptyList()
    val load = rememberLoad(genre?.id ?: decade) { c -> if (genre != null) c.albums(genre.id) else c.albums(years) }
    androidx.compose.foundation.layout.Column(Modifier.fillMaxSize()) {
        PageTopBar(title)
        LoadContent(load) { albums ->
            LazyVerticalGrid(GridCells.Adaptive(150.dp), contentPadding = PaddingValues(Spacing.l),
                horizontalArrangement = Arrangement.spacedBy(Spacing.m), verticalArrangement = Arrangement.spacedBy(Spacing.l)) {
                item(span = { GridItemSpan(maxLineSpan) }) {
                    Row(horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
                        Button(onClick = {
                            app.player.play(title) { c -> if (genre != null) c.songs(genre.id) else c.songsFromYears(years) }
                        }) { Icon(Icons.Rounded.PlayArrow, null); Spacer(Modifier.width(Spacing.xs)); Text("Play") }
                        FilledTonalButton(onClick = {
                            app.player.play(title, shuffle = true) { c -> if (genre != null) c.songs(genre.id) else c.songsFromYears(years) }
                        }) { Icon(Icons.Rounded.Shuffle, null); Spacer(Modifier.width(Spacing.xs)); Text("Shuffle") }
                    }
                }
                items(albums, key = { it.id }) { album ->
                    Tile(album.name, listOfNotNull(album.albumArtistLine, album.productionYear?.toString()).joinToString(", "),
                        client?.imageUrl(album.id), 150.dp, onClick = { navigator.open(AlbumRoute(album.id, album.name)) })
                }
            }
        }
    }
}
