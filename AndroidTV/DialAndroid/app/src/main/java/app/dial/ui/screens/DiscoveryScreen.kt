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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ConfirmationNumber
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
    val client = client()
    val uriHandler = LocalUriHandler.current
    var feed by remember { mutableStateOf(DiscoveryEngine.latest ?: DiscoveryFeed()) }
    var owned by remember { mutableStateOf<Owned?>(null) }
    // Whether the fetch that started with this page has finished: until then an empty row shows its skeleton.
    var done by remember { mutableStateOf(false) }
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
        // New releases: its skeleton while it loads, then the cards. Nothing at all if there is nothing.
        if (loading(feed.fresh.isEmpty())) item { ReleasesSkeleton() }
        else if (feed.fresh.isNotEmpty()) item { AlbumRow("New From Your Artists", "Recent albums and EPs by artists you own", feed.fresh.take(24), own) }

        // People recommendations: one big title, a quieter "Fans of ..." line over each row.
        if (loading(feed.fans.isEmpty())) item { FansSkeleton() }
        else if (feed.fans.isNotEmpty()) {
            item { Text("You Might Also Like", style = MaterialTheme.typography.titleLarge.bold(), modifier = Modifier.padding(horizontal = Spacing.l)) }
            feed.fans.take(3).forEach { group -> item { ArtistRow("Fans of ${group.seed}", null, group.picks, own, light = true) } }
        }

        if (feed.concertsEnabled) {
            if (loading(feed.concerts.isEmpty())) item { ConcertsSkeleton() }
            else if (feed.concerts.isNotEmpty()) {
                item {
                    Column(Modifier.padding(horizontal = Spacing.l)) {
                        Text("On Tour", style = MaterialTheme.typography.titleLarge.bold())
                        Text("Upcoming concerts by artists you own", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
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

/** A concert as a card, like Apple's event cards: the artwork across the whole card, the date in a badge, the artist and where over a soft gradient, and a Tickets button. */
@Composable
private fun ConcertCard(concert: Concert, onOpen: (Concert) -> Unit) {
    val parts = concert.date.split("-")
    val month = parts.getOrNull(1)?.toIntOrNull()?.let {
        java.time.Month.of(it).getDisplayName(java.time.format.TextStyle.SHORT, java.util.Locale.getDefault()).uppercase()
    } ?: ""
    val tint = listOf(Color(0xFF6B3FA0), Color(0xFFE0735A), Color(0xFF2A6F97), Color(0xFF3A7D5C))[Math.abs(concert.artist.sumOf { it.code }) % 4]
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
                Text(listOf(concert.venue, concert.city).filter { it.isNotBlank() }.joinToString(" · "), style = MaterialTheme.typography.bodyMedium,
                    color = Color.White.copy(alpha = 0.85f), maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Text("Tickets", style = MaterialTheme.typography.labelLarge, color = Color.Black,
                modifier = Modifier.clip(RoundedCornerShape(50)).background(Color.White).padding(horizontal = 14.dp, vertical = 7.dp))
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
