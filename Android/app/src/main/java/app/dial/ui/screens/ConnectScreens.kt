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
