package app.dial.ui.screens

import app.dial.ui.components.OfflineCover
import app.dial.ui.LocalNavigator
import androidx.compose.foundation.layout.Spacer
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material.icons.rounded.Piano
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.rounded.Mic
import app.dial.data.MixSections
import app.dial.data.MixCatalog
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Bolt
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.NightsStay
import androidx.compose.material.icons.rounded.Psychology
import androidx.compose.material.icons.rounded.Spa
import androidx.compose.material.icons.rounded.Celebration
import androidx.compose.material.icons.rounded.Cloud
import androidx.compose.material.icons.rounded.WbSunny
import androidx.compose.material.icons.rounded.Sensors
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import app.dial.data.Item
import app.dial.ui.LocalApp
import app.dial.ui.components.ArtistTile
import app.dial.ui.components.SectionTitle
import app.dial.ui.components.Shelf
import app.dial.ui.components.Spacing
import app.dial.ui.components.black
import app.dial.ui.components.bold
import app.dial.ui.components.focusHighlight
import app.dial.data.ArtistNames
import app.dial.data.RadioBrowser
import app.dial.data.YouTubeLive
import app.dial.data.Station
import app.dial.ui.components.Artwork
import app.dial.ui.components.Loading
import kotlinx.coroutines.launch

/** Moods for AudioMuse's sound search, the same as on iPhone. */
private data class Mood(val title: String, val description: String, val icon: ImageVector, val from: Color, val to: Color)

private val moods = listOf(
    Mood("Chill", "relaxed chill laid back mellow", Icons.Rounded.Spa, Color(0xFF227870), Color(0xFF8FCC9E)),
    Mood("Focus", "calm instrumental ambient focus", Icons.Rounded.Psychology, Color(0xFF293D73), Color(0xFF6B8CCC)),
    Mood("Energy", "energetic upbeat powerful fast", Icons.Rounded.Bolt, Color(0xFFBF3333), Color(0xFFF29933)),
    Mood("Feel Good", "happy cheerful sunny feel good", Icons.Rounded.WbSunny, Color(0xFFF28C33), Color(0xFFF2CC59)),
    Mood("Party", "danceable party groove club", Icons.Rounded.Celebration, Color(0xFF8C2680), Color(0xFF4073E6)),
    Mood("Melancholy", "sad melancholic emotional slow", Icons.Rounded.Cloud, Color(0xFF333859), Color(0xFF737FA6)),
    Mood("Romantic", "romantic tender soulful love", Icons.Rounded.Favorite, Color(0xFF99264D), Color(0xFFE6737F)),
    Mood("Late Night", "late night dark smooth atmospheric", Icons.Rounded.NightsStay, Color(0xFF1A1A40), Color(0xFF664D99)),
)

private data class RadioData(val artists: List<Item>, val canSearchBySound: Boolean, val canYourSound: Boolean = false)

@Composable
fun RadioScreen() {
    val app = LocalApp.current
    val offline by app.connectivity.offline.collectAsState()
    if (offline) {
        val scope = androidx.compose.runtime.rememberCoroutineScope()
        OfflineCover("Tune In needs a connection",
            "Live radio, your mixes and the stations need your server or the internet. Your downloads are on Home.") { scope.launch { app.connectivity.check() } }
        return
    }
    val client = client()
    // Pulling the page down looks everything up again.
    var refreshKey by remember { mutableStateOf(0) }
    var refreshing by remember { mutableStateOf(false) }
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    val load = rememberLoad(refreshKey) { RadioData(it.randomArtists(12), it.audioMuseCanSearch(), it.audioMuseCanYourSound()) }
    // The mixtapes start with what was shown last time, then fill in (tags first, the sound-based moods last).
    var mixes by remember { mutableStateOf(MixCatalog.latest ?: MixSections()) }
    var mixesLoaded by remember { mutableStateOf(false) }
    androidx.compose.runtime.LaunchedEffect((load as? Load.Ready)?.value?.canSearchBySound, refreshKey) {
        val ready = (load as? Load.Ready)?.value ?: return@LaunchedEffect
        val c = app.session.client.value ?: return@LaunchedEffect
        MixCatalog.load(c, ready.canSearchBySound) { if (it != mixes) mixes = it }
        mixesLoaded = true
    }

    androidx.compose.material3.pulltorefresh.PullToRefreshBox(
        isRefreshing = refreshing,
        onRefresh = { refreshing = true; refreshKey++; scope.launch { kotlinx.coroutines.delay(1500); refreshing = false } },
    ) {
    LoadContent(load) { data ->
        LazyColumn(contentPadding = PaddingValues(bottom = Spacing.section), verticalArrangement = Arrangement.spacedBy(Spacing.section)) {
            item {
                Text("Tune In", style = MaterialTheme.typography.displaySmall.bold(),
                    modifier = Modifier.padding(start = Spacing.l, top = Spacing.l))
            }
            item {
                Shelf("Your Stations", listOf("mix", "favorites") + if (data.canYourSound) listOf("sound") else emptyList(), key = { it }) { which ->
                    when (which) {
                        "sound" -> StationTile("Your Sound", "Matches what you play most", Icons.Rounded.GraphicEq, Color(0xFF3A6FD8), Color(0xFF5B2A86)) {
                            app.player.play("Your Sound", radio = true) { c -> c.yourSound().shuffled() }
                        }
                        "mix" -> StationTile("Your Mix", "Your whole library", Icons.Rounded.Sensors, Color(0xFFE8742C), Color(0xFFA8401A)) {
                            app.player.play("Your Mix", radio = true) { c ->
                                val seed = c.randomSongs(1).firstOrNull() ?: return@play emptyList()
                                listOf(seed) + c.instantMix(seed.id, 30).filter { it.id != seed.id }
                            }
                        }
                        else -> StationTile("Favorites Mix", "Songs you love, and more like them", Icons.Rounded.Favorite,
                            Color(0xFFC2455E), Color(0xFF6E2A6E)) {
                            app.player.play("Favorites Mix", radio = true) { c ->
                                val seed = c.favoriteSongs().randomOrNull() ?: return@play emptyList()
                                listOf(seed) + c.instantMix(seed.id, 30).filter { it.id != seed.id }
                            }
                        }
                    }
                }
            }
            // Grey placeholder rows hold the places of the shelves still being made, so nothing below jumps.
            if (mixes.daily.isEmpty() && !mixesLoaded) item { ShelfPlaceholder("Made for You") }
            if (mixes.daily.isEmpty() && !mixesLoaded && data.canSearchBySound) item { ShelfPlaceholder("Mixtapes") }
            val madeForYou = mixes.daily.filter { !it.id.startsWith("daily-") }
            val moodTapes = mixes.daily.filter { it.id.startsWith("daily-") }
            if (madeForYou.isNotEmpty()) item { Shelf("Made for You", madeForYou, key = { it.id }) { MixtapeTile(it) } }
            if (moodTapes.isNotEmpty()) item { Shelf("Mixtapes", moodTapes, key = { it.id }) { MixtapeTile(it) } }
            if (mixes.decades.isEmpty() && !mixesLoaded) item { ShelfPlaceholder("Decades") }
            if (mixes.decades.isNotEmpty()) item { Shelf("Decades", mixes.decades, key = { it.id }) { MixtapeTile(it) } }
            if (mixes.genres.isEmpty() && !mixesLoaded) item { ShelfPlaceholder("Genres") }
            if (mixes.genres.isNotEmpty()) item { Shelf("Genres", mixes.genres, key = { it.id }) { MixtapeTile(it) } }
            if (data.artists.isNotEmpty()) {
                item {
                    Shelf("Artists", data.artists, key = { it.id }) { artist ->
                        ArtistTile(ArtistNames.primary(artist.name), client?.imageUrl(artist.id), 150.dp) {
                            app.player.startRadio(artist)
                        }
                    }
                }
            }
            item { LiveRadio() }
        }
    }
    }
}

@Composable
private fun ShelfPlaceholder(title: String) {
    Column(verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        SectionTitle(title)
        androidx.compose.foundation.lazy.LazyRow(contentPadding = PaddingValues(horizontal = Spacing.l),
            horizontalArrangement = Arrangement.spacedBy(Spacing.m), userScrollEnabled = false) {
            items(4) {
                Box(Modifier.width(150.dp).aspectRatio(1f).clip(RoundedCornerShape(12.dp)).background(MaterialTheme.colorScheme.surfaceContainerHigh))
            }
        }
    }
}

/** A station as a square tile with a symbol, the same size as a mixtape. */
@Composable
private fun StationTile(title: String, subtitle: String, icon: ImageVector, from: Color, to: Color, onClick: () -> Unit) {
    Column(Modifier.width(150.dp).focusHighlight(RoundedCornerShape(12.dp)).clickable(onClick = onClick)) {
        Box(Modifier.fillMaxWidth().aspectRatio(1f).clip(RoundedCornerShape(12.dp))
            .background(Brush.linearGradient(listOf(from, to))), contentAlignment = Alignment.Center) {
            Icon(icon, null, tint = Color.White.copy(alpha = 0.9f), modifier = Modifier.size(48.dp))
        }
        Text(title, style = MaterialTheme.typography.titleSmall, maxLines = 1, modifier = Modifier.padding(top = Spacing.s))
        Text(subtitle, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun StationCard(title: String, subtitle: String, icon: ImageVector, from: Color, to: Color,
                        modifier: Modifier = Modifier, onClick: () -> Unit) {
    Column(modifier.clickable(onClick = onClick)) {
        Box(Modifier.fillMaxWidth().aspectRatio(1f).clip(RoundedCornerShape(28.dp))
            .background(Brush.linearGradient(listOf(from, to))), contentAlignment = Alignment.Center) {
            // An expressive "sunny" shape behind the icon.
            Box(Modifier.size(84.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.22f)),
                contentAlignment = Alignment.Center) {
                Icon(icon, null, tint = Color.White, modifier = Modifier.size(40.dp))
            }
        }
        Text(title, style = MaterialTheme.typography.titleMedium.bold(), modifier = Modifier.padding(top = Spacing.s))
        Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun MoodCard(mood: Mood, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Box(modifier.height(96.dp).clip(RoundedCornerShape(24.dp)).background(Brush.linearGradient(listOf(mood.from, mood.to)))
        .clickable(onClick = onClick).padding(Spacing.l)) {
        Text(mood.title, style = MaterialTheme.typography.titleMedium.bold(), color = Color.White)
        Icon(mood.icon, null, tint = Color.White.copy(alpha = 0.45f), modifier = Modifier.align(Alignment.BottomEnd).size(36.dp))
    }
}

@kotlinx.serialization.Serializable data class StationsRoute(val tag: String, val title: String)

/** The live radio categories, same names and colours as on iPhone. */
private data class RadioCategory(val tag: String, val title: String, val icon: ImageVector, val from: Color, val to: Color)

private val radioCategories = listOf(
    RadioCategory("christmas", "Christmas", Icons.Rounded.Celebration, Color(0xFFD62F3E), Color(0xFF1E7A4A)),
    RadioCategory("lofi", "Lo-Fi", Icons.Rounded.NightsStay, Color(0xFF7B5CD6), Color(0xFF3B2A7A)),
    RadioCategory("jazz", "Jazz", Icons.Rounded.MusicNote, Color(0xFFE08A2B), Color(0xFF8A3B12)),
    RadioCategory("chillout", "Chill", Icons.Rounded.Spa, Color(0xFF2BB5A8), Color(0xFF1B6E8A)),
    RadioCategory("ambient", "Ambient", Icons.Rounded.Cloud, Color(0xFF5B8DEF), Color(0xFF2A3F8F)),
    RadioCategory("classical", "Classical", Icons.Rounded.Piano, Color(0xFFB08968), Color(0xFF5A3E2B)),
    RadioCategory("hip hop", "Hip-Hop", Icons.Rounded.Mic, Color(0xFFF2634B), Color(0xFF8E1F3A)),
    RadioCategory("electronic", "Electronic", Icons.Rounded.Bolt, Color(0xFF29C5E6), Color(0xFF5A35C8)),
    RadioCategory("soul", "Soul & Funk", Icons.Rounded.Favorite, Color(0xFFE0568A), Color(0xFF8A2A5E)),
    RadioCategory("rock", "Rock", Icons.Rounded.GraphicEq, Color(0xFF8E8E93), Color(0xFF2C2C2E)),
    RadioCategory("80s", "80s", Icons.Rounded.WbSunny, Color(0xFFFF4FA3), Color(0xFF7A2BD6)),
)

@Composable
private fun CategoryCard(category: RadioCategory, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Box(modifier.height(92.dp).clip(RoundedCornerShape(18.dp))
        .background(Brush.linearGradient(listOf(category.from, category.to), start = Offset.Zero, end = Offset.Infinite))
        .clickable(onClick = onClick)) {
        Text(category.title, style = MaterialTheme.typography.titleMedium.bold(), color = Color.White,
            modifier = Modifier.align(Alignment.TopStart).padding(12.dp))
        Icon(category.icon, null, tint = Color.White.copy(alpha = 0.35f),
            modifier = Modifier.align(Alignment.BottomEnd).padding(8.dp).size(44.dp).rotate(-12f))
    }
}

/** Live radio: a grid of coloured categories, like on iPhone. */
@Composable
private fun LiveRadio() {
    val navigator = LocalNavigator.current
    Column(verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        SectionTitle("Live Radio")
        Column(Modifier.padding(horizontal = Spacing.l), verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
            radioCategories.chunked(2).forEach { pair ->
                Row(horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
                    pair.forEach { c -> CategoryCard(c, Modifier.weight(1f)) { navigator.open(StationsRoute(c.tag, c.title)) } }
                    if (pair.size == 1) Spacer(Modifier.weight(1f))
                }
            }
        }
    }
}

/** The stations of one category: artwork, name, country and bitrate. */
@Composable
fun StationsScreen(route: StationsRoute) {
    val app = LocalApp.current
    val state by app.player.state.collectAsState()
    var stations by remember { mutableStateOf<List<Station>?>(null) }
    LaunchedEffect(route.tag) {
        val found = runCatching { RadioBrowser.byTag(route.tag) }.getOrDefault(emptyList())
        stations = if (route.tag == "lofi") YouTubeLive.stations() + found else found
    }
    Column(Modifier.fillMaxSize()) {
        PageTopBar(route.title)
        val list = stations
        if (list == null) Loading(Modifier.fillMaxSize())
        else LazyColumn(contentPadding = PaddingValues(vertical = Spacing.s)) {
            items(list.size) { i ->
                val station = list[i]
                val playing = state.current?.id == station.id
                Row(Modifier.fillMaxWidth().focusHighlight(RoundedCornerShape(12.dp), grow = 1f)
                    .clickable { app.player.playStation(station) }.padding(horizontal = Spacing.l, vertical = Spacing.s),
                    verticalAlignment = Alignment.CenterVertically) {
                    Artwork(station.favicon?.takeIf { it.isNotBlank() }, Modifier.size(52.dp), RoundedCornerShape(12.dp), Icons.Rounded.Sensors)
                    Column(Modifier.weight(1f).padding(horizontal = Spacing.m)) {
                        Text(station.name.trim(), style = MaterialTheme.typography.bodyLarge, maxLines = 1,
                            color = if (playing) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface)
                        Text(listOfNotNull(station.country, station.bitrate?.takeIf { it > 0 }?.let { "$it kbps" }).joinToString(" · "),
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                    }
                    if (playing) Icon(Icons.Rounded.GraphicEq, null, tint = MaterialTheme.colorScheme.primary)
                }
            }
        }
    }
}
