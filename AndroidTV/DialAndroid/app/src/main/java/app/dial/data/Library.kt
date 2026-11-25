package app.dial.data

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** Your favorites (on the server) and hidden songs (on this device), shown everywhere. */
class Library(private val session: Session, context: android.content.Context) {
    private val prefs = context.getSharedPreferences("dial.hidden", android.content.Context.MODE_PRIVATE)
    private val _hidden = MutableStateFlow(prefs.getStringSet("ids", emptySet())!!.toSet())
    /** Songs you chose not to hear: radio and mixes skip them; tapping one still plays it. */
    val hidden: StateFlow<Set<String>> = _hidden

    fun isHidden(id: String) = id in _hidden.value

    fun setHidden(id: String, hide: Boolean) {
        _hidden.update { if (hide) it + id else it - id }
        prefs.edit().putStringSet("ids", _hidden.value).apply()
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val _favorites = MutableStateFlow<Set<String>>(emptySet())
    val favorites: StateFlow<Set<String>> = _favorites

    fun refresh() {
        val client = session.client.value ?: return
        scope.launch {
            runCatching { client.favoriteSongs() + client.favoriteAlbums() }
                .onSuccess { items -> _favorites.value = items.map { it.id }.toSet() }
        }
    }

    fun isFavorite(id: String) = id in _favorites.value

    /** A favorite changed on another device (the server tells every open app). */
    fun applyFavorite(id: String, favorite: Boolean) = _favorites.update { if (favorite) it + id else it - id }

    fun toggleFavorite(item: Item) {
        val client = session.client.value ?: return
        val makeFavorite = item.id !in _favorites.value
        _favorites.update { if (makeFavorite) it + item.id else it - item.id }
        scope.launch {
            runCatching { client.setFavorite(item.id, makeFavorite) }.onFailure {
                _favorites.update { if (makeFavorite) it - item.id else it + item.id }
            }
        }
    }
}
