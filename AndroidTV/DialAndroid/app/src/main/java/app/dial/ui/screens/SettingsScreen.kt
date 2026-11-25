package app.dial.ui.screens

import app.dial.data.DialPlugin
import app.dial.data.PluginStatus
import app.dial.data.DiscoveryEngine
import androidx.compose.runtime.setValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.mutableStateOf
import android.text.format.Formatter
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.FilterChip
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import app.dial.playback.Effects
import app.dial.ui.LocalApp
import app.dial.ui.components.SectionTitle
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.background
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import app.dial.ui.components.Spacing

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
    val audioMuse by produceState<Boolean?>(null) { value = app.session.client.value?.audioMuseCanSearch() }
    val hasPlugin by DialPlugin.present.collectAsState()
    val addons by produceState<PluginStatus?>(null) { value = app.session.client.value?.dialStatus() }

    Column(Modifier.fillMaxSize()) {
        PageTopBar("Settings")
        LazyColumn(contentPadding = PaddingValues(bottom = Spacing.section)) {
            // The Dial plugin, and everything it builds on, as the server reports it.
            item { SectionTitle("Server Add-ons") }
            item {
                ListItem(
                    leadingContent = { Box(Modifier.size(12.dp).clip(androidx.compose.foundation.shape.CircleShape).background(if (hasPlugin) Color(0xFF34C759) else Color(0xFFFF9500))) },
                    headlineContent = { Text(if (hasPlugin) "Dial plugin is active" else "Dial plugin isn\u2019t installed") },
                    supportingContent = { Text(if (hasPlugin) "Discovery and mixtapes" else "Discovery and mixtapes need it. Without it those two parts are hidden; everything else works.") },
                )
            }
            addons?.groups?.forEach { group ->
                item { Text(group.title, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = Spacing.l, vertical = Spacing.s)) }
                items(group.rows.size) { i ->
                    val row = group.rows[i]
                    ListItem(
                        leadingContent = { Box(Modifier.size(12.dp).clip(androidx.compose.foundation.shape.CircleShape).background(if (row.active) Color(0xFF34C759) else Color(0xFFFF9500))) },
                        headlineContent = { Text(row.name) },
                        supportingContent = { Text(row.provides + (row.note?.let { "\n$it" } ?: "")) },
                    )
                }
            }

            item { SectionTitle("Playback", Modifier.padding(top = Spacing.l)) }
            item {
                Column(Modifier.padding(horizontal = Spacing.l)) {
                    Text("Crossfade: " + if (settings.crossfadeSeconds == 0) "Off" else "${settings.crossfadeSeconds} s")
                    Slider(settings.crossfadeSeconds.toFloat(), { v -> app.settings.update { it.copy(crossfadeSeconds = v.toInt()) } },
                        valueRange = 0f..12f, steps = 11)
                }
            }
            item {
                ListItem(headlineContent = { Text("Volume Leveling") },
                    supportingContent = { Text("Loud and quiet songs play at a similar volume, using what Jellyfin measures.") },
                    trailingContent = { Switch(settings.volumeLeveling, { on -> app.settings.update { it.copy(volumeLeveling = on) } }) })
            }
            item {
                Text("With crossfade off, songs follow each other with no gap. Songs that run into each other on the same album never crossfade.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = Spacing.l))
            }

            item { SectionTitle("Equalizer", Modifier.padding(top = Spacing.l)) }
            item {
                ListItem(headlineContent = { Text("Equalizer") },
                    trailingContent = { Switch(settings.equalizerOn, { on -> app.settings.update { it.copy(equalizerOn = on) } }) })
            }
            val info = eq
            if (info == null) item {
                Text("Play a song once and the equalizer\u2019s bands appear here.", color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = Spacing.l))
            } else if (settings.equalizerOn) {
                item {
                    LazyRow(contentPadding = PaddingValues(horizontal = Spacing.l), horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
                        items(info.presets) { preset ->
                            FilterChip(selected = settings.equalizerPreset == preset, label = { Text(preset) }, onClick = {
                                val levels = Effects.presetLevels(preset) ?: emptyList()
                                app.settings.update { it.copy(equalizerPreset = preset, equalizerBands = levels) }
                            })
                        }
                    }
                }
                items(info.bands.size) { band ->
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

            item { SectionTitle("Downloads", Modifier.padding(top = Spacing.l)) }
            item {
                ListItem(headlineContent = { Text("${records.size} songs, ${Formatter.formatShortFileSize(context, app.downloads.totalBytes)}") },
                    supportingContent = { Text("Downloads continue in the background. Offline, Dial plays these.") },
                    trailingContent = { TextButton(onClick = { app.downloads.deleteAll() }, enabled = records.isNotEmpty()) { Text("Remove All") } })
            }

            item { SectionTitle("Hidden Songs", Modifier.padding(top = Spacing.l)) }
            item {
                ListItem(headlineContent = { Text(if (hidden.isEmpty()) "No hidden songs" else "${hidden.size} hidden songs") },
                    supportingContent = { Text("Radio and mixes skip them. Tap one to play it anyway.") },
                    trailingContent = {
                        TextButton(onClick = { hidden.forEach { app.library.setHidden(it, false) } }, enabled = hidden.isNotEmpty()) { Text("Allow All") }
                    })
            }

            item { SectionTitle("Discovery", Modifier.padding(top = Spacing.l)) }
            item {
                var key by remember { mutableStateOf(DiscoveryEngine.ticketmasterKey) }
                var city by remember { mutableStateOf(DiscoveryEngine.city) }
                var country by remember { mutableStateOf(DiscoveryEngine.country) }
                var cleared by remember { mutableStateOf(false) }
                Column(Modifier.padding(horizontal = Spacing.l), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                    Text("Concerts: Discovery can show upcoming concerts by artists you own. It needs a free key from developer.ticketmaster.com. " +
                        "With a key, the names of your most played artists are sent to Ticketmaster to look up their events; without one, nothing is sent.",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    androidx.compose.material3.OutlinedTextField(key, { key = it; DiscoveryEngine.ticketmasterKey = it },
                        label = { Text("Ticketmaster API key") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                    androidx.compose.material3.OutlinedTextField(city, { city = it; DiscoveryEngine.city = it },
                        label = { Text("City (optional)") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                    androidx.compose.material3.OutlinedTextField(country, { country = it; DiscoveryEngine.country = it },
                        label = { Text("Country code, like GB or US (optional)") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                    androidx.compose.material3.TextButton(onClick = { DiscoveryEngine.clearCache(); cleared = true }, enabled = !cleared) {
                        Text(if (cleared) "Cleared" else "Clear Discovery cache")
                    }
                    Text("Discovery keeps what it found, so it opens at once: concerts for twelve hours, releases for a day and each artist\u2019s albums for a few days.",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            item { SectionTitle("Server", Modifier.padding(top = Spacing.l)) }
            item {
                ListItem(headlineContent = { Text(app.session.lastServer) },
                    supportingContent = { Text(when { offline -> "Can\u2019t be reached right now"; linked -> "Connected, live"; else -> "Connected" }) })
            }
            item {
                ListItem(headlineContent = { Text("AudioMuse") },
                    supportingContent = { Text(when (audioMuse) {
                        null -> "Checking\u2026"
                        true -> "Active: radio, mixes and mood stations follow how songs sound"
                        false -> "Not installed: radio uses Jellyfin\u2019s genre matching"
                    }) })
            }
            item {
                ListItem(headlineContent = { Text("Marlo") },
                    supportingContent = { Text("Not on Android yet. It runs on Dial for iPhone and Mac, and shows here when it plays there.") })
            }
            item {
                OutlinedButton(onClick = { app.player.stop(); app.session.signOut() },
                    modifier = Modifier.fillMaxWidth().padding(Spacing.l)) { Text("Sign Out") }
            }
        }
    }
}
