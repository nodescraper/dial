package app.dial.ui.screens

import android.text.format.Formatter
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.rounded.QueueMusic
import androidx.compose.material.icons.rounded.Dns
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.Equalizer
import androidx.compose.material.icons.rounded.Explore
import androidx.compose.material.icons.rounded.Extension
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Speaker
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material.icons.rounded.Storage
import androidx.compose.material.icons.rounded.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import app.dial.data.DialPlugin
import app.dial.data.DiscoveryEngine
import app.dial.data.JellyfinClient
import app.dial.data.LibraryExport
import app.dial.data.PluginStatus
import app.dial.data.ResponseCache
import app.dial.playback.Effects
import app.dial.ui.LocalApp
import app.dial.ui.components.Spacing
import app.dial.ui.components.bold
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Settings like on iPhone, in Android's look: your server on top, then grouped rows that each open a page. */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen() {
    val app = LocalApp.current
    val context = LocalContext.current
    val settings by app.settings.settings.collectAsState()
    val eq by Effects.info.collectAsState()
    val records by app.downloads.records.collectAsState()
    val hidden by app.library.hidden.collectAsState()
    val linked by app.remote.linked.collectAsState()
    val offline by app.connectivity.offline.collectAsState()
    val playback by app.player.state.collectAsState()
    val hasPlugin by DialPlugin.present.collectAsState()
    val audioMuse by produceState<Boolean?>(null) { value = app.session.client.value?.audioMuseCanSearch() }
    val addons by produceState<PluginStatus?>(null) { value = app.session.client.value?.dialStatus() }
    var page by rememberSaveable { mutableStateOf("") }
    var devices by remember { mutableStateOf(false) }
    var confirmSignOut by remember { mutableStateOf(false) }
    BackHandler(enabled = page != "") { page = "" }
    val back = LocalBack.current

    fun title() = when (page) {
        "account" -> "Account"; "playback" -> "Playback"; "eq" -> "Equalizer"; "discovery" -> "Discovery"; "downloads" -> "Downloads"
        "storage" -> "Storage"; "playlists" -> "Playlists"; "export" -> "Export Library"; "hidden" -> "Hidden Songs"; "addons" -> "Server Add-ons"; "about" -> "About"; else -> "Settings"
    }

    Column(Modifier.fillMaxSize()) {
        androidx.compose.material3.TopAppBar(title = { Text(title()) }, navigationIcon = {
            androidx.compose.material3.IconButton(onClick = { if (page == "") back() else page = "" }) {
                Icon(Icons.AutoMirrored.Rounded.ArrowBack, "Back")
            }
        })
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = Spacing.l).padding(bottom = Spacing.section),
            verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
            when (page) {
                "" -> {
                    val server = app.session.lastServer
                    Group {
                        Row(Modifier.fillMaxWidth().clickable { page = "account" }.padding(Spacing.l), verticalAlignment = Alignment.CenterVertically) {
                            Box(Modifier.size(56.dp).clip(CircleShape).background(MaterialTheme.colorScheme.primary), contentAlignment = Alignment.Center) {
                                Text(server.removePrefix("https://").removePrefix("http://").take(1).uppercase(), style = MaterialTheme.typography.titleLarge,
                                    color = MaterialTheme.colorScheme.onPrimary)
                            }
                            Column(Modifier.weight(1f).padding(horizontal = Spacing.m)) {
                                Text("Your server", style = MaterialTheme.typography.titleMedium.bold())
                                Text(server.removePrefix("https://").removePrefix("http://"), maxLines = 1, overflow = TextOverflow.Ellipsis,
                                    style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            Chevron()
                        }
                    }
                    Group {
                        SettingsRow("Playback", Icons.Rounded.PlayArrow, Color(0xFFF2994A),
                            if (settings.crossfadeSeconds == 0) "No crossfade" else "${settings.crossfadeSeconds} s crossfade") { page = "playback" }
                        SettingsRow("Equalizer", Icons.Rounded.Equalizer, Color(0xFFE0568A), if (settings.equalizerOn) (settings.equalizerPreset ?: "Custom") else "Off") { page = "eq" }
                        SettingsRow("Discovery", Icons.Rounded.Explore, Color(0xFF2BB5A8), if (DiscoveryEngine.ticketmasterKey.isNotBlank()) "Concerts on" else null) { page = "discovery" }
                    }
                    Group {
                        SettingsRow("Downloads", Icons.Rounded.Download, Color(0xFF3B82F6), if (records.isEmpty()) "None" else "${records.size} songs") { page = "downloads" }
                        SettingsRow("Storage", Icons.Rounded.Storage, Color(0xFF8E8E93), null) { page = "storage" }
                        SettingsRow("Hidden Songs", Icons.Rounded.VisibilityOff, Color(0xFFE8742C), if (hidden.isEmpty()) "None" else "${hidden.size}") { page = "hidden" }
                        SettingsRow("Playlists", Icons.AutoMirrored.Rounded.QueueMusic, Color(0xFFE5484D), null) { page = "playlists" }
                        SettingsRow("Export Library", Icons.Rounded.Share, Color(0xFF5856D6), null) { page = "export" }
                    }
                    Group {
                        SettingsRow("Server Add-ons", Icons.Rounded.Extension, Color(0xFF34C759),
                            if (hasPlugin) "Dial" else if (audioMuse == true) "AudioMuse" else null) { page = "addons" }
                        SettingsRow("Devices", Icons.Rounded.Speaker, Color(0xFF2BB5A8), playback.outputName ?: "This phone") { devices = true }
                    }
                    Group { SettingsRow("About Dial", Icons.Rounded.Info, Color(0xFF8E8E93), JellyfinClient.VERSION) { page = "about" } }
                }

                "account" -> {
                    Group {
                        InfoRow("Address", app.session.lastServer)
                        InfoRow("Status", when { offline -> "Can\u2019t be reached"; linked -> "Connected, live"; else -> "Connected" })
                    }
                    Group {
                        Text("Sign Out", color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyLarge,
                            modifier = Modifier.fillMaxWidth().clickable { confirmSignOut = true }.padding(Spacing.l))
                    }
                    Footer("Downloaded songs stay on this phone.")
                }

                "playback" -> {
                    Group {
                        listOf("original" to "Original quality", "high" to "High (320 kbps)", "saver" to "Data saver (128 kbps)").forEachIndexed { i, (key, label) ->
                            if (i > 0) Divider()
                            Row(Modifier.fillMaxWidth().clickable { app.settings.update { it.copy(quality = key) } }.padding(horizontal = Spacing.l, vertical = 14.dp),
                                verticalAlignment = Alignment.CenterVertically) {
                                androidx.compose.material3.RadioButton(settings.quality == key, { app.settings.update { it.copy(quality = key) } })
                                Text(label, Modifier.padding(start = Spacing.s))
                            }
                        }
                    }
                    Footer("Original plays your files exactly as stored. Lower settings save mobile data; your server converts the music. Downloads always keep the original.")
                    Group {
                        Column(Modifier.padding(Spacing.l)) {
                            Row { Text("Crossfade", Modifier.weight(1f)); Text(if (settings.crossfadeSeconds == 0) "Off" else "${settings.crossfadeSeconds} seconds",
                                color = MaterialTheme.colorScheme.onSurfaceVariant) }
                            Slider(settings.crossfadeSeconds.toFloat(), { v -> app.settings.update { it.copy(crossfadeSeconds = v.toInt()) } },
                                valueRange = 0f..12f, steps = 11)
                        }
                        Divider()
                        SwitchRow("Volume Leveling", settings.volumeLeveling) { on -> app.settings.update { it.copy(volumeLeveling = on) } }
                    }
                    Footer("With crossfade off, songs follow each other with no gap; albums that run into the next song never crossfade. Volume leveling plays loud and quiet songs at a similar volume.")
                }

                "eq" -> {
                    Group { SwitchRow("Equalizer", settings.equalizerOn) { on -> app.settings.update { it.copy(equalizerOn = on) } } }
                    val info = eq
                    if (info == null) Footer("Play a song once and the equalizer\u2019s bands appear here.")
                    else if (settings.equalizerOn) {
                        LazyRow(horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
                            items(info.presets) { preset ->
                                FilterChip(selected = settings.equalizerPreset == preset, label = { Text(preset) }, onClick = {
                                    val levels = Effects.presetLevels(preset) ?: emptyList()
                                    app.settings.update { it.copy(equalizerPreset = preset, equalizerBands = levels) }
                                })
                            }
                        }
                        Group {
                            info.bands.indices.forEach { band ->
                                val level = settings.equalizerBands.getOrNull(band) ?: 0
                                val hz = info.bands[band]
                                Row(Modifier.fillMaxWidth().padding(horizontal = Spacing.l), verticalAlignment = Alignment.CenterVertically) {
                                    Text(if (hz >= 1000) "${hz / 1000} kHz" else "$hz Hz", modifier = Modifier.padding(end = Spacing.m))
                                    Slider(level.toFloat(), { v ->
                                        app.settings.update { s ->
                                            val bands = List(info.bands.size) { i -> if (i == band) v.toInt() else s.equalizerBands.getOrNull(i) ?: 0 }
                                            s.copy(equalizerBands = bands, equalizerPreset = null)
                                        }
                                    }, valueRange = info.minLevel.toFloat()..info.maxLevel.toFloat(), modifier = Modifier.weight(1f))
                                    Text("%+.0f dB".format(level / 100f), modifier = Modifier.padding(start = Spacing.m))
                                }
                            }
                        }
                    }
                }

                "discovery" -> {
                    var key by remember { mutableStateOf(DiscoveryEngine.ticketmasterKey) }
                    var city by remember { mutableStateOf(DiscoveryEngine.city) }
                    var country by remember { mutableStateOf(DiscoveryEngine.country) }
                    var cleared by remember { mutableStateOf(false) }
                    Group {
                        Column(Modifier.padding(Spacing.l), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                            OutlinedTextField(key, { key = it; DiscoveryEngine.ticketmasterKey = it }, label = { Text("Ticketmaster API key") },
                                singleLine = true, modifier = Modifier.fillMaxWidth())
                            OutlinedTextField(city, { city = it; DiscoveryEngine.city = it }, label = { Text("City (optional)") },
                                singleLine = true, modifier = Modifier.fillMaxWidth())
                            OutlinedTextField(country, { country = it; DiscoveryEngine.country = it }, label = { Text("Country code, like GB or US (optional)") },
                                singleLine = true, modifier = Modifier.fillMaxWidth())
                        }
                    }
                    Footer("Discovery can show upcoming concerts by artists you own. It needs a free key from developer.ticketmaster.com. With a key, the names of your most played artists are sent to Ticketmaster to look up their events; without one, nothing is sent.")
                    Group {
                        ActionRow(if (cleared) "Cleared" else "Clear Discovery Cache", enabled = !cleared) { DiscoveryEngine.clearCache(); cleared = true }
                    }
                    Footer("Discovery keeps what it found, so it opens at once: concerts for twelve hours, releases for a day and each artist\u2019s albums for a few days.")
                }

                "downloads" -> {
                    Group {
                        InfoRow("Songs", "${records.size}")
                        Divider()
                        InfoRow("Space Used", Formatter.formatShortFileSize(context, app.downloads.totalBytes))
                    }
                    Footer("Downloads keep going in the background. When your server can\u2019t be reached, Dial plays these.")
                    Group { ActionRow("Remove All Downloads", destructive = true, enabled = records.isNotEmpty()) { app.downloads.deleteAll() } }
                }

                "storage" -> {
                    var cleared by remember { mutableStateOf(false) }
                    Group {
                        ActionRow(if (cleared) "Cleared" else "Clear Saved Pages", enabled = !cleared) { ResponseCache.clear(); cleared = true }
                    }
                    Footer("Home, Library and artist pages are saved so they open instantly. Clearing them makes each page load fresh once.")
                }

                "playlists" -> {
                    var show by remember { mutableStateOf(JellyfinClient.showPlaylistFiles) }
                    val files by produceState<List<app.dial.data.Item>>(emptyList()) {
                        value = runCatching { app.session.client.value?.allPlaylists()?.filter { it.isPlaylistFile } }.getOrNull() ?: emptyList()
                    }
                    Group {
                        SwitchRow("Show Playlist Files", show) { show = it; JellyfinClient.showPlaylistFiles = it }
                    }
                    if (files.isNotEmpty()) {
                        Text("${files.size} playlist files", style = MaterialTheme.typography.titleSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = Spacing.s))
                        Group {
                            files.forEachIndexed { i, file ->
                                if (i > 0) Divider()
                                Column(Modifier.fillMaxWidth().padding(Spacing.l)) {
                                    Text(file.name)
                                    file.path?.let { Text(it, style = MaterialTheme.typography.bodySmall, fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2) }
                                }
                            }
                        }
                    }
                    Footer("Many albums come with a playlist file (.m3u), often called \u201CPlay Me\u201D or after the album. Jellyfin lists each one as a playlist but can\u2019t delete them, because they\u2019re files in your music folder. Dial hides them unless this is on. To remove them for good, delete the .m3u files on your server; Jellyfin drops them on its next library scan.")
                }

                "export" -> {
                    ExportLibraryPage()
                }

                "hidden" -> {
                    Group {
                        InfoRow("Hidden songs", if (hidden.isEmpty()) "None" else "${hidden.size}")
                        Divider()
                        ActionRow("Allow All Songs", enabled = hidden.isNotEmpty()) { hidden.toList().forEach { app.library.setHidden(it, false) } }
                    }
                    Footer("Radio and mixes skip hidden songs. You can still play one yourself.")
                }

                "addons" -> {
                    Group {
                        StatusRow(if (hasPlugin) "Dial plugin is active" else "Dial plugin isn\u2019t installed",
                            if (hasPlugin) "Discovery and mixtapes" else "Discovery and mixtapes need it. Without it those two parts are hidden; everything else works.", hasPlugin)
                    }
                    addons?.groups?.forEach { group ->
                        Text(group.title, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(start = Spacing.s))
                        Group {
                            group.rows.forEachIndexed { i, row ->
                                if (i > 0) Divider()
                                StatusRow(row.name, row.provides + (row.note?.let { "\n$it" } ?: ""), row.active)
                            }
                        }
                    }
                    Group {
                        StatusRow("AudioMuse", when (audioMuse) {
                            null -> "Checking\u2026"
                            true -> "Active: radio, mixes and mood stations follow how songs sound"
                            false -> "Not installed: radio uses Jellyfin\u2019s genre matching"
                        }, audioMuse == true)
                    }
                }

                "about" -> {
                    Group { InfoRow("Version", JellyfinClient.VERSION) }
                    Text("Where Dial\u2019s Information Comes From", style = MaterialTheme.typography.titleSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = Spacing.s))
                    Group {
                        listOf("MusicBrainz" to "Albums and artists not in your library", "ListenBrainz" to "Charts, new releases and similar artists",
                            "Cover Art Archive" to "Covers of albums not in your library", "Wikidata and Wikimedia Commons" to "Artist photos",
                            "LRCLIB" to "Lyrics your server doesn\u2019t have", "Radio Browser" to "Live radio stations",
                            "AudioMuse" to "How songs sound (optional, on your server)").forEachIndexed { i, (name, what) ->
                            if (i > 0) Divider()
                            Column(Modifier.fillMaxWidth().padding(Spacing.l)) {
                                Text(name)
                                Text(what, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                    Footer("Dial has no account of its own and no tracking. It talks to your server and to these open, free services, and keeps everything else on this phone.")
                }
            }
        }
    }
    if (devices) DevicesSheet { devices = false }
    if (confirmSignOut) AlertDialog(
        onDismissRequest = { confirmSignOut = false },
        title = { Text("Sign out of your server?") },
        text = { Text("Downloaded songs stay on this phone.") },
        confirmButton = { TextButton(onClick = { confirmSignOut = false; app.player.stop(); app.session.signOut() }) {
            Text("Sign Out", color = MaterialTheme.colorScheme.error) } },
        dismissButton = { TextButton(onClick = { confirmSignOut = false }) { Text("Cancel") } },
    )
}

/** Settings > Export Library: your artists, albums and tracks as three CSV spreadsheets in one zip, saved where you choose. */
@Composable
private fun ExportLibraryPage() {
    val app = LocalApp.current
    val context = LocalContext.current
    val offline by app.connectivity.offline.collectAsState()
    val scope = rememberCoroutineScope()
    var working by remember { mutableStateOf(false) }
    var counts by remember { mutableStateOf<LibraryExport.Counts?>(null) }
    var message by remember { mutableStateOf<String?>(null) }
    var pending by remember { mutableStateOf<LibraryExport.Made?>(null) }
    // The system's save dialog, with the zip's name filled in.
    val saver = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/zip")) { uri ->
        val made = pending ?: return@rememberLauncherForActivityResult
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch(Dispatchers.IO) {
            runCatching {
                context.contentResolver.openOutputStream(uri)?.use { it.write(made.zip) }
                    ?: throw java.io.IOException("Couldn't open that location.")
            }.onSuccess { message = "Saved." }
                .onFailure { message = "Couldn't save the file: ${it.message}" }
        }
    }
    Group {
        ActionRow(if (working) "Exporting…" else "Export Library…", enabled = !working && !offline) {
            val client = app.session.client.value ?: return@ActionRow
            scope.launch {
                working = true
                message = null
                try {
                    val made = withContext(Dispatchers.IO) { LibraryExport.make(client) }
                    counts = made.counts
                    pending = made
                    saver.launch("${made.name}.zip")
                } catch (e: Exception) {
                    message = "Couldn't read your library: ${e.message}"
                }
                working = false
            }
        }
    }
    Footer("Three spreadsheets in one zip: artists.csv (artist, albums, tracks), albums.csv (album artist, album, year, tracks, length) and tracks.csv (album artist, album, disc, track, title, artists, year, length). They open in Excel, Numbers and Google Sheets.")
    counts?.let {
        Group {
            InfoRow("Artists", "${it.artists}")
            Divider()
            InfoRow("Albums", "${it.albums}")
            Divider()
            InfoRow("Tracks", "${it.tracks}")
        }
    }
    message?.let { Group { Text(it, modifier = Modifier.padding(Spacing.l), color = MaterialTheme.colorScheme.onSurfaceVariant) } }
}

// MARK: - Building blocks

/** A rounded card holding rows, like a settings group. */
@Composable
private fun Group(content: @Composable () -> Unit) {
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(MaterialTheme.colorScheme.surfaceContainer)) {
        content()
    }
}

@Composable private fun Divider() = HorizontalDivider(Modifier.padding(start = Spacing.l), color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f))

@Composable private fun Chevron() = Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)

@Composable
private fun Footer(text: String) = Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
    modifier = Modifier.padding(horizontal = Spacing.s))

/** A row that opens a page: a coloured square icon, the title, what it is set to, and an arrow. */
@Composable
private fun SettingsRow(title: String, icon: ImageVector, color: Color, value: String?, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = Spacing.l, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(36.dp).clip(RoundedCornerShape(10.dp)).background(color), contentAlignment = Alignment.Center) {
            Icon(icon, null, tint = Color.White, modifier = Modifier.size(20.dp))
        }
        Text(title, Modifier.weight(1f).padding(start = Spacing.m), style = MaterialTheme.typography.bodyLarge)
        if (value != null) Text(value, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(end = 4.dp), style = MaterialTheme.typography.bodyMedium)
        Chevron()
    }
}

@Composable
private fun InfoRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth().padding(Spacing.l), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.padding(end = Spacing.m))
        Text(value, Modifier.weight(1f), color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis,
            textAlign = androidx.compose.ui.text.style.TextAlign.End)
    }
}

@Composable
private fun SwitchRow(title: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().clickable { onChange(!checked) }.padding(horizontal = Spacing.l, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, Modifier.weight(1f))
        Switch(checked, onChange)
    }
}

@Composable
private fun ActionRow(title: String, destructive: Boolean = false, enabled: Boolean = true, onClick: () -> Unit) {
    val color = when { !enabled -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f); destructive -> MaterialTheme.colorScheme.error; else -> MaterialTheme.colorScheme.primary }
    Text(title, color = color, modifier = Modifier.fillMaxWidth().clickable(enabled = enabled, onClick = onClick).padding(Spacing.l))
}

@Composable
private fun StatusRow(title: String, detail: String, active: Boolean) {
    Row(Modifier.fillMaxWidth().padding(Spacing.l), verticalAlignment = Alignment.Top) {
        Box(Modifier.padding(top = 6.dp).size(10.dp).clip(CircleShape).background(if (active) Color(0xFF34C759) else Color(0xFFFF9500)))
        Column(Modifier.padding(start = Spacing.m)) {
            Text(title)
            Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
