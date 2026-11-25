package app.dial.playback

import android.content.ComponentName
import android.content.Context
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import app.dial.data.Item
import app.dial.data.ArtistNames
import app.dial.data.RemoteControl
import app.dial.data.Session
import app.dial.data.Station
import app.dial.data.youtubeId
import com.google.common.util.concurrent.MoreExecutors
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import app.dial.data.JellyfinClient
import app.dial.data.JellyfinJson
import app.dial.playback.MediaItems
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.serialization.builtins.ListSerializer

/** Everything the screens need to show about playback, here or on another device. */
data class PlaybackState(
    val current: Item? = null,
    val queue: List<Item> = emptyList(),
    val index: Int = 0,
    val isPlaying: Boolean = false,
    val isBuffering: Boolean = false,
    val positionMs: Long = 0,
    val durationMs: Long = 0,
    val shuffle: Boolean = false,
    val repeat: Int = Player.REPEAT_MODE_OFF,
    val radio: Boolean = false,
    /** A live station playing (here, or on another Dial). */
    val station: Station? = null,
    /** Set while something is being prepared (a radio or mix loading). */
    val pendingTitle: String? = null,
    /** What the music was started from (a station, a mix, a mixtape), shown small in the mini player. */
    val source: String? = null,
    val error: String? = null,
    /** Playing on another device, controlled from here. */
    val outputId: String? = null,
    val outputName: String? = null,
    /** The other device's volume, 0 to 100. */
    val remoteVolume: Int? = null,
    /** When the sleep timer stops the music, or true while it waits for the song to end. */
    val sleepEndsAt: Long? = null,
    val sleepAtEndOfSong: Boolean = false,
) {
    val hasContent: Boolean get() = current != null || station != null || pendingTitle != null
    val upNext: List<Item> get() = queue.drop(index + 1)
    val isRemote: Boolean get() = outputId != null
    val isLive: Boolean get() = station != null
}

/**
 * The app's side of playback: talks to the background service through a Media3 controller, adds radio that
 * keeps going, and sends everything to another device instead while this one is the remote.
 */
class PlayerController(private val context: Context, private val session: Session) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val _state = MutableStateFlow(PlaybackState())
    val state: StateFlow<PlaybackState> = _state

    /** Sends commands to the device playing, when it isn't this one. */
    var remote: RemoteControl? = null
    /** Songs you hid; never queued automatically. */
    var isHidden: (String) -> Boolean = { false }
    /** Offline, only downloaded songs can play. */
    var isOffline: () -> Boolean = { false }
    var isDownloaded: (String) -> Boolean = { false }

    private var controller: MediaController? = null
    private var pendingActions = mutableListOf<(MediaController) -> Unit>()
    private var ticker: Job? = null
    private var radioSeen = mutableSetOf<String>()
    /** Artist radio keeps coming back to these between similar songs. */
    private var radioPool = mutableListOf<Item>()
    private var likeToken = 0
    private var connecting = false
    /// The YouTube live stream playing through the embedded player (Lofi Girl), when there is one.
    private var youtube: Station? = null
    /// When playback last started on this device by choice, so the newest start across your devices wins.
    @Volatile var playStartedAt = 0L
        private set

    private fun withController(action: (MediaController) -> Unit) {
        controller?.let(action) ?: run {
            pendingActions.add(action)
            connect()
        }
    }

    private fun connect() {
        if (controller != null || connecting) return
        connecting = true
        val token = SessionToken(context, ComponentName(context, PlaybackService::class.java))
        val future = MediaController.Builder(context, token).buildAsync()
        future.addListener({
            connecting = false
            val built = runCatching { future.get() }.getOrNull() ?: return@addListener
            controller = built
            built.addListener(listener)
            refresh()
            pendingActions.forEach { it(built) }
            pendingActions.clear()
        }, MoreExecutors.directExecutor())
    }

    init { connect(); restoreLastSession() }

    // MARK: Picking up where you left off

    private val prefs = context.getSharedPreferences("dial.lastsession", Context.MODE_PRIVATE)
    private var lastSave = 0L

    /** What is playing, saved now and then (and when you pause or skip), so Dial opens with it after being closed. */
    private fun saveSession() {
        val c = controller ?: return
        val s = _state.value
        if (s.isRemote || youtube != null || s.station != null || s.current == null || s.queue.isEmpty()) return
        lastSave = System.currentTimeMillis()
        val start = maxOf(s.index - 20, 0)
        val window = s.queue.subList(start, minOf(start + 150, s.queue.size))
        prefs.edit()
            .putString("queue", JellyfinJson.encodeToString(ListSerializer(Item.serializer()), window))
            .putInt("index", s.index - start).putLong("position", c.currentPosition).apply()
    }

    /** Loads the last session without playing it: the player shows the song, paused at the same spot. */
    private fun restoreLastSession() {
        scope.launch {
            val client = session.client.filterNotNull().first()
            withController { c ->
                if (c.mediaItemCount > 0 || _state.value.isRemote || youtube != null) return@withController
                val text = prefs.getString("queue", null) ?: return@withController
                val items = runCatching { JellyfinJson.decodeFromString(ListSerializer(Item.serializer()), text) }.getOrNull() ?: return@withController
                val index = prefs.getInt("index", 0)
                if (index !in items.indices) return@withController
                c.setMediaItems(items.map { MediaItems.song(it, client) }, index, prefs.getLong("position", 0))
                c.prepare()
                c.pause()
            }
        }
    }

    /** Closes the player: stops, empties the queue and forgets the last session. Following another device only stops following it. */
    fun close() {
        if (_state.value.isRemote) remote?.stopFollowing() else stop()
        prefs.edit().clear().apply()
    }

    private val listener = object : Player.Listener {
        override fun onEvents(player: Player, events: Player.Events) {
            refresh()
            if (events.containsAny(Player.EVENT_MEDIA_ITEM_TRANSITION, Player.EVENT_PLAY_WHEN_READY_CHANGED, Player.EVENT_IS_PLAYING_CHANGED)) saveSession()
            if (events.contains(Player.EVENT_MEDIA_ITEM_TRANSITION)) {
                if (_state.value.sleepAtEndOfSong) { player.pause(); cancelSleepTimer() } else extendRadioIfNeeded()
            }
        }
    }

    private var sleepJob: Job? = null

    /** Stops the music after a number of minutes. */
    fun setSleepTimer(minutes: Int) {
        sleepJob?.cancel()
        val end = System.currentTimeMillis() + minutes * 60_000L
        _state.update { it.copy(sleepEndsAt = end, sleepAtEndOfSong = false) }
        sleepJob = scope.launch {
            delay(minutes * 60_000L)
            pauseNow()
            cancelSleepTimer()
        }
    }

    /** Stops the music when the song that is playing ends. */
    fun sleepAtEndOfSong() {
        sleepJob?.cancel()
        _state.update { it.copy(sleepEndsAt = null, sleepAtEndOfSong = true) }
    }

    fun cancelSleepTimer() {
        sleepJob?.cancel()
        sleepJob = null
        _state.update { it.copy(sleepEndsAt = null, sleepAtEndOfSong = false) }
    }

    private fun pauseNow() {
        if (_state.value.isRemote) remote?.playstate("Pause") else withController { it.pause() }
        youtube?.let { stopYouTube() }
    }

    private fun refresh() {
        val c = controller ?: return
        if (_state.value.isRemote || youtube != null) return // showing the other device, or a YouTube stream, instead
        val items = (0 until c.mediaItemCount).map { c.getMediaItemAt(it) }
        val station = MediaItems.station(c.currentMediaItem)
        _state.update {
            it.copy(
                current = if (station != null) null else MediaItems.item(c.currentMediaItem),
                queue = items.mapNotNull(MediaItems::item),
                index = c.currentMediaItemIndex,
                station = station,
                isPlaying = c.isPlaying,
                isBuffering = c.playbackState == Player.STATE_BUFFERING,
                positionMs = c.currentPosition,
                durationMs = if (station != null) 0 else c.duration.takeIf { d -> d > 0 } ?: (MediaItems.item(c.currentMediaItem)?.durationMs ?: 0),
                shuffle = c.shuffleModeEnabled,
                repeat = c.repeatMode,
                pendingTitle = if (c.currentMediaItem != null) null else it.pendingTitle,
            )
        }
        startTicker(c.isPlaying && station == null) { c.currentPosition }
        if (station != null) remote?.stationChanged()
    }

    private fun startTicker(running: Boolean, position: () -> Long) {
        ticker?.cancel()
        if (running) ticker = scope.launch {
            while (isActive) {
                delay(500)
                _state.update { s -> s.copy(positionMs = position()) }
                if (System.currentTimeMillis() - lastSave > 15_000) saveSession()
            }
        }
    }

    // MARK: Playing

    private var pendingSource: String? = null

    fun play(all: List<Item>, start: Int = 0, shuffle: Boolean = false, radio: Boolean = false, startAtMs: Long = 0, source: String? = null) {
        val client = session.client.value ?: return
        // Leave out hidden songs (except the one you tapped) and, offline, songs that aren't downloaded.
        val picked = all.getOrNull(start)
        var items = all.filter { it === picked || !isHidden(it.id) }
        if (isOffline()) items = items.filter { isDownloaded(it.id) }
        if (items.isEmpty()) {
            if (isOffline()) _state.update { it.copy(error = "You\u2019re offline, and none of these songs are downloaded.") }
            return
        }
        val startIndex = picked?.let { p -> items.indexOfFirst { it === p } }?.takeIf { it >= 0 } ?: 0
        radioSeen = items.map { it.id }.toMutableSet()
        radioPool.clear()
        stopYouTube()
        playStartedAt = System.currentTimeMillis()
        remote?.takeOverIfFollowing()
        val named = source ?: pendingSource
        pendingSource = null
        _state.update { it.copy(radio = radio, error = null, pendingTitle = null, source = named) }
        if (_state.value.isRemote) {
            val ordered = if (shuffle) items.shuffled() else items
            val index = if (shuffle) 0 else startIndex
            _state.update { it.copy(queue = ordered, index = index, current = ordered[index], station = null, isPlaying = true, positionMs = startAtMs,
                durationMs = ordered[index].durationMs, shuffle = shuffle) }
            remote?.play(ordered, index, startAtMs)
            return
        }
        withController { c ->
            c.shuffleModeEnabled = shuffle
            c.setMediaItems(items.map { MediaItems.song(it, client) }, if (shuffle) 0 else startIndex, startAtMs)
            c.prepare()
            c.play()
        }
    }

    /** Shows the player right away, then plays once the songs have loaded. */
    fun play(title: String, shuffle: Boolean = false, radio: Boolean = false, load: suspend (JellyfinClient) -> List<Item>) {
        val client = session.client.value ?: return
        _state.update { it.copy(pendingTitle = title, error = null) }
        pendingSource = if (radio && !title.contains("radio", ignoreCase = true)) "$title \u00B7 Radio" else title
        scope.launch {
            val songs = runCatching { load(client) }.getOrElse {
                _state.update { s -> s.copy(pendingTitle = null, error = "Couldn't play $title: ${it.message}") }
                return@launch
            }
            if (songs.isEmpty()) {
                _state.update { s -> s.copy(pendingTitle = null, error = "There's nothing to play in $title yet.") }
                return@launch
            }
            play(songs, shuffle = shuffle, radio = radio)
        }
    }

    /**
     * A single song tapped outside an album: it plays first, then the songs AudioMuse finds closest to it,
     * in a random order that still tends to put the closest first. Radio stays on, and the source is kept.
     */
    fun playLike(track: Item, source: String? = null) {
        val client = session.client.value ?: run { play(listOf(track), radio = true, source = source); return }
        _state.update { it.copy(pendingTitle = track.name, error = null) }
        pendingSource = source
        val token = ++likeToken
        scope.launch {
            val closest = runCatching { client.instantMix(track.id, 40) }.getOrDefault(emptyList()).filter { it.id != track.id }
            if (token != likeToken) return@launch // something else was started meanwhile
            play(listOf(track) + closestFirstShuffled(closest), radio = true, source = source)
        }
    }

    /** A random order that tends to keep the closest songs first: each song gets a random key that grows with its rank. */
    private fun closestFirstShuffled(songs: List<Item>): List<Item> =
        songs.mapIndexed { rank, song -> song to (Math.random() * (rank + 6)) }.sortedBy { it.second }.map { it.first }

    /** A live radio station (it moves to another Dial when that's where the music is). */
    fun playStation(station: Station) {
        station.youtubeId?.let { startYouTube(station, it); return }
        stopYouTube()
        playStartedAt = System.currentTimeMillis()
        remote?.takeOverIfFollowing()
        if (_state.value.isRemote) {
            // Other Jellyfin apps can't play internet radio, so it plays here.
            useThisDeviceQuietly()
        }
        _state.update { it.copy(radio = false, error = null, pendingTitle = null, source = null) }
        withController { c ->
            c.shuffleModeEnabled = false
            c.setMediaItem(MediaItems.station(station))
            c.prepare()
            c.play()
        }
    }

    /** Endless radio from a song, album, artist or playlist: similar songs keep coming. */
    fun startRadio(seed: Item) {
        when (seed.type) {
            "MusicArtist" -> startArtistRadio(seed.id, ArtistNames.primary(seed.name))
            null, "Audio" -> play("${seed.name} Radio", radio = true) { client ->
                listOf(seed) + client.instantMix(seed.id, 40).filter { it.id != seed.id }
            }
            else -> play("${seed.name} Radio", radio = true) { client -> client.instantMix(seed.id, 40) }
        }
    }

    /** Artist radio opens with two of their songs and keeps coming back to them between similar songs. */
    private fun startArtistRadio(id: String, name: String) {
        val client = session.client.value ?: return
        _state.update { it.copy(pendingTitle = "$name Radio", error = null) }
        pendingSource = "$name Radio"
        scope.launch {
            val own = runCatching { client.artistSongs(id, 30) }.getOrDefault(emptyList()).shuffled()
            if (_state.value.pendingTitle != "$name Radio") return@launch // something else was started meanwhile
            if (own.isEmpty()) {
                val mix = runCatching { client.instantMix(id, 40) }.getOrDefault(emptyList())
                if (mix.isEmpty()) {
                    _state.update { s -> s.copy(pendingTitle = null, error = "There aren't enough songs yet to make a radio from $name.") }
                    return@launch
                }
                play(mix, radio = true)
                return@launch
            }
            play(own.take(2), radio = true)
            radioPool = own.drop(2).toMutableList()
        }
    }

    private fun extendRadioIfNeeded() {
        val s = _state.value
        val client = session.client.value ?: return
        val now = s.current ?: return
        if (!s.radio || s.upNext.size > 3 || isOffline()) return
        scope.launch {
            val queue = _state.value.queue
            val index = _state.value.index
            val existing = queue.map { it.id }.toHashSet()
            val heardCutoff = System.currentTimeMillis() - 3 * 86_400_000L
            // Half the time the radio grows from a song heard a moment ago, so it wanders instead of always
            // returning to the same neighbours of the song playing now.
            val seed = if (Math.random() < 0.5) queue.subList(0, (index + 1).coerceAtMost(queue.size)).takeLast(8).randomOrNull() ?: now else now
            var fresh = runCatching { client.instantMix(seed.id, 80) }.getOrDefault(emptyList())
                .filter { it.id !in existing && !heardLately(it, heardCutoff) }
            if (fresh.isEmpty()) {
                // Small library: everything similar has played, so fall back to
                // random songs and allow repeats of anything not played recently.
                val recent = queue.takeLast(5).map { it.id }.toSet()
                fresh = runCatching { client.randomSongs(20) }.getOrDefault(emptyList()).filter { it.id !in recent }
            }
            if (!_state.value.radio) return@launch // radio was switched off while loading
            // Any of the closest 40, in random order: the same top neighbours no longer come back in the same order.
            val batch = fresh.filter { !isHidden(it.id) }.take(40).shuffled().take(if (radioPool.isEmpty()) 10 else 4).toMutableList()
            // Artist radio: put two of its own songs back into every batch.
            val own = radioPool.filter { it.id !in existing }.take(2)
            radioPool.removeAll { o -> own.any { it.id == o.id } }
            own.forEachIndexed { offset, song -> batch.add(minOf(offset * 3, batch.size), song) }
            radioSeen.addAll(batch.map { it.id })
            if (batch.isNotEmpty()) addToQueue(batch)
        }
    }

    /** Whether the song played in the last few days (it rests, so the radio doesn't repeat it). */
    private fun heardLately(song: Item, cutoffMs: Long): Boolean {
        val text = song.userData?.lastPlayedDate ?: return false
        val ms = runCatching { java.time.Instant.parse(text).toEpochMilli() }.getOrElse {
            runCatching { java.time.OffsetDateTime.parse(text).toInstant().toEpochMilli() }.getOrDefault(0L)
        }
        return ms > cutoffMs
    }

    /** A live stream that plays in YouTube's embedded player. */
    private fun startYouTube(station: Station, id: String) {
        playStartedAt = System.currentTimeMillis()
        if (_state.value.isRemote) useThisDeviceQuietly()
        withController { it.pause(); it.clearMediaItems() }
        youtube = station
        ticker?.cancel()
        _state.update { PlaybackState(station = station, isPlaying = true, isBuffering = true) }
        YouTubeEmbed.onState = { playing, buffering ->
            if (youtube?.id == station.id) _state.update { it.copy(isPlaying = playing, isBuffering = buffering) }
        }
        YouTubeEmbed.onError = { code ->
            if (youtube?.id == station.id) _state.update { it.copy(isPlaying = false, isBuffering = false, error = "YouTube wouldn\u2019t play this stream (error $code).") }
        }
        YouTubeEmbed.load(context, id)
        remote?.stationChanged()
    }

    private fun stopYouTube() {
        if (youtube == null) return
        youtube = null
        YouTubeEmbed.stop()
    }

    fun togglePlayPause() {
        if (youtube != null) {
            if (_state.value.isPlaying) YouTubeEmbed.pause() else YouTubeEmbed.play()
            _state.update { it.copy(isPlaying = !it.isPlaying) }
            remote?.stationChanged()
            return
        }
        if (_state.value.isRemote) {
            // The device we follow was turned off or closed: nothing would happen there, so play it here, from the same spot.
            if (remote?.targetLooksGone == true) { remote?.selectThisDevice(); return }
            val playing = !_state.value.isPlaying
            _state.update { it.copy(isPlaying = playing) }
            remote?.playstate(if (playing) "Unpause" else "Pause")
            startRemoteTicker()
            return
        }
        withController { if (it.isPlaying) it.pause() else it.play() }
    }

    /// Pauses what plays here (a song, a station or a YouTube stream), as when another device takes over.
    fun pause() {
        if (youtube != null) { YouTubeEmbed.pause(); _state.update { it.copy(isPlaying = false) }; return }
        withController { it.pause() }
    }

    /// Shows the live station playing on the device this one follows (this device is already the remote).
    fun showRemoteStation(station: Station, playing: Boolean) {
        if (!_state.value.isRemote) return
        _state.update { it.copy(station = station, current = null, queue = emptyList(), index = 0, isPlaying = playing,
            isBuffering = false, positionMs = 0, durationMs = 0, pendingTitle = null) }
    }

    fun next() { if (_state.value.isRemote) remote?.playstate("NextTrack") else withController { it.seekToNextMediaItem() } }

    fun previous() {
        if (_state.value.isRemote) { remote?.playstate("PreviousTrack"); return }
        withController { if (it.currentPosition > 3000) it.seekTo(0) else it.seekToPreviousMediaItem() }
    }

    fun seek(toMs: Long) {
        if (_state.value.isRemote) { _state.update { it.copy(positionMs = toMs) }; remote?.seek(toMs); return }
        withController { it.seekTo(toMs) }
    }

    fun jump(index: Int) {
        val s = _state.value
        if (s.isRemote) { if (index in s.queue.indices) remote?.play(s.queue, index); return }
        withController { it.seekTo(index, 0) }
    }

    fun toggleShuffle() = setShuffle(!_state.value.shuffle)

    fun setShuffle(on: Boolean) {
        if (_state.value.isRemote) { _state.update { it.copy(shuffle = on) }; remote?.setShuffle(on); return }
        withController { it.shuffleModeEnabled = on }
    }

    fun toggleRadio() { _state.update { it.copy(radio = !it.radio) }; extendRadioIfNeeded() }

    fun cycleRepeat() {
        val next = when (_state.value.repeat) {
            Player.REPEAT_MODE_OFF -> Player.REPEAT_MODE_ALL
            Player.REPEAT_MODE_ALL -> Player.REPEAT_MODE_ONE
            else -> Player.REPEAT_MODE_OFF
        }
        setRepeatMode(next)
    }

    /** "RepeatNone", "RepeatAll" or "RepeatOne", as Jellyfin names them. */
    fun setRepeat(mode: String) = setRepeatMode(when (mode) {
        "RepeatAll" -> Player.REPEAT_MODE_ALL
        "RepeatOne" -> Player.REPEAT_MODE_ONE
        else -> Player.REPEAT_MODE_OFF
    })

    private fun setRepeatMode(mode: Int) {
        if (_state.value.isRemote) {
            _state.update { it.copy(repeat = mode) }
            remote?.setRepeat(when (mode) { Player.REPEAT_MODE_ALL -> "RepeatAll"; Player.REPEAT_MODE_ONE -> "RepeatOne"; else -> "RepeatNone" })
            return
        }
        withController { it.repeatMode = mode }
    }

    fun playNext(items: List<Item>) {
        val client = session.client.value ?: return
        if (_state.value.isRemote) {
            remote?.enqueue(items, next = true)
            _state.update { s -> s.copy(queue = s.queue.take(s.index + 1) + items + s.queue.drop(s.index + 1)) }
            return
        }
        withController { c ->
            if (c.mediaItemCount == 0) play(items) else c.addMediaItems(c.currentMediaItemIndex + 1, items.map { MediaItems.song(it, client) })
        }
    }

    fun addToQueue(items: List<Item>) {
        val client = session.client.value ?: return
        if (_state.value.isRemote) {
            remote?.enqueue(items, next = false)
            _state.update { s -> s.copy(queue = s.queue + items) }
            return
        }
        withController { c ->
            if (c.mediaItemCount == 0) play(items) else c.addMediaItems(items.map { MediaItems.song(it, client) })
        }
    }

    fun removeFromQueue(index: Int) {
        if (_state.value.isRemote) return // other apps don't support removing from their queue
        withController { it.removeMediaItem(index) }
    }

    fun setRemoteVolume(level: Int) {
        _state.update { it.copy(remoteVolume = level) }
        remote?.setVolume(level)
    }

    fun clearError() = _state.update { it.copy(error = null) }

    fun stop() {
        stopYouTube()
        if (_state.value.isRemote) remote?.playstate("Stop")
        useThisDeviceQuietly()
        withController { it.stop(); it.clearMediaItems() }
    }

    // MARK: Playing on another device

    /** This device becomes the remote for another one. Local playback stops. */
    fun useRemote(id: String, name: String) {
        stopYouTube()
        if (!_state.value.isRemote) withController { it.pause(); it.clearMediaItems() }
        ticker?.cancel()
        _state.update { it.copy(outputId = id, outputName = name, station = it.station) }
    }

    fun useThisDevice() {
        ticker?.cancel()
        _state.update { PlaybackState() }
        refresh()
    }

    private fun useThisDeviceQuietly() {
        if (!_state.value.isRemote) return
        _state.value.outputId?.let { remote?.playstate("Stop") }
        useThisDevice()
    }

    /** The other device's latest state, from the server. */
    fun applyRemote(queue: List<Item>, index: Int, positionMs: Long, durationMs: Long, playing: Boolean,
                    volume: Int?, repeat: String?, shuffled: Boolean?) {
        if (!_state.value.isRemote || index !in queue.indices) return
        _state.update {
            it.copy(queue = queue, index = index, current = queue[index], station = null, positionMs = positionMs,
                durationMs = durationMs, isPlaying = playing, remoteVolume = volume ?: it.remoteVolume,
                repeat = when (repeat) { "RepeatAll" -> Player.REPEAT_MODE_ALL; "RepeatOne" -> Player.REPEAT_MODE_ONE; null -> it.repeat; else -> Player.REPEAT_MODE_OFF },
                shuffle = shuffled ?: it.shuffle, pendingTitle = null)
        }
        startRemoteTicker()
        extendRadioIfNeeded()
    }

    /** Moves the progress bar along between updates from the other device. */
    private fun startRemoteTicker() {
        ticker?.cancel()
        if (!_state.value.isPlaying) return
        ticker = scope.launch {
            while (isActive) {
                delay(500)
                _state.update { s -> if (!s.isRemote || !s.isPlaying) s else s.copy(positionMs = (s.positionMs + 500).coerceAtMost(maxOf(s.durationMs, s.positionMs))) }
            }
        }
    }
}
