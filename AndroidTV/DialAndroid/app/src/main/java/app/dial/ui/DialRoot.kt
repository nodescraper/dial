package app.dial.ui

import app.dial.data.DialPlugin
import app.dial.data.DiscoveryEngine
import app.dial.ui.screens.DiscoveryScreen
import androidx.compose.material.icons.rounded.Explore
import app.dial.ui.screens.AddToPlaylistDialog
import app.dial.ui.screens.MixtapeScreen
import app.dial.ui.theme.dialNavigationColors
import androidx.compose.material3.MaterialTheme
import app.dial.R
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.spring
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.ui.unit.dp
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Home
import androidx.compose.material.icons.rounded.LibraryMusic
import androidx.compose.material.icons.rounded.Radio
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.navigation.NavDestination.Companion.hasRoute
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.toRoute
import app.dial.DialApplication
import app.dial.data.Item
import app.dial.data.LibrarySection
import app.dial.ui.components.SongActions
import app.dial.ui.screens.AlbumScreen
import app.dial.ui.screens.CategoryScreen
import app.dial.ui.screens.FeaturedArtistScreen
import app.dial.ui.screens.ImportScreen
import app.dial.ui.screens.PublicAlbumScreen
import app.dial.ui.screens.ArtistScreen
import app.dial.ui.screens.HomeScreen
import app.dial.ui.screens.LibraryScreen
import app.dial.ui.screens.LibrarySectionScreen
import app.dial.ui.screens.LocalBack
import app.dial.ui.screens.LoginScreen
import app.dial.ui.screens.MiniPlayer
import app.dial.ui.screens.NowPlayingScreen
import app.dial.ui.screens.PlaylistScreen
import app.dial.ui.screens.RadioScreen
import app.dial.ui.theme.DialTheme
import kotlinx.serialization.Serializable
import app.dial.ui.components.Spacing
import app.dial.ui.screens.ArtistPreviewRoute
import app.dial.ui.screens.ArtistPreviewScreen
import app.dial.ui.screens.ExploreGenreRoute
import app.dial.ui.screens.ExploreGenreScreen
import app.dial.ui.screens.SettingsScreen

// Pages, as typed routes.
@Serializable object HomeRoute
@Serializable object RadioRoute
@Serializable object LibraryRoute
@Serializable object SearchRoute
@Serializable data class AlbumRoute(val id: String, val name: String)
@Serializable data class ArtistRoute(val id: String, val name: String)
@Serializable data class PlaylistRoute(val id: String, val name: String)
@Serializable data class SectionRoute(val section: String)
@Serializable data class GenreRoute(val id: String, val name: String)
@Serializable data class DecadeRoute(val start: Int)
/** An album you don't have, from MusicBrainz. */
@Serializable data class PublicAlbumRoute(val releaseGroupId: String, val title: String, val year: Int?, val artist: String, val artistId: String?)
/** An artist your library only has as a feature. */
@Serializable data class FeaturedArtistRoute(val name: String)
/** A mixtape from Radio or Home, looked up by id. */
@Serializable data class MixtapeRoute(val id: String)
@Serializable object ImportRoute
@Serializable object SettingsRoute

val LocalApp = staticCompositionLocalOf<DialApplication> { error("No app") }

/** Opens pages from anywhere. */
class Navigator(val open: (Any) -> Unit)
val LocalNavigator = staticCompositionLocalOf { Navigator {} }

/** The song menu's actions, wired to the player and favorites. */
@Composable
fun songActions(): SongActions {
    val app = LocalApp.current
    val favorites by app.library.favorites.collectAsState()
    val hidden by app.library.hidden.collectAsState()
    val navigator = LocalNavigator.current
    // "Add to Playlist": the song waiting for a playlist to be chosen.
    var adding by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf<Item?>(null) }
    adding?.let { song -> AddToPlaylistDialog(song) { adding = null } }
    return SongActions(
        onAddToPlaylist = { adding = it },
        onPlayNext = { app.player.playNext(listOf(it)) },
        onAddToQueue = { app.player.addToQueue(listOf(it)) },
        onRadio = { app.player.startRadio(it) },
        onFavorite = { app.library.toggleFavorite(it) },
        isFavorite = { it.id in favorites },
        isHidden = { it.id in hidden },
        onHide = { app.library.setHidden(it.id, it.id !in hidden) },
        credits = { app.credits.credits(it) },
        onArtist = { name -> navigator.open(artistRoute(app, name)) },
        onAlbum = { song -> song.albumRoute()?.let(navigator.open) },
        onDownload = { song -> app.session.client.value?.let { app.downloads.download(listOf(song), it) } },
    )
}

@Composable
fun DialRoot(app: DialApplication) {
    val client by app.session.client.collectAsState()
    CompositionLocalProvider(LocalApp provides app) {
        DialTheme {
            if (client == null) {
                LoginScreen()
            } else {
                // Soon after the app opens, Discovery is brought up to date in the background, so it is ready when you get there.
                LaunchedEffect(client) {
                    val c = client ?: return@LaunchedEffect
                    // Whether the server has the Dial plugin decides if Discovery and mixtapes are there at all.
                    if (DialPlugin.check(c)) {
                        kotlinx.coroutines.delay(5_000)
                        DiscoveryEngine.prefetch(c)
                    }
                }
                LaunchedEffect(client) {
                    app.library.refresh()
                    client?.let { app.credits.refresh(it) }
                }
                MainScreen()
            }
        }
    }
}

private data class Tab(val route: Any, val title: String, val icon: ImageVector)

@Composable
private fun MainScreen() {
    val app = LocalApp.current
    val nav = rememberNavController()
    val playback by app.player.state.collectAsState()
    var showPlayer by rememberSaveable { mutableStateOf(false) }
    val snackbar = remember { SnackbarHostState() }

    LaunchedEffect(playback.error) {
        playback.error?.let {
            snackbar.showSnackbar(it)
            app.player.clearError()
        }
    }

    val hasPlugin by DialPlugin.present.collectAsState()
    val tabs = listOfNotNull(
        Tab(HomeRoute, "Home", Icons.Rounded.Home),
        Tab(RadioRoute, "Radio", Icons.Rounded.Radio),
        Tab(LibraryRoute, "Library", Icons.Rounded.LibraryMusic),
        if (hasPlugin) Tab(SearchRoute, "Discovery", Icons.Rounded.Explore) else null,
    )
    val backStack by nav.currentBackStackEntryAsState()
    val navigator = remember { Navigator { route -> nav.navigate(route) } }

    CompositionLocalProvider(LocalNavigator provides navigator, LocalBack provides { nav.popBackStack(); Unit }) {
        Box(Modifier.fillMaxSize()) {
            val selectTab: (Any) -> Unit = { route ->
                nav.navigate(route) {
                    popUpTo(nav.graph.findStartDestination().id) { saveState = true }
                    launchSingleTop = true
                    restoreState = true
                }
            }
            androidx.compose.foundation.layout.Row(Modifier.fillMaxSize()) {
            Scaffold(
                modifier = Modifier.weight(1f),
                snackbarHost = { SnackbarHost(snackbar) },
                bottomBar = {
                    Column {
                        if (playback.hasContent) MiniPlayer(onOpen = { showPlayer = true })
                        NavigationBar(containerColor = MaterialTheme.colorScheme.surfaceContainerLow) {
                            tabs.forEach { tab ->
                                val selected = backStack?.destination?.hierarchy()?.any { it.hasRoute(tab.route::class) } == true
                                NavigationBarItem(
                                    selected = selected,
                                    onClick = { selectTab(tab.route) },
                                    icon = { Icon(tab.icon, null) },
                                    label = { Text(tab.title) },
                                    colors = dialNavigationColors(),
                                )
                            }
                        }
                    }
                },
            ) { padding ->
                NavHost(nav, startDestination = HomeRoute, modifier = Modifier.padding(padding)) {
                    composable<HomeRoute> { HomeScreen() }
                    composable<RadioRoute> { RadioScreen() }
                    composable<LibraryRoute> { LibraryScreen() }
                    composable<SearchRoute> { DiscoveryScreen() }
                    composable<SectionRoute> { LibrarySectionScreen(LibrarySection.valueOf(it.toRoute<SectionRoute>().section)) }
                    composable<AlbumRoute> { val r = it.toRoute<AlbumRoute>(); AlbumScreen(r.id, r.name) }
                    composable<ArtistRoute> { val r = it.toRoute<ArtistRoute>(); ArtistScreen(r.id, r.name) }
                    composable<PlaylistRoute> { val r = it.toRoute<PlaylistRoute>(); PlaylistScreen(r.id, r.name) }
                    composable<GenreRoute> { val r = it.toRoute<GenreRoute>(); CategoryScreen(genre = r, decade = null) }
                    composable<DecadeRoute> { CategoryScreen(genre = null, decade = it.toRoute<DecadeRoute>().start) }
                    composable<PublicAlbumRoute> { PublicAlbumScreen(it.toRoute()) }
                    composable<FeaturedArtistRoute> { FeaturedArtistScreen(it.toRoute<FeaturedArtistRoute>().name) }
                    composable<MixtapeRoute> { MixtapeScreen(it.toRoute<MixtapeRoute>().id) }
                    composable<ImportRoute> { ImportScreen() }
                    composable<SettingsRoute> { SettingsScreen() }
                    composable<ArtistPreviewRoute> { ArtistPreviewScreen(it.toRoute()) }
                    composable<ExploreGenreRoute> {
                        ExploreGenreScreen(it.toRoute<ExploreGenreRoute>().name)
                    }
                }
            }
            }

            // The player slides up over everything, with a springy expressive motion.
            AnimatedVisibility(
                visible = showPlayer && playback.hasContent,
                enter = slideInVertically(spring(dampingRatio = 0.82f, stiffness = 380f)) { it },
                exit = slideOutVertically(spring(dampingRatio = 1f, stiffness = 500f)) { it },
            ) {
                BackHandler { showPlayer = false }
                NowPlayingScreen(onClose = { showPlayer = false }, onOpen = { route ->
                    showPlayer = false
                    navigator.open(route)
                })
            }
        }
    }
}

private fun androidx.navigation.NavDestination.hierarchy() = generateSequence(this) { it.parent }

/** An artist's page: from your library when they're in it, otherwise their featured songs. */
fun artistRoute(app: DialApplication, name: String): Any =
    app.credits.libraryArtist(name)?.let { ArtistRoute(it.id, it.name) } ?: FeaturedArtistRoute(name)

/** The album page for a song's album, or the artist page. */
fun Item.albumRoute(): Any? = albumId?.let { AlbumRoute(it, album ?: "") }
