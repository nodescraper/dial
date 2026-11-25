package app.dial.ui.screens

import app.dial.data.ServerDiscovery
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.graphics.Brush
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.TextButton
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import app.dial.R
import app.dial.ui.LocalApp
import app.dial.ui.components.Spacing
import app.dial.ui.components.black
import kotlinx.coroutines.launch
import androidx.compose.foundation.background
import app.dial.data.JellyfinClient

/** Two steps, like Dial on iPhone and Mac: where your server is, then how you sign in. */
@Composable
fun LoginScreen() {
    val app = LocalApp.current
    val scope = rememberCoroutineScope()
    var step by remember { mutableStateOf(0) }
    var server by remember { mutableStateOf(app.session.lastServer) }
    var serverName by remember { mutableStateOf<String?>(null) }
    var quickConnectAvailable by remember { mutableStateOf(false) }
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var quickCode by remember { mutableStateOf<String?>(null) }
    var quickJob by remember { mutableStateOf<kotlinx.coroutines.Job?>(null) }
    var discovered by remember { mutableStateOf<List<ServerDiscovery.Found>>(emptyList()) }

    androidx.compose.runtime.LaunchedEffect(Unit) { discovered = ServerDiscovery.find() }

    fun connect(address: String) {
        busy = true; error = null
        scope.launch {
            val name = JellyfinClient.serverName(address)
            if (name == null) {
                error = "Couldn\u2019t reach a Jellyfin server at that address. Check it, and that you\u2019re on the same network."
            } else {
                server = JellyfinClient.normalize(address); serverName = name
                quickConnectAvailable = JellyfinClient.quickConnectEnabled(address)
                step = 1
            }
            busy = false
        }
    }

    fun startQuickConnect() {
        quickJob?.cancel(); error = null
        quickJob = scope.launch {
            runCatching {
                val (code, secret) = JellyfinClient.quickConnectStart(server)
                quickCode = code
                repeat(150) {
                    kotlinx.coroutines.delay(2000)
                    JellyfinClient.quickConnectFinish(server, secret)?.let { client -> app.session.use(client); return@launch }
                }
                quickCode = null
                error = "That code expired. Try again."
            }.onFailure {
                if (it !is kotlinx.coroutines.CancellationException) { error = it.message ?: "Quick Connect didn\u2019t work."; quickCode = null }
            }
        }
    }

    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color(0xFF2A1245), Color(0xFF0C0714))))) {
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).imePadding().padding(Spacing.xl),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(Spacing.l, Alignment.CenterVertically),
        ) {
            val size = if (step == 0) 112.dp else 72.dp
            Image(painterResource(R.drawable.ic_launcher_foreground), null,
                Modifier.size(size).clip(RoundedCornerShape(if (step == 0) 26.dp else 17.dp)).background(Color(0xFF1B1030)))
            Text("Dial", style = MaterialTheme.typography.displaySmall, color = Color.White)
            if (step == 0) {
                Text("Your music, from your own server.", style = MaterialTheme.typography.titleMedium, color = Color.White.copy(alpha = 0.7f))
            } else {
                Text(serverName ?: "Jellyfin", style = MaterialTheme.typography.titleMedium, color = Color.White)
                Text(server, style = MaterialTheme.typography.bodySmall, color = Color.White.copy(alpha = 0.6f))
                TextButton(onClick = { quickJob?.cancel(); quickCode = null; error = null; step = 0 }) { Text("Change server") }
            }
            Column(Modifier.widthIn(max = 480.dp).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
                if (step == 0) {
                    if (discovered.isNotEmpty()) {
                        Text("On your network", style = MaterialTheme.typography.labelLarge, color = Color.White.copy(alpha = 0.7f))
                        discovered.forEach { found ->
                            FilledTonalButton(onClick = { connect(found.address) }, modifier = Modifier.fillMaxWidth(),
                                shape = RoundedCornerShape(12.dp)) { Text("${found.name}  \u00b7  ${found.address}") }
                        }
                        Text("Or enter the address", style = MaterialTheme.typography.labelLarge, color = Color.White.copy(alpha = 0.7f))
                    }
                    OutlinedTextField(server, { server = it }, label = { Text("Server address") },
                        placeholder = { Text("192.168.1.10:8096") }, singleLine = true, modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(12.dp),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Go))
                    error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium) }
                    Button(onClick = { connect(server) }, enabled = !busy && server.isNotBlank(), shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.fillMaxWidth().height(52.dp)) { Text(if (busy) "Connecting\u2026" else "Continue") }
                    Text("Use the address you open Jellyfin with. This device has to reach the server, for example on your home Wi-Fi.",
                        style = MaterialTheme.typography.bodySmall, color = Color.White.copy(alpha = 0.6f), textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth())
                } else {
                    if (quickConnectAvailable) {
                        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Color(0xFFE8742C).copy(alpha = 0.16f))
                            .padding(Spacing.l), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                            val code = quickCode
                            if (code != null) {
                                Text("Your code", style = MaterialTheme.typography.labelLarge, color = Color.White.copy(alpha = 0.7f))
                                Text(code, fontSize = 44.sp, fontWeight = FontWeight.Bold, letterSpacing = 8.sp, color = Color(0xFFE8742C))
                                Text("On a device where you\u2019re signed in to Jellyfin, open your profile, choose Quick Connect and enter this code.",
                                    style = MaterialTheme.typography.bodySmall, color = Color.White.copy(alpha = 0.7f), textAlign = TextAlign.Center)
                                Text("Waiting for approval\u2026", style = MaterialTheme.typography.bodySmall, color = Color.White.copy(alpha = 0.7f))
                                TextButton(onClick = { quickJob?.cancel(); quickCode = null }) { Text("Cancel") }
                            } else {
                                Button(onClick = { startQuickConnect() }, modifier = Modifier.fillMaxWidth().height(52.dp),
                                    shape = RoundedCornerShape(12.dp)) { Text("Sign in with Quick Connect") }
                                Text("No password to type: approve a code from Jellyfin on another device.",
                                    style = MaterialTheme.typography.bodySmall, color = Color.White.copy(alpha = 0.7f), textAlign = TextAlign.Center)
                            }
                        }
                        Text("Or use your account",
                            style = MaterialTheme.typography.labelLarge, color = Color.White.copy(alpha = 0.7f))
                    }
                    OutlinedTextField(username, { username = it }, label = { Text("Username") }, singleLine = true,
                        modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(12.dp),
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next))
                    OutlinedTextField(password, { password = it }, label = { Text("Password") }, singleLine = true,
                        visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(12.dp),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done))
                    error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium) }
                    FilledTonalButton(onClick = {
                        busy = true; error = null
                        scope.launch {
                            runCatching { app.session.signIn(server, username, password) }.onFailure { error = it.message ?: "Couldn\u2019t sign in." }
                            busy = false
                        }
                    }, enabled = !busy && username.isNotBlank(), shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.fillMaxWidth().height(52.dp)) { Text(if (busy) "Signing in\u2026" else "Sign In") }
                }
            }
        }
    }
}
