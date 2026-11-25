package app.dial.tv

import kotlinx.coroutines.delay
import androidx.compose.ui.focus.focusRequester
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
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
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.QueueMusic
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Repeat
import androidx.compose.material.icons.rounded.RepeatOne
import androidx.compose.material.icons.rounded.Shuffle
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material.icons.rounded.SkipPrevious
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Lyrics
import androidx.compose.material.icons.rounded.MoreHoriz
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.media3.common.Player
import app.dial.data.Item
import app.dial.data.Lyrics
import app.dial.data.formatTime
import coil3.compose.AsyncImage

/**
 * Dial's player on a TV. Not the phone's player made bigger: the cover is the backdrop, the title is large at the left,
 * and everything you press is one row of round buttons under a thin progress bar. Queue opens from the right edge.
 */
@Composable
fun TvPlayer() {
    val app = LocalTvApp.current
    val nav = LocalTvNav.current
    val client = tvClient()
    val state by app.player.state.collectAsState()
    val favorites by app.library.favorites.collectAsState()
    // One panel at a time on the right: the queue or the lyrics. Back closes it before it leaves the player.
    var panel by remember { mutableStateOf(0) } // 0 none, 1 queue, 2 lyrics
    // The player opens with play/pause selected, so one press pauses or resumes.
    val playFocus = remember { androidx.compose.ui.focus.FocusRequester() }
    LaunchedEffect(Unit) { delay(150); runCatching { playFocus.requestFocus() } }
    androidx.activity.compose.BackHandler(enabled = panel != 0) { panel = 0 }
    val track = state.current
    val art = track?.let { client?.imageUrl(it.imageItemId, 800) } ?: state.station?.favicon

    var details by remember(track?.id) { mutableStateOf<Item?>(null) }
    LaunchedEffect(track?.id) { track?.let { details = runCatching { client?.details(it.id) }.getOrNull() } }

    Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
        // The cover is the backdrop, with a scrim so the text stays readable.
        AsyncImage(art, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop, alpha = 0.45f)
        Box(Modifier.fillMaxSize().background(Brush.horizontalGradient(listOf(MaterialTheme.colorScheme.background.copy(alpha = 0.92f), Color.Transparent))))
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0.5f to Color.Transparent, 1f to MaterialTheme.colorScheme.background)))

        Column(Modifier.fillMaxSize().padding(horizontal = Tv.marginX, vertical = 36.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                RoundButton(Icons.Rounded.Close, "Close", 44.dp) { nav.back() }
            }
            Spacer(Modifier.weight(1f))
            // Title block: the small cover, the title, who and where from, the file.
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                AsyncImage(art, null, Modifier.size(132.dp).clip(RoundedCornerShape(12.dp)), contentScale = ContentScale.Crop)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(track?.name ?: state.station?.name ?: state.pendingTitle ?: "", style = MaterialTheme.typography.displayMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    Text(track?.artistLine ?: "Live radio", style = MaterialTheme.typography.titleLarge, color = Accent, maxLines = 1)
                    val album = listOfNotNull(track?.album, track?.productionYear?.toString()).joinToString(" · ")
                    if (album.isNotEmpty()) Text(album, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                    details?.let { d ->
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                            d.formatLabel?.let { Text(it, style = MaterialTheme.typography.labelMedium, modifier = Modifier.border(1.dp, MaterialTheme.colorScheme.onSurfaceVariant, RoundedCornerShape(4.dp)).padding(horizontal = 6.dp, vertical = 2.dp)) }
                            d.qualityLabel?.let { Text(it, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                        }
                    }
                }
            }
            Spacer(Modifier.height(20.dp))
            if (!state.isLive) {
                SeekBar(state.positionMs, state.durationMs) { app.player.seek(it) }
                Row(Modifier.fillMaxWidth().padding(top = 4.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(formatTime(state.positionMs), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text("-" + formatTime(state.durationMs - state.positionMs), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            Spacer(Modifier.height(14.dp))
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                RoundButton(Icons.Rounded.SkipPrevious, "Previous", 52.dp) { app.player.previous() }
                RoundButton(if (state.isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow, if (state.isPlaying) "Pause" else "Play", 68.dp, filled = true,
                    modifier = Modifier.focusRequester(playFocus)) { app.player.togglePlayPause() }
                RoundButton(Icons.Rounded.SkipNext, "Next", 52.dp) { app.player.next() }
                RoundButton(Icons.Rounded.Shuffle, "Shuffle", 52.dp, active = state.shuffle) { app.player.toggleShuffle() }
                RoundButton(if (state.repeat == Player.REPEAT_MODE_ONE) Icons.Rounded.RepeatOne else Icons.Rounded.Repeat, "Repeat", 52.dp,
                    active = state.repeat != Player.REPEAT_MODE_OFF) { app.player.cycleRepeat() }
                Spacer(Modifier.weight(1f))
                val favorite = track?.id in favorites
                RoundButton(if (favorite) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder, "Favorite", 52.dp, active = favorite) { track?.let(app.library::toggleFavorite) }
                if (!state.isLive) RoundButton(Icons.Rounded.Lyrics, "Lyrics", 52.dp, active = panel == 2) { panel = if (panel == 2) 0 else 2 }
                RoundButton(Icons.AutoMirrored.Rounded.QueueMusic, "Queue", 52.dp, active = panel == 1) { panel = if (panel == 1) 0 else 1 }
                RoundButton(Icons.Rounded.MoreHoriz, "More", 52.dp, active = panel == 3) { panel = if (panel == 3) 0 else 3 }
            }
        }

        if (panel == 2 && track != null) TvLyrics(track, state.positionMs)
        if (panel == 3) Box(Modifier.align(Alignment.CenterEnd)) { TvPlayerMenu(track, state) { panel = 0 } }
        if (panel == 1) {
            Column(Modifier.align(Alignment.CenterEnd).fillMaxHeight().width(380.dp).background(MaterialTheme.colorScheme.surface.copy(alpha = 0.96f)).padding(20.dp)) {
                Text("Up Next", style = MaterialTheme.typography.headlineMedium, modifier = Modifier.padding(bottom = 12.dp))
                LazyColumn(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    itemsIndexed(state.upNext) { offset, song ->
                        val shape = RoundedCornerShape(Tv.radius)
                        Row(Modifier.fillMaxWidth().tvFocus(shape).clip(shape).clickable { app.player.jump(state.index + 1 + offset) }.padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                            AsyncImage(client?.imageUrl(song.imageItemId, 120), null, Modifier.size(44.dp).clip(RoundedCornerShape(6.dp)), contentScale = ContentScale.Crop)
                            Column(Modifier.padding(start = 12.dp)) {
                                Text(song.name, style = MaterialTheme.typography.labelLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text(song.artistLine, style = MaterialTheme.typography.labelMedium, maxLines = 1, overflow = TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                }
            }
        }
    }
}

/** A round button for the remote. The play button is filled; toggles turn amber when on. */
@Composable
private fun RoundButton(icon: ImageVector, label: String, size: Dp, filled: Boolean = false, active: Boolean = false, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Box(modifier.size(size).tvFocus(CircleShape).clip(CircleShape)
        .background(if (filled) Color.White else MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.7f))
        .clickable(onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(icon, label, Modifier.size(size * 0.5f), tint = if (filled) Color.Black else if (active) Accent else Color.White)
    }
}

/** A thin bar you can focus; Left and Right on the remote move 10 seconds. */
@Composable
private fun SeekBar(positionMs: Long, durationMs: Long, onSeek: (Long) -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val progress = if (durationMs > 0) (positionMs.toFloat() / durationMs).coerceIn(0f, 1f) else 0f
    Box(Modifier.fillMaxWidth().height(14.dp).onFocusChanged { focused = it.isFocused }
        .onKeyEvent { event ->
            if (event.type == KeyEventType.KeyDown && (event.key == Key.DirectionLeft || event.key == Key.DirectionRight)) {
                onSeek((positionMs + if (event.key == Key.DirectionRight) 10_000 else -10_000).coerceIn(0, durationMs)); true
            } else false
        }.focusable(), contentAlignment = Alignment.CenterStart) {
        Box(Modifier.fillMaxWidth().height(if (focused) 10.dp else 6.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.25f)))
        Box(Modifier.fillMaxWidth(progress).height(if (focused) 10.dp else 6.dp).clip(CircleShape).background(if (focused) Accent else Color.White))
    }
}

/** Lyrics from your server, or from LRCLIB when it has none. Synced lyrics follow the song; the line being sung is bright. */
@Composable
private fun BoxScope.TvLyrics(track: Item, positionMs: Long) {
    val app = LocalTvApp.current
    val client = tvClient()
    var result by remember(track.id) { mutableStateOf<Lyrics.Result?>(null) }
    var loaded by remember(track.id) { mutableStateOf(false) }
    LaunchedEffect(track.id) {
        result = client?.let { runCatching { Lyrics.find(track, it) }.getOrNull() }
        loaded = true
    }
    val lines = result?.lines ?: emptyList()
    val synced = lines.any { it.startMs != null }
    val active = if (synced) lines.indexOfLast { (it.startMs ?: Long.MAX_VALUE) <= positionMs } else -1
    val listState = androidx.compose.foundation.lazy.rememberLazyListState()
    LaunchedEffect(active) { if (active > 2) listState.animateScrollToItem(active - 2) }
    Column(Modifier.align(Alignment.CenterEnd).fillMaxHeight().width(420.dp).background(MaterialTheme.colorScheme.surface.copy(alpha = 0.96f)).padding(20.dp)) {
        Text("Lyrics", style = MaterialTheme.typography.headlineMedium, modifier = Modifier.padding(bottom = 12.dp))
        when {
            !loaded -> Text("Finding lyrics\u2026", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            lines.isEmpty() -> Text("No lyrics for this song. Neither your server nor LRCLIB has them.", style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            else -> LazyColumn(state = listState, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                itemsIndexed(lines) { index, line ->
                    val shape = RoundedCornerShape(Tv.radius)
                    Text(line.text.ifBlank { "\u266a" }, style = MaterialTheme.typography.titleLarge,
                        color = if (!synced || index == active) Color.White else Color.White.copy(alpha = 0.4f),
                        modifier = Modifier.fillMaxWidth().tvFocus(shape).clip(shape).clickable(enabled = line.startMs != null) { line.startMs?.let { app.player.seek(it) } }.padding(6.dp))
                }
                if (result?.fromLrclib == true) item {
                    Text("Lyrics from LRCLIB", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(vertical = 12.dp))
                }
            }
        }
    }
}
