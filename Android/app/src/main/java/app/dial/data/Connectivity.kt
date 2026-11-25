package app.dial.data

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit

/** Whether your server can be reached. Offline, Dial plays your downloads and checks again every 15 seconds. */
class Connectivity(context: Context, private val session: Session) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val _offline = MutableStateFlow(false)
    val offline: StateFlow<Boolean> = _offline
    private var retry: Job? = null
    private val quick = OkHttpClient.Builder().connectTimeout(4, TimeUnit.SECONDS).readTimeout(4, TimeUnit.SECONDS).build()

    init {
        val manager = context.getSystemService(ConnectivityManager::class.java)
        manager.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) { scope.launch { check() } }
            override fun onLost(network: Network) { scope.launch { check() } }
        })
        scope.launch { check() }
    }

    suspend fun check() {
        val client = session.client.value ?: run { _offline.value = false; return }
        val reachable = withContext(Dispatchers.IO) {
            runCatching {
                quick.newCall(Request.Builder().url("${client.server}/System/Ping").build()).execute().use { it.code < 500 }
            }.getOrDefault(false)
        }
        _offline.value = !reachable
        retry?.cancel()
        if (!reachable) retry = scope.launch {
            while (isActive) {
                delay(15_000)
                check()
                if (!_offline.value) break
            }
        }
    }
}
