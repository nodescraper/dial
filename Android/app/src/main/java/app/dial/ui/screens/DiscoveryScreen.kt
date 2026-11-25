package app.dial.ui.screens

import app.dial.ui.components.OfflineCover
import app.dial.ui.LocalApp
import app.dial.data.PublicMusic
import kotlinx.coroutines.withContext
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.NearMe
import androidx.compose.material.icons.rounded.Place
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import kotlinx.coroutines.launch
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.dial.data.Concert
import app.dial.data.DiscoveryEngine
import app.dial.data.DiscoveryFeed
import app.dial.ui.LocalNavigator
import app.dial.ui.OnTourRoute
import java.time.LocalDate
import app.dial.ui.components.Artwork
import app.dial.ui.components.EmptyMessage
import app.dial.ui.components.Spacing
import app.dial.ui.components.black
import app.dial.ui.components.bold

/**
 * The Discovery tab, for a library you chose yourself: nothing global or random, only what concerns the artists you own.
 * New albums by them, who their fans also play and their concerts. The Dial plugin on the server makes the feed once a day;
 * the page shows what was saved at once and a grey skeleton for a row that is still on its way.
 */
@Composable
fun DiscoveryScreen() {
    val appForOffline = LocalApp.current
    val offline by appForOffline.connectivity.offline.collectAsState()
    if (offline) {
        val scope = androidx.compose.runtime.rememberCoroutineScope()
        OfflineCover("Discovery needs a connection",
            "New releases, artist pages and Following look things up online. They are back as soon as the server can be reached.") { scope.launch { appForOffline.connectivity.check() } }
        return
    }
    val client = client()
    val uriHandler = LocalUriHandler.current
    val navigator = LocalNavigator.current
    var feed by remember { mutableStateOf(DiscoveryEngine.latest ?: DiscoveryFeed()) }
    var owned by remember { mutableStateOf<Owned?>(null) }
    // Whether the fetch that started with this page has finished: until then an empty row shows its skeleton.
    var done by remember { mutableStateOf(false) }
    var tab by remember { mutableStateOf(DiscoveryTab.ForYou) }
    // Albums by the artists you play most that you do not have yet (from their saved discographies).
    var gaps by remember { mutableStateOf<List<app.dial.data.PublicMusic.Pick>>(emptyList()) }
    var sawLoading by remember { mutableStateOf(false) }

    val onUpdate: (DiscoveryFeed) -> Unit = { update ->
        feed = update
        if (update.loading) sawLoading = true else if (sawLoading) done = true
    }
    LaunchedEffect(client) {
        feed = feed.copy(loading = false)
        val c = client ?: return@LaunchedEffect
        val library = runCatching { c.artists() }.getOrDefault(emptyList())
        val o = Owned(library, runCatching { c.albumsForBrowsing(3000) }.getOrDefault(emptyList()))
        owned = o
        DiscoveryEngine.refresh(c, { o.album(it) != null }, true, onUpdate)
    }

    val own = owned ?: remember { Owned(emptyList(), emptyList()) }
    LaunchedEffect(feed.artists.size, owned) {
        val o = owned ?: return@LaunchedEffect
        gaps = withContext(kotlinx.coroutines.Dispatchers.IO) {
            val found = mutableListOf<app.dial.data.PublicMusic.Pick>()
            for (artist in feed.artists.take(25)) {
                val saved = app.dial.data.PublicMusic.savedDiscography(artist.mbid)?.first ?: continue
                found += saved.filter { it.kind == "album" }.take(8).map {
                    app.dial.data.PublicMusic.Pick("album", it.id, it.title, artist.name, artist.mbid, it.year, releaseDate = it.date)
                }.filter { o.album(it) == null }.take(2)
            }
            found.distinctBy { it.mbid }.take(18)
        }
    }
    fun loading(empty: Boolean) = empty && !done
    LazyColumn(contentPadding = PaddingValues(bottom = Spacing.section), verticalArrangement = Arrangement.spacedBy(28.dp)) {
        item {
            Row(Modifier.fillMaxWidth().padding(start = Spacing.l, end = Spacing.s, top = Spacing.l), verticalAlignment = Alignment.CenterVertically) {
                Text("Discovery", style = MaterialTheme.typography.displaySmall.black(), modifier = Modifier.weight(1f))
                IconButton(onClick = { client?.let { c -> done = false; sawLoading = false; DiscoveryEngine.refresh(c, { own.album(it) != null }, true, onUpdate) } }) {
                    Icon(Icons.Rounded.Refresh, "Refresh")
                }
            }
        }
        item { DiscoveryTabBar(tab) { tab = it } }
        when (tab) {
            DiscoveryTab.Calendar -> item { ReleaseCalendar((feed.fresh + feed.upcoming).distinctBy { it.mbid }, own) }
            DiscoveryTab.Following -> item { FollowingTab() }
            DiscoveryTab.ForYou -> {
                // The biggest news first (the releases of the artists you play most), then the shelves, in the look of Recently Added.
                val heroes = discoveryHeroes(feed, own)
                if (heroes.isNotEmpty()) item { HighlightsRow(heroes, captioned = true) }
                if (loading(feed.fresh.isEmpty() && feed.upcoming.isEmpty())) item {
                    Column(verticalArrangement = Arrangement.spacedBy(28.dp)) { DiscoveryHeroSkeleton(); ReleasesSkeleton() }
                }
                else {
                    fun days(p: PublicMusic.Pick) = -(ReleaseDates.date(p)?.let { ReleaseDates.days(it) } ?: -400)
                    item { ReleaseShelf("Coming Soon", feed.upcoming, own) }
                    item { ReleaseShelf("New This Week", feed.fresh.filter { days(it) <= 7 }, own) }
                    item { ReleaseShelf("Recent Releases", feed.fresh.filter { days(it) in 8..40 }, own) }
                    item { ReleaseShelf("Complete Your Collection", gaps, own, limit = 18) }
                    item { ReleaseShelf("Earlier", feed.fresh.filter { days(it) > 40 }, own) }
                    if (feed.fresh.isEmpty() && feed.upcoming.isEmpty() && gaps.isEmpty() && heroes.isEmpty())
                        item { EmptyMessage("Nothing new yet", "When an artist you own puts something out, or announces a date, it shows up here.") }
                }

                // People recommendations: one big title, a quieter "Fans of ..." line over each row.
                if (loading(feed.fans.isEmpty())) item { FansSkeleton() }
                else if (feed.fans.isNotEmpty()) {
                    item { Column(Modifier.padding(horizontal = Spacing.l)) {
                        Text("Because You Listen", style = app.dial.ui.components.sectionStyle())
                        Text("Artists that fit what you play", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    } }
                    feed.fans.take(2).forEach { group -> item { ArtistRow("Fans of ${group.seed}", null, group.picks, own, light = true) } }
                }

        if (feed.concertsEnabled) {
                if (loading(feed.concerts.isEmpty())) item { ConcertsSkeleton() }
                else if (feed.concerts.isNotEmpty()) {
                    item {
                        Row(Modifier.fillMaxWidth().clickable { navigator.open(OnTourRoute) }.padding(horizontal = Spacing.l), verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text("On Tour", style = app.dial.ui.components.sectionStyle())
                                Text("Upcoming concerts by artists you own", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, "See all concerts", tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    item {
                        LazyRow(contentPadding = PaddingValues(horizontal = Spacing.l), horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
                            items(feed.concerts.take(12), key = { it.id }) { concert -> ConcertCard(concert) { uriHandler.openUri(it.url) } }
                        }
                    }
                }
            }
            }
        }
    }
}

/** The weekday of a "2026-11-14" date, like "Saturday". */
private fun weekday(date: String): String = runCatching {
    LocalDate.parse(date).dayOfWeek.getDisplayName(java.time.format.TextStyle.FULL, java.util.Locale.getDefault())
}.getOrDefault("")

/** A concert as a card (the same as on iPhone): artwork across the card, the date in a badge, the artist, a pin with where, the weekday, and a round arrow. */
@Composable
private fun ConcertCard(concert: Concert, onOpen: (Concert) -> Unit) {
    val parts = concert.date.split("-")
    val month = parts.getOrNull(1)?.toIntOrNull()?.let {
        java.time.Month.of(it).getDisplayName(java.time.format.TextStyle.SHORT, java.util.Locale.getDefault()).uppercase()
    } ?: ""
    val tint = listOf(Color(0xFFA8401A), Color(0xFFE0735A), Color(0xFF2A6F97), Color(0xFF3A7D5C))[Math.abs(concert.artist.sumOf { it.code }) % 4]
    Box(Modifier.width(300.dp).height(220.dp).clip(RoundedCornerShape(22.dp)).background(Brush.linearGradient(listOf(tint, tint.copy(alpha = 0.55f))))
        .clickable { onOpen(concert) }) {
        if (concert.image != null) Artwork(concert.image, Modifier.fillMaxSize(), RoundedCornerShape(0.dp), Icons.Rounded.Mic)
        else Icon(Icons.Rounded.Mic, null, tint = Color.White.copy(alpha = 0.35f), modifier = Modifier.align(Alignment.Center).size(56.dp))
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.78f)), startY = 110f)))
        Column(Modifier.align(Alignment.TopStart).padding(14.dp).width(48.dp).height(52.dp).clip(RoundedCornerShape(12.dp)).background(Color.White.copy(alpha = 0.88f)),
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
            Text(month, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.primary)
            Text(parts.getOrNull(2)?.trimStart('0') ?: "", style = MaterialTheme.typography.titleMedium, color = Color.Black)
        }
        Row(Modifier.align(Alignment.BottomStart).fillMaxWidth().padding(14.dp), verticalAlignment = Alignment.Bottom) {
            Column(Modifier.weight(1f)) {
                Text(concert.artist, style = MaterialTheme.typography.titleLarge, color = Color.White, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Rounded.Place, null, tint = Color.White.copy(alpha = 0.9f), modifier = Modifier.size(15.dp))
                    Spacer(Modifier.width(4.dp))
                    Text(listOf(concert.venue, concert.city).filter { it.isNotBlank() }.joinToString(" · "), style = MaterialTheme.typography.bodyMedium,
                        color = Color.White.copy(alpha = 0.9f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                Text(weekday(concert.date), style = MaterialTheme.typography.labelMedium, color = Color.White.copy(alpha = 0.7f), maxLines = 1)
            }
            Icon(Icons.Rounded.NearMe, "Tickets", tint = Color.White,
                modifier = Modifier.size(40.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.22f)).padding(10.dp))
        }
    }
}

/** Every concert on one page, by month, down a timeline: the day, a dot on the line, and the show. */
@Composable
@OptIn(ExperimentalFoundationApi::class)
fun OnTourScreen() {
    val uriHandler = LocalUriHandler.current
    val concerts = remember { DiscoveryEngine.latest?.concerts.orEmpty().sortedBy { it.date } }
    val months = remember(concerts) { concerts.groupBy { it.date.take(7) }.toList() }
    Column(Modifier.fillMaxSize()) {
        PageTopBar("On Tour")
        if (concerts.isEmpty()) { EmptyMessage("No upcoming concerts", "Nothing is announced yet for the artists you own."); return@Column }
        LazyColumn(contentPadding = PaddingValues(bottom = Spacing.section)) {
            months.forEach { (key, shows) ->
                stickyHeader(key = key) {
                    val title = runCatching {
                        LocalDate.parse("$key-01").month.getDisplayName(java.time.format.TextStyle.FULL, java.util.Locale.getDefault()) + " " + key.take(4)
                    }.getOrDefault(key)
                    Text(title, style = app.dial.ui.components.sectionStyle(),
                        modifier = Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.background).padding(horizontal = Spacing.l, vertical = Spacing.s))
                }
                items(shows.size, key = { shows[it].id }) { i -> TimelineRow(shows[i], isLast = i == shows.size - 1) { uriHandler.openUri(it.url) } }
            }
        }
    }
}

@Composable
private fun TimelineRow(concert: Concert, isLast: Boolean, onOpen: (Concert) -> Unit) {
    val accent = MaterialTheme.colorScheme.primary
    val day = concert.date.split("-").getOrNull(2)?.trimStart('0') ?: ""
    Row(Modifier.fillMaxWidth().clickable { onOpen(concert) }.padding(horizontal = Spacing.l).height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
        Column(Modifier.width(44.dp).padding(top = 14.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Text(weekday(concert.date).take(3).uppercase(), style = MaterialTheme.typography.labelSmall, color = accent, fontWeight = FontWeight.Bold)
            Text(day, style = app.dial.ui.components.sectionStyle())
        }
        Box(Modifier.width(12.dp).fillMaxHeight(), contentAlignment = Alignment.TopCenter) {
            if (!isLast) Box(Modifier.padding(top = 22.dp).width(2.dp).fillMaxHeight().background(MaterialTheme.colorScheme.outlineVariant))
            Box(Modifier.padding(top = 18.dp).size(12.dp).clip(CircleShape).background(accent))
        }
        Row(Modifier.weight(1f).padding(bottom = Spacing.m).clip(RoundedCornerShape(18.dp)).background(MaterialTheme.colorScheme.surfaceContainer).padding(10.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
            Artwork(concert.image, Modifier.size(64.dp), RoundedCornerShape(12.dp), Icons.Rounded.Mic)
            Column(Modifier.weight(1f)) {
                Text(concert.artist, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Rounded.Place, null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(14.dp))
                    Spacer(Modifier.width(3.dp))
                    Text(concert.venue.ifBlank { concert.city }, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                if (concert.venue.isNotBlank() && concert.city.isNotBlank())
                    Text(concert.city, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f))
            }
            Icon(Icons.Rounded.NearMe, "Tickets", tint = accent, modifier = Modifier.size(36.dp).clip(CircleShape).background(accent.copy(alpha = 0.14f)).padding(9.dp))
        }
    }
}

/** The "Fans of ..." row while it is being looked up: a grey title and a row of grey circles. */
@Composable
private fun FansSkeleton() {
    val grey = MaterialTheme.colorScheme.surfaceContainerHigh
    Column(verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        Box(Modifier.padding(horizontal = Spacing.l).width(190.dp).height(22.dp).clip(RoundedCornerShape(6.dp)).background(grey))
        Box(Modifier.padding(horizontal = Spacing.l).width(120.dp).height(14.dp).clip(RoundedCornerShape(6.dp)).background(grey))
        LazyRow(contentPadding = PaddingValues(horizontal = Spacing.l), horizontalArrangement = Arrangement.spacedBy(Spacing.l), userScrollEnabled = false) {
            items(5) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Box(Modifier.size(88.dp).clip(androidx.compose.foundation.shape.CircleShape).background(grey))
                    Box(Modifier.width(64.dp).height(10.dp).clip(RoundedCornerShape(4.dp)).background(grey))
                }
            }
        }
    }
}

/** "New from your artists" while it loads: a title bar and a row of grey covers. */
@Composable
private fun ReleasesSkeleton() {
    val grey = MaterialTheme.colorScheme.surfaceContainerHigh
    Column(verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        Box(Modifier.padding(horizontal = Spacing.l).width(230.dp).height(22.dp).clip(RoundedCornerShape(6.dp)).background(grey))
        LazyRow(contentPadding = PaddingValues(horizontal = Spacing.l), horizontalArrangement = Arrangement.spacedBy(Spacing.m), userScrollEnabled = false) {
            items(3) {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Box(Modifier.size(150.dp).clip(RoundedCornerShape(16.dp)).background(grey))
                    Box(Modifier.width(110.dp).height(12.dp).clip(RoundedCornerShape(4.dp)).background(grey))
                    Box(Modifier.width(80.dp).height(10.dp).clip(RoundedCornerShape(4.dp)).background(grey))
                }
            }
        }
    }
}

/** "On Tour" while it loads: a title bar and wide grey cards. */
@Composable
private fun ConcertsSkeleton() {
    val grey = MaterialTheme.colorScheme.surfaceContainerHigh
    Column(verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        Box(Modifier.padding(horizontal = Spacing.l).width(130.dp).height(22.dp).clip(RoundedCornerShape(6.dp)).background(grey))
        LazyRow(contentPadding = PaddingValues(horizontal = Spacing.l), horizontalArrangement = Arrangement.spacedBy(Spacing.m), userScrollEnabled = false) {
            items(2) { Box(Modifier.width(300.dp).height(220.dp).clip(RoundedCornerShape(22.dp)).background(grey)) }
        }
    }
}
