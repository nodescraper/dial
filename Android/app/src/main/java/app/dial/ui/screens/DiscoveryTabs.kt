package app.dial.ui.screens

import app.dial.ui.components.Ghost
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.rounded.OpenInNew
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.material.icons.rounded.NotificationsActive
import androidx.compose.material.icons.rounded.NotificationsOff
import androidx.compose.material.icons.rounded.PersonAdd
import androidx.compose.material.icons.rounded.PersonRemove
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.dial.data.Follows
import app.dial.data.Highlight
import app.dial.data.HighlightAction
import app.dial.data.PublicMusic
import app.dial.data.DiscoveryFeed
import app.dial.data.WishItem
import app.dial.ui.AlbumRoute
import app.dial.ui.LocalNavigator
import app.dial.ui.PublicAlbumRoute
import app.dial.ui.components.Artwork
import app.dial.ui.components.JewelCase
import app.dial.ui.components.Spacing
import app.dial.ui.components.sectionStyle
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.time.YearMonth
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.time.temporal.ChronoUnit
import java.util.Locale

/** The three parts of Discovery. */
enum class DiscoveryTab(val title: String) { ForYou("For You"), Calendar("Calendar"), Following("Following") }

// MARK: - Dates and links

object ReleaseDates {
    fun date(pick: PublicMusic.Pick): LocalDate? =
        pick.releaseDate?.takeIf { it.length >= 10 }?.let { runCatching { LocalDate.parse(it.take(10)) }.getOrNull() }

    fun date(text: String): LocalDate? = runCatching { LocalDate.parse(text.take(10)) }.getOrNull()

    /** Days until the date (negative once it is out). */
    fun days(date: LocalDate): Int = ChronoUnit.DAYS.between(LocalDate.now(), date).toInt()

    /** "Fri 14 Nov" */
    fun chip(date: LocalDate): String = date.format(DateTimeFormatter.ofPattern("EEE d MMM", Locale.getDefault()))

    /** "Out today", "Out 3 days ago", "Tomorrow", "In 12 days" */
    fun relative(date: LocalDate): String = when (val d = days(date)) {
        0 -> "Out today"
        1 -> "Tomorrow"
        in 2..Int.MAX_VALUE -> "In $d days"
        -1 -> "Out yesterday"
        in -13..-2 -> "Out ${-d} days ago"
        else -> "Out " + date.format(DateTimeFormatter.ofPattern("d MMM", Locale.getDefault()))
    }
}

/** The album's own Spotify page when MusicBrainz knows it, else a Spotify search for it (which always works). */
suspend fun spotifyUrl(pick: PublicMusic.Pick): String =
    PublicMusic.spotifyAlbumUrl(pick.mbid)
        ?: "https://open.spotify.com/search/" + android.net.Uri.encode("${pick.artist ?: ""} ${pick.title}".trim())

// MARK: - Components

/** "Fri 14 Nov" on a dark chip, for covers. */
@Composable
fun DateChip(text: String, tint: Color? = null, modifier: Modifier = Modifier) {
    Text(text, style = MaterialTheme.typography.labelSmall, color = Color.White, fontWeight = FontWeight.SemiBold,
        modifier = modifier.clip(CircleShape).background(tint?.copy(alpha = 0.9f) ?: Color.Black.copy(alpha = 0.55f)).padding(horizontal = 8.dp, vertical = 3.dp))
}

/** The bell on a release: tell me when it is out. */
@Composable
fun BellButton(pick: PublicMusic.Pick, modifier: Modifier = Modifier) {
    val belled by Follows.releases.collectAsState()
    val on = belled.any { it.id == pick.mbid }
    Box(modifier.size(30.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.45f)).clickable { Follows.toggleBell(pick) },
        contentAlignment = Alignment.Center) {
        Icon(if (on) Icons.Rounded.NotificationsActive else Icons.Rounded.Notifications, if (on) "Stop telling me when ${pick.title} is out" else "Tell me when ${pick.title} is out",
            tint = if (on) MaterialTheme.colorScheme.primary else Color.White, modifier = Modifier.size(18.dp))
    }
}

/** The menu every release shares: Spotify, the release-day reminder and following the artist. */
@Composable
fun ReleaseMenu(pick: PublicMusic.Pick, expanded: Boolean, onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    val uriHandler = LocalUriHandler.current
    val belled by Follows.releases.collectAsState()
    val followed by Follows.artists.collectAsState()
    val date = ReleaseDates.date(pick)
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        DropdownMenuItem(text = { Text("Open in Spotify") }, leadingIcon = { Icon(Icons.AutoMirrored.Rounded.OpenInNew, null) },
            onClick = { onDismiss(); scope.launch { runCatching { uriHandler.openUri(spotifyUrl(pick)) } } })
        WishlistMenuItem(WishItem.album(pick.artist ?: "", pick.title, pick.sourceId ?: pick.mbid.ifEmpty { null }, pick.cover)) { onDismiss() }
        if (date != null && ReleaseDates.days(date) >= 0) {
            val on = belled.any { it.id == pick.mbid }
            DropdownMenuItem(text = { Text(if (on) "Remove Reminder" else "Remind Me on Release Day") },
                leadingIcon = { Icon(if (on) Icons.Rounded.NotificationsOff else Icons.Rounded.Notifications, null) },
                onClick = { onDismiss(); Follows.toggleBell(pick) })
        }
        if (pick.artistMbid != null) {
            val on = followed.any { it.id == pick.artistMbid }
            DropdownMenuItem(text = { Text(if (on) "Unfollow ${pick.artist ?: "Artist"}" else "Follow ${pick.artist ?: "Artist"}") },
                leadingIcon = { Icon(if (on) Icons.Rounded.PersonRemove else Icons.Rounded.PersonAdd, null) },
                onClick = { onDismiss(); Follows.toggleFollow(pick.artistMbid, pick.artist ?: "") })
        }
    }
}

/** A release as a tile, like Recently Added on Home: the cover with its date and, when it is not out yet, a bell. Long press for more. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun ReleaseTile(pick: PublicMusic.Pick, ownedArtistId: String?, modifier: Modifier = Modifier) {
    val navigator = LocalNavigator.current
    val date = ReleaseDates.date(pick)
    val upcoming = date != null && ReleaseDates.days(date) > 0
    var menu by remember { mutableStateOf(false) }
    Column(modifier.width(150.dp).combinedClickable(onClick = {
        navigator.open(PublicAlbumRoute(pick.releaseId, pick.title, pick.year, pick.artist ?: "", ownedArtistId, pick.coverFile))
    }, onLongClick = { menu = true })) {
        Box {
            // Flat, like the Discovery tiles on iPhone (only the faded not-owned discography entries use the case).
            Artwork(pick.cover, Modifier.fillMaxWidth().aspectRatio(1f), RoundedCornerShape(12.dp), ghost = true)
            if (date != null) DateChip(ReleaseDates.chip(date), if (upcoming) MaterialTheme.colorScheme.primary else null,
                Modifier.align(Alignment.BottomStart).padding(8.dp))
            if (upcoming) BellButton(pick, Modifier.align(Alignment.TopEnd).padding(8.dp))
        }
        Text(pick.title, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = Spacing.s))
        Text(pick.artist ?: "", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1,
            overflow = TextOverflow.Ellipsis)
        ReleaseMenu(pick, menu) { menu = false }
    }
}

/** A titled shelf of release tiles. */
@Composable
fun ReleaseShelf(title: String, picks: List<PublicMusic.Pick>, owned: Owned, limit: Int = 20) {
    val shown = picks.distinctBy { it.mbid }
    if (shown.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        Text(title, style = sectionStyle(), modifier = Modifier.padding(horizontal = Spacing.l))
        LazyRow(contentPadding = PaddingValues(horizontal = Spacing.l), horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
            items(shown.take(limit), key = { it.listId }) { pick -> ReleaseTile(pick, owned.artistOf(pick)?.id) }
        }
    }
}

/** The tabs as plain titles, like Apple Music's page headings: the open one dark, the others grey. */
@Composable
fun DiscoveryTabBar(tab: DiscoveryTab, onSelect: (DiscoveryTab) -> Unit) {
    val belled by Follows.releases.collectAsState()
    val followed by Follows.artists.collectAsState()
    Row(Modifier.fillMaxWidth().padding(horizontal = Spacing.l), horizontalArrangement = Arrangement.spacedBy(Spacing.l), verticalAlignment = Alignment.Bottom) {
        DiscoveryTab.entries.forEach { item ->
            Row(Modifier.clickable { onSelect(item) }.padding(vertical = 6.dp), verticalAlignment = Alignment.Bottom) {
                Text(item.title, style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.SemiBold),
                    color = if (tab == item) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f))
                if (item == DiscoveryTab.Following && belled.size + followed.size > 0)
                    Text(" ${belled.size + followed.size}", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.primary)
            }
        }
    }
}

// MARK: - Discovery's big cards

/**
 * The biggest news first, from the releases of the artists you play most: out in the last three weeks or coming in the next
 * month. The nearer a date and the more you play the artist, the higher it goes. One card per artist, five at most.
 */
fun discoveryHeroes(feed: DiscoveryFeed, owned: Owned): List<Highlight> {
    val rank = feed.artists.mapIndexed { index, artist -> artist.mbid to index }.toMap()
    data class Scored(val pick: PublicMusic.Pick, val date: LocalDate, val score: Double)
    val scored = (feed.fresh + feed.upcoming).mapNotNull { pick ->
        val date = ReleaseDates.date(pick) ?: return@mapNotNull null
        val base = when (ReleaseDates.days(date)) {
            in Int.MIN_VALUE..-22 -> return@mapNotNull null
            in -21..-15 -> 40.0
            in -14..-8 -> 55.0
            in -7..-4 -> 75.0
            in -3..-2 -> 90.0
            in -1..0 -> 100.0
            in 1..2 -> 95.0
            in 3..7 -> 80.0
            in 8..14 -> 60.0
            in 15..30 -> 40.0
            else -> return@mapNotNull null
        }
        Scored(pick, date, base + maxOf(0, 25 - (pick.artistMbid?.let { rank[it] } ?: 25)))
    }
    val seen = HashSet<String>()
    return scored.sortedByDescending { it.score }.filter { seen.add(it.pick.artistMbid ?: it.pick.artist ?: it.pick.mbid) }.take(5).map { s ->
        val owner = owned.artistOf(s.pick)
        Highlight("newRelease", ReleaseDates.relative(s.date), s.pick.title, s.pick.artist ?: "",
            coverUrl = "https://coverartarchive.org/release-group/${s.pick.mbid}/front-500", artistId = owner?.id,
            action = HighlightAction.PublicAlbum(s.pick, s.pick.artist ?: "", owner?.id))
    }
}

// MARK: - Calendar

/** A month of releases: a dot under each day that has one, and the day's releases below. */
@Composable
fun ReleaseCalendar(picks: List<PublicMusic.Pick>, owned: Owned) {
    var month by remember { mutableStateOf(YearMonth.now()) }
    var selected by remember { mutableStateOf(LocalDate.now()) }
    val navigator = LocalNavigator.current
    val scope = rememberCoroutineScope()
    val uriHandler = LocalUriHandler.current
    val belled by Follows.releases.collectAsState()
    val byDay = remember(picks) { picks.mapNotNull { p -> ReleaseDates.date(p)?.let { it to p } }.groupBy({ it.first }, { it.second }) }
    val today = LocalDate.now()
    val first = month.atDay(1)
    val lead = (first.dayOfWeek.value - 1)
    val cells: List<LocalDate?> = List(lead) { null } + (1..month.lengthOfMonth()).map { month.atDay(it) }
    Column(Modifier.padding(horizontal = Spacing.l), verticalArrangement = Arrangement.spacedBy(Spacing.l)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(month.month.getDisplayName(TextStyle.FULL, Locale.getDefault()) + " " + month.year, style = sectionStyle(), modifier = Modifier.weight(1f))
            IconButton(onClick = { month = month.minusMonths(1) }) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, "Previous month") }
            Text("Today", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.clickable { month = YearMonth.now(); selected = today }.padding(8.dp))
            IconButton(onClick = { month = month.plusMonths(1) }) { Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, "Next month") }
        }
        Row(Modifier.fillMaxWidth()) {
            listOf("M", "T", "W", "T", "F", "S", "S").forEach {
                Text(it, Modifier.weight(1f), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            }
        }
        cells.chunked(7).forEach { week ->
            Row(Modifier.fillMaxWidth()) {
                for (i in 0 until 7) {
                    val day = week.getOrNull(i)
                    if (day == null) { Spacer(Modifier.weight(1f).height(44.dp)); continue }
                    val count = byDay[day]?.size ?: 0
                    val isSelected = day == selected
                    val upcoming = day.isAfter(today)
                    Column(Modifier.weight(1f).height(44.dp).clip(RoundedCornerShape(10.dp))
                        .background(if (isSelected) MaterialTheme.colorScheme.primary else Color.Transparent).clickable { selected = day },
                        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                        Text("${day.dayOfMonth}", style = MaterialTheme.typography.bodyMedium.copy(fontWeight = if (day == today) FontWeight.Bold else FontWeight.Normal),
                            color = if (isSelected) MaterialTheme.colorScheme.onPrimary else if (day == today) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface)
                        Box(Modifier.padding(top = 3.dp).size(5.dp).clip(CircleShape).background(when {
                            count == 0 -> Color.Transparent
                            isSelected -> MaterialTheme.colorScheme.onPrimary
                            upcoming -> MaterialTheme.colorScheme.primary
                            else -> Color(0xFF34C759)
                        }))
                    }
                }
            }
        }
        Text(selected.format(DateTimeFormatter.ofPattern("EEEE d MMMM", Locale.getDefault())), style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold))
        val items = byDay[selected].orEmpty()
        if (items.isEmpty()) Text("No releases from your artists this day.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        items.forEach { pick ->
            val future = ReleaseDates.date(pick)?.let { ReleaseDates.days(it) > 0 } ?: false
            Row(Modifier.fillMaxWidth().clickable {
                navigator.open(PublicAlbumRoute(pick.releaseId, pick.title, pick.year, pick.artist ?: "", owned.artistOf(pick)?.id, pick.coverFile))
            }, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
                Artwork(pick.cover, Modifier.size(52.dp), RoundedCornerShape(8.dp), ghost = true)
                Column(Modifier.weight(1f)) {
                    Text(pick.title, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(pick.artist ?: "", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                }
                IconButton(onClick = { scope.launch { runCatching { uriHandler.openUri(spotifyUrl(pick)) } } }) { Icon(Icons.AutoMirrored.Rounded.OpenInNew, "Open in Spotify") }
                if (future) IconButton(onClick = { Follows.toggleBell(pick) }) {
                    val on = belled.any { it.id == pick.mbid }
                    Icon(if (on) Icons.Rounded.NotificationsActive else Icons.Rounded.Notifications, "Remind me",
                        tint = if (on) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface)
                }
            }
        }
    }
}

// MARK: - Following

/** What you asked to hear about: albums waiting for their day, and the artists you follow. */
@Composable
fun FollowingTab() {
    val releases by Follows.releases.collectAsState()
    val artists by Follows.artists.collectAsState()
    val navigator = LocalNavigator.current
    val scope = rememberCoroutineScope()
    val uriHandler = LocalUriHandler.current
    val waiting = releases.filter { ReleaseDates.date(it.date)?.let { d -> ReleaseDates.days(d) >= 0 } ?: true }.sortedBy { it.date }
    val out = releases.filterNot { it in waiting }.sortedByDescending { it.date }
    Column(Modifier.padding(horizontal = Spacing.l), verticalArrangement = Arrangement.spacedBy(Spacing.xl)) {
        if (waiting.isEmpty() && out.isEmpty() && artists.isEmpty()) {
            Column(Modifier.fillMaxWidth().padding(top = Spacing.xl), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                Icon(Icons.Rounded.Notifications, null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(40.dp))
                Text("Nothing followed yet", style = MaterialTheme.typography.titleMedium)
                Text("Tap the bell on an album that is coming soon to be told on its release day, or follow an artist (press and hold a release) to hear about everything they put out.",
                    style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            }
        }
        @Composable
        fun releaseRow(release: app.dial.data.FollowedRelease, waitingFor: Boolean) {
            val date = ReleaseDates.date(release.date)
            val pick = PublicMusic.Pick("album", release.id, release.title, release.artist, release.artistMbid, releaseDate = release.date)
            Row(Modifier.fillMaxWidth().clickable { navigator.open(PublicAlbumRoute(release.id, release.title, null, release.artist, null)) },
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
                Artwork(pick.cover, Modifier.size(52.dp), RoundedCornerShape(8.dp), ghost = true)
                Column(Modifier.weight(1f)) {
                    Text(release.title, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(release.artist, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                }
                if (date != null) Text(if (waitingFor) ReleaseDates.relative(date) else ReleaseDates.chip(date), style = MaterialTheme.typography.labelMedium,
                    color = if (waitingFor) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
                IconButton(onClick = { scope.launch { runCatching { uriHandler.openUri(spotifyUrl(pick)) } } }) { Icon(Icons.AutoMirrored.Rounded.OpenInNew, "Open in Spotify") }
                IconButton(onClick = { Follows.removeRelease(release.id) }) { Icon(Icons.Rounded.NotificationsOff, "Remove") }
            }
        }
        if (waiting.isNotEmpty()) Column(verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
            Text("Waiting for release", style = sectionStyle()); waiting.forEach { releaseRow(it, true) }
        }
        if (artists.isNotEmpty()) Column(verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
            Text("Followed artists", style = sectionStyle())
            artists.forEach { artist ->
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(artist.name, Modifier.weight(1f))
                    Text("Unfollow", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.clickable { Follows.removeArtist(artist.id) }.padding(8.dp))
                }
            }
        }
        if (out.isNotEmpty()) Column(verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
            Text("Released", style = sectionStyle()); out.forEach { releaseRow(it, false) }
        }
    }
}


// MARK: - What the world plays

/** An artist's most played songs worldwide: the ones you have play, the others are faded, with Spotify in their long-press menu. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun PopularSongs(tracks: List<PublicMusic.TopTrack>, artistName: String, owned: List<app.dial.data.Item>, onPlay: (List<app.dial.data.Item>, Int) -> Unit) {
    val uriHandler = LocalUriHandler.current
    var showAll by remember { mutableStateOf(false) }
    val client = app.dial.ui.screens.client()
    fun mine(track: PublicMusic.TopTrack) = owned.firstOrNull { app.dial.data.LibraryMatcher.key(it.name) == app.dial.data.LibraryMatcher.key(track.title) }
    val playable = tracks.mapNotNull { mine(it) }
    Column(verticalArrangement = Arrangement.spacedBy(Spacing.xs)) {
        Row(Modifier.fillMaxWidth().padding(horizontal = Spacing.l), verticalAlignment = Alignment.CenterVertically) {
            Text("Popular", style = sectionStyle(), modifier = Modifier.weight(1f))
            if (tracks.size > 5) Text(if (showAll) "Show Less" else "See All", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.clickable { showAll = !showAll }.padding(8.dp))
        }
        (if (showAll) tracks else tracks.take(5)).forEach { track ->
            val song = mine(track)
            var menu by remember { mutableStateOf(false) }
            Row(Modifier.fillMaxWidth().then(
                if (song != null) Modifier.clickable { onPlay(playable, playable.indexOf(song).coerceAtLeast(0)) }
                else Modifier.combinedClickable(onClick = { menu = true }, onLongClick = { menu = true }))
                .padding(horizontal = Spacing.l, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
                if (song != null) Artwork(client?.imageUrl(song.imageItemId, 160), Modifier.size(48.dp), RoundedCornerShape(8.dp))
                Column(Modifier.weight(1f).then(if (song == null) Modifier.padding(start = 0.dp) else Modifier)) {
                    Text(track.title, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        color = if (song != null) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f))
                    track.album?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = if (song != null) 1f else 0.5f), maxLines = 1) }
                }
                Text(compact(track.listens), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (song == null) DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text("Open in Spotify") }, leadingIcon = { Icon(Icons.AutoMirrored.Rounded.OpenInNew, null) }, onClick = {
                        menu = false
                        uriHandler.openUri("https://open.spotify.com/search/" + android.net.Uri.encode("$artistName ${track.title}"))
                    })
                }
            }
        }
    }
}

private fun compact(n: Int): String = when {
    n >= 1_000_000_000 -> "%.1fB".format(n / 1e9)
    n >= 1_000_000 -> "%.1fM".format(n / 1e6)
    n >= 1_000 -> "${n / 1000}K"
    else -> "$n"
}


// MARK: - Skeletons in the shape of the page

/** A row of grey tiles in the shape of a shelf (circles for artists, covers for albums), with its grey title above. */
@Composable
fun SkeletonShelf(tileWidth: androidx.compose.ui.unit.Dp, circular: Boolean, count: Int = 4, titleWidth: androidx.compose.ui.unit.Dp = 140.dp) {
    Column(verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        Ghost(Modifier.padding(horizontal = Spacing.l).width(titleWidth).height(20.dp).clip(RoundedCornerShape(6.dp)))
        LazyRow(contentPadding = PaddingValues(horizontal = Spacing.l), horizontalArrangement = Arrangement.spacedBy(Spacing.m), userScrollEnabled = false) {
            items(count) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Ghost(Modifier.size(tileWidth).clip(if (circular) CircleShape else RoundedCornerShape(16.dp)))
                    Ghost(Modifier.width(tileWidth * 0.7f).height(10.dp).clip(RoundedCornerShape(4.dp)))
                }
            }
        }
    }
}

/** Grey song rows: a small cover, two lines. */
@Composable
fun SkeletonRows(count: Int = 3) {
    Column(verticalArrangement = Arrangement.spacedBy(Spacing.m), modifier = Modifier.padding(horizontal = Spacing.l)) {
        repeat(count) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
                Ghost(Modifier.size(48.dp).clip(RoundedCornerShape(8.dp)))
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Ghost(Modifier.width(170.dp).height(12.dp).clip(RoundedCornerShape(4.dp)))
                    Ghost(Modifier.width(100.dp).height(10.dp).clip(RoundedCornerShape(4.dp)))
                }
            }
        }
    }
}

/** Search results while they load, shaped like the results: artists, albums, then songs (only the kind chosen, when one is). */
@Composable
fun SearchSkeleton(scope: String = "All") {
    Column(verticalArrangement = Arrangement.spacedBy(Spacing.l), modifier = Modifier.padding(top = Spacing.l)) {
        if (scope == "All" || scope == "Artists") SkeletonShelf(110.dp, circular = true)
        if (scope == "All" || scope == "Albums") SkeletonShelf(140.dp, circular = false, count = 3)
        if (scope == "All" || scope == "Playlists") if (scope == "Playlists") SkeletonShelf(140.dp, circular = false, count = 3)
        if (scope == "All" || scope == "Songs") SkeletonRows()
    }
}

/** Discovery's hero while it loads: the wide picture and the three lines under it. */
@Composable
fun DiscoveryHeroSkeleton() {
    Column(Modifier.padding(horizontal = Spacing.l), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
        Ghost(Modifier.fillMaxWidth().aspectRatio(16f / 9f).clip(RoundedCornerShape(16.dp)))
        Ghost(Modifier.width(70.dp).height(10.dp).clip(RoundedCornerShape(4.dp)))
        Ghost(Modifier.width(190.dp).height(18.dp).clip(RoundedCornerShape(4.dp)))
        Ghost(Modifier.width(120.dp).height(12.dp).clip(RoundedCornerShape(4.dp)))
    }
}

/** An artist's page while it loads: the Popular rows and a shelf of albums. */
@Composable
fun ArtistPageSkeleton() {
    Column(verticalArrangement = Arrangement.spacedBy(Spacing.l)) {
        Ghost(Modifier.padding(horizontal = Spacing.l).width(100.dp).height(20.dp).clip(RoundedCornerShape(6.dp)))
        SkeletonRows(4)
        SkeletonShelf(150.dp, circular = false, count = 3)
    }
}
