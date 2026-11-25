package app.dial.data

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** Who's signed in. Kept in the app's private storage. */
class Session(context: Context) {
    private val prefs = context.getSharedPreferences("dial.session", Context.MODE_PRIVATE)
    private val _client = MutableStateFlow(load())
    val client: StateFlow<JellyfinClient?> = _client

    private fun load(): JellyfinClient? {
        val server = prefs.getString("server", null) ?: return null
        val token = prefs.getString("token", null) ?: return null
        val user = prefs.getString("userId", null) ?: return null
        return JellyfinClient(server, token, user)
    }

    suspend fun signIn(server: String, username: String, password: String) {
        val client = JellyfinClient.login(server, username, password)
        prefs.edit().putString("server", client.server).putString("token", client.token)
            .putString("userId", client.userId).apply()
        _client.value = client
    }

    /** Signs in with an account approved through Quick Connect. */
    fun use(client: JellyfinClient) {
        prefs.edit().putString("server", client.server).putString("token", client.token)
            .putString("userId", client.userId).apply()
        _client.value = client
    }

    fun signOut() {
        prefs.edit().clear().apply()
        _client.value = null
    }

    val lastServer: String get() = prefs.getString("server", "") ?: ""
}
