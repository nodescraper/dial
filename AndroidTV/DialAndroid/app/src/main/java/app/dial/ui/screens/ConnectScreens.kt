@file:OptIn(ExperimentalMaterial3Api::class)

package app.dial.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Computer
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.Language
import androidx.compose.material.icons.rounded.PhoneAndroid
import androidx.compose.material.icons.rounded.PhoneIphone
import androidx.compose.material.icons.rounded.Speaker
import androidx.compose.material.icons.rounded.Tv
import androidx.compose.material.icons.rounded.VolumeDown
import androidx.compose.material.icons.rounded.VolumeUp
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import app.dial.data.RemoteControl
import app.dial.ui.LocalApp
import app.dial.ui.components.Spacing
import app.dial.ui.components.bold

private fun symbolFor(name: String): ImageVector {
    val n = name.lowercase()
    return when {
        "tv" in n || "shield" in n || "chromecast" in n -> Icons.Rounded.Tv
        "iphone" in n || "ipad" in n -> Icons.Rounded.PhoneIphone
        "phone" in n || "pixel" in n || "galaxy" in n || "android" in n -> Icons.Rounded.PhoneAndroid
        "web" in n || "chrome" in n || "firefox" in n || "safari" in n -> Icons.Rounded.Language
        "speaker" in n || "sonos" in n -> Icons.Rounded.Speaker
        else -> Icons.Rounded.Computer
    }
}

/** Where the music plays: this device or another of yours. Like Spotify's device picker. */
@Composable
fun DevicesSheet(onDismiss: () -> Unit) {
    val app = LocalApp.current
    val state by app.player.state.collectAsState()
    val devices by app.remote.devices.collectAsState()
    val linked by app.remote.linked.collectAsState()
    val thisDevice = "This Phone"
    LaunchedEffect(Unit) { app.remote.refresh() }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        LazyColumn(Modifier.padding(bottom = Spacing.xl)) {
            item {
                Text("Current Device", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = Spacing.l, vertical = Spacing.s))
                DeviceRow(state.outputName ?: thisDevice, state.current?.name ?: state.station?.name ?: "Nothing playing",
                    if (state.isRemote) symbolFor(state.outputName ?: "") else Icons.Rounded.PhoneAndroid,
                    current = true) {}
                if (state.isRemote && state.remoteVolume != null) RemoteVolume(state.remoteVolume!!)
            }
            item {
                Text("Select a Device", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(start = Spacing.l, end = Spacing.l, top = Spacing.l, bottom = Spacing.s))
            }
            if (state.isRemote) item {
                DeviceRow(thisDevice, "Play here", Icons.Rounded.PhoneAndroid, current = false) {
                    app.remote.selectThisDevice(); onDismiss()
                }
            }
            val others = devices.filter { it.controllable && it.id != state.outputId }
            if (others.isEmpty() && !state.isRemote) item {
                Text("No other devices are open right now.", color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = Spacing.l, vertical = Spacing.m))
            }
            items(others, key = { it.id }) { device ->
                DeviceRow(device.name, device.nowPlaying?.let { "Playing ${it.name}" } ?: if (device.isDial) "Dial" else device.app,
                    symbolFor(device.name + " " + device.app), current = false) { app.remote.select(device); onDismiss() }
            }
            item {
                Text(
                    (if (linked) "" else "Not connected to your server live, so other devices can\u2019t see this one. ") +
                        "Open Dial or Jellyfin on your TV, computer or another phone, signed in to the same account, and it appears here. " +
                        "The music moves there from the same spot, and you keep controlling it from here. Between Dial apps, live radio moves too.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(Spacing.l),
                )
            }
        }
    }
}

@Composable
private fun DeviceRow(name: String, detail: String, icon: ImageVector, current: Boolean, onClick: () -> Unit) {
    ListItem(
        headlineContent = { Text(name, color = if (current) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface) },
        supportingContent = { Text(detail, maxLines = 1) },
        leadingContent = { Icon(icon, null, tint = if (current) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant) },
        trailingContent = { if (current) Icon(Icons.Rounded.GraphicEq, null, tint = MaterialTheme.colorScheme.primary) },
        colors = ListItemDefaults.colors(containerColor = androidx.compose.ui.graphics.Color.Transparent),
        modifier = Modifier.clickable(enabled = !current, onClick = onClick),
    )
}

/** The other device's volume. */
@Composable
fun RemoteVolume(level: Int) {
    val app = LocalApp.current
    var dragging by remember { mutableStateOf<Float?>(null) }
    Row(Modifier.fillMaxWidth().padding(horizontal = Spacing.l), verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Rounded.VolumeDown, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Slider(value = dragging ?: level.toFloat(), onValueChange = { dragging = it }, valueRange = 0f..100f,
            onValueChangeFinished = { dragging?.let { app.player.setRemoteVolume(it.toInt()) }; dragging = null },
            modifier = Modifier.weight(1f).padding(horizontal = Spacing.s))
        Icon(Icons.Rounded.VolumeUp, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

// MARK: - Marlo

/** Marlo on the Radio tab: what it is, that it runs on your iPhone and Mac for now, and a way to start it there. */
@Composable
fun MarloCard(modifier: Modifier = Modifier) {
    val app = LocalApp.current
    val devices by app.remote.devices.collectAsState()
    val mirror by app.remote.djMirror.collectAsState()
    var explain by remember { mutableStateOf(false) }
    val appleDials = devices.filter { it.isDial }
    Surface(onClick = { explain = true }, shape = RoundedCornerShape(28.dp), color = MaterialTheme.colorScheme.secondaryContainer,
        modifier = modifier.fillMaxWidth()) {
        Row(Modifier.padding(Spacing.l), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.GraphicEq, null, Modifier.size(40.dp), tint = MaterialTheme.colorScheme.primary)
            Column(Modifier.weight(1f).padding(start = Spacing.m)) {
                Text("Marlo, your DJ", style = MaterialTheme.typography.titleMedium.bold())
                Text(
                    when {
                        mirror != null -> "On air on ${app.player.state.value.outputName ?: "your other device"}"
                        appleDials.isNotEmpty() -> "Runs on your iPhone and Mac. Tap to start it there."
                        else -> "Coming to Android. For now Marlo runs on Dial for iPhone and Mac."
                    },
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSecondaryContainer,
                )
            }
        }
    }
    if (explain) AlertDialog(
        onDismissRequest = { explain = false },
        title = { Text("Marlo isn\u2019t on Android yet") },
        text = {
            Text("Marlo, the DJ that talks between sets, needs an on-device AI model and a voice, and is planned as a Jellyfin plugin " +
                "so it can work everywhere. Until then it runs on Dial for iPhone and Mac. When Marlo plays on one of those, this " +
                "device shows it and you can talk to it from here.")
        },
        confirmButton = {
            val target = appleDials.firstOrNull()
            if (target != null) TextButton(onClick = { app.remote.startMarlo(target); explain = false }) { Text("Start Marlo on ${target.name}") }
            else TextButton(onClick = { explain = false }) { Text("OK") }
        },
        dismissButton = { if (appleDials.isNotEmpty()) TextButton(onClick = { explain = false }) { Text("Not Now") } },
    )
}

/** While following a device that runs Marlo: what Marlo is doing, and talking to it. */
@Composable
fun MarloMirrorBar(mirror: RemoteControl.DJMirror) {
    val app = LocalApp.current
    var talking by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
        Text("Marlo" + (mirror.blockTitle?.let { ": $it" } ?: ""), style = MaterialTheme.typography.labelLarge.bold(),
            color = MaterialTheme.colorScheme.primary)
        if (mirror.onAir && mirror.caption != null) {
            Text("\u201c${mirror.caption}\u201d", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurface,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
            TextButton(onClick = { talking = true }) { Text("Talk to Marlo") }
            TextButton(onClick = { app.remote.marloSomethingDifferent() }) { Text("Something Different") }
            if (mirror.onAir) TextButton(onClick = { app.remote.marloSkipBreak() }) { Text("Skip") }
        }
    }
    if (talking) {
        var text by remember { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = { talking = false },
            title = { Text("Talk to Marlo") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                    mirror.messages.takeLast(4).forEach { (fromDJ, message) ->
                        Text((if (fromDJ) "Marlo: " else "You: ") + message, style = MaterialTheme.typography.bodySmall,
                            color = if (fromDJ) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    OutlinedTextField(text, { text = it }, placeholder = { Text("What's the vibe?") }, singleLine = true)
                }
            },
            confirmButton = {
                TextButton(onClick = { app.remote.askMarlo(text); talking = false }, enabled = text.isNotBlank()) { Text("Send") }
            },
            dismissButton = { TextButton(onClick = { talking = false }) { Text("Cancel") } },
        )
    }
}
