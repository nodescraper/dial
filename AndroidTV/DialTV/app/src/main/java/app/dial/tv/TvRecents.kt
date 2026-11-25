package app.dial.tv

import android.content.Context
import androidx.compose.runtime.mutableStateListOf
import app.dial.data.JellyfinJson
import app.dial.data.Station
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer

/** A station you played: a live station, one of the mixes, or an artist's radio. */
@Serializable
data class RecentStation(
    /** "live", "mix", "favorites" or "artist" */
    val kind: String,
    val key: String,
    val title: String,
    val subtitle: String,
    val image: String? = null,
    val station: Station? = null,
    val artistId: String? = null,
)

/** The stations you played most recently, newest first, remembered between launches. */
object TvRecents {
    val items = mutableStateListOf<RecentStation>()
    private var context: Context? = null

    fun init(context: Context) {
        if (this.context != null) return
        this.context = context.applicationContext
        val text = context.getSharedPreferences("dial.tv", Context.MODE_PRIVATE).getString("recentStations", null) ?: return
        runCatching { JellyfinJson.decodeFromString(ListSerializer(RecentStation.serializer()), text) }.getOrNull()?.let { items.addAll(it) }
    }

    fun add(recent: RecentStation) {
        items.removeAll { it.key == recent.key }
        items.add(0, recent)
        while (items.size > 12) items.removeAt(items.lastIndex)
        context?.getSharedPreferences("dial.tv", Context.MODE_PRIVATE)?.edit()
            ?.putString("recentStations", JellyfinJson.encodeToString(ListSerializer(RecentStation.serializer()), items.toList()))?.apply()
    }

    fun live(station: Station) = add(RecentStation("live", "live:${station.id}", station.name.trim(),
        listOfNotNull(station.country?.takeIf { it.isNotBlank() }, "Live radio").joinToString(" · "), station.favicon?.takeIf { it.isNotBlank() }, station = station))
}
