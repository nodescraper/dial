package app.dial.tv

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.dial.data.ArtistNames
import app.dial.data.LibraryStats
import app.dial.data.LibraryStatsEngine
import app.dial.data.StatEntry
import app.dial.data.Wishlist
import coil3.compose.AsyncImage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** The artist of a song you own, for the wishlist. */
fun wishArtistOf(song: app.dial.data.Item) =
    ArtistNames.primary(song.artists?.firstOrNull() ?: song.artistLine)

/** Albums and songs you want but don't have, newest first. Tap a row's button to remove it. */
@Composable
fun TvWishlist() {
    val client = tvClient()
    val items by Wishlist.items.collectAsState()
    val scope = rememberCoroutineScope()
    LaunchedEffect(client) { client?.let { Wishlist.refresh(it) } }
    if (items.isEmpty()) {
        Text("Nothing here yet.", style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = Tv.marginX))
        return
    }
    LazyColumn(contentPadding = PaddingValues(start = Tv.marginX, end = Tv.marginX, top = 6.dp, bottom = 32.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp)) {
        items(items, key = { it.id }) { item ->
            val shape = RoundedCornerShape(Tv.radius)
            Row(Modifier.fillMaxWidth().tvFocus(shape).clip(shape).padding(horizontal = 8.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically) {
                AsyncImage(item.coverUrl, null, Modifier.size(56.dp).clip(RoundedCornerShape(8.dp)), contentScale = ContentScale.Crop)
                Column(Modifier.weight(1f).padding(horizontal = 14.dp)) {
                    Text(item.title, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(if (item.isAlbum) item.artist else "Song · ${item.artist}",
                        style = MaterialTheme.typography.labelMedium, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                TvButton("Remove", primary = false) {
                    scope.launch { client?.let { Wishlist.remove(item.id, it) } }
                }
            }
        }
    }
}

/** Your library in numbers, read-only: size, quality, eras, biggest artists and what's missing. */
@Composable
fun TvStats() {
    val client = tvClient()
    val nav = LocalTvNav.current
    var stats by remember { mutableStateOf<LibraryStats?>(null) }
    var failed by remember { mutableStateOf(false) }
    LaunchedEffect(client) {
        val made = client?.let { withContext(Dispatchers.IO) { LibraryStatsEngine.make(it) } }
        stats = made
        failed = made == null
    }
    val current = stats
    Column(Modifier.fillMaxSize().padding(horizontal = Tv.marginX)) {
        Text("Library Stats", style = MaterialTheme.typography.displayMedium, modifier = Modifier.padding(bottom = 12.dp))
        when {
            current == null && !failed -> Text("Counting your library…", style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            current == null || current.isEmpty -> Text(if (failed) "Couldn't read your library." else "No music yet.",
                style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            else -> LazyColumn(contentPadding = PaddingValues(bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(22.dp)) {
                item {
                    StatSection("Size") {
                        StatFact("${current.songs} songs", "${current.albums} albums · ${current.artists} artists")
                        StatFact("${current.hours} hours", "of music, back to back")
                    }
                }
                item {
                    StatSection("Quality") {
                        StatFact("${current.losslessShare}% lossless", "${current.hiRes} songs in hi-res")
                        current.formats.take(4).forEach { StatFact("${it.value} songs", it.name) }
                        current.weakestAlbums.take(3).forEach { StatRow(it, "Weakest") { openStat(nav, it) } }
                    }
                }
                if (current.decades.isNotEmpty() || current.genres.isNotEmpty()) item {
                    StatSection("Eras and Genres") {
                        current.decades.take(6).forEach { StatFact("${it.value} songs", it.name) }
                        current.genres.take(6).forEach { StatFact("${it.value} songs", it.name) }
                    }
                }
                if (current.topArtists.isNotEmpty()) item {
                    StatSection("Biggest Artists") {
                        current.topArtists.take(8).forEach { StatRow(it, null) { openStat(nav, it) } }
                    }
                }
                item {
                    StatSection("Unplayed") {
                        StatFact("${current.unplayedSongs} songs (${current.unplayedShare}%)", "never played")
                        StatFact("${current.unplayedAlbums} albums", "never played all the way through")
                        current.unplayedAlbumList.take(5).forEach { StatRow(it, null) { openStat(nav, it) } }
                    }
                }
                if (current.problemAlbumCount > 0 || current.noCover > 0 || current.noYear > 0) item {
                    StatSection("Missing") {
                        if (current.noCover > 0) StatFact("${current.noCover} albums", "have no cover")
                        if (current.noYear > 0) StatFact("${current.noYear} albums", "have no year")
                        current.problemAlbums.take(5).forEach { StatRow(it, null) { openStat(nav, it) } }
                    }
                }
            }
        }
    }
}

private fun openStat(nav: TvNav, entry: StatEntry) {
    val id = entry.routeId?.ifEmpty { return } ?: return
    if (entry.routeKind == "artist") nav.open(TvRoute.Artist(id, entry.routeName))
    else nav.open(TvRoute.Album(id, entry.routeName))
}

@Composable
private fun StatSection(title: String, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, style = MaterialTheme.typography.headlineMedium)
        content()
    }
}

@Composable
private fun StatFact(value: String, label: String) {
    Column(Modifier.padding(vertical = 2.dp)) {
        Text(value, style = MaterialTheme.typography.titleLarge)
        Text(label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun StatRow(entry: StatEntry, badge: String?, onClick: () -> Unit) {
    val shape = RoundedCornerShape(Tv.radius)
    val enabled = !entry.routeId.isNullOrEmpty()
    Row(Modifier.fillMaxWidth().tvFocus(shape).clip(shape)
        .clickable(enabled = enabled, onClick = onClick).padding(horizontal = 8.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        if (entry.imageItemId != null) {
            AsyncImage(tvClient()?.imageUrl(entry.imageItemId, 160), null,
                Modifier.size(48.dp).clip(RoundedCornerShape(8.dp)), contentScale = ContentScale.Crop)
        }
        Column(Modifier.weight(1f)) {
            Text(entry.name, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (entry.detail.isNotEmpty()) Text(entry.detail, style = MaterialTheme.typography.labelMedium, maxLines = 1,
                overflow = TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (badge != null) Text(badge, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        else if (entry.value > 0) Text("${entry.value}", style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

