package app.dial.data

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer

/**
 * The Dial plugin on your Jellyfin server makes Discovery and the made-for-you mixtapes once a day, the same on every
 * device. Without it those two parts are hidden. Whether it is there is remembered, so the tabs are right at launch.
 */
object DialPlugin {
    private lateinit var prefs: android.content.SharedPreferences
    private val _present = MutableStateFlow(false)
    val present: StateFlow<Boolean> get() = _present
    @Volatile var checked = false
        private set

    fun init(context: Context) {
        prefs = context.getSharedPreferences("dial", Context.MODE_PRIVATE)
        _present.value = prefs.getBoolean("hasPlugin", false)
    }

    /** Asks the server, and remembers the answer. */
    suspend fun check(client: JellyfinClient): Boolean {
        val found = client.hasDialPlugin()
        checked = true
        _present.value = found
        prefs.edit().putBoolean("hasPlugin", found).apply()
        return found
    }
}

@Serializable
data class PluginFanGroup(val seedName: String, val picks: List<PublicMusic.Pick> = emptyList())

/** The Discovery feed as the plugin makes it. */
@Serializable
data class PluginFeed(
    val fresh: List<PublicMusic.Pick> = emptyList(),
    /** Releases with an exact date still ahead, soonest first. */
    val upcoming: List<PublicMusic.Pick> = emptyList(),
    /** The artists you play most, in order. */
    val artists: List<DiscoveryArtist> = emptyList(),
    val fans: List<PluginFanGroup> = emptyList(),
    val concerts: List<Concert> = emptyList(),
    val concertsEnabled: Boolean = false,
)

@Serializable
data class PluginMixtape(val id: String, val title: String, val subtitle: String = "", val palette: List<String> = emptyList(),
                         val trackIds: List<String> = emptyList(), val coverIds: List<String> = emptyList())

@Serializable
data class PluginMixtapeSet(val day: String = "", val mixes: List<PluginMixtape> = emptyList())

@Serializable
data class PluginStatusRow(val name: String, val active: Boolean, val provides: String, val note: String? = null)

@Serializable
data class PluginStatusGroup(val title: String, val rows: List<PluginStatusRow> = emptyList())

@Serializable
data class PluginStatus(val groups: List<PluginStatusGroup> = emptyList())
