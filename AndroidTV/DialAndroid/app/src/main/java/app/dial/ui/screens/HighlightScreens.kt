package app.dial.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.QueueMusic
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Sensors
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.dial.data.Highlight
import app.dial.data.HighlightAction
import app.dial.ui.AlbumRoute
import app.dial.ui.ArtistRoute
import app.dial.ui.LocalApp
import app.dial.ui.LocalNavigator
import app.dial.ui.PublicAlbumRoute
import app.dial.ui.components.Artwork
import app.dial.ui.components.Spacing
import app.dial.ui.components.focusHighlight
import coil3.compose.AsyncImage

/** Home's lead row: big cards that each say something, at most three, the next one peeking in. */
@Composable
fun HighlightsRow(highlights: List<Highlight>) {
    LazyRow(contentPadding = PaddingValues(horizontal = Spacing.l, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
        items(highlights, key = { it.id }) { highlight ->
            HighlightCard(highlight, Modifier.widthIn(max = 720.dp).fillParentMaxWidth(if (highlights.size == 1) 1f else 0.88f))
        }
    }
}

/** The artist's backdrop (or the cover, enlarged), their logo, and at the bottom the cover, label, title, artist and one round button. */
@Composable
private fun HighlightCard(highlight: Highlight, modifier: Modifier) {
    val app = LocalApp.current
    val navigator = LocalNavigator.current
    val client = client()
    val shape = RoundedCornerShape(16.dp)
    val coverUrl = highlight.coverItemId?.let { client?.imageUrl(it, 400) } ?: highlight.coverUrl

    fun open() = when (val action = highlight.action) {
        is HighlightAction.Album -> navigator.open(AlbumRoute(action.id, action.name))
        is HighlightAction.PublicAlbum -> navigator.open(PublicAlbumRoute(action.pick.mbid, action.pick.title, action.pick.year, action.artist, action.artistId))
        is HighlightAction.ArtistRadio -> navigator.open(ArtistRoute(action.id, action.name))
    }

    fun act() = when (val action = highlight.action) {
        is HighlightAction.Album -> app.player.play(highlight.title) { it.albumTracks(action.id) }
        is HighlightAction.PublicAlbum -> open()
        is HighlightAction.ArtistRadio -> app.player.play("${action.name} Radio", radio = true) { c ->
            val own = c.artistSongs(action.id, 30).shuffled()
            (own.take(2) + c.instantMix(action.id, 30) + own.drop(2)).distinctBy { it.id }
        }
    }

    Box(modifier.aspectRatio(16f / 9f).clip(shape).focusHighlight(shape).clickable { open() }) {
        // No backdrop on the server: the cover, enlarged, shows instead.
        Artwork(coverUrl, Modifier.fillMaxSize().scale(1.3f), RoundedCornerShape(0.dp))
        highlight.artistId?.let { id ->
            AsyncImage(client?.imageUrl(id, "Backdrop/0", 1280), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            AsyncImage(client?.imageUrl(id, "Logo", 500), null, Modifier.align(Alignment.TopStart).padding(Spacing.l).size(width = 150.dp, height = 40.dp),
                contentScale = ContentScale.Fit, alignment = Alignment.TopStart)
        }
        Box(Modifier.align(Alignment.BottomCenter).fillMaxSize().background(
            Brush.verticalGradient(0.45f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.7f))))
        Row(Modifier.align(Alignment.BottomCenter).padding(Spacing.m), verticalAlignment = Alignment.Bottom,
            horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
            Artwork(coverUrl, Modifier.size(56.dp), RoundedCornerShape(6.dp))
            Column(Modifier.weight(1f)) {
                Text(highlight.label, style = MaterialTheme.typography.labelMedium, color = Color.White.copy(alpha = 0.75f), maxLines = 1)
                Text(highlight.title, style = MaterialTheme.typography.titleMedium, color = Color.White, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(highlight.subtitle, style = MaterialTheme.typography.bodyMedium, color = Color.White.copy(alpha = 0.75f), maxLines = 1,
                    overflow = TextOverflow.Ellipsis)
            }
            IconButton(onClick = { act() }, modifier = Modifier.clip(CircleShape).background(Color.White.copy(alpha = 0.22f))) {
                Icon(when (highlight.action) {
                    is HighlightAction.Album -> Icons.Rounded.PlayArrow
                    is HighlightAction.PublicAlbum -> Icons.AutoMirrored.Rounded.QueueMusic
                    is HighlightAction.ArtistRadio -> Icons.Rounded.Sensors
                }, "Play", tint = Color.White)
            }
        }
    }
}
