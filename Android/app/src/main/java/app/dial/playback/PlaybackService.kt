package app.dial.playback

import android.app.PendingIntent
import android.content.Intent
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.LibraryResult
import androidx.media3.session.MediaLibraryService
import androidx.media3.session.MediaSession
import app.dial.DialApplication
import app.dial.MainActivity
import app.dial.data.ArtistNames
import app.dial.data.JellyfinClient
import app.dial.data.PlayLog
import app.dial.data.RadioBrowser
import com.google.common.collect.ImmutableList
import com.google.common.util.concurrent.ListenableFuture
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.guava.future
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.collect

/**
 * Plays music in the background. Media3 gives Dial the notification, lock screen and Bluetooth
 * controls, gapless playback, audio focus and Android Auto from this one service.
 */
class PlaybackService : MediaLibraryService() {
    private var session: MediaLibrarySession? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var progressJob: Job? = null

    private val app get() = application as DialApplication
    private val client: JellyfinClient? get() = app.session.client.value

    // Two players: the active one plays; the other takes over for crossfades.
    private lateinit var players: List<ExoPlayer>
    private var activeIndex = 0
    private val active get() = players[activeIndex]
    private val fades = floatArrayOf(1f, 1f)
    private var crossfading: Job? = null
    private var audioSession = C.AUDIO_SESSION_ID_UNSET

    override fun onCreate() {
        super.onCreate()
        audioSession = androidx.media3.common.util.Util.generateAudioSessionIdV21(this)
        players = List(2) { slot ->
            ExoPlayer.Builder(this)
                .setAudioAttributes(
                    AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build(),
                    /* handleAudioFocus = */ slot == 0,
                )
                .setHandleAudioBecomingNoisy(true) // pause when headphones are unplugged
                .setWakeMode(C.WAKE_MODE_NETWORK)
                .build().apply {
                    setAudioSessionId(audioSession)
                    addListener(object : Player.Listener {
                        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) = applyVolumes()
                    })
                }
        }
        players.forEach { it.addListener(Reporter(it)) }
        Effects.attach(audioSession)

        val openApp = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        session = MediaLibrarySession.Builder(this, active, LibraryCallback())
            .setSessionActivity(openApp)
            .build()

        // Settings and the volume another device sets apply right away.
        scope.launch {
            app.settings.settings.collect { s ->
                Effects.apply(s.equalizerOn, s.equalizerPreset, s.equalizerBands)
                applyVolumes()
            }
        }
        scope.launch { AudioLevels.userVolume.collect { applyVolumes() } }
        scope.launch { watchForCrossfade() }
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaLibrarySession? = session

    override fun onTaskRemoved(rootIntent: Intent?) {
        val player = session?.player
        if (player == null || !player.playWhenReady || player.mediaItemCount == 0) stopSelf()
    }

    override fun onDestroy() {
        scope.cancel()
        Effects.release()
        session?.release()
        players.forEach { it.release() }
        session = null
        super.onDestroy()
    }

    // MARK: Volume leveling

    /** Quieter for loud masters, so songs play at a similar loudness (aiming for -14 LUFS; never boosts). */
    private fun level(item: MediaItem?): Float {
        if (!app.settings.settings.value.volumeLeveling) return 1f
        val song = MediaItems.item(item) ?: return 1f
        val gain = (song.normalizationGain?.plus(4) ?: -4.0).coerceAtMost(0.0)
        return Math.pow(10.0, gain / 20).toFloat()
    }

    private fun applyVolumes() {
        players.forEachIndexed { slot, p -> p.volume = level(p.currentMediaItem) * AudioLevels.userVolume.value * fades[slot] }
    }

    // MARK: Crossfade

    /** Near the end of a song, starts the next one in the other player and fades between them. */
    private suspend fun watchForCrossfade() {
        while (true) {
            delay(250)
            val seconds = app.settings.settings.value.crossfadeSeconds
            val p = active
            if (seconds <= 0 || crossfading != null || !p.isPlaying || p.shuffleModeEnabled || !p.hasNextMediaItem()) continue
            val remaining = p.duration - p.currentPosition
            if (p.duration <= 0 || remaining > seconds * 1000L) continue
            val current = MediaItems.item(p.currentMediaItem) ?: continue
            val next = MediaItems.item(p.getMediaItemAt(p.nextMediaItemIndex))
            // Songs that run into each other on the same album stay gapless, as recorded.
            if (next != null && next.albumId != null && next.albumId == current.albumId &&
                (next.indexNumber ?: 0) == (current.indexNumber ?: 0) + 1) continue
            crossfade(seconds)
        }
    }

    private fun crossfade(seconds: Int) {
        val outgoing = activeIndex
        val incoming = 1 - activeIndex
        val old = players[outgoing]
        val new = players[incoming]
        val rest = (old.nextMediaItemIndex until old.mediaItemCount).map { old.getMediaItemAt(it) }
        new.repeatMode = old.repeatMode
        new.setMediaItems(rest, 0, 0)
        fades[incoming] = 0f
        applyVolumes()
        new.prepare()
        new.play()
        activeIndex = incoming
        session?.player = new // the notification, controls and app now follow the new song
        crossfading = scope.launch {
            val steps = 30
            for (step in 1..steps) {
                delay(seconds * 1000L / steps)
                fades[incoming] = step.toFloat() / steps
                fades[outgoing] = 1f - fades[incoming]
                applyVolumes()
            }
            old.stop()
            old.clearMediaItems()
            fades[0] = 1f; fades[1] = 1f
            applyVolumes()
            crossfading = null
        }
    }

    /** Tells your server what's playing: play counts, and what your other devices show. */
    private inner class Reporter(private val player: Player) : Player.Listener {
        private var reportedId: String? = null
        private var startedAt = System.currentTimeMillis()
        private var endedPositionMs = 0L
        private var endedDurationMs = 0L
        private val isCurrentPlayer get() = player === active

        /** Where the song that just ended was left (the transition itself already points at the next one). */
        override fun onPositionDiscontinuity(oldPosition: Player.PositionInfo, newPosition: Player.PositionInfo, reason: Int) {
            if (!isCurrentPlayer) return
            endedPositionMs = oldPosition.positionMs
            endedDurationMs = player.duration.takeIf { it > 0 } ?: 0L
        }

        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
            if (!isCurrentPlayer) return
            val client = client ?: return
            reportedId?.let { old -> finish(client, old) }
            reportedId = mediaItem?.mediaId?.takeIf { !it.startsWith("station:") }
            endedPositionMs = 0L
            startedAt = System.currentTimeMillis()
            reportedId?.let { id -> scope.launch { client.reportPlayback("start", id, 0, false, queueIds(), volume(), repeat(), player.shuffleModeEnabled) } }
        }

        /** The last song of the queue ended: it played to its end, so it counts. */
        override fun onPlaybackStateChanged(state: Int) {
            if (!isCurrentPlayer || state != Player.STATE_ENDED) return
            val client = client ?: return
            val id = reportedId ?: return
            reportedId = null
            endedPositionMs = player.duration.takeIf { it > 0 } ?: player.currentPosition
            endedDurationMs = endedPositionMs
            finish(client, id)
        }

        /** Tells the server the song stopped where it did (so it counts as played); with no connection the play is kept and sent later. */
        private fun finish(client: JellyfinClient, id: String) {
            val position = endedPositionMs
            val started = startedAt
            val length = endedDurationMs
            scope.launch {
                if (!client.reportPlayback("stop", id, position, true)) {
                    PlayLog.record(this@PlaybackService, id, started, position / 1000.0, length / 1000.0)
                }
            }
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            if (!isCurrentPlayer) return
            report()
            progressJob?.cancel()
            if (isPlaying) {
                progressJob = scope.launch {
                    while (isActive) {
                        delay(10_000)
                        report()
                    }
                }
            }
        }

        private fun queueIds() = (0 until player.mediaItemCount).map { player.getMediaItemAt(it).mediaId }
            .filter { !it.startsWith("station:") }.take(100)
        private fun volume() = (AudioLevels.userVolume.value * 100).toInt()
        private fun repeat() = when (player.repeatMode) { Player.REPEAT_MODE_ALL -> "RepeatAll"; Player.REPEAT_MODE_ONE -> "RepeatOne"; else -> "RepeatNone" }

        private fun report() {
            val client = client ?: return
            val id = player.currentMediaItem?.mediaId?.takeIf { !it.startsWith("station:") } ?: return
            val position = player.currentPosition
            val paused = !player.isPlaying
            scope.launch { client.reportPlayback("progress", id, position, paused, queueIds(), volume(), repeat(), player.shuffleModeEnabled) }
        }
    }

    /** What Android Auto (and other media browsers) can browse and play. */
    private inner class LibraryCallback : MediaLibrarySession.Callback {
        private val root = MediaItems.root()

        override fun onGetLibraryRoot(
            session: MediaLibrarySession, browser: MediaSession.ControllerInfo, params: LibraryParams?,
        ): ListenableFuture<LibraryResult<MediaItem>> = scope.future { LibraryResult.ofItem(root, params) }

        /**
         * What Android Auto shows. Four tabs at the top (the most a car allows), each a short list of big, plain rows:
         * Recent (what you played), Tune In (live radio), Library (albums, artists, playlists) and Favorites.
         * Lists are capped, since a driver scrolls little.
         */
        override fun onGetChildren(
            session: MediaLibrarySession, browser: MediaSession.ControllerInfo, parentId: String,
            page: Int, pageSize: Int, params: LibraryParams?,
        ): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> = scope.future {
            val client = client ?: return@future LibraryResult.ofItemList(ImmutableList.of(), params)
            val grid = MediaItems.Layout.GRID
            fun album(it: app.dial.data.Item) =
                MediaItems.folder("album:${it.id}", it.name, it.albumArtistLine, client.imageUrl(it.id, 400), MediaMetadata.MEDIA_TYPE_ALBUM)
            val children: List<MediaItem> = runCatching {
                when {
                    parentId == "root" -> listOf(
                        MediaItems.folder("recent", "Recent", type = MediaMetadata.MEDIA_TYPE_FOLDER_MIXED),
                        MediaItems.folder("tunein", "Tune In", type = MediaMetadata.MEDIA_TYPE_FOLDER_RADIO_STATIONS),
                        MediaItems.folder("library", "Library", type = MediaMetadata.MEDIA_TYPE_FOLDER_MIXED),
                        MediaItems.folder("favorites", "Favorites", type = MediaMetadata.MEDIA_TYPE_FOLDER_MIXED),
                    )
                    parentId == "recent" -> client.recentlyPlayed(30).map { MediaItems.song(it, client) }
                    parentId == "tunein" -> RadioBrowser.categories.map { tag ->
                        MediaItems.folder("tag:$tag", tag.replaceFirstChar { it.uppercase() }, "Live radio", null,
                            MediaMetadata.MEDIA_TYPE_FOLDER_RADIO_STATIONS)
                    }
                    parentId.startsWith("tag:") -> RadioBrowser.byTag(parentId.removePrefix("tag:")).take(30).map { MediaItems.station(it) }
                    parentId == "library" -> listOf(
                        MediaItems.folder("albums", "Albums", type = MediaMetadata.MEDIA_TYPE_FOLDER_ALBUMS, children = grid),
                        MediaItems.folder("artists", "Artists", type = MediaMetadata.MEDIA_TYPE_FOLDER_ARTISTS, children = grid),
                        MediaItems.folder("playlists", "Playlists", type = MediaMetadata.MEDIA_TYPE_FOLDER_PLAYLISTS, children = grid),
                        MediaItems.folder("added", "Recently Added", type = MediaMetadata.MEDIA_TYPE_FOLDER_ALBUMS, children = grid),
                    )
                    parentId == "added" -> client.recentAlbums(40).map(::album)
                    parentId == "albums" -> client.albums(200).map(::album)
                    parentId == "artists" -> client.artists().take(200).map {
                        MediaItems.folder("artist:${it.id}", ArtistNames.primary(it.name), null, client.imageUrl(it.id, 400),
                            MediaMetadata.MEDIA_TYPE_ARTIST, children = grid)
                    }
                    parentId.startsWith("artist:") -> client.artistAlbums(parentId.removePrefix("artist:")).take(100).map(::album)
                    parentId == "playlists" -> client.playlists().map {
                        MediaItems.folder("playlist:${it.id}", it.name, null, client.imageUrl(it.id, 400), MediaMetadata.MEDIA_TYPE_PLAYLIST)
                    }
                    parentId == "favorites" -> client.favoriteSongs().take(100).map { MediaItems.song(it, client) }
                    parentId.startsWith("album:") -> client.albumTracks(parentId.removePrefix("album:")).map { MediaItems.song(it, client) }
                    parentId.startsWith("playlist:") -> client.playlistTracks(parentId.removePrefix("playlist:")).take(200).map { MediaItems.song(it, client) }
                    else -> emptyList()
                }
            }.getOrDefault(emptyList())
            // Cars ask for a page at a time: give exactly that page.
            val from = (page.toLong() * pageSize).coerceAtMost(children.size.toLong()).toInt()
            val to = (from.toLong() + pageSize).coerceAtMost(children.size.toLong()).toInt()
            LibraryResult.ofItemList(ImmutableList.copyOf(children.subList(from, to)), params)
        }

        /** "Hey Google, play Dark Fantasy": the car or assistant searches, then plays the first matches. */
        override fun onSearch(
            session: MediaLibrarySession, browser: MediaSession.ControllerInfo, query: String, params: LibraryParams?,
        ): ListenableFuture<LibraryResult<Void>> = scope.future {
            session.notifySearchResultChanged(browser, query, 20, params)
            LibraryResult.ofVoid()
        }

        override fun onGetSearchResult(
            session: MediaLibrarySession, browser: MediaSession.ControllerInfo, query: String,
            page: Int, pageSize: Int, params: LibraryParams?,
        ): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> = scope.future {
            val client = client ?: return@future LibraryResult.ofItemList(ImmutableList.of(), params)
            val songs = runCatching { client.search(query).filter { it.type == "Audio" }.take(20).map { MediaItems.song(it, client) } }
                .getOrDefault(emptyList())
            LibraryResult.ofItemList(ImmutableList.copyOf(songs), params)
        }

        override fun onGetItem(
            session: MediaLibrarySession, browser: MediaSession.ControllerInfo, mediaId: String,
        ): ListenableFuture<LibraryResult<MediaItem>> = scope.future {
            val client = client ?: return@future LibraryResult.ofError(LibraryResult.RESULT_ERROR_SESSION_AUTHENTICATION_EXPIRED)
            runCatching { LibraryResult.ofItem(MediaItems.song(client.details(mediaId), client), null) }
                .getOrElse { LibraryResult.ofError(LibraryResult.RESULT_ERROR_BAD_VALUE) }
        }

        /** Songs sent from the app or the car arrive without their stream address: add it here. */
        override fun onAddMediaItems(
            mediaSession: MediaSession, controller: MediaSession.ControllerInfo, mediaItems: MutableList<MediaItem>,
        ): ListenableFuture<MutableList<MediaItem>> = scope.future {
            val client = client ?: return@future mediaItems
            mediaItems.map { item ->
                when {
                    item.localConfiguration != null -> item
                    item.mediaId.startsWith("station:") -> MediaItems.station(item)?.let { MediaItems.station(it) } ?: item
                    else -> item.buildUpon().setUri(
                        MediaItems.downloadedFile(item.mediaId)?.let { android.net.Uri.fromFile(it) } ?: android.net.Uri.parse(client.streamUrl(item.mediaId))
                    ).build()
                }
            }.toMutableList()
        }
    }
}
