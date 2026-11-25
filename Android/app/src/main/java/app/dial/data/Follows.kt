package app.dial.data

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId

/** An album you asked to be told about on its release day (the bell). */
@Serializable
data class FollowedRelease(val id: String, val title: String, val artist: String, val artistMbid: String? = null, val date: String)

/** An artist you follow: any new release of theirs is announced. */
@Serializable
data class FollowedArtist(val id: String, val name: String)

/**
 * The bells and followed artists behind Discovery, and the notifications that go with them (the same as on iPhone and Mac).
 * Notifications are local: each is an alarm for nine in the morning on release day, renewed whenever Discovery refreshes and
 * after the phone restarts.
 */
object Follows {
    private lateinit var context: Context
    private lateinit var prefs: SharedPreferences
    private val _releases = MutableStateFlow<List<FollowedRelease>>(emptyList())
    private val _artists = MutableStateFlow<List<FollowedArtist>>(emptyList())
    val releases: StateFlow<List<FollowedRelease>> = _releases
    val artists: StateFlow<List<FollowedArtist>> = _artists
    private const val CHANNEL = "releases"

    fun init(app: Context) {
        context = app.applicationContext
        prefs = context.getSharedPreferences("dial.follows", Context.MODE_PRIVATE)
        _releases.value = runCatching { JellyfinJson.decodeFromString(ListSerializer(FollowedRelease.serializer()), prefs.getString("releases", "[]")!!) }.getOrDefault(emptyList())
        _artists.value = runCatching { JellyfinJson.decodeFromString(ListSerializer(FollowedArtist.serializer()), prefs.getString("artists", "[]")!!) }.getOrDefault(emptyList())
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "New releases", NotificationManager.IMPORTANCE_DEFAULT))
    }

    private fun save() {
        prefs.edit()
            .putString("releases", JellyfinJson.encodeToString(ListSerializer(FollowedRelease.serializer()), _releases.value))
            .putString("artists", JellyfinJson.encodeToString(ListSerializer(FollowedArtist.serializer()), _artists.value))
            .apply()
    }

    fun isBelled(id: String) = _releases.value.any { it.id == id }
    fun isFollowing(artistMbid: String?) = artistMbid != null && _artists.value.any { it.id == artistMbid }

    fun toggleBell(pick: PublicMusic.Pick) {
        if (isBelled(pick.mbid)) {
            _releases.value = _releases.value.filterNot { it.id == pick.mbid }
            cancel("rel-${pick.mbid}")
        } else {
            val date = pick.releaseDate?.takeIf { it.length >= 10 }?.take(10) ?: return
            val release = FollowedRelease(pick.mbid, pick.title, pick.artist ?: "", pick.artistMbid, date)
            _releases.value = _releases.value + release
            schedule("rel-${release.id}", release.artist, release.title, release.date)
        }
        save()
    }

    fun toggleFollow(artistMbid: String?, name: String) {
        if (artistMbid == null) return
        _artists.value = if (isFollowing(artistMbid)) _artists.value.filterNot { it.id == artistMbid } else _artists.value + FollowedArtist(artistMbid, name)
        save()
    }

    fun removeRelease(id: String) { _releases.value = _releases.value.filterNot { it.id == id }; cancel("rel-$id"); save() }
    fun removeArtist(id: String) { _artists.value = _artists.value.filterNot { it.id == id }; save() }

    // MARK: Notifications

    private fun requestCode(key: String) = key.hashCode()

    private fun intentFor(key: String, artist: String, title: String, immediate: Boolean = false) =
        Intent(context, ReleaseAlarmReceiver::class.java).putExtra("key", key).putExtra("artist", artist).putExtra("title", title)
            .putExtra("immediate", immediate).setAction("app.dial.RELEASE.$key")

    private fun pending(key: String, artist: String, title: String): PendingIntent =
        PendingIntent.getBroadcast(context, requestCode(key), intentFor(key, artist, title), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    /** An alarm for nine in the morning on the day it comes out. */
    private fun schedule(key: String, artist: String, title: String, date: String) {
        val day = runCatching { LocalDate.parse(date.take(10)) }.getOrNull() ?: return
        val at = day.atTime(LocalTime.of(9, 0)).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
        if (at < System.currentTimeMillis() + 60_000) return
        val alarms = context.getSystemService(AlarmManager::class.java)
        alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending(key, artist, title))
    }

    private fun cancel(key: String) {
        context.getSystemService(AlarmManager::class.java).cancel(pending(key, "", ""))
    }

    /** After a restart, or whenever the dates may have moved. */
    fun rescheduleAll() { _releases.value.forEach { schedule("rel-${it.id}", it.artist, it.title, it.date) } }

    internal fun post(key: String, artist: String, title: String, today: Boolean) {
        val open = PendingIntent.getActivity(context, requestCode("open-$key"),
            context.packageManager.getLaunchIntentForPackage(context.packageName), PendingIntent.FLAG_IMMUTABLE)
        val notification = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_notify_more)
            .setContentTitle(if (artist.isEmpty()) "Out today" else "New from $artist")
            .setContentText(if (today) "$title is out today." else "$title is out.")
            .setContentIntent(open).setAutoCancel(true).build()
        runCatching { context.getSystemService(NotificationManager::class.java).notify(requestCode(key), notification) }
    }

    private val announced: MutableSet<String> get() = prefs.getStringSet("announced", emptySet())!!.toMutableSet()

    /**
     * Called after Discovery refreshes: keeps every alarm in step with the newest release dates (they move), schedules the
     * upcoming releases of followed artists, and announces a followed artist's release that came out in the last two days.
     * Followed artists the feed does not cover (outside your top artists) are looked up here.
     */
    suspend fun reconcile(feed: DiscoveryFeed) {
        if (_releases.value.isEmpty() && _artists.value.isEmpty()) return
        val followed = _artists.value.map { it.id }.toSet()
        // The feed covers your top artists; anyone else you follow is looked up on their own (saved for three days).
        val covered = feed.artists.map { it.mbid }.toSet()
        val extraUpcoming = mutableListOf<PublicMusic.Pick>()
        val extraFresh = mutableListOf<PublicMusic.Pick>()
        for (artist in _artists.value.filter { it.id !in covered }) {
            for (release in PublicMusic.discography(artist.id, 3L * 24 * 3600 * 1000)) {
                val date = release.date?.takeIf { it.length >= 10 } ?: continue
                val days = runCatching { java.time.temporal.ChronoUnit.DAYS.between(LocalDate.now(), LocalDate.parse(date.take(10))) }.getOrNull() ?: continue
                if (release.kind !in listOf("album", "ep", "single")) continue
                val pick = PublicMusic.Pick("album", release.id, release.title, artist.name, artist.id, release.year, releaseDate = date)
                if (days in 0..200) extraUpcoming += pick else if (days in -2..-1) extraFresh += pick
            }
        }
        val upcoming = feed.upcoming + extraUpcoming
        val fresh = feed.fresh + extraFresh
        val dates = (upcoming + fresh).mapNotNull { p -> p.releaseDate?.takeIf { it.length >= 10 }?.let { p.mbid to it.take(10) } }.toMap()
        _releases.value = _releases.value.map { r -> dates[r.id]?.takeIf { it != r.date }?.let { r.copy(date = it) } ?: r }
        for (r in _releases.value) schedule("rel-${r.id}", r.artist, r.title, r.date)
        for (p in upcoming) if (p.artistMbid in followed) schedule("rel-${p.mbid}", p.artist ?: "", p.title, p.releaseDate ?: "")
        val seen = announced
        for (p in fresh) {
            if (p.artistMbid !in followed || p.mbid in seen) continue
            val days = runCatching { java.time.temporal.ChronoUnit.DAYS.between(LocalDate.parse(p.releaseDate!!.take(10)), LocalDate.now()) }.getOrNull() ?: continue
            if (days !in 0..2) continue
            seen += p.mbid
            post("new-${p.mbid}", p.artist ?: "", p.title, today = false)
        }
        prefs.edit().putStringSet("announced", seen.toList().takeLast(300).toSet()).apply()
        save()
    }
}

/** Fires at nine on release day (and after a restart, puts the alarms back). */
class ReleaseAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Follows.init(context)
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) { Follows.rescheduleAll(); return }
        Follows.post(intent.getStringExtra("key") ?: return, intent.getStringExtra("artist") ?: "", intent.getStringExtra("title") ?: "", today = true)
    }
}
