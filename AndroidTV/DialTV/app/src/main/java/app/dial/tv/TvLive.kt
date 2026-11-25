package app.dial.tv

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Sensors
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.dial.data.RadioBrowser
import app.dial.data.YouTubeLive
import app.dial.data.Station
import coil3.compose.SubcomposeAsyncImage

/** Live radio categories, the same set as on iPhone and Mac: a name, the Radio Browser tag, and two colors. */
class LiveCategory(val title: String, val tag: String, val from: Color, val to: Color)

val liveCategories = listOf(
    LiveCategory("Christmas", "christmas", Color(0xFF8C1420), Color(0xFF1F7340)),
    LiveCategory("Lo-fi", "lofi", Color(0xFF8C3380), Color(0xFFF28066)),
    LiveCategory("Jazz", "jazz", Color(0xFF264D99), Color(0xFF59BFD9)),
    LiveCategory("Chill", "chillout", Color(0xFF26665A), Color(0xFF99D98C)),
    LiveCategory("Ambient", "ambient", Color(0xFF333366), Color(0xFF8C73D9)),
    LiveCategory("Classical", "classical", Color(0xFF80592A), Color(0xFFD9BF80)),
    LiveCategory("Hip-Hop", "hip hop", Color(0xFF592633), Color(0xFFD95966)),
    LiveCategory("Pop", "pop", Color(0xFF99401A), Color(0xFFF2B24D)),
    LiveCategory("Rock", "rock", Color(0xFF2B1A1A), Color(0xFFC2412D)),
    LiveCategory("Dance", "dance", Color(0xFF1F4D73), Color(0xFFE8742C)),
    LiveCategory("News", "news", Color(0xFF3C3C46), Color(0xFF9AA7B8)),
    LiveCategory("80s", "80s", Color(0xFF8C2680), Color(0xFF4073E6)),
)

/** A category as a gradient square with its name. */
@Composable
fun TvCategoryCard(category: LiveCategory, onClick: () -> Unit) {
    val shape = RoundedCornerShape(Tv.radius)
    val stage = LocalTvStage.current
    Box(Modifier.width(Tv.coverWidth).aspectRatio(1f).tvFocus(shape) { stage.show(TvStage(category.title, "Live radio")) }.clip(shape).clickable(onClick = onClick)
        .background(Brush.linearGradient(listOf(category.from, category.to)))) {
        Text(category.title, style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.ExtraBold), color = Color.White,
            modifier = Modifier.align(Alignment.BottomStart).padding(10.dp))
        Icon(Icons.Rounded.Sensors, null, Modifier.align(Alignment.TopEnd).padding(10.dp).size(22.dp), tint = Color.White.copy(alpha = 0.6f))
    }
}

/** A station: its logo filling a rounded square, like an album cover. Only stations without a logo get the accent placeholder. */
@Composable
fun TvStationTile(station: Station, onClick: () -> Unit) {
    val shape = RoundedCornerShape(Tv.radius)
    val logo = station.favicon?.takeIf { it.isNotBlank() }
    val stage = LocalTvStage.current
    Column(Modifier.width(Tv.coverWidth)) {
        Box(Modifier.fillMaxWidth().aspectRatio(1f).tvFocus(shape) {
            stage.show(TvStage(station.name.trim(), listOfNotNull(station.country?.takeIf { it.isNotBlank() }, "Live radio").joinToString(" \u00b7 "), logo))
        }.clip(shape).clickable(onClick = onClick)) {
            @Composable fun placeholder() {
                Box(Modifier.fillMaxSize().background(Brush.linearGradient(listOf(Accent.copy(alpha = 0.55f), Accent.copy(alpha = 0.2f)))), contentAlignment = Alignment.Center) {
                    Icon(Icons.Rounded.Sensors, null, Modifier.size(34.dp), tint = Color.White.copy(alpha = 0.85f))
                }
            }
            if (logo == null) placeholder()
            else SubcomposeAsyncImage(logo, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop,
                loading = { placeholder() }, error = { placeholder() })
        }
        Text(station.name.trim(), style = MaterialTheme.typography.labelLarge, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 8.dp))
        Text(listOfNotNull(station.country?.takeIf { it.isNotBlank() }, station.bitrate?.takeIf { it > 0 }?.let { "$it kbps" }).joinToString(" \u00b7 "),
            style = MaterialTheme.typography.labelMedium, maxLines = 1, overflow = TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** The stations of one category, as a grid. */
@Composable
fun TvStations(tag: String, title: String) {
    val app = LocalTvApp.current
    val nav = LocalTvNav.current
    val stations = rememberTvLoad(tag) { RadioBrowser.byTag(tag).let { found -> if (tag == "lofi") YouTubeLive.stations() + found else found } }
    Column(Modifier.fillMaxSize()) {
        Text(title, style = MaterialTheme.typography.displayMedium, modifier = Modifier.padding(horizontal = Tv.marginX))
        Text("Live radio", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = Tv.marginX, vertical = 4.dp))
        when {
            stations == null -> Text("Finding stations…", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(Tv.marginX))
            stations.isEmpty() -> Text("No stations found.", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(Tv.marginX))
            else -> LazyVerticalGrid(columns = GridCells.Adaptive(Tv.coverWidth + 12.dp),
                contentPadding = PaddingValues(start = Tv.marginX, end = Tv.marginX, top = 12.dp, bottom = 32.dp),
                horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
                items(stations.size, key = { stations[it].id }) { i ->
                    TvStationTile(stations[i]) { TvRecents.live(stations[i]); app.player.playStation(stations[i]); nav.open(TvRoute.Player) }
                }
            }
        }
    }
}
