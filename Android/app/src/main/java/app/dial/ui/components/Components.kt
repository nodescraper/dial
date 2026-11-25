package app.dial.ui.components

import androidx.compose.ui.unit.sp
import androidx.compose.runtime.LaunchedEffect
import app.dial.data.PublicMusic
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.animation.core.animateFloat
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.draw.drawBehind
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.KeyboardArrowUp
import androidx.compose.material.icons.rounded.RemoveCircleOutline
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.QueueMusic
import androidx.compose.material.icons.rounded.Album
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.PlaylistAdd
import androidx.compose.material.icons.rounded.Radio
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.WifiOff
import androidx.compose.material.icons.rounded.Visibility
import androidx.compose.material.icons.rounded.VisibilityOff
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.foundation.border
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.dial.data.Item
import app.dial.data.formatTime
import coil3.compose.SubcomposeAsyncImage

/**
 * With a keyboard or a D-pad, the item you are on gets an accent-colored outline,
 * so you always see where you are.
 */
@Composable
fun Modifier.focusHighlight(shape: Shape = RoundedCornerShape(12.dp), grow: Float = 1f): Modifier {
    var focused by remember { mutableStateOf(false) }
    val scale = androidx.compose.animation.core.animateFloatAsState(if (focused) grow else 1f, label = "focus")
    return this
        .onFocusChanged { focused = it.isFocused || it.hasFocus }
        .graphicsLayer { scaleX = scale.value; scaleY = scale.value }
        .then(if (focused) Modifier.border(3.dp, MaterialTheme.colorScheme.primary, shape) else Modifier)
}

/** Spacing used across Dial's Android screens. */
object Spacing {
    val xxs = 2.dp
    val xs = 4.dp
    val s = 8.dp
    val m = 12.dp
    val l = 16.dp
    val xl = 24.dp
    val section = 28.dp
}

val ArtistShapeIcon = Icons.Rounded.Person

/** Artist photos use one of Material's expressive shapes: a soft "cookie". */
val ArtistShape: Shape @Composable get() = CircleShape

/**
 * A cover or photo from your server, with the one placeholder while it loads or when there is none ([ghost] makes the wait a
 * shimmering block). A Cover Art Archive cover that does not exist is looked for at another source before giving up.
 */
@Composable
fun Artwork(url: String?, modifier: Modifier = Modifier, shape: Shape = RoundedCornerShape(12.dp),
            placeholder: ImageVector = Icons.Rounded.MusicNote, ghost: Boolean = false) {
    // 0 loading, 1 loaded, 2 the picture is missing (looking for another source), 3 the other source is loading, 4 nothing found
    var stage by remember(url) { mutableStateOf(0) }
    var alternative by remember(url) { mutableStateOf<String?>(null) }
    var resolved by remember(url) { mutableStateOf(false) }
    LaunchedEffect(stage, url) {
        if (stage == 2 && url != null) {
            val id = Regex("release-group/([0-9a-fA-F-]{36})").find(url)?.groupValues?.get(1)
            alternative = id?.let { PublicMusic.alternativeCover(it) }
            resolved = true
            stage = if (alternative != null) 3 else 4
        }
    }
    Box(modifier.clip(shape).background(MaterialTheme.colorScheme.surfaceContainerHigh)) {
        if ((stage == 0 || stage == 2 || stage == 3) && ghost && url != null) Ghost(Modifier.fillMaxSize())
        if (url == null || stage == 4) PlaceholderIcon(placeholder)
        else coil3.compose.AsyncImage(
            model = if (stage == 3) alternative else url,
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxSize(),
            onSuccess = { if (stage != 2) stage = 1 },
            onError = { stage = if (stage == 3) 4 else 2 },
        )
    }
}

/** A grey block with a soft light sweeping across it: shown where something is still loading. */
@Composable
fun Ghost(modifier: Modifier = Modifier) {
    val t = androidx.compose.animation.core.rememberInfiniteTransition(label = "ghost").animateFloat(
        initialValue = -1f, targetValue = 2f,
        animationSpec = androidx.compose.animation.core.infiniteRepeatable(androidx.compose.animation.core.tween(1300, easing = androidx.compose.animation.core.LinearEasing)),
        label = "sweep")
    val base = MaterialTheme.colorScheme.surfaceContainerHigh
    val light = MaterialTheme.colorScheme.surfaceContainerHighest
    // Read while drawing, so the sweep never recomposes anything.
    Box(modifier.drawBehind {
        drawRect(base)
        val x = size.width * t.value
        drawRect(androidx.compose.ui.graphics.Brush.horizontalGradient(listOf(Color.Transparent, light, Color.Transparent),
            startX = x - size.width * 0.5f, endX = x + size.width * 0.5f))
    })
}

/** The one placeholder: a calm tile with the kind of thing in it, the symbol growing and shrinking with the tile. */
@Composable
private fun PlaceholderIcon(icon: ImageVector) {
    androidx.compose.foundation.layout.BoxWithConstraints(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        val side = minOf(maxWidth, maxHeight) * 0.4f
        Icon(icon, null, tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.45f), modifier = Modifier.size(side))
    }
}

/** Material's expressive loading indicator, centered. */
@Composable
fun Loading(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
}

@Composable
fun EmptyMessage(title: String, message: String, modifier: Modifier = Modifier) {
    Column(modifier.fillMaxSize().padding(Spacing.xl), verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally) {
        Text(title, style = MaterialTheme.typography.titleLarge, textAlign = TextAlign.Center)
        Text(message, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center, modifier = Modifier.padding(top = Spacing.s))
    }
}

/** Section titles one step lighter than before (20 sp semibold), the same as the iPhone's Title 3. */
@Composable
fun sectionStyle() = MaterialTheme.typography.titleLarge.copy(fontSize = 20.sp, fontWeight = FontWeight.SemiBold)

@Composable
fun SectionTitle(title: String, modifier: Modifier = Modifier, trailing: @Composable (() -> Unit)? = null) {
    Row(modifier.fillMaxWidth().padding(horizontal = Spacing.l), verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = sectionStyle(), modifier = Modifier.weight(1f))
        trailing?.invoke()
    }
}

/** What a song's menu can do. */
data class SongActions(
    val onPlayNext: (Item) -> Unit,
    val onAddToQueue: (Item) -> Unit,
    val onRadio: (Item) -> Unit,
    val onFavorite: (Item) -> Unit,
    val isFavorite: (Item) -> Boolean,
    val isHidden: (Item) -> Boolean = { false },
    val onHide: (Item) -> Unit = {},
    /** Everyone credited on the song, main artist first. */
    val credits: (Item) -> List<String> = { emptyList() },
    val onArtist: (String) -> Unit = {},
    val onAlbum: (Item) -> Unit = {},
    val onDownload: (Item) -> Unit = {},
    val onAddToPlaylist: (Item) -> Unit = {},
    /** Set inside a playlist: take the song out of it, or move it one place up or down. */
    val onRemoveFromPlaylist: ((Item) -> Unit)? = null,
    val onMoveUp: ((Item) -> Unit)? = null,
    val onMoveDown: ((Item) -> Unit)? = null,
)

/** One song: cover (or track number), title and artist, and a menu. */
@Composable
fun SongRow(song: Item, artworkUrl: String?, isCurrent: Boolean, onClick: () -> Unit, actions: SongActions,
            numbered: Boolean = false) {
    var menu by remember { mutableStateOf(false) }
    val hidden = actions.isHidden(song)
    Row(
        Modifier.fillMaxWidth().focusHighlight(RoundedCornerShape(12.dp), grow = 1f).clickable(onClick = onClick)
            .padding(horizontal = Spacing.l, vertical = Spacing.s).alpha(if (hidden) 0.4f else 1f),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (numbered) {
            Box(Modifier.width(32.dp), contentAlignment = Alignment.CenterStart) {
                if (isCurrent) Icon(Icons.Rounded.GraphicEq, "Playing", tint = MaterialTheme.colorScheme.primary)
                else Text("${song.indexNumber ?: ""}", style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        } else {
            Artwork(artworkUrl, Modifier.size(52.dp), RoundedCornerShape(8.dp))
        }
        Column(Modifier.weight(1f).padding(horizontal = Spacing.m)) {
            Text(song.name, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis,
                color = if (isCurrent) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
                fontWeight = if (isCurrent) FontWeight.SemiBold else FontWeight.Normal)
            Text(song.artistLine, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (actions.isFavorite(song)) {
            Icon(Icons.Rounded.Favorite, "Favorite", tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(16.dp))
        }
        Text(formatTime(song.durationMs), style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = Spacing.s))
        Box {
            IconButton(onClick = { menu = true }) { Icon(Icons.Rounded.MoreVert, "More") }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(text = { Text("Play Next") }, leadingIcon = { Icon(Icons.AutoMirrored.Rounded.QueueMusic, null) },
                    onClick = { menu = false; actions.onPlayNext(song) })
                DropdownMenuItem(text = { Text("Add to Queue") }, leadingIcon = { Icon(Icons.Rounded.PlaylistAdd, null) },
                    onClick = { menu = false; actions.onAddToQueue(song) })
                DropdownMenuItem(text = { Text("Start Radio") }, leadingIcon = { Icon(Icons.Rounded.Radio, null) },
                    onClick = { menu = false; actions.onRadio(song) })
                DropdownMenuItem(text = { Text("Add to Playlist\u2026") }, leadingIcon = { Icon(Icons.Rounded.PlaylistAdd, null) },
                    onClick = { menu = false; actions.onAddToPlaylist(song) })
                actions.onRemoveFromPlaylist?.let { remove ->
                    DropdownMenuItem(text = { Text("Remove from Playlist") }, leadingIcon = { Icon(Icons.Rounded.RemoveCircleOutline, null) },
                        onClick = { menu = false; remove(song) })
                }
                actions.onMoveUp?.let { up ->
                    DropdownMenuItem(text = { Text("Move Up") }, leadingIcon = { Icon(Icons.Rounded.KeyboardArrowUp, null) },
                        onClick = { menu = false; up(song) })
                }
                actions.onMoveDown?.let { down ->
                    DropdownMenuItem(text = { Text("Move Down") }, leadingIcon = { Icon(Icons.Rounded.KeyboardArrowDown, null) },
                        onClick = { menu = false; down(song) })
                }
                val favorite = actions.isFavorite(song)
                DropdownMenuItem(text = { Text(if (favorite) "Remove from Favorites" else "Favorite") },
                    leadingIcon = { Icon(if (favorite) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder, null) },
                    onClick = { menu = false; actions.onFavorite(song) })
                if (song.albumId != null) {
                    DropdownMenuItem(text = { Text("Go to Album") }, leadingIcon = { Icon(Icons.Rounded.Album, null) },
                        onClick = { menu = false; actions.onAlbum(song) })
                }
                actions.credits(song).forEach { name ->
                    DropdownMenuItem(text = { Text("Go to $name") }, leadingIcon = { Icon(Icons.Rounded.Person, null) },
                        onClick = { menu = false; actions.onArtist(name) })
                }
                DropdownMenuItem(text = { Text("Download") }, leadingIcon = { Icon(Icons.Rounded.Download, null) },
                    onClick = { menu = false; actions.onDownload(song) })
                DropdownMenuItem(text = { Text(if (hidden) "Allow This Song" else "Don\u2019t Play This Song") },
                    leadingIcon = { Icon(if (hidden) Icons.Rounded.Visibility else Icons.Rounded.VisibilityOff, null) },
                    onClick = { menu = false; actions.onHide(song) })
            }
        }
    }
}

/** A square tile with a title and subtitle under it (albums, playlists, mixes). */
@Composable
fun Tile(title: String, subtitle: String?, artworkUrl: String?, width: Dp, onClick: () -> Unit,
         shape: Shape = RoundedCornerShape(12.dp), placeholder: ImageVector = Icons.Rounded.Album,
         modifier: Modifier = Modifier, jewelCase: Boolean = false) {
    Column(modifier.width(width).focusHighlight(if (jewelCase) RoundedCornerShape(3.dp) else shape).clickable(onClick = onClick)) {
        if (jewelCase) {
            JewelCase(artworkUrl, Modifier.fillMaxWidth(),
                cover = { Artwork(artworkUrl, Modifier.fillMaxSize(), RoundedCornerShape(0.dp), placeholder) })
        } else {
            Artwork(artworkUrl, Modifier.fillMaxWidth().aspectRatio(1f), shape, placeholder)
        }
        Text(title, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = Spacing.s))
        if (subtitle != null) {
            Text(subtitle, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** A round-ish (cookie-shaped) artist photo with the name under it. */
@Composable
fun ArtistTile(name: String, artworkUrl: String?, width: Dp, onClick: () -> Unit) {
    Column(Modifier.width(width).focusHighlight(ArtistShape).clickable(onClick = onClick), horizontalAlignment = Alignment.CenterHorizontally) {
        Artwork(artworkUrl, Modifier.fillMaxWidth().aspectRatio(1f), ArtistShape, Icons.Rounded.Person)
        Text(name, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center, modifier = Modifier.padding(top = Spacing.s))
    }
}

/**
 * An album cover inside a CD jewel case, shaped like a real one (142 x 125 mm): the tray card showing
 * through the spine, the ridged hinge, the lid's raised lip and the reflections on the clear plastic.
 * Kept cheap for long grids: the tray is the same already-loaded cover, scaled up and darkened (no blur,
 * no blend modes), and the plastic is drawn in one layer. Mixtapes have no single cover, so their tray
 * takes the mix's colours ([trayColors]) instead of a picture.
 */
@Composable
fun JewelCase(
    artworkUrl: String?,
    modifier: Modifier = Modifier,
    trayColors: List<Color>? = null,
    cover: @Composable () -> Unit = { Artwork(artworkUrl, Modifier.fillMaxSize(), RoundedCornerShape(0.dp)) },
) {
    val caseShape = RoundedCornerShape(3.dp)
    BoxWithConstraints(modifier.aspectRatio(142f / 125f).shadow(6.dp, caseShape).clip(caseShape)
        .background(Color(0xFF212121))) {
        val w = maxWidth
        val h = maxHeight
        val side = h * 0.956f
        // The tray card behind the spine and edges.
        Box(Modifier.fillMaxSize()) {
            if (trayColors != null) {
                Box(Modifier.fillMaxSize().background(Brush.linearGradient(trayColors)))
            } else {
                Artwork(artworkUrl, Modifier.fillMaxSize().scale(1.2f), RoundedCornerShape(0.dp))
            }
            // The spine's shadow, then everything under the plastic darkened a little.
            Box(Modifier.fillMaxHeight().width(w * 0.128f)
                .background(Brush.horizontalGradient(listOf(
                    Color.Black.copy(alpha = 0.35f),
                    Color.Black.copy(alpha = 0.2f),
                    Color.Black.copy(alpha = 0.3f),
                ))))
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.15f)))
        }
        // The booklet, square, under the lid, with a hairline edge.
        Box(Modifier.size(side).offset(x = w * 0.98f - side, y = (h - side) / 2f)
            .border(0.5.dp, Color.Black.copy(alpha = 0.4f))) {
            cover()
        }
        // The plastic on top: the lid's edge along the spine, the hinge, the lid's raised lip and the glare.
        Box(Modifier.fillMaxSize()) {
            Box(Modifier.fillMaxHeight().width(1.dp).offset(x = w * 0.014f)
                .background(Color.White.copy(alpha = 0.4f)))
            Box(Modifier.fillMaxHeight().width(w * 0.036f).offset(x = w * 0.086f)
                .background(Brush.horizontalGradient(listOf(
                    Color.Transparent,
                    Color.White.copy(alpha = 0.55f),
                    Color.Black.copy(alpha = 0.28f),
                    Color.White.copy(alpha = 0.32f),
                    Color.Black.copy(alpha = 0.22f),
                    Color.White.copy(alpha = 0.5f),
                    Color.Transparent,
                ))))
            Box(Modifier.size(w * (1f - 0.124f - 0.009f), h * (1f - 0.022f))
                .offset(x = w * 0.124f, y = h * 0.011f)
                .border(1.dp, Color.White.copy(alpha = 0.28f), RoundedCornerShape(2.dp)))
            Box(Modifier.fillMaxSize().background(Brush.linearGradient(listOf(
                Color.White.copy(alpha = 0.06f),
                Color.Transparent,
                Color.White.copy(alpha = 0.18f),
                Color.White.copy(alpha = 0.05f),
                Color.Transparent,
                Color.White.copy(alpha = 0.08f),
                Color.Transparent,
            ))))
        }
        // The lit outer edge.
        Box(Modifier.fillMaxSize().border(1.dp, Brush.linearGradient(listOf(
            Color.White.copy(alpha = 0.6f),
            Color.White.copy(alpha = 0.15f),
            Color.Black.copy(alpha = 0.35f),
        )), caseShape))
    }
}

/** A titled row of tiles that scrolls sideways. */
@Composable
fun <T> Shelf(title: String, items: List<T>, key: (T) -> String, tile: @Composable (T) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
        SectionTitle(title)
        LazyRow(contentPadding = PaddingValues(horizontal = Spacing.l, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
            // Keys include the position, so a list that repeats an id can never crash the page.
            itemsIndexed(items, key = { index, item -> "${key(item)}#$index" }) { _, item -> tile(item) }
        }
    }
}

val CircleArt: Shape = CircleShape

/** Expressive, heavier versions of Material's type styles for titles. */
fun androidx.compose.ui.text.TextStyle.bold() = copy(fontWeight = FontWeight.Bold)
fun androidx.compose.ui.text.TextStyle.black() = copy(fontWeight = FontWeight.Black, letterSpacing = androidx.compose.ui.unit.TextUnit.Unspecified)

/** Shown at the top of Home, Library and Search when the server can't be reached: one quiet line, not a card. */
@Composable
fun OfflineBanner(downloads: Int, onRetry: () -> Unit) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val plays = remember { mutableStateOf(0) }
    androidx.compose.runtime.LaunchedEffect(Unit) { plays.value = app.dial.data.PlayLog.pending(context) }
    val detail = buildString {
        append(if (downloads == 0) "nothing downloaded" else "playing your downloads")
        if (plays.value > 0) append(" \u00b7 ${plays.value} ${if (plays.value == 1) "play" else "plays"} to sync")
    }
    androidx.compose.material3.Surface(shape = androidx.compose.foundation.shape.CircleShape, color = MaterialTheme.colorScheme.surfaceContainerHigh,
        modifier = Modifier.fillMaxWidth().padding(horizontal = Spacing.l)) {
        Row(Modifier.padding(start = Spacing.m, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.WifiOff, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(18.dp))
            Text(buildAnnotatedString {
                withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { append("Offline") }
                withStyle(SpanStyle(color = MaterialTheme.colorScheme.onSurfaceVariant)) { append(" \u00b7 $detail") }
            }, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f).padding(horizontal = Spacing.s))
            androidx.compose.material3.TextButton(onClick = onRetry) { Text("Retry") }
        }
    }
}

/** Covers a screen that only works with a connection (live radio, Discovery) while the server can't be reached. */
@Composable
fun OfflineCover(title: String, message: String, onRetry: () -> Unit) {
    Column(Modifier.fillMaxSize().padding(vertical = Spacing.l), verticalArrangement = Arrangement.spacedBy(Spacing.l)) {
        OfflineBanner(0, onRetry)
        Column(Modifier.weight(1f).fillMaxWidth().padding(horizontal = Spacing.xl), horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center) {
            Icon(Icons.Rounded.WifiOff, null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(48.dp))
            Text(title, style = MaterialTheme.typography.titleLarge.bold(), modifier = Modifier.padding(top = Spacing.m))
            Text(message, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center, modifier = Modifier.padding(top = Spacing.s))
        }
    }
}
