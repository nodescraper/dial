package app.dial.ui.screens

import androidx.compose.material3.Icon
import androidx.compose.runtime.collectAsState
import androidx.compose.material.icons.automirrored.rounded.OpenInNew
import androidx.compose.material.icons.rounded.NotificationsActive
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.BookmarkAdd
import androidx.compose.material.icons.rounded.BookmarkRemove
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
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
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.dial.data.ArtistNames
import app.dial.data.DeezerSearch
import app.dial.data.DialPlugin
import app.dial.data.Item
import app.dial.data.LibraryMatcher
import app.dial.data.PublicMusic
import app.dial.data.WishItem
import app.dial.data.Wishlist
import app.dial.data.musicBrainzId
import app.dial.ui.AlbumRoute
import app.dial.ui.ArtistRoute
import app.dial.ui.LocalApp
import app.dial.ui.LocalNavigator
import app.dial.ui.PublicAlbumRoute
import app.dial.ui.components.ArtistShape
import app.dial.ui.components.Artwork
import app.dial.ui.components.JewelCase
import app.dial.ui.components.SectionTitle
import app.dial.ui.components.Spacing
import app.dial.ui.components.bold
import app.dial.ui.components.focusHighlight
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable

/** An artist you don't have, from MusicBrainz: photo and discography. */
@Serializable data class ArtistPreviewRoute(val mbid: String, val name: String)
@Serializable data class ExploreGenreRoute(val name: String)

/**
 * Opens an album from outside the library. With its id (MusicBrainz, Deezer or iTunes) it opens at once; otherwise it is
 * looked up by artist and title, on MusicBrainz first and then on Deezer, which has many albums MusicBrainz doesn't.
 */
fun openOutsideAlbum(navigator: app.dial.ui.Navigator, scope: kotlinx.coroutines.CoroutineScope,
                     artist: String, title: String, sourceId: String? = null, cover: String? = null) {
    fun open(id: String) { navigator.open(PublicAlbumRoute(id, title, null, artist, null, cover)) }
    val id = sourceId?.ifEmpty { null }
    if (id != null) { open(id); return }
    scope.launch {
        PublicMusic.releaseGroupId(artist, title)?.let { open(it); return@launch }
        DeezerSearch.albumSourceId(artist, title)?.let { open(it) }
    }
}

/** "Add to Wishlist" (or "Remove from Wishlist") in the menu of an album or song you don't have. Needs the Dial plugin. */
@Composable
fun WishlistMenuItem(item: WishItem, onDone: () -> Unit) {
    val hasPlugin by DialPlugin.present.collectAsState()
    if (!hasPlugin) return
    val items by Wishlist.items.collectAsState()
    val scope = rememberCoroutineScope()
    val c = client()
    val on = items.any { it.id == item.id }
    DropdownMenuItem(
        text = { Text(if (on) "Remove from Wishlist" else "Add to Wishlist") },
        leadingIcon = { Icon(if (on) Icons.Rounded.BookmarkRemove else Icons.Rounded.BookmarkAdd, null) },
        onClick = { onDone(); scope.launch { Wishlist.toggle(item, c) } },
    )
}

/** Your library, to tell what you have from what you don't. */
class Owned(val artists: List<Item>, val albums: List<Item>) {
    fun artist(pick: PublicMusic.Pick): Item? =
        artists.firstOrNull { it.musicBrainzId == pick.mbid } ?: artists.firstOrNull { ArtistNames.key(it.name) == ArtistNames.key(pick.title) }
    fun artistOf(pick: PublicMusic.Pick): Item? =
        pick.artistMbid?.let { m -> artists.firstOrNull { it.musicBrainzId == m } }
            ?: pick.artist?.let { a -> artists.firstOrNull { ArtistNames.key(it.name) == ArtistNames.key(ArtistNames.primary(a)) } }
    fun album(pick: PublicMusic.Pick): Item? = albums.firstOrNull {
        LibraryMatcher.key(it.name) == LibraryMatcher.key(pick.title) &&
            (pick.artist == null || ArtistNames.key(ArtistNames.primary(it.albumArtistLine)) == ArtistNames.key(ArtistNames.primary(pick.artist)))
    }
}

@Composable
private fun Header(title: String, subtitle: String?, light: Boolean = false) {
    Column(Modifier.padding(horizontal = Spacing.l)) {
        // The light kind is the quieter grey heading, used for the "Fans of ..." rows under the main ones.
        if (light) Text(title, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        else Text(title, style = app.dial.ui.components.sectionStyle())
        subtitle?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
}

@Composable
internal fun ArtistRow(title: String, subtitle: String?, picks: List<PublicMusic.Pick>, owned: Owned, light: Boolean = false) {
    Column(verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        Header(title, subtitle, light)
        LazyRow(contentPadding = PaddingValues(horizontal = Spacing.l), horizontalArrangement = Arrangement.spacedBy(Spacing.l)) {
            items(picks, key = { it.listId }) { pick -> PickArtist(pick, owned.artist(pick), 116.dp) }
        }
    }
}

@Composable
internal fun AlbumRow(title: String, subtitle: String?, picks: List<PublicMusic.Pick>, owned: Owned) {
    Column(verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        Header(title, subtitle)
        LazyRow(contentPadding = PaddingValues(horizontal = Spacing.l), horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
            items(picks, key = { it.listId }) { pick -> PickAlbum(pick, owned.album(pick), owned.artistOf(pick)) }
        }
    }
}

@Composable
fun PickArtistTile(pick: PublicMusic.Pick, owned: Item?, width: androidx.compose.ui.unit.Dp) = PickArtist(pick, owned, width)

@Composable
private fun PickArtist(pick: PublicMusic.Pick, owned: Item?, width: androidx.compose.ui.unit.Dp) {
    val navigator = LocalNavigator.current
    val client = client()
    val scope = rememberCoroutineScope()
    var photo by remember(pick.listId) { mutableStateOf<String?>(null) }
    LaunchedEffect(pick.listId) { if (owned == null && pick.image == null) photo = PublicMusic.artistImage(pick.mbid.ifEmpty { null }, pick.title) }
    Column(Modifier.width(width).focusHighlight(ArtistShape).clickable {
        owned?.let { navigator.open(ArtistRoute(it.id, it.name)); return@clickable }
        // Artists found on Deezer have no MusicBrainz id: it is looked up by name first.
        if (pick.mbid.isNotEmpty()) navigator.open(ArtistPreviewRoute(pick.mbid, pick.title))
        else scope.launch {
            PublicMusic.artistMbid(pick.title)?.let { navigator.open(ArtistPreviewRoute(it, pick.title)) }
        }
    }, horizontalAlignment = Alignment.CenterHorizontally) {
        Artwork(if (owned != null) client?.imageUrl(owned.id) else pick.image ?: photo, Modifier.fillMaxWidth().aspectRatio(1f), ArtistShape, Icons.Rounded.Person)
        Text(pick.title, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center, modifier = Modifier.padding(top = Spacing.s))
        Text(if (owned != null) "In your library" else "New to you", style = MaterialTheme.typography.labelSmall,
            color = if (owned != null) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.primary)
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun PickAlbum(pick: PublicMusic.Pick, owned: Item?, ownedArtist: Item?) {
    val navigator = LocalNavigator.current
    val client = client()
    var menu by remember { mutableStateOf(false) }
    val coverUrl = if (owned != null) client?.imageUrl(owned.id) else pick.cover
    Column(Modifier.width(150.dp).focusHighlight().combinedClickable(
        onClick = {
            navigator.open(owned?.let { AlbumRoute(it.id, it.name) }
                ?: PublicAlbumRoute(pick.releaseId, pick.title, pick.year, pick.artist ?: "", ownedArtist?.id, pick.coverFile))
        },
        onLongClick = { menu = true },
    )) {
        Artwork(coverUrl, Modifier.fillMaxWidth().aspectRatio(1f), RoundedCornerShape(12.dp))
        Text(pick.title, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = Spacing.s))
        Text(if (owned != null) "In your library" else pick.artist ?: "", style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            WishlistMenuItem(WishItem.album(pick.artist ?: "", pick.title, pick.sourceId ?: pick.mbid.ifEmpty { null }, pick.cover)) { menu = false }
        }
    }
}

private val genres = listOf(
    "Hip Hop" to listOf(Color(0xFF8C3326), Color(0xFFF28C40)), "R&B" to listOf(Color(0xFF732666), Color(0xFFE6738C)),
    "Pop" to listOf(Color(0xFFD94D8C), Color(0xFFFAB266)), "Rock" to listOf(Color(0xFF40404D), Color(0xFFBF4D40)),
    "Electronic" to listOf(Color(0xFF26338C), Color(0xFF59BFD9)), "Jazz" to listOf(Color(0xFF334D59), Color(0xFFD9A64D)),
    "Indie" to listOf(Color(0xFF4D734D), Color(0xFFD9CC80)), "Soul" to listOf(Color(0xFF80401A), Color(0xFFF2B24D)),
    "Latin" to listOf(Color(0xFFBF3333), Color(0xFFFABF33)), "Metal" to listOf(Color(0xFF1A1A1F), Color(0xFF737380)),
    "Classical" to listOf(Color(0xFF594D40), Color(0xFFD9CCB2)), "Folk" to listOf(Color(0xFF664D33), Color(0xFFBF9966)),
)

@Composable
internal fun GenreTiles() {
    val navigator = LocalNavigator.current
    Column(verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        SectionTitle("Explore Genres")
        genres.chunked(2).forEach { pair ->
            Row(Modifier.padding(horizontal = Spacing.l), horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
                pair.forEach { (name, colors) ->
                    Box(Modifier.weight(1f).height(84.dp).focusHighlight(RoundedCornerShape(20.dp)).clip(RoundedCornerShape(20.dp))
                        .background(Brush.linearGradient(colors)).clickable { navigator.open(ExploreGenreRoute(name)) }.padding(Spacing.m)) {
                        Text(name, style = MaterialTheme.typography.titleMedium.bold(), color = Color.White)
                    }
                }
            }
        }
    }
}

/** One genre: what's new in it, and the artists MusicBrainz tags with it. */
@Composable
fun ExploreGenreScreen(name: String) {
    val load = rememberLoad(name) { c ->
        val owned = Owned(runCatching { c.artists() }.getOrDefault(emptyList()), emptyList())
        val tag = name.lowercase()
        Triple(owned, PublicMusic.freshReleases().filter { p -> p.tags.any { it.contains(tag) } }, PublicMusic.artistsTagged(tag).take(30))
    }
    Column(Modifier.fillMaxSize()) {
        PageTopBar(name)
        LoadContent(load) { (owned, fresh, artists) ->
            LazyVerticalGrid(GridCells.Adaptive(110.dp), contentPadding = PaddingValues(Spacing.l),
                horizontalArrangement = Arrangement.spacedBy(Spacing.l), verticalArrangement = Arrangement.spacedBy(Spacing.l)) {
                if (fresh.isNotEmpty()) item(span = { androidx.compose.foundation.lazy.grid.GridItemSpan(maxLineSpan) }) {
                    AlbumRow("New in $name", null, fresh, owned)
                }
                item(span = { androidx.compose.foundation.lazy.grid.GridItemSpan(maxLineSpan) }) { SectionTitle("Artists") }
                items(artists, key = { it.mbid }) { pick -> PickArtist(pick, owned.artist(pick), 110.dp) }
            }
        }
    }
}

/** An artist you don't have: photo, and their albums (opening the faded tracklist). */
@Composable
fun ArtistPreviewScreen(route: ArtistPreviewRoute) {
    val navigator = LocalNavigator.current
    val uriHandler = androidx.compose.ui.platform.LocalUriHandler.current
    var photo by remember(route.mbid) { mutableStateOf<String?>(null) }
    LaunchedEffect(route.mbid) { photo = PublicMusic.artistImage(route.mbid, route.name) }
    val followed by app.dial.data.Follows.artists.collectAsState()
    val following = followed.any { it.id == route.mbid }
    val load = rememberLoad(route.mbid) {
        Triple(PublicMusic.discography(route.mbid), PublicMusic.topTracks(route.mbid), PublicMusic.similarArtists(route.mbid))
    }
    val display = ArtistNames.primary(route.name)
    // The same page as for an artist you own: photo and name, what the world plays, discography, similar artists.
    Column(Modifier.fillMaxSize()) {
        PageTopBar("") {
            androidx.compose.material3.TextButton(onClick = { app.dial.data.Follows.toggleFollow(route.mbid, display) }) {
                Icon(if (following) Icons.Rounded.NotificationsActive else Icons.Rounded.Notifications, null, Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text(if (following) "Following" else "Follow")
            }
        }
        LazyColumn(contentPadding = PaddingValues(bottom = Spacing.section), verticalArrangement = Arrangement.spacedBy(Spacing.l)) {
            item {
                Column(Modifier.fillMaxWidth().padding(horizontal = Spacing.l), horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                    Artwork(photo, Modifier.size(240.dp), ArtistShape, Icons.Rounded.Person)
                    Text(display, style = MaterialTheme.typography.headlineMedium.bold(), textAlign = TextAlign.Center, modifier = Modifier.padding(top = Spacing.s))
                    Text("Not in your library", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    androidx.compose.material3.FilledTonalButton(onClick = {
                        uriHandler.openUri("https://open.spotify.com/search/" + android.net.Uri.encode(display))
                    }) { Icon(Icons.AutoMirrored.Rounded.OpenInNew, null); Spacer(Modifier.width(6.dp)); Text("Open in Spotify") }
                }
            }
            val ready = (load as? Load.Ready)?.value
            if (ready == null) item { ArtistPageSkeleton() }
            else {
                val (releases, popular, similar) = ready
                if (popular.isNotEmpty()) item { PopularSongs(popular, display, emptyList()) { _, _ -> } }
                item { Discography(emptyList(), releases, display, null, showsFilter = false) }
                if (similar.isNotEmpty()) item {
                    ArtistRow("Similar Artists", null, similar.take(15).map { PublicMusic.Pick("artist", it.mbid, it.name) }, Owned(emptyList(), emptyList()))
                }
            }
        }
    }
}

/**
 * While typing: artists and albums from Deezer (iTunes when Deezer can't be reached) beyond your library, faded
 * (songs, for the Songs filter). Always shows a skeleton while it looks, and looks again when the filter changes.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun BeyondLibrary(term: String, libraryNames: Set<String>, scope: String = "All") {
    val navigator = LocalNavigator.current
    val scope_ = rememberCoroutineScope()
    var picks by remember { mutableStateOf<List<PublicMusic.Pick>>(emptyList()) }
    var songs by remember { mutableStateOf<List<PublicMusic.SongPick>>(emptyList()) }
    var loading by remember { mutableStateOf(term.length >= 3) }
    LaunchedEffect(term, scope) {
        picks = emptyList(); songs = emptyList()
        if (term.length < 3) { loading = false; return@LaunchedEffect }
        loading = true
        kotlinx.coroutines.delay(500)
        if (scope == "Songs") songs = PublicMusic.searchSongs(term).filter { LibraryMatcher.key(it.title) !in libraryNames }
        else picks = PublicMusic.search(term).filter { LibraryMatcher.key(it.title) !in libraryNames }
            .filter { scope == "All" || (scope == "Artists") == it.isArtist }
        loading = false
    }
    if (!loading && picks.isEmpty() && songs.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        SectionTitle("Beyond Your Library")
        if (loading) {
            // The same shapes the results will have: circles for artists, covers for albums, rows for songs.
            if (scope == "All" || scope == "Artists") app.dial.ui.screens.SkeletonShelf(100.dp, circular = true, titleWidth = 0.dp)
            if (scope == "All" || scope == "Albums") app.dial.ui.screens.SkeletonShelf(130.dp, circular = false, count = 3, titleWidth = 0.dp)
            if (scope == "Songs") app.dial.ui.screens.SkeletonRows()
            return@Column
        }
        Column(verticalArrangement = Arrangement.spacedBy(Spacing.m), modifier = Modifier.alpha(0.75f)) {
            val artists = picks.filter { it.isArtist }
            val albums = picks.filter { !it.isArtist }
            if (artists.isNotEmpty()) LazyRow(contentPadding = PaddingValues(horizontal = Spacing.l), horizontalArrangement = Arrangement.spacedBy(Spacing.l)) {
                items(artists, key = { it.listId }) { PickArtist(it, null, 100.dp) }
            }
            if (albums.isNotEmpty()) LazyRow(contentPadding = PaddingValues(horizontal = Spacing.l), horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
                items(albums, key = { it.listId }) { pick ->
                    var menu by remember { mutableStateOf(false) }
                    // Albums open at once: the Deezer or iTunes id needs no lookup.
                    Column(Modifier.width(130.dp).focusHighlight().combinedClickable(
                        onClick = { navigator.open(PublicAlbumRoute(pick.releaseId, pick.title, pick.year, pick.artist ?: "", null, pick.coverFile)) },
                        onLongClick = { menu = true },
                    )) {
                        Artwork(pick.cover, Modifier.fillMaxWidth().aspectRatio(1f), RoundedCornerShape(12.dp))
                        Text(pick.title, style = MaterialTheme.typography.titleSmall, maxLines = 1, modifier = Modifier.padding(top = Spacing.s))
                        Text(pick.artist ?: "", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                            WishlistMenuItem(WishItem.album(pick.artist ?: "", pick.title, pick.sourceId ?: pick.mbid.ifEmpty { null }, pick.cover)) { menu = false }
                        }
                    }
                }
            }
            // Songs you do not have, left-aligned: tap to see the album they are on, long-press for the wishlist.
            songs.forEach { song ->
                var menu by remember(song.id) { mutableStateOf(false) }
                Row(Modifier.fillMaxWidth().combinedClickable(
                    onClick = {
                        openOutsideAlbum(navigator, scope_, song.artist, song.album ?: song.title, song.albumSourceId, song.albumCover)
                    },
                    onLongClick = { menu = true },
                ).padding(horizontal = Spacing.l), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(song.title, maxLines = 1)
                        Text(listOfNotNull(song.artist.ifEmpty { null }, song.album).joinToString(", "), style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                    }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        WishlistMenuItem(WishItem.song(song.artist, song.title, song.album, song.albumSourceId, song.albumCover)) { menu = false }
                    }
                }
            }
        }
    }
}
