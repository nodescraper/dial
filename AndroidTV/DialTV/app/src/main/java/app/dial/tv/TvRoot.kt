package app.dial.tv

import androidx.activity.compose.BackHandler
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import app.dial.R
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Home
import androidx.compose.material.icons.rounded.LibraryMusic
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Radio
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.draw.alpha
import app.dial.playback.YouTubeEmbed
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.dial.DialApplication
import app.dial.data.Wishlist
import coil3.compose.AsyncImage

/** Where you are. Tabs are the roots; the rest open on top of them and Back peels them off. */
sealed interface TvRoute {
    data object Home : TvRoute
    data object Radio : TvRoute
    data object Library : TvRoute
    data object Search : TvRoute
    data object Settings : TvRoute
    data object Player : TvRoute
    data object Stats : TvRoute
    data class Album(val id: String, val name: String) : TvRoute
    data class Artist(val id: String, val name: String) : TvRoute
    data class Playlist(val id: String, val name: String) : TvRoute
    data class Mixtape(val id: String) : TvRoute
    data class Stations(val tag: String, val title: String) : TvRoute
}

class TvNav {
    val stack = mutableStateListOf<TvRoute>(TvRoute.Home)
    val current: TvRoute get() = stack.last()
    fun open(route: TvRoute) { stack.add(route) }
    fun tab(route: TvRoute) { stack.clear(); stack.add(route) }
    fun back(): Boolean = if (stack.size > 1) { stack.removeAt(stack.lastIndex); true } else false
}

val LocalTvApp = androidx.compose.runtime.staticCompositionLocalOf<DialApplication> { error("no app") }
val LocalTvNav = androidx.compose.runtime.staticCompositionLocalOf<TvNav> { error("no nav") }
/** The top bar's place for Up from the first row: the now-playing chip, or the active tab when nothing plays. */
val LocalTvTopFocus = androidx.compose.runtime.staticCompositionLocalOf { androidx.compose.ui.focus.FocusRequester() }

@Composable
fun TvRoot(app: DialApplication) {
    val client by app.session.client.collectAsState()
    androidx.compose.runtime.CompositionLocalProvider(LocalTvApp provides app) {
        Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
            // YouTube's player page for the live streams that only exist there (Lofi Girl): behind the screens, nearly clear.
            // Added after the first frame: starting a WebView is slow, and only the Lofi streams need it.
            var youTubeAttached by remember { mutableStateOf(false) }
            androidx.compose.runtime.LaunchedEffect(Unit) { kotlinx.coroutines.delay(1500); youTubeAttached = true }
            // Never focusable: it is invisible, so Left from the top bar would land on nothing.
            if (youTubeAttached) androidx.compose.ui.viewinterop.AndroidView(
                factory = { YouTubeEmbed.view(it).apply { isFocusable = false; isFocusableInTouchMode = false } },
                modifier = Modifier.size(240.dp).alpha(0.02f).focusProperties { canFocus = false })
            if (client == null) TvLogin() else TvSignedIn()
            TvSplashGate(signedIn = client != null)
            // The wishlist lives here, so every screen sees the same list.
            androidx.compose.runtime.LaunchedEffect(client) {
                client?.let { Wishlist.refresh(it) }
            }
        }
    }
}

@Composable
private fun TvSignedIn() {
    val nav = remember { TvNav() }
    val stage = remember { TvStageState() }
    val topFocus = remember { androidx.compose.ui.focus.FocusRequester() }
    androidx.compose.runtime.CompositionLocalProvider(LocalTvNav provides nav, LocalTvStage provides stage, LocalTvTopFocus provides topFocus) {
        val route = nav.current
        BackHandler(enabled = nav.stack.size > 1) { nav.back() }
        if (route == TvRoute.Player) {
            // The player is a page of its own: no bar on top.
            TvPlayer()
        } else if (route == TvRoute.Home || route == TvRoute.Radio || route == TvRoute.Library) {
            TvStageScaffold(title = when (route) { TvRoute.Home -> "Home"; TvRoute.Radio -> "Tune In"; else -> "Library" },
                topBar = { TvTopBar(route) }) {
                when (route) {
                    TvRoute.Home -> TvHome()
                    TvRoute.Radio -> TvRadio()
                    else -> TvLibrary()
                }
            }
        } else {
            Column(Modifier.fillMaxSize()) {
                TvTopBar(route)
                Box(Modifier.weight(1f).fillMaxWidth()) {
                    when (route) {
                        TvRoute.Home -> TvHome()
                        TvRoute.Radio -> TvRadio()
                        TvRoute.Library -> TvLibrary()
                        TvRoute.Search -> TvSearch()
                        TvRoute.Settings -> TvSettings()
                        is TvRoute.Album -> TvAlbum(route.id, route.name)
                        is TvRoute.Artist -> TvArtist(route.id, route.name)
                        is TvRoute.Playlist -> TvPlaylist(route.id, route.name)
                        is TvRoute.Mixtape -> TvMixtape(route.id)
                        is TvRoute.Stations -> TvStations(route.tag, route.title)
                        TvRoute.Stats -> TvStats()
                        TvRoute.Player -> Unit
                    }
                }
            }
        }
    }
}

/**
 * The top bar, as on Spotify's TV app: the now-playing chip on the left, the four places centered, settings on the right.
 */
@Composable
private fun TvTopBar(route: TvRoute) {
    val app = LocalTvApp.current
    val nav = LocalTvNav.current
    val playback by app.player.state.collectAsState()
    val client = app.session.client.collectAsState().value
    Row(Modifier.fillMaxWidth().padding(horizontal = Tv.marginX).padding(top = Tv.marginTop, bottom = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        // Left: what's playing (opens the player), or the app's name.
        Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
            val track = playback.current
            if (playback.hasContent) {
                val shape = RoundedCornerShape(Tv.radius)
                val artUrl = track?.let { client?.imageUrl(it.imageItemId, 160) } ?: playback.station?.favicon
                val artColors = rememberArtworkColors(artUrl)
                val left by androidx.compose.animation.animateColorAsState(artColors?.get(0) ?: MaterialTheme.colorScheme.surfaceVariant, androidx.compose.animation.core.tween(600), label = "chip-left")
                val right by androidx.compose.animation.animateColorAsState(artColors?.get(1) ?: MaterialTheme.colorScheme.surfaceVariant, androidx.compose.animation.core.tween(600), label = "chip-right")
                Row(Modifier.focusRequester(LocalTvTopFocus.current).width(300.dp).tvFocus(shape).clip(shape).background(androidx.compose.ui.graphics.Brush.horizontalGradient(listOf(left, right)))
                    .clickable { nav.open(TvRoute.Player) }.padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    AsyncImage(artUrl, null,
                        Modifier.size(44.dp).clip(RoundedCornerShape(6.dp)), contentScale = ContentScale.Crop)
                    Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                        Text(track?.name ?: playback.station?.name ?: "", style = MaterialTheme.typography.labelLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(track?.artistLine ?: "Live radio", style = MaterialTheme.typography.labelMedium, maxLines = 1,
                            overflow = TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Icon(if (playback.isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow, null)
                }
            } else {
                androidx.compose.foundation.Image(androidx.compose.ui.res.painterResource(R.drawable.ic_launcher_foreground), "Dial",
                    Modifier.size(48.dp).clip(RoundedCornerShape(11.dp)).background(Color(0xFF1B1030)))
            }
        }
        // Center: the places.
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            // With nothing playing, the active tab is where Up from the first row lands.
            val tabTarget = if (playback.hasContent) null else LocalTvTopFocus.current
            TopTab("Home", Icons.Rounded.Home, route == TvRoute.Home, if (route == TvRoute.Home) tabTarget else null) { nav.tab(TvRoute.Home) }
            TopTab("Tune In", Icons.Rounded.Radio, route == TvRoute.Radio, if (route == TvRoute.Radio) tabTarget else null) { nav.tab(TvRoute.Radio) }
            TopTab("Library", Icons.Rounded.LibraryMusic, route == TvRoute.Library, if (route == TvRoute.Library) tabTarget else null) { nav.tab(TvRoute.Library) }
        }
        // Right: search and settings, as icons.
        Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.End), verticalAlignment = Alignment.CenterVertically) {
            val shape = RoundedCornerShape(Tv.radius)
            val searching = route == TvRoute.Search
            Box(Modifier.tvFocus(shape).clip(shape).clickable { nav.tab(TvRoute.Search) }.padding(10.dp)) {
                Icon(Icons.Rounded.Search, "Search", Modifier.size(26.dp), tint = if (searching) Accent else LocalContentColor.current)
            }
            Box(Modifier.tvFocus(shape).clip(shape).clickable { nav.open(TvRoute.Settings) }.padding(10.dp)) {
                Icon(Icons.Rounded.Settings, "Settings", Modifier.size(26.dp))
            }
        }
    }
}

@Composable
private fun TopTab(label: String, icon: ImageVector, selected: Boolean, target: androidx.compose.ui.focus.FocusRequester?, onClick: () -> Unit) {
    val shape = RoundedCornerShape(Tv.radius)
    val color = if (selected) Accent else MaterialTheme.colorScheme.onSurfaceVariant
    val place = if (target != null) Modifier.focusRequester(target) else Modifier
    Row(place.tvFocus(shape).clip(shape).clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Icon(icon, null, tint = color, modifier = Modifier.size(24.dp))
        Text(label, style = MaterialTheme.typography.labelLarge, color = color)
    }
}
