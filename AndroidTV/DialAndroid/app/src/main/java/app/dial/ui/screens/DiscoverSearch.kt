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
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
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
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.dial.data.ArtistNames
import app.dial.data.Item
import app.dial.data.LibraryMatcher
import app.dial.data.PublicMusic
import app.dial.data.musicBrainzId
import app.dial.ui.AlbumRoute
import app.dial.ui.ArtistRoute
import app.dial.ui.LocalApp
import app.dial.ui.LocalNavigator
import app.dial.ui.PublicAlbumRoute
import app.dial.ui.components.ArtistShape
import app.dial.ui.components.Artwork
import app.dial.ui.components.SectionTitle
import app.dial.ui.components.Spacing
import app.dial.ui.components.bold
import app.dial.ui.components.focusHighlight
import kotlinx.serialization.Serializable

/** An artist you don't have, from MusicBrainz: photo and discography. */
@Serializable data class ArtistPreviewRoute(val mbid: String, val name: String)
@Serializable data class ExploreGenreRoute(val name: String)

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
        else Text(title, style = MaterialTheme.typography.titleLarge.bold())
        subtitle?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
}

@Composable
internal fun ArtistRow(title: String, subtitle: String?, picks: List<PublicMusic.Pick>, owned: Owned, light: Boolean = false) {
    Column(verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        Header(title, subtitle, light)
        LazyRow(contentPadding = PaddingValues(horizontal = Spacing.l), horizontalArrangement = Arrangement.spacedBy(Spacing.l)) {
            items(picks, key = { it.mbid }) { pick -> PickArtist(pick, owned.artist(pick), 116.dp) }
        }
    }
}

@Composable
internal fun AlbumRow(title: String, subtitle: String?, picks: List<PublicMusic.Pick>, owned: Owned) {
    Column(verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        Header(title, subtitle)
        LazyRow(contentPadding = PaddingValues(horizontal = Spacing.l), horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
            items(picks, key = { it.mbid }) { pick -> PickAlbum(pick, owned.album(pick), owned.artistOf(pick)) }
        }
    }
}

@Composable
fun PickArtistTile(pick: PublicMusic.Pick, owned: Item?, width: androidx.compose.ui.unit.Dp) = PickArtist(pick, owned, width)

@Composable
private fun PickArtist(pick: PublicMusic.Pick, owned: Item?, width: androidx.compose.ui.unit.Dp) {
    val navigator = LocalNavigator.current
    val client = client()
    var photo by remember(pick.mbid) { mutableStateOf<String?>(null) }
    LaunchedEffect(pick.mbid) { if (owned == null && pick.image == null) photo = PublicMusic.artistImage(pick.mbid, pick.title) }
    Column(Modifier.width(width).focusHighlight(ArtistShape).clickable {
        navigator.open(owned?.let { ArtistRoute(it.id, it.name) } ?: ArtistPreviewRoute(pick.mbid, pick.title))
    }, horizontalAlignment = Alignment.CenterHorizontally) {
        Artwork(if (owned != null) client?.imageUrl(owned.id) else pick.image ?: photo, Modifier.fillMaxWidth().aspectRatio(1f), ArtistShape, Icons.Rounded.Person)
        Text(pick.title, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center, modifier = Modifier.padding(top = Spacing.s))
        Text(if (owned != null) "In your library" else "New to you", style = MaterialTheme.typography.labelSmall,
            color = if (owned != null) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.primary)
    }
}

@Composable
private fun PickAlbum(pick: PublicMusic.Pick, owned: Item?, ownedArtist: Item?) {
    val navigator = LocalNavigator.current
    val client = client()
    Column(Modifier.width(150.dp).focusHighlight().clickable {
        navigator.open(owned?.let { AlbumRoute(it.id, it.name) }
            ?: PublicAlbumRoute(pick.mbid, pick.title, pick.year, pick.artist ?: "", ownedArtist?.id))
    }) {
        Artwork(if (owned != null) client?.imageUrl(owned.id) else pick.cover, Modifier.fillMaxWidth().aspectRatio(1f), RoundedCornerShape(16.dp))
        Text(pick.title, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = Spacing.s))
        Text(if (owned != null) "In your library" else pick.artist ?: "", style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
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
    var photo by remember(route.mbid) { mutableStateOf<String?>(null) }
    LaunchedEffect(route.mbid) { photo = PublicMusic.artistImage(route.mbid, route.name) }
    val load = rememberLoad(route.mbid) { PublicMusic.discography(route.mbid).filter { it.kind == "album" } }
    Column(Modifier.fillMaxSize()) {
        PageTopBar("")
        LazyVerticalGrid(GridCells.Adaptive(150.dp), contentPadding = PaddingValues(Spacing.l),
            horizontalArrangement = Arrangement.spacedBy(Spacing.m), verticalArrangement = Arrangement.spacedBy(Spacing.l)) {
            item(span = { androidx.compose.foundation.lazy.grid.GridItemSpan(maxLineSpan) }) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
                    Artwork(photo, Modifier.size(200.dp), ArtistShape, Icons.Rounded.Person)
                    Text(route.name, style = MaterialTheme.typography.headlineMedium.bold(), modifier = Modifier.padding(top = Spacing.m))
                    Text("Not in your library", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
                    Spacer(Modifier.height(Spacing.m))
                }
            }
            (load as? Load.Ready)?.value?.let { albums ->
                items(albums, key = { it.id }) { release ->
                    Column(Modifier.focusHighlight().clickable {
                        navigator.open(PublicAlbumRoute(release.id, release.title, release.year, route.name, null))
                    }) {
                        Artwork(release.cover, Modifier.fillMaxWidth().aspectRatio(1f), RoundedCornerShape(16.dp))
                        Text(release.title, style = MaterialTheme.typography.titleSmall, maxLines = 1, modifier = Modifier.padding(top = Spacing.s))
                        release.year?.let { Text("$it", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                    }
                }
            }
        }
    }
}

/** While typing: artists and albums from MusicBrainz beyond your library, faded. */
@Composable
fun BeyondLibrary(term: String, libraryNames: Set<String>) {
    val navigator = LocalNavigator.current
    var picks by remember { mutableStateOf<List<PublicMusic.Pick>>(emptyList()) }
    LaunchedEffect(term) {
        picks = emptyList()
        if (term.length < 3) return@LaunchedEffect
        kotlinx.coroutines.delay(500)
        picks = PublicMusic.search(term).filter { LibraryMatcher.key(it.title) !in libraryNames }
    }
    if (picks.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(Spacing.m), modifier = Modifier.alpha(0.75f)) {
        SectionTitle("Beyond Your Library")
        val artists = picks.filter { it.isArtist }
        val albums = picks.filter { !it.isArtist }
        if (artists.isNotEmpty()) LazyRow(contentPadding = PaddingValues(horizontal = Spacing.l), horizontalArrangement = Arrangement.spacedBy(Spacing.l)) {
            items(artists, key = { it.mbid }) { PickArtist(it, null, 100.dp) }
        }
        if (albums.isNotEmpty()) LazyRow(contentPadding = PaddingValues(horizontal = Spacing.l), horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
            items(albums, key = { it.mbid }) { pick ->
                Column(Modifier.width(130.dp).focusHighlight().clickable {
                    navigator.open(PublicAlbumRoute(pick.mbid, pick.title, pick.year, pick.artist ?: "", null))
                }) {
                    Artwork(pick.cover, Modifier.fillMaxWidth().aspectRatio(1f), RoundedCornerShape(14.dp))
                    Text(pick.title, style = MaterialTheme.typography.titleSmall, maxLines = 1, modifier = Modifier.padding(top = Spacing.s))
                    Text(pick.artist ?: "", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                }
            }
        }
    }
}
