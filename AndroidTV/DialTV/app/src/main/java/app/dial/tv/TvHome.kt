package app.dial.tv

import kotlinx.coroutines.delay
import androidx.compose.ui.focus.focusRequester
import kotlinx.coroutines.launch
import app.dial.data.HighlightBuilder
import app.dial.data.HighlightAction
import app.dial.data.Highlight
import androidx.compose.material3.Icon
import androidx.compose.material.icons.rounded.Sensors
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.Icons
import androidx.compose.foundation.lazy.items
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.dial.data.Item
import app.dial.data.JellyfinClient
import androidx.compose.foundation.combinedClickable
import androidx.compose.ui.focus.focusProperties
import app.dial.data.MixCatalog
import app.dial.data.MixSections
import app.dial.data.Mixtape
import coil3.compose.AsyncImage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Loads something from your server for a screen. null until it arrives (or if it fails). */
@Composable
fun <T> rememberTvLoad(key: Any?, block: suspend (JellyfinClient) -> T): T? {
    val app = LocalTvApp.current
    val state by produceState<T?>(null, key) {
        val client = app.session.client.value ?: return@produceState
        value = withContext(Dispatchers.IO) { runCatching { block(client) }.getOrNull() }
    }
    return state
}

@Composable
fun tvClient(): JellyfinClient? {
    val client by LocalTvApp.current.session.client.collectAsState()
    return client
}

/** A titled row of cards that scrolls sideways. */
@Composable
fun <T> TvRow(title: String, items: List<T>, topRow: Boolean = false, content: @Composable (Int, T) -> Unit) {
    if (items.isEmpty()) return
    val top = LocalTvTopFocus.current
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(title, style = MaterialTheme.typography.headlineMedium, modifier = Modifier.padding(horizontal = Tv.marginX))
        LazyRow(contentPadding = PaddingValues(horizontal = Tv.marginX, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(Tv.gap)) {
            itemsIndexed(items) { index, item ->
                // The first row of a tab: Up from its cards goes to the top bar, not to whatever is above on the left.
                if (topRow) Box(Modifier.focusProperties { up = top }) { content(index, item) } else content(index, item)
            }
        }
    }
}

/** A row's place while it is being made: grey tiles, so nothing below jumps when it arrives. */
@Composable
fun TvRowPlaceholder(title: String) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(title, style = MaterialTheme.typography.headlineMedium, modifier = Modifier.padding(horizontal = Tv.marginX))
        Row(Modifier.padding(horizontal = Tv.marginX, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(Tv.gap)) {
            repeat(5) {
                Box(Modifier.width(Tv.coverWidth).aspectRatio(1f).clip(RoundedCornerShape(Tv.radius))
                    .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f)))
            }
        }
    }
}

/** A mixtape: four covers under a color wash and its name. */
@Composable
fun TvMixtapeCard(mixtape: Mixtape, onFocus: () -> Unit = {}, onClick: () -> Unit) {
    val client = tvClient()
    val shape = RoundedCornerShape(Tv.radius)
    val colors = mixtape.palette.map { runCatching { Color(android.graphics.Color.parseColor(it)) }.getOrDefault(Color.DarkGray) }
    val stage = LocalTvStage.current
    Column(Modifier.width(Tv.coverWidth)) {
        Box(Modifier.fillMaxWidth().aspectRatio(1f).tvFocus(shape) { stage.show(TvStage(mixtape.title, mixtape.subtitle, mixtape.covers.firstOrNull()?.let { client?.imageUrl(it, 900) },
                alternatives = mixtape.covers.drop(1).mapNotNull { client?.imageUrl(it, 900) })); onFocus() }
            .clip(shape).clickable(onClick = onClick)) {
            val decade = if (mixtape.id.startsWith("decade-")) mixtape.id.removePrefix("decade-").toIntOrNull() else null
            if (decade != null) {
                // A decade is a poster of its era.
                EraCover(decade, Modifier.fillMaxSize(), 0.dp)
            } else if (mixtape.id.startsWith("genre-")) {
                GenreCover(mixtape.title, mixtape.palette, Modifier.fillMaxSize(), 0.dp)
            } else {
                Column(Modifier.fillMaxSize()) {
                    for (row in 0..1) Row(Modifier.weight(1f)) {
                        for (column in 0..1) {
                            val id = mixtape.covers.getOrNull((row * 2 + column) % maxOf(mixtape.covers.size, 1))
                            AsyncImage(id?.let { client?.imageUrl(it, 200) }, null, Modifier.weight(1f).fillMaxSize(), contentScale = ContentScale.Crop)
                        }
                    }
                }
                Box(Modifier.fillMaxSize().background(Brush.linearGradient(colors.map { it.copy(alpha = 0.82f) }.ifEmpty { listOf(Color.DarkGray, Color.Black) })))
                Text(mixtape.title, style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.ExtraBold), color = Color.White,
                    maxLines = 3, overflow = TextOverflow.Ellipsis, modifier = Modifier.align(Alignment.BottomStart).padding(10.dp))
            }
        }
        Text(mixtape.subtitle, style = MaterialTheme.typography.labelMedium, maxLines = 1, overflow = TextOverflow.Ellipsis,
            color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 8.dp))
    }
}

private data class HomeData(val added: List<Item>, val played: List<Item>, val favorites: List<Item>)

/** Dial's Home on a TV: the same order as on iPhone and Android, sized for the couch. */
@Composable
fun TvHome() {
    val app = LocalTvApp.current
    val nav = LocalTvNav.current
    val client = tvClient()
    val data = rememberTvLoad("home") { HomeData(it.recentAlbums(12), it.recentlyPlayed(24), it.favoriteAlbums()) }
    // The splash waits for these: once Home's rows have arrived it can go.
    LaunchedEffect(data) { if (data != null) TvBoot.homeReady = true }
    var mixes by remember { mutableStateOf(MixCatalog.latest ?: MixSections()) }
    LaunchedEffect(client) {
        val c = client ?: return@LaunchedEffect
        val muse = withContext(Dispatchers.IO) { runCatching { c.audioMuseCanSearch() }.getOrDefault(false) }
        launch { MixCatalog.load(c, muse) { if (it != mixes) mixes = it } }
    }
    val played = data?.played ?: emptyList()
    // Start with the first recently played song selected, so the stage has something to show.
    val firstSong = remember { androidx.compose.ui.focus.FocusRequester() }
    LaunchedEffect(played.isNotEmpty()) {
        if (played.isNotEmpty()) { delay(150); runCatching { firstSong.requestFocus() } }
    }

    val topFocus = LocalTvTopFocus.current
    LazyColumn(contentPadding = PaddingValues(top = 8.dp, bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(26.dp)) {
        if (played.isNotEmpty()) item {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("Recently Played", style = MaterialTheme.typography.headlineMedium, modifier = Modifier.padding(horizontal = Tv.marginX))
                // Columns of four songs that scroll sideways, as on the phone.
                LazyRow(contentPadding = PaddingValues(horizontal = Tv.marginX, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                    items(played.chunked(4).size) { column ->
                        Column(Modifier.width(430.dp)) {
                            played.chunked(4)[column].forEachIndexed { row, song ->
                                TvSongRow(song, client?.imageUrl(song.imageItemId, 160),
                                    // Only the top song of each column sends Up to the top bar; the rest move up within the column.
                                    (if (column == 0 && row == 0) Modifier.focusRequester(firstSong) else Modifier)
                                        .then(if (row == 0) Modifier.focusProperties { up = topFocus } else Modifier)) { app.player.playLike(song); nav.open(TvRoute.Player) }
                            }
                        }
                    }
                }
            }
        }
        item {
            TvRow("Stations", listOf("mix", "favorites"), topRow = played.isEmpty()) { _, which ->
                val mix = which == "mix"
                TvStationCard(if (mix) "Your Mix" else "Favorites Mix", if (mix) "Your whole library" else "Songs you love", mix) {
                    app.player.play(if (mix) "Your Mix" else "Favorites Mix", radio = true) { c ->
                        val seed = (if (mix) c.randomSongs(1).firstOrNull() else c.favoriteSongs().randomOrNull()) ?: return@play emptyList()
                        listOf(seed) + c.instantMix(seed.id, 30).filter { it.id != seed.id }
                    }
                    nav.open(TvRoute.Player)
                }
            }
        }
        item { TvRow("Mixtapes", mixes.highlights(10)) { _, m -> TvMixtapeCard(m) { nav.open(TvRoute.Mixtape(m.id)) } } }
        item {
            TvRow("Recently Added", data?.added ?: emptyList()) { _, album ->
                CoverCard(album.name, album.albumArtistLine, client?.imageUrl(album.id, 320)) { nav.open(TvRoute.Album(album.id, album.name)) }
            }
        }
        item {
            TvRow("Favorite Albums", data?.favorites ?: emptyList()) { _, album ->
                CoverCard(album.name, album.albumArtistLine, client?.imageUrl(album.id, 320)) { nav.open(TvRoute.Album(album.id, album.name)) }
            }
        }
    }
}

/** One song in a list: cover, title, artist, length. */
@Composable
fun TvSongRow(song: Item, imageUrl: String?, modifier: Modifier = Modifier, onLongClick: (() -> Unit)? = null, onClick: () -> Unit) {
    val shape = RoundedCornerShape(Tv.radius)
    val stage = LocalTvStage.current
    Row(modifier.fillMaxWidth().tvFocus(shape) { stage.show(TvStage(song.name, listOfNotNull(song.artistLine, song.album).joinToString(" \u00b7 "), backdropOf(imageUrl))) }
        .clip(shape).combinedClickable(onClick = onClick, onLongClick = onLongClick).padding(horizontal = 8.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically) {
        AsyncImage(imageUrl, null, Modifier.size(56.dp).clip(RoundedCornerShape(8.dp)), contentScale = ContentScale.Crop)
        Column(Modifier.weight(1f).padding(horizontal = 14.dp)) {
            Text(song.name, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(song.artistLine, style = MaterialTheme.typography.labelMedium, maxLines = 1, overflow = TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Text(app.dial.data.formatTime(song.durationMs), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** Your Mix and Favorites Mix: a gradient square with a symbol, the same as on the phone. */
@Composable
fun TvStationCard(title: String, subtitle: String, mix: Boolean, onClick: () -> Unit) {
    val shape = RoundedCornerShape(Tv.radius)
    val colors = if (mix) listOf(Color(0xFFE8742C), Color(0xFFA8401A)) else listOf(Color(0xFFC2455E), Color(0xFF6E2A6E))
    val stage = LocalTvStage.current
    Column(Modifier.width(Tv.coverWidth)) {
        Box(Modifier.fillMaxWidth().aspectRatio(1f).tvFocus(shape) { stage.show(TvStage(title, subtitle)) }.clip(shape).clickable(onClick = onClick).background(Brush.linearGradient(colors)),
            contentAlignment = Alignment.Center) {
            Icon(if (mix) Icons.Rounded.Sensors else Icons.Rounded.Favorite, null, Modifier.size(52.dp), tint = Color.White.copy(alpha = 0.9f))
        }
        Text(title, style = MaterialTheme.typography.labelLarge, maxLines = 1, modifier = Modifier.padding(top = 8.dp))
        Text(subtitle, style = MaterialTheme.typography.labelMedium, maxLines = 1, overflow = TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** A highlight: the artist's backdrop, their logo, and at the bottom the cover, label, title, artist and a play button. */
@Composable
fun TvHighlightCard(highlight: Highlight, modifier: Modifier) {
    val app = LocalTvApp.current
    val nav = LocalTvNav.current
    val client = tvClient()
    val shape = RoundedCornerShape(16.dp)
    val coverUrl = highlight.coverItemId?.let { client?.imageUrl(it, 400) } ?: highlight.coverUrl
    fun open() = when (val a = highlight.action) {
        is HighlightAction.Album -> nav.open(TvRoute.Album(a.id, a.name))
        is HighlightAction.PublicAlbum -> Unit
        is HighlightAction.ArtistRadio -> nav.open(TvRoute.Artist(a.id, a.name))
    }
    val stage = LocalTvStage.current
    Box(modifier.aspectRatio(16f / 9f).tvFocus(shape) {
        stage.show(TvStage(highlight.title, listOf(highlight.label, highlight.subtitle).joinToString(" \u00b7 "),
            highlight.artistId?.let { client?.imageUrl(it, "Backdrop/0", 1280) } ?: highlight.coverItemId?.let { client?.imageUrl(it, 900) } ?: highlight.coverUrl))
    }.clip(shape).clickable { open() }) {
        AsyncImage(coverUrl, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        highlight.artistId?.let { id ->
            AsyncImage(client?.imageUrl(id, "Backdrop/0", 960), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            AsyncImage(client?.imageUrl(id, "Logo", 400), null, Modifier.align(Alignment.TopStart).padding(16.dp).size(width = 160.dp, height = 44.dp),
                contentScale = ContentScale.Fit, alignment = Alignment.TopStart)
        }
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0.45f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.75f))))
        Row(Modifier.align(Alignment.BottomStart).padding(14.dp), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            AsyncImage(coverUrl, null, Modifier.size(52.dp).clip(RoundedCornerShape(8.dp)), contentScale = ContentScale.Crop)
            Column(Modifier.weight(1f)) {
                Text(highlight.label, style = MaterialTheme.typography.labelMedium, color = Color.White.copy(alpha = 0.8f), maxLines = 1)
                Text(highlight.title, style = MaterialTheme.typography.titleMedium, color = Color.White, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(highlight.subtitle, style = MaterialTheme.typography.labelMedium, color = Color.White.copy(alpha = 0.8f), maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}
