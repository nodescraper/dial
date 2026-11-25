package app.dial.data

import android.content.Context
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer

/**
 * Songs you played without a connection to your server, kept until it can be told. Without this they would be lost: Jellyfin never
 * heard of them, so play counts, "last played" and everything built on them (On Repeat, the daily mixes) would miss them.
 * Back online, each one is sent as played, with the date it was really played.
 */
object PlayLog {
    @Serializable
    data class Entry(val itemId: String, val atMs: Long, val seconds: Double, val duration: Double)

    private const val PREFS = "dial.playlog"
    private const val KEY = "entries"
    private val lock = Any()
    @Volatile private var flushing = false

    /** A play counts when most of the song was heard (half of it, or at least 30 seconds); skips do not. */
    fun counts(seconds: Double, duration: Double) = seconds >= 30 || (duration > 0 && seconds / duration >= 0.5)

    private fun load(context: Context): List<Entry> {
        val text = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null) ?: return emptyList()
        return runCatching { JellyfinJson.decodeFromString(ListSerializer(Entry.serializer()), text) }.getOrDefault(emptyList())
    }

    private fun save(context: Context, entries: List<Entry>) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY, JellyfinJson.encodeToString(ListSerializer(Entry.serializer()), entries)).apply()
    }

    fun pending(context: Context): Int = synchronized(lock) { load(context).size }

    fun record(context: Context, itemId: String, atMs: Long, seconds: Double, duration: Double) {
        if (!counts(seconds, duration)) return
        synchronized(lock) { save(context, load(context) + Entry(itemId, atMs, seconds, duration)) }
    }

    /** Tells the server about every saved play, oldest first; what could not be sent stays for next time. */
    suspend fun flush(context: Context, client: JellyfinClient) {
        if (flushing) return
        flushing = true
        try {
            for (entry in synchronized(lock) { load(context) }.sortedBy { it.atMs }) {
                val sent = runCatching { client.markPlayed(entry.itemId, entry.atMs) }
                // The server is gone again (stop and retry later), or the song no longer exists (drop it).
                if (sent.isFailure && sent.exceptionOrNull() !is JellyfinException) break
                synchronized(lock) { save(context, load(context).filter { it != entry }) }
            }
        } finally { flushing = false }
    }
}
