@file:OptIn(ExperimentalMaterial3Api::class)

package app.dial.ui.screens

import app.dial.ui.LocalNavigator
import kotlinx.coroutines.launch
import androidx.compose.foundation.border
import androidx.compose.material.icons.rounded.Album
import androidx.compose.material.icons.rounded.Sensors
import androidx.compose.material.icons.rounded.AllInclusive
import androidx.compose.material.icons.rounded.StarBorder
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.MoreHoriz
import androidx.compose.material.icons.rounded.FastForward
import androidx.compose.material.icons.rounded.FastRewind
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.draw.clip
import androidx.compose.material3.IconToggleButton
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.animateIntAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
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
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.QueueMusic
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.Lyrics
import androidx.compose.material.icons.rounded.Devices
import androidx.compose.material.icons.rounded.Speaker
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Radio
import androidx.compose.material.icons.rounded.Repeat
import androidx.compose.material.icons.rounded.RepeatOne
import androidx.compose.material.icons.rounded.Shuffle
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material.icons.rounded.SkipPrevious
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.palette.graphics.Palette
import app.dial.data.formatTime
import app.dial.playback.PlaybackState
import app.dial.ui.ArtistRoute
import app.dial.ui.AlbumRoute
import app.dial.ui.LocalApp
import app.dial.ui.components.Artwork
import app.dial.ui.components.Spacing
import app.dial.ui.components.black
import app.dial.ui.components.bold
import app.dial.ui.theme.DialTheme
import app.dial.ui.theme.schemeFromArtwork
import androidx.compose.material3.ColorScheme
import androidx.compose.ui.graphics.toArgb
import androidx.media3.common.Player
import coil3.SingletonImageLoader
import coil3.request.ImageRequest
import coil3.request.SuccessResult
import coil3.request.allowHardware
import coil3.toBitmap
import app.dial.data.Item
import app.dial.data.Lyrics
import app.dial.ui.artistRoute

// MARK: - Mini player

@Composable
fun MiniPlayer(onOpen: () -> Unit) {
    val app = LocalApp.current
    val state by app.player.state.collectAsState()
    val client = client()
    val track = state.current
    Surface(
        onClick = onOpen,
        shape = RoundedCornerShape(24.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        modifier = Modifier.fillMaxWidth().padding(horizontal = Spacing.s, vertical = Spacing.xs),
    ) {
        Column {
            Row(Modifier.padding(Spacing.s), verticalAlignment = Alignment.CenterVertically) {
                Artwork(track?.let { client?.imageUrl(it.imageItemId, 160) } ?: state.station?.favicon, Modifier.size(48.dp), RoundedCornerShape(14.dp))
                Column(Modifier.weight(1f).padding(horizontal = Spacing.m)) {
                    Text(track?.name ?: state.station?.name ?: state.pendingTitle ?: "", style = MaterialTheme.typography.titleSmall.bold(),
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                    val subtitle = when {
                        state.outputName != null -> "Playing on ${state.outputName}"
                        state.station != null -> "Live radio"
                        track == null -> "Loading\u2026"
                        else -> track.artistLine
                    }
                    Text(subtitle, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        color = if (state.isRemote) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
                }
                if ((track == null && state.station == null) || state.isBuffering && !state.isPlaying) {
                    CircularProgressIndicator(Modifier.size(40.dp), strokeWidth = 3.dp)
                } else {
                    IconButton(onClick = { app.player.togglePlayPause() }) {
                        Icon(if (state.isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow, if (state.isPlaying) "Pause" else "Play")
                    }
                }
                IconButton(onClick = { app.player.next() }, enabled = track != null) { Icon(Icons.Rounded.SkipNext, "Next") }
            }
            val progress = if (state.durationMs > 0) state.positionMs.toFloat() / state.durationMs else 0f
            LinearProgressIndicator(progress = { progress }, modifier = Modifier.fillMaxWidth().padding(horizontal = Spacing.l).padding(bottom = Spacing.xs),
                drawStopIndicator = {})
        }
    }
}

// MARK: - Full player

@Composable
fun NowPlayingScreen(onClose: () -> Unit, onOpen: (Any) -> Unit) {
    val app = LocalApp.current
    val state by app.player.state.collectAsState()
    val client = client()
    val context = LocalContext.current
    val track = state.current

    // Colors from the album cover, like on iPhone.
    var scheme by remember { mutableStateOf<ColorScheme?>(null) }
    val artUrl = track?.let { client?.imageUrl(it.imageItemId, 800) } ?: state.station?.favicon
    val mirror by app.remote.djMirror.collectAsState()
    LaunchedEffect(artUrl) {
        if (artUrl == null) return@LaunchedEffect
        val result = SingletonImageLoader.get(context).execute(
            ImageRequest.Builder(context).data(artUrl).allowHardware(false).size(160).build())
        val bitmap = (result as? SuccessResult)?.image?.toBitmap() ?: return@LaunchedEffect
        val palette = Palette.from(bitmap).generate()
        val seed = palette.getVibrantColor(palette.getDominantColor(0xFFE8742C.toInt()))
        scheme = schemeFromArtwork(seed)
    }

    var showLyrics by remember { mutableStateOf(false) }

    DialTheme(colorScheme = scheme) {
        val colors = MaterialTheme.colorScheme
        val top by animateColorAsState(colors.primaryContainer, label = "top")
        val bottom by animateColorAsState(colors.background, label = "bottom")
        // Catches touches so nothing behind the player reacts to them.
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(top, bottom)))
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {}) {
            Column(
                Modifier.fillMaxSize().safeDrawingPadding().padding(horizontal = Spacing.xl),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                IconButton(onClick = onClose, modifier = Modifier.padding(top = Spacing.s)) {
                    Icon(Icons.Rounded.KeyboardArrowDown, "Close player", tint = colors.onSurface)
                }
                if (showLyrics && track != null) {
                    Box(Modifier.weight(1f).fillMaxWidth()) { LyricsPanel(track, state) }
                } else {
                    Spacer(Modifier.weight(0.5f))
                    // The cover shrinks a little while paused, and springs back when the music plays.
                    val scale by animateFloatAsState(if (state.isPlaying) 1f else 0.88f,
                        spring(dampingRatio = 0.6f, stiffness = 300f), label = "cover")
                    Artwork(artUrl, Modifier.widthIn(max = 420.dp).fillMaxWidth().aspectRatio(1f).scale(scale), RoundedCornerShape(16.dp))
                    Spacer(Modifier.weight(0.5f))
                }
                TrackTitles(track, state, onOpen, centered = true)
                TrackFileRow(track, centered = true)

                Spacer(Modifier.height(Spacing.xl))
                if (state.isLive) {
                    Text("LIVE", style = MaterialTheme.typography.labelLarge.bold(), color = MaterialTheme.colorScheme.primary)
                } else {
                    SeekBar(state) { app.player.seek(it) }
                }
                Spacer(Modifier.height(Spacing.xl))
                Transport(state)
                Spacer(Modifier.height(Spacing.l))
                mirror?.let { MarloMirrorBar(it) }
                state.outputName?.let {
                    Text("Playing on $it", style = MaterialTheme.typography.labelLarge.bold(), color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.padding(bottom = Spacing.s))
                }
                Modes(state, showLyrics) { showLyrics = it }
                Spacer(Modifier.height(Spacing.l))
            }
        }
    }
}

/** Material Expressive's wavy progress while playing (flat while paused); tap or drag to seek. */
@Composable
private fun SeekBar(state: PlaybackState, onSeek: (Long) -> Unit) {
    var dragFraction by remember { mutableStateOf<Float?>(null) }
    var width by remember { mutableIntStateOf(1) }
    val progress = dragFraction ?: if (state.durationMs > 0) state.positionMs.toFloat() / state.durationMs else 0f
    Column(Modifier.fillMaxWidth()) {
        Box(
            Modifier.fillMaxWidth().height(32.dp)
                .pointerInput(state.durationMs) {
                    width = size.width
                    detectTapGestures { offset -> onSeek((offset.x / size.width * state.durationMs).toLong()) }
                }
                .pointerInput(state.durationMs) {
                    detectHorizontalDragGestures(
                        onDragStart = { dragFraction = (it.x / size.width).coerceIn(0f, 1f) },
                        onDragEnd = { dragFraction?.let { f -> onSeek((f * state.durationMs).toLong()) }; dragFraction = null },
                        onDragCancel = { dragFraction = null },
                    ) { change, _ -> dragFraction = (change.position.x / size.width).coerceIn(0f, 1f) }
                },
            contentAlignment = Alignment.Center,
        ) {
            // A thin flat bar, like the iPhone and Mac players.
            LinearProgressIndicator(
                progress = { progress }, modifier = Modifier.fillMaxWidth().height(6.dp).clip(CircleShape),
                color = Color.White, trackColor = Color.White.copy(alpha = 0.25f), gapSize = 0.dp, drawStopIndicator = {},
            )
        }
        Row(Modifier.fillMaxWidth()) {
            Text(formatTime((progress * state.durationMs).toLong()), style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f))
            Text("-" + formatTime(state.durationMs - (progress * state.durationMs).toLong()), style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** Previous, play or pause, next: big white glyphs with no button behind them, as on the iPhone and Mac. */
@Composable
private fun Transport(state: PlaybackState) {
    val app = LocalApp.current
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly, verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = { app.player.previous() }, modifier = Modifier.size(72.dp)) {
            Icon(Icons.Rounded.FastRewind, "Previous", Modifier.size(44.dp), tint = Color.White)
        }
        IconButton(onClick = { app.player.togglePlayPause() }, modifier = Modifier.size(88.dp)) {
            if (state.current == null && state.station == null) CircularProgressIndicator(color = Color.White, strokeWidth = 3.dp)
            else Icon(if (state.isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                if (state.isPlaying) "Pause" else "Play", Modifier.size(64.dp), tint = Color.White)
        }
        IconButton(onClick = { app.player.next() }, modifier = Modifier.size(72.dp)) {
            Icon(Icons.Rounded.FastForward, "Next", Modifier.size(44.dp), tint = Color.White)
        }
    }
}

/** The row at the bottom, the same five buttons as on iPhone and Mac: favorite, lyrics, devices, queue and more. */
@Composable
private fun Modes(state: PlaybackState, showLyrics: Boolean, onLyrics: (Boolean) -> Unit) {
    val app = LocalApp.current
    val navigator = LocalNavigator.current
    val favorites by app.library.favorites.collectAsState()
    var showQueue by remember { mutableStateOf(false) }
    var showDevices by remember { mutableStateOf(false) }
    var more by remember { mutableStateOf(false) }
    val track = state.current
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly, verticalAlignment = Alignment.CenterVertically) {
        val favorite = track?.id in favorites
        IconToggleButton(colors = dialToggleColors(), checked = favorite, onCheckedChange = { track?.let(app.library::toggleFavorite) }) {
            Icon(if (favorite) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder, "Favorite")
        }
        IconToggleButton(colors = dialToggleColors(), checked = showLyrics, onCheckedChange = onLyrics, enabled = !state.isLive) {
            Icon(Icons.Rounded.Lyrics, "Lyrics")
        }
        IconToggleButton(colors = dialToggleColors(), checked = state.isRemote, onCheckedChange = { showDevices = true }) {
            Icon(if (state.isRemote) Icons.Rounded.Speaker else Icons.Rounded.Devices, "Devices")
        }
        IconToggleButton(colors = dialToggleColors(), checked = showQueue, onCheckedChange = { showQueue = it }) {
            Icon(Icons.AutoMirrored.Rounded.QueueMusic, "Queue")
        }
        Box {
            IconButton(onClick = { more = true }) { Icon(Icons.Rounded.MoreHoriz, "More", tint = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.75f)) }
            androidx.compose.material3.DropdownMenu(expanded = more, onDismissRequest = { more = false }) {
                androidx.compose.material3.DropdownMenuItem(text = { Text(if (state.shuffle) "Shuffle: On" else "Shuffle: Off") },
                    leadingIcon = { Icon(Icons.Rounded.Shuffle, null) }, onClick = { more = false; app.player.toggleShuffle() })
                androidx.compose.material3.DropdownMenuItem(
                    text = { Text(when (state.repeat) { Player.REPEAT_MODE_ONE -> "Repeat: One"; Player.REPEAT_MODE_ALL -> "Repeat: All"; else -> "Repeat: Off" }) },
                    leadingIcon = { Icon(if (state.repeat == Player.REPEAT_MODE_ONE) Icons.Rounded.RepeatOne else Icons.Rounded.Repeat, null) },
                    onClick = { more = false; app.player.cycleRepeat() })
                androidx.compose.material3.DropdownMenuItem(text = { Text(if (state.radio) "Radio: On" else "Radio: Off") },
                    leadingIcon = { Icon(Icons.Rounded.Radio, null) }, onClick = { more = false; app.player.toggleRadio() })
                if (track != null) {
                    androidx.compose.material3.DropdownMenuItem(text = { Text("Start Radio") }, leadingIcon = { Icon(Icons.Rounded.Sensors, null) },
                        onClick = { more = false; app.player.startRadio(track) })
                    track.albumId?.let { albumId ->
                        androidx.compose.material3.DropdownMenuItem(text = { Text("Go to Album") }, leadingIcon = { Icon(Icons.Rounded.Album, null) },
                            onClick = { more = false; navigator.open(AlbumRoute(albumId, track.album ?: "")) })
                    }
                }
            }
        }
    }
    if (showDevices) DevicesSheet { showDevices = false }
    if (showQueue) QueueSheet(state, onDismiss = { showQueue = false })
}

/**
 * The file behind the song, as on iPhone and Mac: a format badge (FLAC), the exact quality (44.1 kHz / 16-bit)
 * and your rating in stars. The details arrive a moment after the song starts.
 */
@Composable
private fun TrackFileRow(track: Item?, centered: Boolean) {
    val app = LocalApp.current
    val client = client()
    if (track == null) return
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    var details by remember(track.id) { mutableStateOf<Item?>(null) }
    var rating by remember(track.id) { mutableStateOf(0) }
    LaunchedEffect(track.id) {
        details = runCatching { client?.details(track.id) }.getOrNull()
        rating = ((details?.userData?.rating ?: track.userData?.rating ?: 0.0) / 2).toInt()
    }
    val item = details ?: return
    val muted = MaterialTheme.colorScheme.onSurfaceVariant
    Row(Modifier.fillMaxWidth(), horizontalArrangement = if (centered) Arrangement.Center else Arrangement.Start,
        verticalAlignment = Alignment.CenterVertically) {
        item.formatLabel?.let { format ->
            Text(format, style = MaterialTheme.typography.labelSmall.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.Bold), color = muted,
                modifier = Modifier.border(1.dp, muted, RoundedCornerShape(4.dp)).padding(horizontal = 6.dp, vertical = 2.dp))
            Spacer(Modifier.width(Spacing.m))
        }
        item.qualityLabel?.let {
            Text(it, style = MaterialTheme.typography.labelMedium, color = muted)
            Spacer(Modifier.width(Spacing.m))
        }
        for (star in 1..5) {
            Icon(if (star <= rating) Icons.Rounded.Star else Icons.Rounded.StarBorder, "Rate $star", tint = if (star <= rating) Color.White else muted,
                modifier = Modifier.size(28.dp).clickable {
                    val next = if (star == rating) 0 else star
                    rating = next
                    client?.let { c -> scope.launch { runCatching { c.setRating(track.id, next) } } }
                }.padding(4.dp))
        }
    }
}

@Composable
private fun QueueSheet(state: PlaybackState, onDismiss: () -> Unit) {
    val app = LocalApp.current
    val client = client()
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Row(Modifier.fillMaxWidth().padding(horizontal = Spacing.l), verticalAlignment = Alignment.CenterVertically) {
            Text("Up Next", style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
            IconToggleButton(colors = dialToggleColors(), checked = state.shuffle, onCheckedChange = { app.player.toggleShuffle() }) {
                Icon(Icons.Rounded.Shuffle, "Shuffle")
            }
            IconToggleButton(colors = dialToggleColors(), checked = state.repeat != Player.REPEAT_MODE_OFF, onCheckedChange = { app.player.cycleRepeat() }) {
                Icon(if (state.repeat == Player.REPEAT_MODE_ONE) Icons.Rounded.RepeatOne else Icons.Rounded.Repeat, "Repeat")
            }
            IconToggleButton(colors = dialToggleColors(), checked = state.radio, onCheckedChange = { app.player.toggleRadio() }) {
                Icon(Icons.Rounded.AllInclusive, "Keep the music going")
            }
        }
        if (state.upNext.isEmpty()) {
            Text(if (state.radio) "Radio is finding more songs\u2026" else "Nothing up next. Turn on Radio to keep the music going.",
                color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(Spacing.l))
        }
        LazyColumn(Modifier.padding(bottom = Spacing.xl)) {
            itemsIndexed(state.upNext, key = { i, t -> "${t.id}-$i" }) { offset, song ->
                Row(Modifier.fillMaxWidth().clickable { app.player.jump(state.index + 1 + offset) }
                    .padding(horizontal = Spacing.l, vertical = Spacing.s), verticalAlignment = Alignment.CenterVertically) {
                    Artwork(client?.imageUrl(song.imageItemId, 160), Modifier.size(48.dp), RoundedCornerShape(10.dp))
                    Column(Modifier.weight(1f).padding(horizontal = Spacing.m)) {
                        Text(song.name, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(song.artistLine, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    IconButton(onClick = { app.player.removeFromQueue(state.index + 1 + offset) }) {
                        Icon(Icons.Rounded.Close, "Remove from queue")
                    }
                }
            }
        }
    }
}

/** Title first and biggest, then who made it (every credited artist opens), then the album, smallest. */
@Composable
private fun TrackTitles(track: Item?, state: PlaybackState, onOpen: (Any) -> Unit, centered: Boolean) {
    val app = LocalApp.current
    val colors = MaterialTheme.colorScheme
    var menu by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth(), horizontalAlignment = if (centered) Alignment.CenterHorizontally else Alignment.Start,
        verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(track?.name ?: state.station?.name ?: state.pendingTitle ?: "", style = MaterialTheme.typography.headlineSmall,
            color = colors.onSurface, textAlign = if (centered) TextAlign.Center else TextAlign.Start, maxLines = 2,
            overflow = TextOverflow.Ellipsis)
        Box {
            Text(track?.artistLine ?: "", style = MaterialTheme.typography.titleLarge.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.Normal),
                color = colors.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.clickable(enabled = track != null) { menu = true })
            androidx.compose.material3.DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                track?.let { app.credits.credits(it) }?.forEach { name ->
                    androidx.compose.material3.DropdownMenuItem(text = { Text(name) }, onClick = {
                        menu = false
                        onOpen(artistRoute(app, name))
                    })
                }
            }
        }
        val album = listOfNotNull(track?.album, track?.productionYear?.toString()).joinToString(" \u00b7 ")
        if (album.isNotEmpty()) {
            Text(album, style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant.copy(alpha = 0.8f), maxLines = 1,
                overflow = TextOverflow.Ellipsis, modifier = Modifier.clickable { track?.albumId?.let { onOpen(AlbumRoute(it, track.album ?: "")) } })
        }
    }
}

/** Lyrics from your server or LRCLIB. Synced lyrics follow the song; tap a line to jump there. */
@Composable
private fun LyricsPanel(track: Item, state: PlaybackState) {
    val app = LocalApp.current
    val client = client()
    var result by remember(track.id) { mutableStateOf<Lyrics.Result?>(null) }
    var loaded by remember(track.id) { mutableStateOf(false) }
    LaunchedEffect(track.id) {
        result = client?.let { Lyrics.find(track, it) }
        loaded = true
    }
    val lines = result?.lines ?: emptyList()
    val synced = lines.any { it.startMs != null }
    val active = if (synced) lines.indexOfLast { (it.startMs ?: Long.MAX_VALUE) <= state.positionMs } else -1
    val listState = androidx.compose.foundation.lazy.rememberLazyListState()
    LaunchedEffect(active) { if (active > 2) listState.animateScrollToItem(active - 2) }

    when {
        !loaded -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        lines.isEmpty() -> Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(Icons.Rounded.Lyrics, null, Modifier.size(48.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Text("No lyrics for this song", style = MaterialTheme.typography.titleMedium.bold(), modifier = Modifier.padding(top = Spacing.m))
            Text("Neither your server nor LRCLIB has them.", color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
        }
        else -> LazyColumn(state = listState, modifier = Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
            itemsIndexed(lines) { index, line ->
                val current = index == active
                Text(line.text.ifBlank { "\u266a" }, style = MaterialTheme.typography.headlineSmall.bold(),
                    color = if (!synced || current) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.4f),
                    modifier = Modifier.fillMaxWidth().clickable(enabled = line.startMs != null) {
                        line.startMs?.let { app.player.seek(it) }
                    })
            }
            if (result?.fromLrclib == true) item {
                Text("Lyrics from LRCLIB", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(vertical = Spacing.l))
            }
        }
    }
}

/** Bottom-row buttons like the iPhone's: no box behind them, accent-colored when on. */
@Composable
private fun dialToggleColors() = androidx.compose.material3.IconButtonDefaults.iconToggleButtonColors(
    containerColor = Color.Transparent, checkedContainerColor = Color.Transparent,
    contentColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.75f), checkedContentColor = MaterialTheme.colorScheme.primary,
)
