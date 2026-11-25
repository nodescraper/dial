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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Shuffle
import androidx.compose.material3.Button
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.dial.data.MixCatalog
import app.dial.data.Mixtape
import app.dial.data.Item
import app.dial.ui.LocalApp
import app.dial.ui.LocalNavigator
import app.dial.ui.MixtapeRoute
import app.dial.ui.components.Artwork
import app.dial.ui.components.SongRow
import app.dial.ui.components.Spacing
import app.dial.ui.components.focusHighlight
import app.dial.ui.songActions

private fun hex(value: String): Color = runCatching { Color(android.graphics.Color.parseColor(value)) }.getOrDefault(Color.DarkGray)

/** Four album covers under a color wash with a bold title: mixtapes, decades and genres all look like this. */
/** A mixtape's cover: a decade is a poster of its era, a genre has its own colors and symbol, the rest are collages. */
@Composable
fun MixtapeCover(mixtape: Mixtape, modifier: Modifier = Modifier, titleSize: Int = 20) {
    val decade = if (mixtape.id.startsWith("decade-")) mixtape.id.removePrefix("decade-").toIntOrNull() else null
    when {
        decade != null -> app.dial.ui.components.EraCover(decade, modifier)
        mixtape.id.startsWith("genre-") -> app.dial.ui.components.GenreCover(mixtape.title, mixtape.palette, modifier)
        else -> CollageCover(mixtape.title, mixtape.covers, mixtape.palette, modifier, titleSize)
    }
}

@Composable
fun CollageCover(title: String, covers: List<String>, palette: List<String>, modifier: Modifier = Modifier,
                 titleSize: Int = 20) {
    val client = app.dial.ui.screens.client()
    val colors = palette.map(::hex).ifEmpty { listOf(Color.DarkGray, Color.Black) }
    Box(modifier.aspectRatio(1f).clip(RoundedCornerShape(12.dp))) {
        Column(Modifier.fillMaxSize()) {
            for (row in 0..1) Row(Modifier.weight(1f)) {
                for (column in 0..1) {
                    val id = covers.getOrNull((row * 2 + column) % maxOf(covers.size, 1))
                    Box(Modifier.weight(1f).fillMaxSize()) {
                        if (id != null) Artwork(client?.imageUrl(id, 300), Modifier.fillMaxSize(), RoundedCornerShape(0.dp))
                    }
                }
            }
        }
        Box(Modifier.fillMaxSize().background(Brush.linearGradient(colors.map { it.copy(alpha = 0.82f) })))
        Text(title, color = Color.White, fontSize = titleSize.sp, fontWeight = FontWeight.ExtraBold, maxLines = 3,
            overflow = TextOverflow.Ellipsis, modifier = Modifier.align(Alignment.BottomStart).padding(Spacing.m))
    }
}

/** A mixtape on a shelf: the collage, then what it is. */
@Composable
fun MixtapeTile(mixtape: Mixtape, width: Dp = 150.dp) {
    val navigator = LocalNavigator.current
    Column(Modifier.width(width).focusHighlight(RoundedCornerShape(12.dp)).clickable { navigator.open(MixtapeRoute(mixtape.id)) }) {
        MixtapeCover(mixtape, Modifier.fillMaxWidth())
        Text(mixtape.subtitle, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
            color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = Spacing.xs))
    }
}

/** The songs of a mixtape, picked fresh each time you open it, with Play and Shuffle. */
@Composable
fun MixtapeScreen(id: String) {
    val app = LocalApp.current
    val client = client()
    val actions = songActions()
    val playback by app.player.state.collectAsState()
    val sections = MixCatalog.latest
    val mixtape = remember(id) {
        sections?.let { listOf(it.daily, it.decades, it.genres).flatten().firstOrNull { m -> m.id == id } }
    }
    if (mixtape == null) { EmptyOrBack("This mixtape is no longer available."); return }
    var songs by remember(id) { mutableStateOf<List<Item>?>(null) }
    LaunchedEffect(id) {
        val c = app.session.client.value ?: return@LaunchedEffect
        // The daily mixes are fixed for the day; decades and genres are looked up now.
        if (mixtape.tracks.isNotEmpty()) { songs = mixtape.tracks.filter { !app.library.isHidden(it.id) }; return@LaunchedEffect }
        val muse = runCatching { c.audioMuseCanSearch() }.getOrDefault(false)
        songs = MixCatalog.songs(mixtape.recipe, c, muse) { app.library.isHidden(it) }
    }
    Column(Modifier.fillMaxSize()) {
        PageTopBar(mixtape.title)
        LazyColumn(contentPadding = PaddingValues(bottom = Spacing.section)) {
            item {
                Column(Modifier.fillMaxWidth().padding(Spacing.l), horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
                    MixtapeCover(mixtape, Modifier.width(260.dp), titleSize = 30)
                    Text(mixtape.subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(songs?.let { "${it.size} songs from your library" } ?: "Picking songs…",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Row(horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
                        Button(onClick = { songs?.let { app.player.play(it) } }, enabled = !songs.isNullOrEmpty()) {
                            Icon(Icons.Rounded.PlayArrow, null); Spacer(Modifier.width(Spacing.xs)); Text("Play")
                        }
                        FilledTonalButton(onClick = { songs?.let { app.player.play(it, shuffle = true) } }, enabled = !songs.isNullOrEmpty()) {
                            Icon(Icons.Rounded.Shuffle, null); Spacer(Modifier.width(Spacing.xs)); Text("Shuffle")
                        }
                    }
                }
            }
            songs?.let { list ->
                itemsIndexed(list, key = { _, s -> s.id }) { index, song ->
                    SongRow(song, client?.imageUrl(song.imageItemId, 160), playback.current?.id == song.id,
                        onClick = { app.player.play(list, index) }, actions = actions)
                }
            }
        }
    }
}

@Composable
private fun EmptyOrBack(message: String) {
    Column(Modifier.fillMaxSize()) {
        PageTopBar("Mixtape")
        app.dial.ui.components.EmptyMessage("Not here", message)
    }
}
