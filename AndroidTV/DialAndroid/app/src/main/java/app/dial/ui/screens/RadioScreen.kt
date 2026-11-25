package app.dial.ui.screens

import app.dial.ui.LocalNavigator
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
import app.dial.data.Station
import app.dial.ui.components.Artwork
import app.dial.ui.components.Loading

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

private data class RadioData(val artists: List<Item>, val canSearchBySound: Boolean)

@Composable
fun RadioScreen() {
    val app = LocalApp.current
    val client = client()
    val load = rememberLoad(Unit) { RadioData(it.randomArtists(12), it.audioMuseCanSearch()) }
    // The mixtapes start with what was shown last time, then fill in (tags first, the sound-based moods last).
    var mixes by remember { mutableStateOf(MixCatalog.latest ?: MixSections()) }
    var mixesLoaded by remember { mutableStateOf(false) }
    androidx.compose.runtime.LaunchedEffect((load as? Load.Ready)?.value?.canSearchBySound) {
        val ready = (load as? Load.Ready)?.value ?: return@LaunchedEffect
        val c = app.session.client.value ?: return@LaunchedEffect
        MixCatalog.load(c, ready.canSearchBySound) { if (it != mixes) mixes = it }
        mixesLoaded = true
    }

    LoadContent(load) { data ->
        LazyColumn(contentPadding = PaddingValues(bottom = Spacing.section), verticalArrangement = Arrangement.spacedBy(Spacing.section)) {
            item {
                Text("Radio", style = MaterialTheme.typography.displaySmall.bold(),
                    modifier = Modifier.padding(start = Spacing.l, top = Spacing.l))
            }
            item {
                Shelf("Your Stations", listOf("mix", "favorites"), key = { it }) { which ->
                    when (which) {
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
            item { MarloCard(Modifier.padding(horizontal = Spacing.l)) }
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

/** Internet radio from Radio Browser: pick a category or search, tap to listen. */
@Composable
private fun LiveRadio() {
    val app = LocalApp.current
    var category by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf(RadioBrowser.categories.first()) }
    var query by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf("") }
    var stations by remember { mutableStateOf<List<Station>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    androidx.compose.runtime.LaunchedEffect(category, query) {
        loading = true
        if (query.length >= 2) kotlinx.coroutines.delay(400)
        stations = if (query.length >= 2) RadioBrowser.search(query) else RadioBrowser.byTag(category)
        loading = false
    }
    Column(verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        SectionTitle("Live Radio")
        androidx.compose.material3.OutlinedTextField(query, { query = it }, placeholder = { Text("Search stations") }, singleLine = true,
            shape = RoundedCornerShape(24.dp), modifier = Modifier.fillMaxWidth().padding(horizontal = Spacing.l))
        if (query.length < 2) androidx.compose.foundation.lazy.LazyRow(contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = Spacing.l),
            horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
            items(RadioBrowser.categories.size) { i ->
                val tag = RadioBrowser.categories[i]
                androidx.compose.material3.FilterChip(selected = category == tag, onClick = { category = tag },
                    label = { Text(tag.replaceFirstChar { it.uppercase() }) })
            }
        }
        if (loading) Loading(Modifier.height(120.dp))
        stations.take(15).forEach { station ->
            Row(Modifier.fillMaxWidth().focusHighlight(RoundedCornerShape(12.dp), grow = 1f)
                .clickable { app.player.playStation(station) }.padding(horizontal = Spacing.l, vertical = Spacing.s),
                verticalAlignment = Alignment.CenterVertically) {
                Artwork(station.favicon?.takeIf { it.isNotBlank() }, Modifier.size(48.dp), RoundedCornerShape(12.dp), Icons.Rounded.Sensors)
                Column(Modifier.weight(1f).padding(horizontal = Spacing.m)) {
                    Text(station.name.trim(), style = MaterialTheme.typography.bodyLarge, maxLines = 1)
                    Text(listOfNotNull(station.country, station.bitrate?.takeIf { it > 0 }?.let { "$it kbps" }).joinToString(", "),
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                }
            }
        }
    }
}
