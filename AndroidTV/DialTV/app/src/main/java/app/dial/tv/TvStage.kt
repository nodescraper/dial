package app.dial.tv

import androidx.compose.ui.draw.drawWithContent
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.Box
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/** What the top of a main tab shows: the focused item's picture (faded), its title and one line of details. */
data class TvStage(val title: String, val meta: String = "", val imageUrl: String? = null,
                   /** Other pictures that would do, in case the first is the one already on screen. */
                   val alternatives: List<String> = emptyList())

/**
 * The stage is remembered here. Cards ask for it when they get focus; the stage waits a moment (so scrolling quickly
 * through a row doesn't load a picture for every card) and then crossfades to the new one.
 */
class TvStageState {
    var requested by mutableStateOf<TvStage?>(null)
    var shown by mutableStateOf<TvStage?>(null)
    /** Album covers to fall back on when something has no picture of its own (Your Mix, a category, a tab's own title). */
    var pool by mutableStateOf<List<String>>(emptyList())
    private var cursor = 0

    fun show(stage: TvStage) { requested = stage }
    fun clear() { requested = null; shown = null }

    /**
     * Decides which picture a stage gets, without ever showing the one that's already there:
     * the item's own picture, else one of its alternatives, else the next cover from the pool (round robin).
     */
    fun resolve(stage: TvStage): TvStage {
        val current = shown?.imageUrl
        val own = listOfNotNull(stage.imageUrl) + stage.alternatives
        val picked = when {
            own.isNotEmpty() -> own.firstOrNull { it != current } ?: own.first()
            pool.isNotEmpty() -> {
                var choice = pool[cursor % pool.size]
                repeat(pool.size) { if (choice == current) { cursor++; choice = pool[cursor % pool.size] } }
                cursor++
                choice
            }
            else -> null
        }
        return stage.copy(imageUrl = picked, alternatives = emptyList())
    }
}

val LocalTvStage = androidx.compose.runtime.staticCompositionLocalOf { TvStageState() }

/** A bigger version of a Jellyfin cover address, for the backdrop. */
fun backdropOf(url: String?): String? = url?.replace(Regex("fillWidth=\\d+"), "fillWidth=900")?.replace(Regex("fillHeight=\\d+"), "fillHeight=900")

/**
 * The layout of Home, Radio and Library, as on Spotify's TV app: the top bar, then a stage with the focused item's faded
 * picture behind its title, and under it a fixed area where the rows scroll. Content never rises above the stage.
 */
@Composable
fun TvStageScaffold(title: String, topBar: @Composable () -> Unit, content: @Composable () -> Unit) {
    val stage = LocalTvStage.current
    LaunchedEffect(title) { stage.clear() }
    // The pool of covers for things that have no picture of their own: a handful of recent albums, loaded once.
    val client = tvClient()
    LaunchedEffect(client) {
        val c = client ?: return@LaunchedEffect
        val albums = withContext(Dispatchers.IO) { runCatching { c.recentAlbums(40) }.getOrNull() } ?: return@LaunchedEffect
        stage.pool = albums.shuffled().map { backdropOf(c.imageUrl(it.id, 900))!! }
    }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val totalHeight = maxHeight
        // The stage reads its own state in its own pieces, so a focus change redraws only those, not the rows under them.
        TvStageBackdrop(title, totalHeight)
        Column(Modifier.fillMaxSize()) {
            topBar()
            TvStageTitle(title, totalHeight)
            Box(Modifier.weight(1f).fillMaxWidth().clipToBounds()) { content() }
        }
    }
}

/** Picks the stage's picture a moment after the focus settles, so a quick scroll doesn't load one for every card. */
@Composable
private fun StageTimer(title: String) {
    val stage = LocalTvStage.current
    LaunchedEffect(stage.requested, stage.pool.size, title) {
        delay(170)
        stage.shown = stage.resolve(stage.requested ?: TvStage(title))
    }
}

@Composable
private fun BoxScope.TvStageBackdrop(title: String, totalHeight: androidx.compose.ui.unit.Dp) {
    val stage = LocalTvStage.current
    StageTimer(title)
    val shown = stage.shown ?: TvStage(title)
    // The picture fades into the background on the left and at the bottom with a gradient drawn over it. The background is
    // black, so this looks the same as masking the picture, without an offscreen layer (which was slow to redraw).
    Crossfade(targetState = shown.imageUrl, animationSpec = tween(700), label = "stage-image",
        modifier = Modifier.align(Alignment.TopEnd).fillMaxWidth(0.78f).height(totalHeight * 0.74f)) { url ->
        AsyncImage(url, null, Modifier.fillMaxSize().drawWithContent {
            drawContent()
            drawRect(Brush.horizontalGradient(0f to Color.Black, 0.55f to Color.Transparent))
            drawRect(Brush.verticalGradient(0.5f to Color.Transparent, 1f to Color.Black))
        }, contentScale = ContentScale.Crop, alpha = 0.75f)
    }
}

@Composable
private fun TvStageTitle(title: String, totalHeight: androidx.compose.ui.unit.Dp) {
    val stage = LocalTvStage.current
    val shown = stage.shown ?: TvStage(title)
    // The title and details sit high in the stage, with room under them before the rows.
    Box(Modifier.fillMaxWidth().height(totalHeight * 0.45f).padding(horizontal = Tv.marginX).padding(top = totalHeight * 0.11f), contentAlignment = Alignment.TopStart) {
        Crossfade(targetState = shown.copy(imageUrl = null), animationSpec = tween(450), label = "stage-text") { s ->
            Column {
                Text(s.title, style = MaterialTheme.typography.displayMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
                if (s.meta.isNotBlank()) Text(s.meta, style = MaterialTheme.typography.titleMedium, maxLines = 2, overflow = TextOverflow.Ellipsis,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}
