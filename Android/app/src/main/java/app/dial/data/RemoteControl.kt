package app.dial.data

import android.widget.Toast
import app.dial.playback.AudioLevels
import app.dial.playback.PlayerController
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener

/**
 * One listening session across your devices, like Spotify Connect (and the same as Dial on iPhone and Mac):
 * pick where the music plays, it continues there from the same spot, and this device becomes the remote.
 * Your Dial apps notice each other: open Dial while another of your Dials plays and this one shows it;
 * start music somewhere else and the newest playback wins. Live radio moves between Dials too, and a
 * Marlo session running on your iPhone or Mac shows here (Marlo itself doesn't run on Android yet).
 */
class RemoteControl(
    private val context: android.content.Context,
    private val session: Session,
    private val player: PlayerController,
    private val library: Library,
) {
    data class Device(
        val id: String, val deviceId: String, val name: String, val app: String, val controllable: Boolean,
        val nowPlaying: Item?, val paused: Boolean, val userId: String?,
        /** When the device last reported where it is in the song. A playing device does this every few seconds. */
        val lastCheckInMs: Long? = null,
    ) {
        val isDial get() = app == JellyfinClient.CLIENT_NAME
        /** A device whose last report is old is not playing, whatever the server still lists (app closed or reinstalled mid-song, or it only follows another). */
        val isStale get() = lastCheckInMs?.let { System.currentTimeMillis() - it > 45_000 } ?: false
        val isPlaying get() = nowPlaying != null && !paused && !isStale
    }

    /** What the Marlo running on the device you follow is doing. */
    data class DJMirror(val onAir: Boolean, val caption: String?, val blockTitle: String?, val messages: List<Pair<Boolean, String>>)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val _devices = MutableStateFlow<List<Device>>(emptyList())
    val devices: StateFlow<List<Device>> = _devices
    private val _linked = MutableStateFlow(false)
    /** Whether the live connection is up (others can only see and control this device while it is). */
    val linked: StateFlow<Boolean> = _linked
    private val _dj = MutableStateFlow<DJMirror?>(null)
    val djMirror: StateFlow<DJMirror?> = _dj

    private var socket: WebSocket? = null
    private var connectJob: Job? = null
    private var pollJob: Job? = null
    private var targetDeviceId: String? = null
    private var lastSeen = 0L
    private var lastSessions = 0L
    private var followingAutomatically = false
    private var pausedUntil = 0L
    private var lastPlaying: Map<String, String> = emptyMap()
    private var hasBaseline = false
    private val songs = mutableMapOf<String, Item>()

    val receivers: List<Device> get() = _devices.value.filter { it.controllable }
    private val targetId: String? get() = player.state.value.outputId

    init {
        player.remote = this
        scope.launch { session.client.collect { connect(it) } }
        startQueueSharing()
    }

    // MARK: Sharing the queue

    /** The queue of the Dial being followed, as it last told us. */
    private var sharedQueueIds: List<String> = emptyList()
    private var lastSharedQueue = ""
    private var lastQueueShare = 0L

    /** While this device plays, tell your other Dials what's coming up, so they can show the same queue. */
    private var queueShareJob: Job? = null
    /** While the app is in the background, the periodic sharing and polling loops are paused (the socket stays open). */
    private var inBackground = false
    private var pollingPausedForBackground = false
    private fun startQueueSharing() {
        queueShareJob?.cancel()
        if (inBackground) return
        queueShareJob = scope.launch {
            while (isActive) {
                delay(4_000)
                shareQueue()
                shareStation()
            }
        }
    }

    private var lastStationShare = ""
    private var lastStationShareAt = 0L

    /** A station started, paused or changed here: your other Dials hear of it now, not at the next tick. */
    fun stationChanged() { scope.launch { shareStation(force = true) } }

    /**
     * A live station playing here is told to your other Dials too (the same as the iPhone and Mac do), so an idle one shows it.
     * Sent on change ([force]), and otherwise every 30 seconds, so a Dial that opens later still catches up.
     */
    private suspend fun shareStation(force: Boolean = false) {
        val state = player.state.value
        val station = state.station ?: return
        if (state.isRemote) return
        val signature = "${station.id}:${state.isPlaying}"
        val now = System.currentTimeMillis()
        if (!force && signature == lastStationShare && now - lastStationShareAt < 30_000) return
        lastStationShare = signature
        lastStationShareAt = now
        for (device in _devices.value.filter { it.isDial }) {
            handoff(device.id, buildJsonObject {
                put("kind", "stationState")
                put("station", JellyfinJson.encodeToJsonElement(Station.serializer(), station))
                put("list", JsonArray(emptyList()))
                put("playing", state.isPlaying)
                put("startedAt", player.playStartedAt / 1000.0)
                put("from", JellyfinClient.deviceId)
            })
        }
    }

    private suspend fun shareQueue(force: Boolean = false) {
        val state = player.state.value
        if (state.isRemote || state.queue.size <= 1 || state.current == null) return
        val start = (state.index - 20).coerceAtLeast(0)
        val ids = state.queue.subList(start, minOf(start + 100, state.queue.size)).map { it.id }
        val signature = ids.joinToString(",")
        val now = System.currentTimeMillis()
        if (!force && signature == lastSharedQueue && now - lastQueueShare < 30_000) return
        lastSharedQueue = signature
        lastQueueShare = now
        for (device in _devices.value.filter { it.isDial }) {
            handoff(device.id, buildJsonObject {
                put("kind", "queue"); put("ids", JsonArray(ids.map { JsonPrimitive(it) })); put("from", JellyfinClient.deviceId)
            })
        }
    }

    // MARK: Choosing where to play

    fun select(device: Device) = scope.launch {
        val state = player.state.value
        if (state.outputId == device.id) return@launch
        followingAutomatically = false
        val previous = state.outputId
        val queue = state.queue
        val index = state.index
        val position = state.positionMs
        val station = state.station
        player.useRemote(device.id, device.name)
        targetDeviceId = device.deviceId
        lastSeen = System.currentTimeMillis()
        startPolling()
        when {
            device.isDial && station != null -> handoff(device.id, buildJsonObject {
                put("kind", "station")
                put("station", JellyfinJson.encodeToJsonElement(Station.serializer(), station))
                put("list", JsonArray(emptyList()))
            })
            queue.isNotEmpty() && station == null -> {
                sendQueue(device.id, queue, index, position)
                previous?.let { post("Sessions/$it/Playing/Stop") }
            }
            else -> device.nowPlaying?.let { player.applyRemote(listOf(it), 0, 0, it.durationMs, !device.paused, null, null, null) }
        }
        if (device.isDial) {
            command(device.id, "shareState")
            handoff(device.id, buildJsonObject { put("kind", "queueRequest") })
        }
        refresh()
    }

    /** Stops following the other device without touching it (the player was closed here). */
    fun stopFollowing() {
        followingAutomatically = false
        pausedUntil = System.currentTimeMillis() + 120_000
        stopPolling()
        targetDeviceId = null
        _dj.value = null
        player.useThisDevice()
    }

    /** Whether the device this one follows has gone: it is not listed, or it claims to play but has stopped reporting. */
    val targetLooksGone: Boolean
        get() {
            val id = player.state.value.outputId ?: return false
            val device = _devices.value.firstOrNull { it.id == id || (targetDeviceId != null && it.deviceId == targetDeviceId) }
                ?: return lastSessions != 0L
            return device.nowPlaying != null && !device.paused && device.isStale
        }

    /** Brings the music back to this device, from the same spot. A Marlo session continues as plain songs here. */
    fun selectThisDevice() = scope.launch {
        val state = player.state.value
        val id = state.outputId ?: return@launch
        followingAutomatically = false
        pausedUntil = System.currentTimeMillis() + 30_000
        val other = _devices.value.firstOrNull { it.id == id }
        var queue = state.queue
        var index = state.index
        // Following another device, its queue may not have arrived: its current song is still known.
        if (index !in queue.indices) (state.current ?: other?.nowPlaying)?.let { queue = listOf(it); index = 0 }
        val station = state.station
        val hadMarlo = _dj.value != null
        if (hadMarlo) command(id, "stopQuietly")
        stopPolling()
        targetDeviceId = null
        _dj.value = null
        player.useThisDevice()
        // Start here first, then silence the other device: waiting for the server before starting left this one idle.
        if (station != null) player.playStation(station)
        else if (index in queue.indices) player.play(queue, index, startAtMs = state.positionMs)
        post("Sessions/$id/Playing/Stop")
    }

    /**
     * You started something on this device while it was only following another one on its own (you never picked it): the newest
     * start wins, so it plays here and the other device stops. Sending music to a device that may be gone or stale is how a start
     * could go nowhere, and how two devices ended up fighting over a song.
     */
    fun takeOverIfFollowing() {
        val id = player.state.value.outputId ?: return
        if (!followingAutomatically) return
        followingAutomatically = false
        pausedUntil = System.currentTimeMillis() + 30_000
        stopPolling()
        targetDeviceId = null
        _dj.value = null
        player.useThisDevice()
        scope.launch { post("Sessions/$id/Playing/Stop") }
    }

    // MARK: Commands for the device that's playing (used by the player)

    fun play(queue: List<Item>, index: Int, positionMs: Long = 0) { targetId?.let { scope.launch { sendQueue(it, queue, index, positionMs) } } }
    fun playstate(name: String) { targetId?.let { scope.launch { post("Sessions/$it/Playing/$name") } } }
    fun seek(ms: Long) { targetId?.let { scope.launch { post("Sessions/$it/Playing/Seek", mapOf("seekPositionTicks" to (ms * 10_000).toString())) } } }
    fun enqueue(items: List<Item>, next: Boolean) {
        val id = targetId ?: return
        items.forEach { songs[it.id] = it }
        scope.launch { post("Sessions/$id/Playing", mapOf("playCommand" to if (next) "PlayNext" else "PlayLast", "itemIds" to items.joinToString(",") { it.id })) }
    }
    fun setVolume(level: Int) = general("SetVolume", mapOf("Volume" to "$level"))
    fun setRepeat(mode: String) = general("SetRepeatMode", mapOf("RepeatMode" to mode))
    fun setShuffle(on: Boolean) = general("SetShuffleQueue", mapOf("ShuffleMode" to if (on) "Shuffle" else "Sorted"))


    private fun general(name: String, args: Map<String, String>) {
        val id = targetId ?: return
        val body = buildJsonObject {
            put("Name", name)
            put("Arguments", buildJsonObject { args.forEach { (k, v) -> put(k, v) } })
        }.toString()
        scope.launch { post("Sessions/$id/Command", json = body) }
    }

    private suspend fun sendQueue(sessionId: String, queue: List<Item>, index: Int, positionMs: Long) {
        if (index !in queue.indices) return
        val start = (index - 20).coerceAtLeast(0)
        val window = queue.subList(start, minOf(start + 100, queue.size))
        window.forEach { songs[it.id] = it }
        post("Sessions/$sessionId/Playing", mapOf(
            "playCommand" to "PlayNow", "itemIds" to window.joinToString(",") { it.id },
            "startIndex" to "${index - start}", "startPositionTicks" to "${positionMs * 10_000}"))
    }

    private suspend fun handoff(sessionId: String, payload: JsonObject) {
        val body = buildJsonObject { put("Header", "dial.handoff"); put("Text", payload.toString()); put("TimeoutMs", 1) }.toString()
        post("Sessions/$sessionId/Message", json = body)
    }

    private suspend fun command(sessionId: String, name: String) =
        handoff(sessionId, buildJsonObject { put("kind", "djCommand"); put("command", name) })

    private suspend fun post(path: String, query: Map<String, String> = emptyMap(), json: String? = null) {
        runCatching { session.client.value?.post(path, query, json) }
    }

    // MARK: Keeping up with the other devices

    fun refresh() = scope.launch {
        val client = session.client.value ?: return@launch
        val text = runCatching { client.get("Sessions", mapOf("activeWithinSeconds" to "960")) }.getOrNull() ?: return@launch
        runCatching { JellyfinJson.parseToJsonElement(text).jsonArray }.getOrNull()?.let { update(it) }
    }

    private suspend fun update(sessions: JsonArray) {
        lastSessions = System.currentTimeMillis()
        val client = session.client.value ?: return
        val parsed = sessions.mapNotNull { it as? JsonObject }
        val others = parsed.filter {
            it.str("DeviceId") != JellyfinClient.deviceId && (it.str("UserId") == null || it.str("UserId") == client.userId)
        }
        _devices.value = others.map { s ->
            val app = s.str("Client") ?: "Jellyfin"
            val media = (s["PlayableMediaTypes"] as? JsonArray)?.map { it.jsonPrimitive.content } ?: listOf("Audio")
            val nowPlaying = (s["NowPlayingItem"] as? JsonObject)?.let { runCatching { JellyfinJson.decodeFromJsonElement(Item.serializer(), it) }.getOrNull() }
            Device(
                id = s.str("Id") ?: "", deviceId = s.str("DeviceId") ?: (s.str("Id") ?: ""), name = s.str("DeviceName") ?: "Unknown device",
                app = app, controllable = app == JellyfinClient.CLIENT_NAME || ((s["SupportsRemoteControl"]?.jsonPrimitive?.booleanOrNull ?: false) && "Audio" in media),
                nowPlaying = nowPlaying?.takeIf { it.isSong },
                paused = (s["PlayState"] as? JsonObject)?.get("IsPaused")?.jsonPrimitive?.booleanOrNull ?: false,
                userId = s.str("UserId"),
                lastCheckInMs = s.str("LastPlaybackCheckIn")?.let { runCatching { java.time.Instant.parse(it).toEpochMilli() }.getOrNull() },
            )
        }
        autoFollow()
        follow(parsed)
    }

    /** Your Dial apps share one session: show what plays elsewhere, and let the newest playback win. */
    private fun autoFollow() {
        val client = session.client.value ?: return
        val mine = _devices.value.filter { it.isDial && (it.userId == null || it.userId == client.userId) }
        // The device that reported most recently first: that is the one actually making sound.
        val playing = mine.filter { it.isPlaying }.sortedByDescending { it.lastCheckInMs ?: 0L }
        val startedNow = playing.filter { it.deviceId !in lastPlaying }
        lastPlaying = playing.associate { it.deviceId to (it.nowPlaying?.id ?: "") }
        val baseline = hasBaseline
        hasBaseline = true
        // Just opened: ask the other Dials whether a station is playing (stations don't show in the server's list).
        if (!baseline) mine.forEach { d -> scope.launch { handoff(d.id, buildJsonObject { put("kind", "stationRequest") }) } }
        val state = player.state.value
        if (state.outputId != null || System.currentTimeMillis() < pausedUntil) return
        val busy = state.isPlaying || state.pendingTitle != null
        val device = when {
            !busy -> playing.firstOrNull()
            baseline -> startedNow.firstOrNull()
            else -> null
        } ?: return
        if (busy) player.togglePlayPause()
        followingAutomatically = true
        player.useRemote(device.id, device.name)
        targetDeviceId = device.deviceId
        lastSeen = System.currentTimeMillis()
        startPolling()
        scope.launch { command(device.id, "shareState"); handoff(device.id, buildJsonObject { put("kind", "queueRequest") }) }
    }

    /** Shows what the followed device is doing. */
    private suspend fun follow(sessions: List<JsonObject>) {
        val state = player.state.value
        val id = state.outputId ?: return
        val s = sessions.firstOrNull { it.str("Id") == id } ?: sessions.firstOrNull { targetDeviceId != null && it.str("DeviceId") == targetDeviceId }
        if (s == null) {
            if (System.currentTimeMillis() - lastSeen > 15_000) {
                stopPolling()
                targetDeviceId = null
                _dj.value = null
                player.useThisDevice()
                if (!followingAutomatically) Toast.makeText(context, "${state.outputName} is no longer available.", Toast.LENGTH_SHORT).show()
                followingAutomatically = false
            }
            return
        }
        // A device that says it is playing but has gone silent (turned off, app closed) is not there any more, and one that was only
        // followed automatically and has been quiet for minutes is not worth following: back to this device, without a message.
        val now = System.currentTimeMillis()
        fun age(key: String) = s.str(key)?.let { runCatching { java.time.Instant.parse(it).toEpochMilli() }.getOrNull() }?.let { now - it }
        val claimsPlaying = s["NowPlayingItem"] != null && !((s["PlayState"] as? JsonObject)?.get("IsPaused")?.jsonPrimitive?.booleanOrNull ?: false)
        val silent = claimsPlaying && (age("LastPlaybackCheckIn") ?: 0L) > 90_000
        val away = followingAutomatically && (age("LastActivityDate") ?: 0L) > 180_000
        if (silent || away) {
            stopPolling()
            targetDeviceId = null
            _dj.value = null
            player.useThisDevice()
            followingAutomatically = false
            pausedUntil = now + 60_000
            return
        }
        lastSeen = now
        if (s.str("Id") != id) player.useRemote(s.str("Id")!!, state.outputName ?: "")
        val playState = s["PlayState"] as? JsonObject
        val song = (s["NowPlayingItem"] as? JsonObject)?.let { runCatching { JellyfinJson.decodeFromJsonElement(Item.serializer(), it) }.getOrNull() }
        if (song == null || !song.isSong) {
            if (state.station != null) return // the other Dial plays the station we sent
            player.applyRemote(state.queue, state.index, state.positionMs, state.durationMs, false,
                playState?.get("VolumeLevel")?.jsonPrimitive?.intOrNull, null, null)
            return
        }
        songs[song.id] = song
        var ids = (s["NowPlayingQueue"] as? JsonArray)?.mapNotNull { (it as? JsonObject)?.str("Id")?.replace("-", "")?.lowercase() } ?: emptyList()
        // The server didn't pass the queue on: use the one the other Dial sent directly.
        if (ids.size <= 1 && song.id in sharedQueueIds) ids = sharedQueueIds
        val queue = when {
            ids.size > 1 -> resolve(ids)
            state.queue.any { it.id == song.id } -> state.queue
            else -> listOf(song)
        }.ifEmpty { listOf(song) }
        val index = queue.indexOfFirst { it.id == song.id }.coerceAtLeast(0)
        player.applyRemote(queue, index,
            (playState?.get("PositionTicks")?.jsonPrimitive?.longOrNull ?: 0) / 10_000, song.durationMs,
            !(playState?.get("IsPaused")?.jsonPrimitive?.booleanOrNull ?: false),
            playState?.get("VolumeLevel")?.jsonPrimitive?.intOrNull,
            playState?.get("RepeatMode")?.jsonPrimitive?.contentOrNull,
            playState?.get("ShuffleMode")?.jsonPrimitive?.contentOrNull?.let { it == "Shuffle" })
    }

    private suspend fun resolve(ids: List<String>): List<Item> {
        val missing = ids.filter { it !in songs }
        if (missing.isNotEmpty()) session.client.value?.let { c -> runCatching { c.items(missing) }.getOrNull()?.forEach { songs[it.id] = it } }
        return ids.mapNotNull { songs[it] }
    }

    private fun startPolling() {
        pollJob?.cancel()
        pollJob = scope.launch {
            while (isActive) {
                delay(3000)
                // Live updates come over the socket; if they stop, ask directly. While the socket is connected, the
                // check is much less frequent (a request every 3 seconds would keep the phone's radio awake).
                if (System.currentTimeMillis() - lastSessions > (if (_linked.value) 15_000 else 3000)) refresh()
            }
        }
    }

    private fun stopPolling() { pollJob?.cancel(); pollJob = null }

    /**
     * Called when the app leaves or returns to the foreground. In the background the 4-second sharing
     * and the 3-second poll stop; the socket stays open so other devices can still reach this one.
     */
    fun setInBackground(background: Boolean) {
        if (background == inBackground) return
        inBackground = background
        if (background) {
            queueShareJob?.cancel()
            pollingPausedForBackground = pollJob != null
            stopPolling()
        } else {
            startQueueSharing()
            if (pollingPausedForBackground) {
                pollingPausedForBackground = false
                startPolling()
                refresh()
            }
        }
    }

    // MARK: The live connection

    private fun connect(client: JellyfinClient?) {
        connectJob?.cancel()
        socket?.cancel()
        socket = null
        _linked.value = false
        client ?: return
        connectJob = scope.launch {
            var wait = 2000L
            while (isActive) {
                reportCapabilities(client)
                val opened = kotlinx.coroutines.CompletableDeferred<Boolean>()
                val closed = kotlinx.coroutines.CompletableDeferred<Unit>()
                val url = client.server.replaceFirst("http", "ws") + "/socket?ApiKey=${client.token}&api_key=${client.token}&deviceId=${JellyfinClient.deviceId}"
                val request = Request.Builder().url(url).header("Authorization", JellyfinClient.authHeader(client.token)).build()
                socket = JellyfinClient.http.newWebSocket(request, object : WebSocketListener() {
                    override fun onOpen(webSocket: WebSocket, response: Response) {
                        webSocket.send("""{"MessageType":"SessionsStart","Data":"0,1500"}""")
                        opened.complete(true)
                    }
                    override fun onMessage(webSocket: WebSocket, text: String) { scope.launch { handle(text) } }
                    override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) { opened.complete(false); closed.complete(Unit) }
                    override fun onClosed(webSocket: WebSocket, code: Int, reason: String) { closed.complete(Unit) }
                })
                if (opened.await()) {
                    _linked.value = true
                    reportCapabilities(client)
                    refresh()
                    wait = 2000L
                }
                closed.await()
                _linked.value = false
                delay(wait)
                wait = (wait * 2).coerceAtMost(60_000)
            }
        }
    }

    private suspend fun reportCapabilities(client: JellyfinClient) {
        val body = buildJsonObject {
            put("PlayableMediaTypes", JsonArray(listOf(JsonPrimitive("Audio"))))
            put("SupportedCommands", JsonArray(listOf("PlayState", "PlayNext", "PlayMediaSource", "SetShuffleQueue", "SetRepeatMode",
                "SetVolume", "VolumeUp", "VolumeDown", "Mute", "Unmute", "ToggleMute", "DisplayMessage").map { JsonPrimitive(it) }))
            put("SupportsMediaControl", true)
            put("SupportsPersistentIdentifier", true)
        }.toString()
        runCatching { client.post("Sessions/Capabilities/Full", json = body) }
    }

    private suspend fun handle(text: String) {
        val message = runCatching { JellyfinJson.parseToJsonElement(text).jsonObject }.getOrNull() ?: return
        val data = message["Data"]
        when (message.str("MessageType")) {
            "Sessions" -> (data as? JsonArray)?.let { update(it) }
            "ForceKeepAlive" -> keepAlive(((data as? JsonPrimitive)?.doubleOrNull ?: 60.0) / 2)
            "UserDataChanged" -> ((data as? JsonObject)?.get("UserDataList") as? JsonArray)?.forEach { change ->
                val c = change as? JsonObject ?: return@forEach
                val id = c.str("ItemId")?.replace("-", "")?.lowercase() ?: return@forEach
                c["IsFavorite"]?.jsonPrimitive?.booleanOrNull?.let { library.applyFavorite(id, it) }
            }
            "Play" -> (data as? JsonObject)?.let { playHere(it) }
            "Playstate" -> (data as? JsonObject)?.let { playstateHere(it.str("Command") ?: "", it["SeekPositionTicks"]?.jsonPrimitive?.longOrNull) }
            "GeneralCommand" -> (data as? JsonObject)?.let { general(it.str("Name") ?: "", it["Arguments"] as? JsonObject ?: JsonObject(emptyMap())) }
        }
    }

    private var keepAliveJob: Job? = null
    private fun keepAlive(seconds: Double) {
        keepAliveJob?.cancel()
        keepAliveJob = scope.launch { while (isActive) { delay((seconds.coerceAtLeast(10.0) * 1000).toLong()); socket?.send("""{"MessageType":"KeepAlive"}""") } }
    }

    /** Another app sent music here: it plays on this device. */
    private suspend fun playHere(body: JsonObject) {
        val client = session.client.value ?: return
        val ids = (body["ItemIds"] as? JsonArray)?.map { it.jsonPrimitive.content } ?: return
        val tracks = runCatching { client.items(ids) }.getOrNull()?.takeIf { it.isNotEmpty() } ?: return
        leaveRemote()
        when (body.str("PlayCommand")) {
            "PlayNext" -> player.playNext(tracks)
            "PlayLast" -> player.addToQueue(tracks)
            else -> player.play(tracks, body["StartIndex"]?.jsonPrimitive?.intOrNull ?: 0,
                startAtMs = (body["StartPositionTicks"]?.jsonPrimitive?.longOrNull ?: 0) / 10_000)
        }
    }

    private fun playstateHere(command: String, ticks: Long?) {
        if (player.state.value.outputId != null) return
        when (command) {
            "Pause", "Stop" -> if (player.state.value.isPlaying) player.togglePlayPause()
            "Unpause" -> if (!player.state.value.isPlaying) player.togglePlayPause()
            "PlayPause" -> player.togglePlayPause()
            "NextTrack" -> player.next()
            "PreviousTrack" -> player.previous()
            "Seek" -> ticks?.let { player.seek(it / 10_000) }
        }
    }

    private var mutedVolume = 1f
    private fun general(name: String, args: JsonObject) {
        fun number(key: String) = args[key]?.jsonPrimitive?.contentOrNull?.toDoubleOrNull()
        when (name) {
            "SetVolume" -> number("Volume")?.let { AudioLevels.userVolume.value = (it / 100).toFloat().coerceIn(0f, 1f) }
            "VolumeUp" -> AudioLevels.userVolume.value = (AudioLevels.userVolume.value + 0.05f).coerceAtMost(1f)
            "VolumeDown" -> AudioLevels.userVolume.value = (AudioLevels.userVolume.value - 0.05f).coerceAtLeast(0f)
            "Mute" -> { mutedVolume = AudioLevels.userVolume.value; AudioLevels.userVolume.value = 0f }
            "Unmute" -> AudioLevels.userVolume.value = mutedVolume
            "ToggleMute" -> if (AudioLevels.userVolume.value == 0f) AudioLevels.userVolume.value = mutedVolume
                            else { mutedVolume = AudioLevels.userVolume.value; AudioLevels.userVolume.value = 0f }
            "SetRepeatMode" -> player.setRepeat(args.str("RepeatMode") ?: "RepeatNone")
            "SetShuffleQueue" -> player.setShuffle(args.str("ShuffleMode") == "Shuffle")
            "DisplayMessage" -> if (args.str("Header") == "dial.handoff") args.str("Text")?.let { receiveHandoff(it) }
        }
    }

    /** Messages only Dial apps send each other. */
    private fun receiveHandoff(text: String, retried: Boolean = false) {
        val payload = runCatching { JellyfinJson.parseToJsonElement(text).jsonObject }.getOrNull() ?: return
        when (payload.str("kind")) {
            "djState" -> {
                // The Marlo on the device we follow: show it here.
                if (player.state.value.outputId == null || payload.str("from") != targetDeviceId) return
                val state = payload["state"] as? JsonObject ?: return
                val active = state["active"]?.jsonPrimitive?.booleanOrNull ?: false
                if (!active) { _dj.value = null; return }
                val sessionState = state["session"] as? JsonObject
                val messages = (sessionState?.get("messages") as? JsonArray)?.mapNotNull { m ->
                    val o = m as? JsonObject ?: return@mapNotNull null
                    (o.str("sender") == "dj") to (o.str("text") ?: "")
                } ?: emptyList()
                _dj.value = DJMirror(state["onAir"]?.jsonPrimitive?.booleanOrNull ?: false, state.str("caption"),
                    sessionState?.str("blockTitle"), messages)
            }
            "djCommand" -> Unit // no Marlo here to command
            "queue" -> {
                // Only from the device this one follows.
                if (!player.state.value.isRemote || payload.str("from") != targetDeviceId) return
                sharedQueueIds = (payload["ids"] as? JsonArray)?.map { it.jsonPrimitive.content.replace("-", "").lowercase() } ?: return
                refresh()
            }
            "queueRequest" -> if (!player.state.value.isRemote) scope.launch { shareQueue(force = true) }
            "stationRequest" -> if (!player.state.value.isRemote && player.state.value.station != null) scope.launch { shareStation(force = true) }
            "stationState" -> {
                val from = payload.str("from") ?: return
                val station = (payload["station"] as? JsonObject)?.let { runCatching { JellyfinJson.decodeFromJsonElement(Station.serializer(), it) }.getOrNull() } ?: return
                val playing = payload["playing"]?.jsonPrimitive?.booleanOrNull ?: true
                val state = player.state.value
                val now = System.currentTimeMillis()
                if (state.isRemote) {
                    // Following that device: show what it plays now.
                    if (from != targetDeviceId) return
                    lastSeen = now
                    player.showRemoteStation(station, playing)
                    return
                }
                if (!playing || now < pausedUntil) return
                val busy = state.isPlaying || state.pendingTitle != null
                // Idle: show what plays elsewhere. Busy: only if that was started after what plays here (the newest wins).
                val startedAt = ((payload["startedAt"]?.jsonPrimitive?.doubleOrNull ?: 0.0) * 1000).toLong()
                if (busy && startedAt <= player.playStartedAt + 2_000) return
                val device = _devices.value.firstOrNull { it.deviceId == from }
                if (device == null) {
                    // The device list may not have the other one yet: look again, then follow.
                    if (!retried) scope.launch { refresh().join(); receiveHandoff(text, retried = true) }
                    return
                }
                if (busy) player.pause()
                followingAutomatically = true
                player.useRemote(device.id, device.name)
                targetDeviceId = from
                lastSeen = now
                startPolling()
                player.showRemoteStation(station, playing)
            }
            "station" -> {
                val station = (payload["station"] as? JsonObject)?.let { runCatching { JellyfinJson.decodeFromJsonElement(Station.serializer(), it) }.getOrNull() } ?: return
                leaveRemote()
                player.playStation(station)
            }
            "dj", "djSession" -> {
                // There is no DJ on Android: just play the session's songs, if there are any.
                leaveRemote()
                val ids = (payload["queue"] as? JsonArray)?.map { it.jsonPrimitive.content } ?: emptyList()
                if (ids.isNotEmpty()) scope.launch {
                    val tracks = session.client.value?.let { runCatching { it.items(ids) }.getOrNull() } ?: return@launch
                    player.play(tracks, payload["index"]?.jsonPrimitive?.intOrNull ?: 0,
                        startAtMs = ((payload["position"]?.jsonPrimitive?.doubleOrNull ?: 0.0) * 1000).toLong())
                }
            }
        }
    }

    private fun leaveRemote() {
        if (player.state.value.outputId == null) return
        stopPolling()
        targetDeviceId = null
        followingAutomatically = false
        _dj.value = null
        player.useThisDevice()
        pausedUntil = System.currentTimeMillis() + 10_000
    }

    private fun JsonObject.str(key: String) = (this[key] as? JsonPrimitive)?.contentOrNull
}
