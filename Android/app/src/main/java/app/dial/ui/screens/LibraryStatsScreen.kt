package app.dial.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Error
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.dial.data.LibraryStats
import app.dial.data.LibraryStatsEngine
import app.dial.data.StatEntry
import app.dial.ui.AlbumRoute
import app.dial.ui.ArtistRoute
import app.dial.ui.LocalNavigator
import app.dial.ui.components.Artwork
import app.dial.ui.components.EmptyMessage
import app.dial.ui.components.Loading
import app.dial.ui.components.Spacing
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * Your library in numbers, as big cards: size, growth, quality, eras and genres, biggest artists,
 * what you've never played, and what's missing. The same numbers as iOS LibraryStatsView.
 */
@Composable
fun LibraryStatsScreen() {
    val load = rememberLoad(Unit) { LibraryStatsEngine.make(it) }
    Column(Modifier.fillMaxSize()) {
        PageTopBar("Library Stats")
        when (load) {
            Load.Loading -> Loading()
            is Load.Failed -> EmptyMessage("Couldn't load this", load.message)
            is Load.Ready -> {
                val stats = load.value
                if (stats == null || stats.isEmpty) {
                    EmptyMessage("No music yet", "Once your server has music, its numbers show up here.")
                } else {
                    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(Spacing.l),
                        verticalArrangement = Arrangement.spacedBy(Spacing.l)) {
                        item { TotalsCard(stats) }
                        item { GrowthCard(stats) }
                        item { QualityCard(stats) }
                        if (stats.decades.isNotEmpty() || stats.genres.isNotEmpty()) item { ErasCard(stats) }
                        if (stats.topArtists.isNotEmpty()) item { BiggestArtistsCard(stats) }
                        item { UnplayedCard(stats) }
                        item { HealthCard(stats) }
                    }
                }
            }
        }
    }
}

// MARK: - Cards

private val Dim = Color.White.copy(alpha = 0.75f)

/** A big rounded card with a color wash and white text, like Your Stats on iPhone. */
@Composable
private fun StatCard(colors: List<Color>, content: @Composable () -> Unit) {
    Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp))
        .background(Brush.linearGradient(colors)).padding(Spacing.l)) {
        Column(verticalArrangement = Arrangement.spacedBy(Spacing.s)) { content() }
    }
}

@Composable
private fun CardTitle(text: String) {
    Text(text.uppercase(), style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Bold, color = Dim)
}

/** A number with a word under it, in a row of facts. */
@Composable
private fun Fact(value: String, label: String) {
    Column {
        Text(value, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = Color.White)
        Text(label, style = MaterialTheme.typography.bodySmall, color = Dim)
    }
}

@Composable
private fun TotalsCard(stats: LibraryStats) {
    val context = androidx.compose.ui.platform.LocalContext.current
    StatCard(listOf(Color(0xFFE0568A), Color(0xFFB84A33))) {
        CardTitle("Your Library")
        Text(formatNumber(stats.hours.toLong()) + " hours", style = MaterialTheme.typography.displayMedium,
            fontWeight = FontWeight.ExtraBold, color = Color.White, maxLines = 1)
        val days = stats.seconds / 86400
        Text(if (days >= 1) "That's ${if (days >= 10) "%.0f".format(days) else "%.1f".format(days)} days of music back to back"
            else "of music, back to back", style = MaterialTheme.typography.titleMedium, color = Color.White)
        Row(horizontalArrangement = Arrangement.spacedBy(Spacing.xl)) {
            Fact(formatNumber(stats.songs.toLong()), "songs")
            Fact(formatNumber(stats.albums.toLong()), "albums")
            Fact(formatNumber(stats.artists.toLong()), "artists")
            if (stats.bytes > 0) Fact(android.text.format.Formatter.formatShortFileSize(context, stats.bytes), "on disk")
        }
    }
}

@Composable
private fun GrowthCard(stats: LibraryStats) {
    StatCard(listOf(Color(0xFF27925A), Color(0xFF0D4033))) {
        CardTitle("How It Grew")
        Text("+${formatNumber(stats.addedThisMonth.toLong())} songs", style = MaterialTheme.typography.displaySmall,
            fontWeight = FontWeight.ExtraBold, color = Color.White)
        Text("added this month", style = MaterialTheme.typography.bodyMedium, color = Dim)
        if (stats.addedByMonth.any { it.value > 0 }) MonthBars(stats.addedByMonth)
        Row(horizontalArrangement = Arrangement.spacedBy(Spacing.xl)) {
            stats.biggestMonth?.let { Fact(it.name, "biggest month, ${it.value} songs") }
            stats.firstAdded?.let {
                val month = it.atZone(ZoneId.systemDefault())
                    .format(DateTimeFormatter.ofPattern("MMM yyyy", Locale.getDefault()))
                Fact(month, "collecting since")
            }
        }
    }
}

@Composable
private fun QualityCard(stats: LibraryStats) {
    StatCard(listOf(Color(0xFF1A7373), Color(0xFF263359))) {
        CardTitle("Sound Quality")
        Text("${stats.losslessShare}% lossless", style = MaterialTheme.typography.displaySmall,
            fontWeight = FontWeight.ExtraBold, color = Color.White)
        Text(if (stats.hiRes > 0) "${formatNumber(stats.lossless.toLong())} songs, ${formatNumber(stats.hiRes.toLong())} of them hi-res"
            else "${formatNumber(stats.lossless.toLong())} of ${formatNumber(stats.songs.toLong())} songs",
            style = MaterialTheme.typography.bodyMedium, color = Dim)
        LazyRow(horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
            items(stats.formats, key = { it.id }) { format ->
                Surface(shape = RoundedCornerShape(20.dp), color = Color.White.copy(alpha = 0.18f)) {
                    Text("${format.name}  ${formatNumber(format.value.toLong())}", color = Color.White,
                        style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.padding(horizontal = Spacing.m, vertical = Spacing.s))
                }
            }
        }
        if (stats.bitrates.any { it.value > 0 }) {
            Text("Compressed songs by bitrate", style = MaterialTheme.typography.bodyMedium, color = Dim)
            HBars(stats.bitrates, stats.bitrates.lastOrNull()?.id)
        }
        if (stats.weakestAlbums.isNotEmpty()) {
            Text("Weakest albums, worth fetching again", style = MaterialTheme.typography.bodyMedium, color = Dim)
            AlbumRows(stats.weakestAlbums)
        }
    }
}

@Composable
private fun ErasCard(stats: LibraryStats) {
    StatCard(listOf(Color(0xFF593399), Color(0xFF261A4D))) {
        CardTitle("Eras and Genres")
        val top = stats.decades.maxByOrNull { it.value }
        if (top != null && stats.decades.isNotEmpty()) {
            Text("Mostly the ${top.name}", style = MaterialTheme.typography.headlineMedium,
                fontWeight = FontWeight.ExtraBold, color = Color.White)
            HBars(stats.decades, top.id)
        }
        if (stats.genres.isNotEmpty()) {
            Text("Top genres, by songs", style = MaterialTheme.typography.bodyMedium, color = Dim)
            HBars(stats.genres, stats.genres.firstOrNull()?.id)
        }
    }
}

@Composable
private fun BiggestArtistsCard(stats: LibraryStats) {
    val navigator = LocalNavigator.current
    val client = client()
    StatCard(listOf(Color(0xFF992626), Color(0xFF4D142E))) {
        CardTitle("Biggest Artists")
        stats.topArtists.forEachIndexed { index, artist ->
            Row(Modifier.fillMaxWidth().clickable(enabled = artist.routeId != null) {
                artist.routeId?.let { navigator.open(ArtistRoute(it, artist.routeName)) }
            }.padding(vertical = Spacing.xs), verticalAlignment = Alignment.CenterVertically) {
                Text("${index + 1}", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.ExtraBold,
                    color = Color.White, modifier = Modifier.width(28.dp))
                Artwork(client?.imageUrl(artist.imageItemId ?: "", 160), Modifier.size(48.dp), CircleShape,
                    placeholder = androidx.compose.material.icons.Icons.Rounded.MusicNote)
                Column(Modifier.weight(1f).padding(start = Spacing.m)) {
                    Text(artist.name, style = MaterialTheme.typography.titleMedium, color = Color.White,
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text("${artist.value} songs, ${artist.detail}", style = MaterialTheme.typography.bodyMedium,
                        color = Dim, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}

@Composable
private fun UnplayedCard(stats: LibraryStats) {
    StatCard(listOf(Color(0xFF141A40), Color(0xFF403380))) {
        CardTitle("Never Played")
        Text("${stats.unplayedShare}%", style = MaterialTheme.typography.displayMedium,
            fontWeight = FontWeight.ExtraBold, color = Color.White)
        Text(if (stats.unplayedSongs == 0) "You've played every song you have."
            else "of your songs you've never played: ${formatNumber(stats.unplayedSongs.toLong())} songs, ${stats.unplayedAlbums} whole albums",
            style = MaterialTheme.typography.bodyMedium, color = Dim)
        if (stats.unplayedAlbumList.isNotEmpty()) {
            Text("Waiting for you", style = MaterialTheme.typography.bodyMedium, color = Dim)
            AlbumRows(stats.unplayedAlbumList)
        }
    }
}

@Composable
private fun HealthCard(stats: LibraryStats) {
    StatCard(listOf(Color(0xFF33333D), Color(0xFF141419))) {
        CardTitle("Library Health")
        Text(when (stats.problemAlbumCount) {
            0 -> "All in order"
            1 -> "1 album needs a look"
            else -> "${stats.problemAlbumCount} albums need a look"
        }, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.ExtraBold, color = Color.White)
        HealthCheck(stats.noCover, "albums without a cover")
        HealthCheck(stats.noYear, "albums without a year")
        HealthCheck(stats.noGenre, "albums without a genre")
        HealthCheck(stats.songsWithoutMusicBrainz, "songs without a MusicBrainz ID")
        if (stats.problemAlbums.isNotEmpty()) AlbumRows(stats.problemAlbums)
    }
}

@Composable
private fun HealthCheck(count: Int, label: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
        androidx.compose.material3.Icon(if (count == 0) Icons.Rounded.CheckCircle else Icons.Rounded.Error, null,
            tint = if (count == 0) Color(0xFF4CAF50) else Color(0xFFFF9800), modifier = Modifier.size(20.dp))
        Text(if (count == 0) "No $label" else "${formatNumber(count.toLong())} $label",
            style = MaterialTheme.typography.bodyMedium, color = Color.White)
    }
}

// MARK: - Pieces

/** Labeled horizontal bars with their counts. */
@Composable
private fun HBars(entries: List<StatEntry>, highlight: String?) {
    val max = (entries.maxOfOrNull { it.value } ?: 0).coerceAtLeast(1)
    Column(verticalArrangement = Arrangement.spacedBy(Spacing.xs)) {
        entries.forEach { entry ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(entry.name, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold,
                    color = Color.White, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                Box(Modifier.weight(1.2f).height(10.dp).clip(RoundedCornerShape(5.dp))
                    .background(Color.White.copy(alpha = 0.2f))) {
                    Box(Modifier.fillMaxWidth(entry.value.toFloat() / max).height(10.dp).clip(RoundedCornerShape(5.dp))
                        .background(if (entry.id == highlight) Color(0xFFE0568A) else Color.White.copy(alpha = 0.55f)))
                }
                Text(formatNumber(entry.value.toLong()), style = MaterialTheme.typography.bodySmall, color = Dim,
                    modifier = Modifier.width(48.dp), textAlign = androidx.compose.ui.text.style.TextAlign.End)
            }
        }
    }
}

/** Songs added in each of the last 12 months, oldest first. */
@Composable
private fun MonthBars(months: List<StatEntry>) {
    val max = (months.maxOfOrNull { it.value } ?: 0).coerceAtLeast(1)
    Row(Modifier.fillMaxWidth().height(110.dp), horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.Bottom) {
        months.forEachIndexed { i, month ->
            Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Bottom) {
                Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.BottomCenter) {
                    Box(Modifier.fillMaxWidth()
                        .height((96 * month.value.toFloat() / max).coerceAtLeast(if (month.value > 0) 4f else 0f).dp)
                        .clip(RoundedCornerShape(3.dp))
                        .background(if (month.value == max && max > 0) Color.White else Color.White.copy(alpha = 0.4f)))
                }
                // Every third month, like iOS.
                Text(if (i % 3 == 2) month.name else "", style = MaterialTheme.typography.labelSmall, color = Dim, maxLines = 1)
            }
        }
    }
}

/** Rows of albums with their cover and a line under the name; tap to open the album. */
@Composable
private fun AlbumRows(entries: List<StatEntry>) {
    val navigator = LocalNavigator.current
    val client = client()
    Column {
        entries.forEach { album ->
            Row(Modifier.fillMaxWidth().clickable(enabled = album.routeId != null) {
                album.routeId?.let { navigator.open(AlbumRoute(it, album.routeName)) }
            }.padding(vertical = Spacing.xs), verticalAlignment = Alignment.CenterVertically) {
                Artwork(client?.imageUrl(album.imageItemId ?: album.id, 160), Modifier.size(48.dp), RoundedCornerShape(8.dp))
                Column(Modifier.weight(1f).padding(start = Spacing.m)) {
                    Text(album.name, style = MaterialTheme.typography.titleMedium, color = Color.White,
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(album.detail, style = MaterialTheme.typography.bodyMedium, color = Dim,
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}

private fun formatNumber(value: Long): String = java.text.NumberFormat.getInstance(Locale.getDefault()).format(value)
