package app.dial

import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.launch
import android.app.Application
import app.dial.data.Credits
import app.dial.data.JellyfinClient
import app.dial.data.PublicMusic
import app.dial.data.Connectivity
import app.dial.data.Downloads
import app.dial.data.RemoteControl
import app.dial.data.SettingsStore
import app.dial.data.Library
import app.dial.data.Session
import app.dial.playback.PlayerController
import app.dial.playback.MediaItems

/** Holds the pieces every screen shares. */
class DialApplication : Application(), coil3.SingletonImageLoader.Factory {
    /** Covers are kept on disk and in memory for good: Jellyfin's answer headers would have them fetched again and again. */
    override fun newImageLoader(context: coil3.PlatformContext): coil3.ImageLoader = coil3.ImageLoader.Builder(context)
        .components {
            add(coil3.network.okhttp.OkHttpNetworkFetcherFactory(callFactory = { JellyfinClient.http }, cacheStrategy = { KeepCovers }))
        }
        .memoryCache { coil3.memory.MemoryCache.Builder().maxSizePercent(context, 0.3).build() }
        .diskCache { coil3.disk.DiskCache.Builder().directory(okio.Path.Companion.run { cacheDir.resolve("covers").absolutePath.toPath() }).maxSizeBytes(512L * 1024 * 1024).build() }
        .build()

    lateinit var session: Session
        private set
    lateinit var player: PlayerController
        private set
    lateinit var library: Library
        private set
    /** Who's on each song, so featured artists get pages too. */
    val credits = Credits()
    lateinit var settings: SettingsStore
        private set
    lateinit var downloads: Downloads
        private set
    lateinit var connectivity: Connectivity
        private set
    /** Connect play between your devices. */
    lateinit var remote: RemoteControl
        private set

    override fun onCreate() {
        super.onCreate()
        JellyfinClient.init(this)
        PublicMusic.init(this)
        app.dial.data.MixCatalog.init(this)
        app.dial.data.DiscoveryEngine.init(this)
        app.dial.data.Follows.init(this)
        app.dial.data.Wishlist.init(this)
        app.dial.data.DialPlugin.init(this)
        session = Session(this)
        settings = SettingsStore(this)
        downloads = Downloads(this)
        MediaItems.downloadedFile = { downloads.file(it) }
        player = PlayerController(this, session)
        library = Library(session, this)
        connectivity = Connectivity(this, session)
        player.isHidden = { library.isHidden(it) }
        player.isOffline = { connectivity.offline.value }
        player.isDownloaded = { downloads.isDownloaded(it) }
        remote = RemoteControl(this, session, player, library)
        // Songs played without a connection are told to the server when it is back (and at every start).
        val scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.Main)
        scope.launch {
            var wasOffline = connectivity.offline.value
            connectivity.offline.collect { now ->
                if (wasOffline && !now) session.client.value?.let { app.dial.data.PlayLog.flush(this@DialApplication, it) }
                wasOffline = now
            }
        }
        scope.launch { session.client.filterNotNull().collect { app.dial.data.PlayLog.flush(this@DialApplication, it) } }
    }
}

private object KeepCovers : coil3.network.CacheStrategy {
    override suspend fun read(cacheResponse: coil3.network.NetworkResponse, networkRequest: coil3.network.NetworkRequest, options: coil3.request.Options) =
        coil3.network.CacheStrategy.ReadResult(cacheResponse)

    override suspend fun write(cacheResponse: coil3.network.NetworkResponse?, networkRequest: coil3.network.NetworkRequest,
                               networkResponse: coil3.network.NetworkResponse, options: coil3.request.Options) =
        coil3.network.CacheStrategy.WriteResult(networkResponse)
}
