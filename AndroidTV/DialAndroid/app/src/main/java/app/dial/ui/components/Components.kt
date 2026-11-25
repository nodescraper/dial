package app.dial.ui.components

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
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
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
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
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
    val scale by androidx.compose.animation.core.animateFloatAsState(if (focused) grow else 1f, label = "focus")
    return this
        .onFocusChanged { focused = it.isFocused || it.hasFocus }
        .scale(scale)
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

/** A cover or photo from your server, with a quiet placeholder while it loads. */
@Composable
fun Artwork(url: String?, modifier: Modifier = Modifier, shape: Shape = RoundedCornerShape(12.dp),
            placeholder: ImageVector = Icons.Rounded.MusicNote) {
    Box(modifier.clip(shape).background(MaterialTheme.colorScheme.surfaceContainerHigh)) {
        SubcomposeAsyncImage(
            model = url,
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxSize(),
            error = { PlaceholderIcon(placeholder) },
            loading = { PlaceholderIcon(placeholder) },
        )
    }
}

@Composable
private fun PlaceholderIcon(icon: ImageVector) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Icon(icon, null, tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f))
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

@Composable
fun SectionTitle(title: String, modifier: Modifier = Modifier, trailing: @Composable (() -> Unit)? = null) {
    Row(modifier.fillMaxWidth().padding(horizontal = Spacing.l), verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = MaterialTheme.typography.titleLarge.bold(), modifier = Modifier.weight(1f))
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
         modifier: Modifier = Modifier) {
    Column(modifier.width(width).focusHighlight(shape).clickable(onClick = onClick)) {
        Artwork(artworkUrl, Modifier.fillMaxWidth().aspectRatio(1f), shape, placeholder)
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

/** Shown at the top of Home, Library and Search when the server can't be reached. */
@Composable
fun OfflineBanner(downloads: Int, onRetry: () -> Unit) {
    androidx.compose.material3.Surface(shape = RoundedCornerShape(20.dp), color = MaterialTheme.colorScheme.surfaceContainerHigh,
        modifier = Modifier.fillMaxWidth().padding(horizontal = Spacing.l)) {
        Row(Modifier.padding(Spacing.m), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.WifiOff, null, tint = MaterialTheme.colorScheme.primary)
            Column(Modifier.weight(1f).padding(horizontal = Spacing.m)) {
                Text("You\u2019re offline", style = MaterialTheme.typography.titleSmall.bold())
                Text(if (downloads == 0) "Your server can\u2019t be reached. Download music to listen without a connection."
                     else "Your server can\u2019t be reached, so Dial is playing your downloads.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            androidx.compose.material3.TextButton(onClick = onRetry) { Text("Retry") }
        }
    }
}
