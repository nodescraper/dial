package app.dial.tv

import androidx.compose.ui.focus.focusRequester
import app.dial.data.RadioBrowser
import app.dial.data.Station
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.Sensors
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material.icons.rounded.ArrowDropDown
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Sort
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import app.dial.data.ArtistNames
import app.dial.data.Item
import app.dial.data.MixCatalog
import app.dial.data.MixSections
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

private fun Modifier.screenPadding() = padding(top = 8.dp, bottom = 32.dp)

@Composable
fun TvRadio() {
    val app = LocalTvApp.current
    val nav = LocalTvNav.current
    val client = tvClient()
    val artists = rememberTvLoad("radio-artists") { it.randomArtists(14) }
    var mixes by remember { mutableStateOf(MixCatalog.latest ?: MixSections()) }
    var mixesLoaded by remember { mutableStateOf(false) }
    var canSound by remember { mutableStateOf(false) }
    LaunchedEffect(client) {
        val c = client ?: return@LaunchedEffect
        canSound = withContext(Dispatchers.IO) { runCatching { c.audioMuseCanYourSound() }.getOrDefault(false) }
        val muse = withContext(Dispatchers.IO) { runCatching { c.audioMuseCanSearch() }.getOrDefault(false) }
        MixCatalog.load(c, muse) { if (it != mixes) mixes = it }
        mixesLoaded = true
    }
    // Arrive with your latest station selected (or the first of your stations when there isn't one yet).
    val firstCard = remember { androidx.compose.ui.focus.FocusRequester() }
    val recents = TvRecents.items
    LaunchedEffect(Unit) { delay(200); runCatching { firstCard.requestFocus() } }
    LazyColumn(contentPadding = PaddingValues(bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(22.dp)) {
        if (recents.isNotEmpty()) item {
            TvRow("Recent Stations", recents.toList(), topRow = true) { index, r ->
                val mod = if (index == 0) Modifier.focusRequester(firstCard) else Modifier
                Box(mod) {
                    when (r.kind) {
                        "live" -> r.station?.let { st -> TvStationTile(st) { TvRecents.live(st); app.player.playStation(st); nav.open(TvRoute.Player) } }
                        "artist" -> CoverCard(r.title, r.subtitle, r.image) {
                            val id = r.artistId ?: return@CoverCard
                            app.player.play("${r.title} Radio", radio = true) { c ->
                                val own = c.artistSongs(id, 30).shuffled()
                                (own.take(2) + c.instantMix(id, 30) + own.drop(2)).distinctBy { it.id }
                            }
                            nav.open(TvRoute.Player)
                        }
                        else -> {
                            val mix = r.kind == "mix"
                            StationCard(r.title, r.subtitle, r.kind) {
                                app.player.play(r.title, radio = true) { c ->
                                    if (r.kind == "sound") return@play c.yourSound().shuffled()
                                    val seed = (if (mix) c.randomSongs(1).firstOrNull() else c.favoriteSongs().randomOrNull()) ?: return@play emptyList()
                                    listOf(seed) + c.instantMix(seed.id, 30).filter { it.id != seed.id }
                                }
                                nav.open(TvRoute.Player)
                            }
                        }
                    }
                }
            }
        }
        item {
            TvRow("Your Stations", listOf("mix", "favorites") + if (canSound) listOf("sound") else emptyList(), topRow = recents.isEmpty()) { index, which ->
                val mix = which == "mix"
                val sound = which == "sound"
                Box(if (index == 0 && recents.isEmpty()) Modifier.focusRequester(firstCard) else Modifier) {
                val title = if (sound) "Your Sound" else if (mix) "Your Mix" else "Favorites Mix"
                val line = if (sound) "Matches what you play most" else if (mix) "Your whole library" else "Songs you love"
                StationCard(title, line, which) {
                    TvRecents.add(RecentStation(which, which, title, line))
                    app.player.play(title, radio = true) { c ->
                        if (sound) return@play c.yourSound().shuffled()
                        val seed = (if (mix) c.randomSongs(1).firstOrNull() else c.favoriteSongs().randomOrNull()) ?: return@play emptyList()
                        listOf(seed) + c.instantMix(seed.id, 30).filter { it.id != seed.id }
                    }
                    nav.open(TvRoute.Player)
                }
                }
            }
        }
        if (mixes.daily.isEmpty() && !mixesLoaded) item { TvRowPlaceholder("Made for You") }
        if (mixes.daily.isEmpty() && !mixesLoaded) item { TvRowPlaceholder("Mixtapes") }
        item { TvRow("Made for You", mixes.daily.filter { !it.id.startsWith("daily-") }) { _, m -> TvMixtapeCard(m) { nav.open(TvRoute.Mixtape(m.id)) } } }
        item { TvRow("Mixtapes", mixes.daily.filter { it.id.startsWith("daily-") }) { _, m -> TvMixtapeCard(m) { nav.open(TvRoute.Mixtape(m.id)) } } }
        if (mixes.decades.isEmpty() && !mixesLoaded) item { TvRowPlaceholder("Decades") }
        item { TvRow("Decades", mixes.decades) { _, m -> TvMixtapeCard(m) { nav.open(TvRoute.Mixtape(m.id)) } } }
        if (mixes.genres.isEmpty() && !mixesLoaded) item { TvRowPlaceholder("Genres") }
        item { TvRow("Genres", mixes.genres) { _, m -> TvMixtapeCard(m) { nav.open(TvRoute.Mixtape(m.id)) } } }
        item {
            TvRow("Live Radio", liveCategories) { _, c -> TvCategoryCard(c) { nav.open(TvRoute.Stations(c.tag, c.title)) } }
        }
        item {
            TvRow("Artist Radio", artists ?: emptyList()) { _, artist ->
                CoverCard(ArtistNames.primary(artist.name), "Radio", client?.imageUrl(artist.id, 280)) {
                    TvRecents.add(RecentStation("artist", "artist:${artist.id}", ArtistNames.primary(artist.name), "Artist radio", client?.imageUrl(artist.id, 280), artistId = artist.id))
                    app.player.startRadio(artist); nav.open(TvRoute.Player)
                }
            }
        }
    }
}

@Composable
private fun StationCard(title: String, subtitle: String, kind: String, onClick: () -> Unit) {
    val shape = RoundedCornerShape(Tv.radius)
    val colors = when (kind) {
        "mix" -> listOf(Color(0xFFE8742C), Color(0xFFA8401A))
        "sound" -> listOf(Color(0xFF3A6FD8), Color(0xFF5B2A86))
        else -> listOf(Color(0xFFC2455E), Color(0xFF6E2A6E))
    }
    Column(Modifier.width(Tv.coverWidth)) {
        Box(Modifier.fillMaxWidth().aspectRatio(1f).tvFocus(shape).clip(shape).clickable(onClick = onClick)
            .background(Brush.linearGradient(colors)), contentAlignment = Alignment.Center) {
            Icon(when (kind) { "mix" -> Icons.Rounded.Sensors; "sound" -> Icons.Rounded.GraphicEq; else -> Icons.Rounded.Favorite }, null, Modifier.size(44.dp), tint = Color.White)
        }
        Text(title, style = MaterialTheme.typography.labelLarge, modifier = Modifier.padding(top = 8.dp))
        Text(subtitle, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

private enum class LibFilter(val title: String) {
    Albums("Albums"), Artists("Artists"), Playlists("Playlists"), Songs("Songs"), Favorites("Favorites"), Wishlist("Wishlist"), Stats("Stats"), Genres("Genres"), Decades("Decades")
}

private enum class AlbumSort(val title: String) { Name("A to Z"), Added("Recently Added"), Year("Year") }

/** A pill for choosing what the Library shows. Selected: amber. Focused: the accent outline. */
@Composable
private fun TvChip(label: String, selected: Boolean, onClick: () -> Unit) {
    val shape = RoundedCornerShape(50)
    Text(label, style = MaterialTheme.typography.labelLarge, color = if (selected) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface,
        modifier = Modifier.tvFocus(shape).clip(shape).background(if (selected) Accent else MaterialTheme.colorScheme.surfaceVariant)
            .clickable(onClick = onClick).padding(horizontal = 18.dp, vertical = 9.dp))
}

/** The sort choice for albums: a pill with the current order, which opens a list of the orders. */
@Composable
private fun TvSortMenu(current: AlbumSort, onPick: (AlbumSort) -> Unit) {
    var open by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(50)
    Box {
        Row(Modifier.tvFocus(shape).clip(shape).background(MaterialTheme.colorScheme.surfaceVariant).clickable { open = true }
            .padding(horizontal = 16.dp, vertical = 9.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Icon(Icons.Rounded.Sort, "Sort", Modifier.size(20.dp))
            Text(current.title, style = MaterialTheme.typography.labelLarge)
            Icon(Icons.Rounded.ArrowDropDown, null, Modifier.size(20.dp))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            AlbumSort.entries.forEach { option ->
                DropdownMenuItem(text = { Text(option.title) },
                    leadingIcon = { if (option == current) Icon(Icons.Rounded.Check, null) },
                    onClick = { open = false; onPick(option) })
            }
        }
    }
}

/** The Library as a proper page: pick what to browse at the top, then a grid (or list) of it, sortable where it makes sense. */
@Composable
fun TvLibrary() {
    val app = LocalTvApp.current
    val nav = LocalTvNav.current
    val client = tvClient()
    var filter by rememberSaveable { mutableStateOf(LibFilter.Albums) }
    var sort by rememberSaveable { mutableStateOf(AlbumSort.Name) }

    val playlists = rememberTvLoad("lib-playlists") { it.playlists() }
    val artists = rememberTvLoad("lib-artists") { it.artists() }
    val albums = rememberTvLoad("lib-albums") { it.albums(3000) }
    val recent = rememberTvLoad("lib-recent") { it.recentAlbums(500) }
    val songs = rememberTvLoad("lib-songs") { it.songs(3000) }
    val favorites = rememberTvLoad("lib-favorites") { it.favoriteSongs() }
    val mixes = MixCatalog.latest

    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            LazyRow(Modifier.weight(1f), contentPadding = PaddingValues(start = Tv.marginX), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                // No all-songs list (it is just a very long scroll); the rest as on the phone.
                val filters = LibFilter.entries.filter { it != LibFilter.Songs }
                items(filters.size) { i -> val f = filters[i]; TvChip(f.title, filter == f) { filter = f } }
            }
            // Albums can be sorted; the choice sits at the right end of this row.
            if (filter == LibFilter.Albums) TvSortMenu(sort) { sort = it }
            Spacer(Modifier.width(Tv.marginX))
        }
        Spacer(Modifier.height(8.dp))
        when (filter) {
            LibFilter.Albums -> {
                val list = when (sort) {
                    AlbumSort.Name -> albums
                    AlbumSort.Added -> recent
                    AlbumSort.Year -> albums?.sortedByDescending { it.productionYear ?: 0 }
                } ?: emptyList()
                TvGrid(list, key = { it.id }) { a ->
                    CoverCard(a.name, if (sort == AlbumSort.Year) listOfNotNull(a.albumArtistLine, a.productionYear?.toString()).joinToString(" \u00b7 ") else a.albumArtistLine,
                        client?.imageUrl(a.id, 320)) { nav.open(TvRoute.Album(a.id, a.name)) }
                }
            }
            LibFilter.Artists -> TvGrid(artists ?: emptyList(), key = { it.id }) { a ->
                CoverCard(ArtistNames.primary(a.name), null, client?.imageUrl(a.id, 320)) { nav.open(TvRoute.Artist(a.id, ArtistNames.primary(a.name))) }
            }
            LibFilter.Playlists -> TvGrid(playlists ?: emptyList(), key = { it.id }) { p ->
                CoverCard(p.name, "Playlist", client?.imageUrl(p.id, 320)) { nav.open(TvRoute.Playlist(p.id, p.name)) }
            }
            LibFilter.Songs -> TvSongList(songs ?: emptyList()) { list, index -> list.getOrNull(index)?.let { app.player.playLike(it) }; nav.open(TvRoute.Player) }
            LibFilter.Favorites -> TvSongList(favorites ?: emptyList()) { list, index -> list.getOrNull(index)?.let { app.player.playLike(it) }; nav.open(TvRoute.Player) }
            LibFilter.Wishlist -> TvWishlist()
            LibFilter.Stats -> TvStats()
            LibFilter.Genres -> TvGrid(mixes?.genres ?: emptyList(), key = { it.id }) { m -> TvMixtapeCard(m) { nav.open(TvRoute.Mixtape(m.id)) } }
            LibFilter.Decades -> TvGrid(mixes?.decades ?: emptyList(), key = { it.id }) { m -> TvMixtapeCard(m) { nav.open(TvRoute.Mixtape(m.id)) } }
        }
    }
}

/** A grid of cards that fills the width and scrolls down. */
@Composable
private fun <T> TvGrid(items: List<T>, key: (T) -> Any, card: @Composable (T) -> Unit) {
    if (items.isEmpty()) {
        Text("Nothing here yet.", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = Tv.marginX))
        return
    }
    LazyVerticalGrid(columns = GridCells.Adaptive(Tv.coverWidth + 12.dp), contentPadding = PaddingValues(start = Tv.marginX, end = Tv.marginX, top = 6.dp, bottom = 32.dp),
        horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        items(items.size, key = { key(items[it]) }) { card(items[it]) }
    }
}

/** Songs as rows, two columns wide, scrolling down. */
@Composable
private fun TvSongList(songs: List<Item>, onPlay: (List<Item>, Int) -> Unit) {
    val client = tvClient()
    // Songs deleted from here leave the list at once.
    var gone by remember(songs) { mutableStateOf(emptySet<String>()) }
    var menuSong by remember { mutableStateOf<Item?>(null) }
    val shown = songs.filter { it.id !in gone }
    if (shown.isEmpty()) {
        Text("Nothing here yet.", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = Tv.marginX))
        return
    }
    LazyVerticalGrid(columns = GridCells.Fixed(2), contentPadding = PaddingValues(start = Tv.marginX, end = Tv.marginX, top = 6.dp, bottom = 32.dp),
        horizontalArrangement = Arrangement.spacedBy(16.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        items(shown.size) { i -> TvSongRow(shown[i], client?.imageUrl(shown[i].imageItemId, 160), onLongClick = { menuSong = shown[i] }) { onPlay(shown, i) } }
    }
    menuSong?.let { song ->
        TvSongMenu(song, null, onGone = { gone = gone + song.id; menuSong = null }, onDismiss = { menuSong = null })
    }
}

@Composable
fun TvSearch() {
    val app = LocalTvApp.current
    val nav = LocalTvNav.current
    val client = tvClient()
    var query by remember { mutableStateOf("") }
    var results by remember { mutableStateOf<List<Item>>(emptyList()) }
    var stations by remember { mutableStateOf<List<Station>>(emptyList()) }
    LaunchedEffect(query) {
        if (query.length < 2) { results = emptyList(); stations = emptyList(); return@LaunchedEffect }
        delay(400)
        results = withContext(Dispatchers.IO) { runCatching { client?.search(query) }.getOrNull() ?: emptyList() }
        stations = runCatching { RadioBrowser.search(query) }.getOrNull()?.take(20) ?: emptyList()
    }
    LazyColumn(contentPadding = PaddingValues(bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(22.dp)) {
        item {
            OutlinedTextField(query, { query = it }, singleLine = true, placeholder = { Text("Search your library") },
                shape = RoundedCornerShape(Tv.radius), modifier = Modifier.fillMaxWidth().padding(horizontal = Tv.marginX))
        }
        item {
            TvRow("Artists", results.filter { it.type == "MusicArtist" }) { _, a ->
                CoverCard(ArtistNames.primary(a.name), null, client?.imageUrl(a.id, 280)) { nav.open(TvRoute.Artist(a.id, ArtistNames.primary(a.name))) }
            }
        }
        item {
            TvRow("Albums", results.filter { it.type == "MusicAlbum" }) { _, a ->
                CoverCard(a.name, a.albumArtistLine, client?.imageUrl(a.id, 280)) { nav.open(TvRoute.Album(a.id, a.name)) }
            }
        }
        item {
            TvRow("Live Stations", stations) { _, st -> TvStationTile(st) { TvRecents.live(st); app.player.playStation(st); nav.open(TvRoute.Player) } }
        }
        item {
            val songs = results.filter { it.type == "Audio" }
            TvRow("Songs", songs) { _, s ->
                CoverCard(s.name, s.artistLine, client?.imageUrl(s.imageItemId, 280)) { app.player.playLike(s); nav.open(TvRoute.Player) }
            }
        }
    }
}

@Composable
fun TvSettings() {
    val app = LocalTvApp.current
    val client = tvClient()
    val downloads by app.downloads.records.collectAsState()
    Column(Modifier.padding(horizontal = Tv.marginX), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("Settings", style = MaterialTheme.typography.displayMedium)
        Text("Signed in to ${client?.server ?: ""}", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (downloads.isNotEmpty()) TvDeleteButton("Remove All Downloads", "Remove all downloads?",
            "The songs stay on your server; only the copies on this TV go.", onDelete = { app.downloads.deleteAll() }, onDone = {})
        // The startup screen waits for Home's covers (the first start is slower, and the rows then open with pictures).
        val context = androidx.compose.ui.platform.LocalContext.current
        var longStart by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(longStartupEnabled(context)) }
        TvButton(if (longStart) "Longer startup screen: On" else "Longer startup screen: Off", primary = false) {
            longStart = !longStart
            setLongStartup(context, longStart)
        }
        TvButton("Sign out", primary = false) { app.session.signOut() }
    }
}
