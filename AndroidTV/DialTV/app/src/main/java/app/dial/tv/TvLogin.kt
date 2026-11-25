package app.dial.tv

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.dial.data.JellyfinClient
import app.dial.data.ServerDiscovery
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Sign-in for the couch: find the server by itself, then a Quick Connect code to approve from your phone. */
@Composable
fun TvLogin() {
    val app = LocalTvApp.current
    val scope = rememberCoroutineScope()
    var step by remember { mutableStateOf(0) }
    var server by remember { mutableStateOf(app.session.lastServer) }
    var serverName by remember { mutableStateOf<String?>(null) }
    var quickAvailable by remember { mutableStateOf(false) }
    var code by remember { mutableStateOf<String?>(null) }
    var job by remember { mutableStateOf<Job?>(null) }
    var found by remember { mutableStateOf<List<ServerDiscovery.Found>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }
    var showPassword by remember { mutableStateOf(false) }
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { found = ServerDiscovery.find() }

    fun startQuick() {
        job?.cancel(); error = null
        job = scope.launch {
            runCatching {
                val (c, secret) = JellyfinClient.quickConnectStart(server)
                code = c
                repeat(150) {
                    delay(2000)
                    JellyfinClient.quickConnectFinish(server, secret)?.let { client -> app.session.use(client); return@launch }
                }
                code = null; error = "That code expired."
            }.onFailure { if (it !is CancellationException) { error = it.message ?: "Quick Connect didn’t work."; code = null } }
        }
    }

    fun connect(address: String) {
        busy = true; error = null
        scope.launch {
            val name = JellyfinClient.serverName(address)
            if (name == null) error = "Couldn’t reach a Jellyfin server at that address."
            else {
                server = JellyfinClient.normalize(address); serverName = name
                quickAvailable = JellyfinClient.quickConnectEnabled(address)
                step = 1
                if (quickAvailable) startQuick() else showPassword = true
            }
            busy = false
        }
    }

    Column(Modifier.fillMaxSize().padding(horizontal = Tv.marginX * 2, vertical = 48.dp), verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally) {
        Text("Dial", style = MaterialTheme.typography.displayMedium, color = Accent)
        if (step == 0) {
            Text("Choose your Jellyfin server", style = MaterialTheme.typography.headlineMedium)
            found.forEach { f -> TvButton("${f.name}   ${f.address}", primary = true) { connect(f.address) } }
            OutlinedTextField(server, { server = it }, singleLine = true, label = { Text("Or type the address") }, modifier = Modifier.width(420.dp))
            TvButton(if (busy) "Connecting…" else "Continue", primary = found.isEmpty()) { if (server.isNotBlank() && !busy) connect(server) }
        } else {
            Text(serverName ?: "Jellyfin", style = MaterialTheme.typography.headlineMedium)
            if (quickAvailable) {
                val c = code
                if (c != null) {
                    Text("On a device where you’re signed in to Jellyfin, open your profile, choose Quick Connect and enter:", style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(c, fontSize = 64.sp, fontWeight = FontWeight.Bold, letterSpacing = 12.sp, color = Accent)
                    Text("Waiting for approval…", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                } else TvButton("Get a code") { startQuick() }
            }
            TvButton(if (showPassword) "Hide password sign-in" else "Use username and password", primary = false) { showPassword = !showPassword }
            if (showPassword) {
                OutlinedTextField(username, { username = it }, singleLine = true, label = { Text("Username") }, modifier = Modifier.width(420.dp))
                OutlinedTextField(password, { password = it }, singleLine = true, label = { Text("Password") }, visualTransformation = PasswordVisualTransformation(), modifier = Modifier.width(420.dp))
                TvButton(if (busy) "Signing in…" else "Sign in") {
                    busy = true; error = null
                    scope.launch { runCatching { app.session.signIn(server, username, password) }.onFailure { error = it.message ?: "Couldn’t sign in." }; busy = false }
                }
            }
            TvButton("Change server", primary = false) { job?.cancel(); code = null; step = 0 }
        }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium) }
    }
}
