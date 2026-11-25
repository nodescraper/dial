import AppIntents
import SwiftUI
import UIKit
#if os(iOS) && !targetEnvironment(macCatalyst)
import Intents
#endif

/// Lets iOS hand finished background downloads back to Dial.
final class DialAppDelegate: NSObject, UIApplicationDelegate {
    static var pendingCompletion: (() -> Void)?

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == DownloadManager.sessionIdentifier else { return completionHandler() }
        Self.pendingCompletion = completionHandler
    }

    #if canImport(CarPlay) && !targetEnvironment(macCatalyst)
    /// The car's screen is its own scene, drawn by CarPlay's templates; the phone's window stays SwiftUI's own.
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        if connectingSceneSession.role == .carTemplateApplication {
            configuration.delegateClass = CarPlaySceneDelegate.self
        }
        return configuration
    }

    /// Siri's "play … on Dial" requests are handled here, inside the app.
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        intent is INPlayMediaIntent ? PlayMediaHandler() : nil
    }
    #endif
}

@main
struct DialApp: App {
    @UIApplicationDelegateAdaptor(DialAppDelegate.self) private var appDelegate
    @State private var app = AppModel.shared

    init() {
        // Keep cover art on the phone so scrolling back through the library doesn't refetch it.
        // Decoded images are kept by the image loader, so the network cache mostly lives on disk.
        URLCache.shared = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 512 * 1024 * 1024)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if app.session.client != nil {
                    RootView()
                } else {
                    LoginView()
                }
            }
            .environment(app)
            .tint(Color.dial)
            .onOpenURL { app.open(url: $0) }
        }
        .commands { DialCommands(app: app) }
    }
}

/// Menu bar commands on the Mac (and keyboard shortcuts on iPad with a keyboard).
/// The media keys (play/pause, next, previous) work too, through the system's Now Playing controls.
struct DialCommands: Commands {
    let app: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { app.navigator.open(.settings) }
                .keyboardShortcut(",")
        }
        CommandMenu("Controls") {
            Button(app.player.isPlaying ? "Pause" : "Play") { app.player.togglePlayPause() }
                .keyboardShortcut("p")
                .disabled(!app.player.hasContent)
            Button("Next") { app.player.next() }
                .keyboardShortcut(.rightArrow)
                .disabled(!app.player.hasContent)
            Button("Previous") { app.player.previous() }
                .keyboardShortcut(.leftArrow)
                .disabled(!app.player.hasContent)
            Divider()
            Button(app.player.shuffleOn ? "Turn Off Shuffle" : "Shuffle") { app.player.toggleShuffle() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!app.player.hasContent || app.player.isLive)
            Button("Repeat: \(repeatLabel)") { app.player.cycleRepeat() }
                .keyboardShortcut("r")
                .disabled(!app.player.hasContent || app.player.isLive)
            Divider()
            Button(app.dj.isActive ? "Talk to \(app.dj.name)…" : "Start \(app.dj.name)") {
                if app.dj.isActive {
                    app.navigator.open(.dj)
                } else {
                    app.play(.dj)
                }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Show Now Playing") { app.navigator.showNowPlaying = true }
                .keyboardShortcut("0")
                .disabled(!app.player.hasContent)
        }
        CommandGroup(after: .sidebar) {
            Button("Home") { app.navigator.tab = .home }.keyboardShortcut("1")
            Button("Tune In") { app.navigator.tab = .radio }.keyboardShortcut("2")
            Button("Library") { app.navigator.tab = .library }.keyboardShortcut("3")
            Button("Search Library") { app.navigator.openLibrarySearch() }.keyboardShortcut("f")
            Divider()
        }
    }

    private var repeatLabel: String {
        switch app.player.repeatMode {
        case .off: "Off"
        case .all: "All"
        case .one: "One"
        }
    }
}

// MARK: - App model

/// Holds every part of the app so views only need one environment object.
@MainActor
@Observable
final class AppModel {
    let session = Session()
    let settings = AppSettings()
    let player = Player()
    let library = LibraryStore()
    let downloads = DownloadManager()
    let stations = StationStore()
    let navigator = Navigator()
    let dj = DJ()
    let follows = FollowStore()
    let wishlist = WishlistStore()
    let equalizer = Equalizer()
    let remote = RemoteControl()
    let audioMuse = AudioMuse()
    let connectivity = Connectivity()
    /// Plays made without a connection, told to the server when it is back.
    let playLog = PlayLog()
    /// Who's credited on each song, so featured artists get pages too.
    let credits = Credits()
    /// Every play with its date (Jellyfin's Playback Reporting plugin), for the DJ.
    let history = ListeningHistory()

    /// One model for the phone's window and the car's screen.
    static let shared = AppModel()

    init() {
        player.downloads = downloads
        downloads.backgroundCompletion = { DialAppDelegate.pendingCompletion?(); DialAppDelegate.pendingCompletion = nil }
        player.settings = settings
        dj.player = player
        dj.settings = settings
        dj.audioMuse = audioMuse
        dj.history = history
        dj.isHidden = { [weak library] id in library?.isHidden(id) ?? false }
        player.equalizerSettings = equalizer.tapSettings
        equalizer.onChange = { [weak player] in player?.equalizerChanged() }
        remote.player = player
        remote.dj = dj
        remote.library = library
        player.remote = remote
        // Music playing on another Dial: the DJ runs there, with its voice.
        // Marlo's session is shared with your other Dials, and can be steered from them.
        dj.onStateChange = { [weak remote] in remote?.djStateChanged() }
        dj.sendCommand = { [weak remote] command in remote?.handOff(.djCommand(command)) }
        dj.runElsewhere = { [weak player, weak remote] request in
            guard let player, let remote, player.isRemote, remote.targetIsDial else { return false }
            remote.handOff(.dj(request: request))
            return true
        }
        player.isOffline = { [weak connectivity] in connectivity?.isOffline ?? false }
        player.playLog = playLog
        connectivity.onReconnect = { [weak self] in
            guard let self, let client = self.session.client else { return }
            Task { await self.playLog.flush(client: client) }
        }
        player.isHidden = { [weak library] id in library?.isHidden(id) ?? false }
        // The Home Screen widget's play button starts the last played album or station without opening the app.
        DialIntentHooks.handler = { [weak self] command in
            guard command == "playLast" else { return }
            Task { await self?.playLastFromWidget() }
        }
        player.onPlay = { [weak self] in
            guard let self, self.settings.opensPlayerOnPlay else { return }
            self.navigator.showNowPlaying = true
        }
        connect()
    }

    var client: JellyfinClient? { session.client }

    /// Plays what the widget shows: the album from its start, or the station.
    func playLastFromWidget() async {
        // Following another device: the button controls that one.
        if player.isRemote, player.hasContent {
            player.togglePlayPause()
            return
        }
        // Playing on this device: the button pauses. Paused with the same thing loaded: it resumes.
        if !player.isRemote, player.hasContent {
            if player.isPlaying { player.pause(); return }
            if let last = DialWidgetStore.load()?.item,
               (last.kind == .station && player.liveStation?.id == last.id) || (last.kind == .song && player.current?.id == last.id) {
                player.resume()
                return
            }
        }
        var tries = 0
        while session.client == nil, tries < 80 { tries += 1; try? await Task.sleep(for: .milliseconds(100)) }
        guard session.client != nil, let last = DialWidgetStore.load()?.item else { return }
        switch last.kind {
        case .album, .song:
            guard let albumId = last.kind == .album ? last.id : last.albumId else { return }
            player.play(PendingPlayback(title: last.title, subtitle: last.subtitle, artwork: .item(albumId)), loading: { [weak self] in
                try await self?.session.client?.tracks(inAlbum: albumId) ?? []
            })
        case .station:
            if let data = last.station, let station = try? JSONDecoder().decode(Station.self, from: data) { player.playStation(station) }
        }
    }

    /// The widget's tap (dial://last): open the album, or play the station.
    func open(url: URL) {
        guard url.scheme == "dial", url.host == "last", let last = DialWidgetStore.load()?.item else { return }
        switch last.kind {
        case .album: navigator.open(.album(id: last.id, name: last.title))
        case .song:
            if let albumId = last.albumId { navigator.open(.album(id: albumId, name: last.album ?? last.title)) }
        case .station:
            if let data = last.station, let station = try? JSONDecoder().decode(Station.self, from: data) { player.playStation(station) }
        }
    }

    /// Whether the server has the Dial plugin (Discovery and mixtapes come from it). Remembered, so the tabs are right at launch.
    var hasPlugin: Bool = UserDefaults.standard.bool(forKey: "dial.hasPlugin")

    func signIn(server: String, username: String, password: String) async throws {
        try await session.login(server: server, username: username, password: password)
        connect()
    }

    func signIn(server: String, quickConnectSecret: String) async throws {
        try await session.login(server: server, quickConnectSecret: quickConnectSecret)
        connect()
    }

    func signOut() {
        dj.stop(silently: true)
        player.stop()
        session.logout()
        library.reset()
        navigator.reset()
        connect()
    }

    private func connect() {
        let client = session.client
        player.client = client
        library.client = client
        downloads.client = client
        dj.client = client
        remote.client = client
        audioMuse.client = client
        connectivity.client = client
        history.client = client
        credits.client = client
        if let client {
            Task { await playLog.flush(client: client) }
            Task {
                await library.refresh()
                // Siri learns the names of today's mixtapes and your playlists ("Hey Siri, play Daily Mix 1 in Dial").
                DialShortcuts.updateAppShortcutParameters()
                #if os(iOS) && !targetEnvironment(macCatalyst)
                await SiriMedia.setUp(client: client, app: self)
                #endif
            }
            Task {
                // Give other Dials a moment: if one of them is playing, this one follows it instead.
                try? await Task.sleep(for: .seconds(2))
                await player.restoreLastSession()
            }
            Task(priority: .background) { await Self.prefetchDiscographies(client: client) }
            Task {
                let present = await client.hasDialPlugin()
                hasPlugin = present
                UserDefaults.standard.set(present, forKey: "dial.hasPlugin")
                if present { await wishlist.refresh(client: client) }
            }
        }
    }

    /// Looks up every library artist's discography once (one per second, as MusicBrainz asks),
    /// so artist pages open complete instead of filling in later. Already-saved ones are skipped.
    private static func prefetchDiscographies(client: JellyfinClient) async {
        try? await Task.sleep(for: .seconds(8)) // let the app settle first
        guard let artists = try? await client.distinctArtists() else { return }
        for artist in artists.prefix(400) {
            guard !Task.isCancelled, let mbid = artist.musicBrainzId else { continue }
            _ = await PublicMusic.discography(artistMBID: mbid)
        }
    }

    /// Plays any station: the DJ, a live station, or a radio from the library.
    func play(_ station: RecentStation, in list: [Station] = []) {
        stations.markPlayed(station)
        switch station {
        case .dj:
            if dj.isActive {
                navigator.showNowPlaying = true
            } else {
                Task { await dj.start() }
            }
        case .live(let live):
            player.playStation(live, in: list.isEmpty ? stations.recentLive : list)
        case .yourMix:
            player.play(PendingPlayback(title: "Your Mix", subtitle: "Your whole library", artwork: .symbol("dot.radiowaves.left.and.right")),
                        loading: { [client = self.client] in
                            guard let client, let seed = try await client.randomSongs(limit: 1).first else { return [] }
                            return [seed] + (try await client.instantMix(for: seed.id, limit: 30)).filter { $0.id != seed.id }
                        })
        case .favoritesMix:
            player.play(PendingPlayback(title: "Favorites Mix", subtitle: "Songs you love, and more like them", artwork: .symbol("heart.fill")),
                        loading: { [client = self.client] in
                            guard let client, let seed = try await client.favoriteSongs().randomElement() else {
                                throw FavoritesMixError.noFavorites
                            }
                            return [seed] + (try await client.instantMix(for: seed.id, limit: 30)).filter { $0.id != seed.id }
                        })
        case .artist(let id, let name):
            player.startArtistRadio(id: id, name: name)
        case .genre(let id, let name):
            player.startGenreRadio(id: id, name: name)
        case .mood(let id):
            guard let mood = SoundMood.all.first(where: { $0.id == id }) else { return }
            player.startSoundRadio(PendingPlayback(title: mood.title, subtitle: "Mood station", artwork: .symbol(mood.symbol))) {
                [audioMuse] in try await audioMuse.songs(matching: mood.description).topShuffled()
            }
        case .yourSound:
            player.startSoundRadio(PendingPlayback(title: "Your Sound", subtitle: "Matches what you play most", artwork: .symbol("waveform"))) {
                [audioMuse] in try await audioMuse.yourSound().topShuffled()
            }
        }
    }

    var errorText: String? {
        // Offline, "couldn't reach the server" errors aren't news: the offline banner already says so.
        if connectivity.isOffline { return player.errorMessage }
        return player.errorMessage ?? library.errorMessage ?? downloads.errorMessage ?? remote.errorMessage
    }

    func clearErrors() {
        player.errorMessage = nil
        library.errorMessage = nil
        downloads.errorMessage = nil
        remote.errorMessage = nil
    }
}

extension Array {
    /// Keeps the best matches near the front but varies the order each time:
    /// shuffles within each group of ten.
    func topShuffled() -> [Element] {
        stride(from: 0, to: count, by: 10).flatMap { self[$0..<Swift.min($0 + 10, count)].shuffled() }
    }
}

enum FavoritesMixError: LocalizedError {
    case noFavorites
    var errorDescription: String? { "Favorite a few songs first: long-press any song and choose Favorite." }
}

// MARK: - Session

/// Remembers which server you're signed in to. The access token lives in the Keychain.
@MainActor
@Observable
final class Session {
    private(set) var client: JellyfinClient?

    init() {
        let defaults = UserDefaults.standard
        // Earlier versions kept the token in UserDefaults; move it to the Keychain.
        if let legacy = defaults.string(forKey: "dial.token") {
            Keychain.set(legacy, for: "token")
            defaults.removeObject(forKey: "dial.token")
        }
        if let server = defaults.string(forKey: "dial.server"),
           let url = URL(string: server),
           let token = Keychain.get("token"),
           let userId = defaults.string(forKey: "dial.userId") {
            client = JellyfinClient(server: url, token: token, userId: userId)
        }
    }

    var lastServer: String? { UserDefaults.standard.string(forKey: "dial.server") }

    func login(server raw: String, username: String, password: String) async throws {
        let url = try JellyfinClient.normalizedServer(raw)
        remember(try await JellyfinClient.login(server: url, username: username, password: password), at: url)
    }

    /// Signs in with a Quick Connect code that was approved on another device.
    func login(server raw: String, quickConnectSecret: String) async throws {
        let url = try JellyfinClient.normalizedServer(raw)
        remember(try await JellyfinClient.login(server: url, quickConnectSecret: quickConnectSecret), at: url)
    }

    private func remember(_ newClient: JellyfinClient, at url: URL) {
        UserDefaults.standard.set(url.absoluteString, forKey: "dial.server")
        UserDefaults.standard.set(newClient.userId, forKey: "dial.userId")
        Keychain.set(newClient.token, for: "token")
        client = newClient
    }

    func logout() {
        Keychain.delete("token")
        UserDefaults.standard.removeObject(forKey: "dial.userId")
        Task { await JellyfinClient.clearCache() }
        client = nil
    }
}

// MARK: - Settings

enum StreamingQuality: String, CaseIterable, Identifiable {
    case original, high, saver

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: return "Original quality"
        case .high: return "High (320 kbps)"
        case .saver: return "Data saver (128 kbps)"
        }
    }

    /// nil means "send the original file".
    var maxBitrate: Int? {
        switch self {
        case .original: return nil
        case .high: return 320_000
        case .saver: return 128_000
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    var quality: StreamingQuality {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "dial.quality") }
    }

    /// The voice the DJ speaks with; nil picks the best English voice on the iPhone.
    var djVoiceId: String? {
        didSet { UserDefaults.standard.set(djVoiceId, forKey: "dial.djVoice") }
    }

    /// The DJ is always Marlo (not renamable, so "Hey Siri, start Marlo in Dial" always fits).
    static let defaultDJName = "Marlo"

    /// Open the full-screen player when you start songs or a station.
    var opensPlayerOnPlay: Bool {
        didSet { UserDefaults.standard.set(opensPlayerOnPlay, forKey: "dial.opensPlayer") }
    }

    /// Seconds songs overlap; 0 plays them back to back with no gap.
    var crossfadeSeconds: Double {
        didSet { UserDefaults.standard.set(crossfadeSeconds, forKey: "dial.crossfade") }
    }

    /// Plays songs at a similar loudness.
    var volumeLeveling: Bool {
        didSet { UserDefaults.standard.set(volumeLeveling, forKey: "dial.leveling") }
    }

    init() {
        crossfadeSeconds = UserDefaults.standard.object(forKey: "dial.crossfade") as? Double ?? 0
        volumeLeveling = UserDefaults.standard.object(forKey: "dial.leveling") as? Bool ?? true
        quality = StreamingQuality(rawValue: UserDefaults.standard.string(forKey: "dial.quality") ?? "") ?? .original
        djVoiceId = UserDefaults.standard.string(forKey: "dial.djVoice")
        opensPlayerOnPlay = UserDefaults.standard.object(forKey: "dial.opensPlayer") as? Bool ?? true
    }

    /// The DJ's name: always Marlo, whatever an older version saved.
    var displayDJName: String { Self.defaultDJName }
}

// MARK: - Navigation

enum AppTab: Hashable {
    case home, radio, library, search
}

enum Route: Hashable {
    case album(id: String, name: String)
    case artist(id: String, name: String)
    /// An artist you don't have, from MusicBrainz: the same page as an owned artist, with what the world plays and their discography.
    case publicArtist(mbid: String, name: String)
    /// An album you don't have, from MusicBrainz: its tracks shown faded, the ones you have playable.
    case publicAlbum(PublicMusic.Release, artist: String, artistId: String?)
    /// An artist your library only has as a feature ("Post Malone feat. Justin Bieber").
    case featuredArtist(name: String)
    case playlist(id: String, name: String)
    case genre(id: String, name: String)
    /// All the mixtapes of one kind.
    case mixtapeList(title: String, mixtapes: [Mixtape])
    /// Your listening and your collection, in numbers.
    case stats
    /// Your library in numbers: size, growth, quality, eras, unplayed, health.
    case libraryStats
    /// A genre as you'd say it, gathering its spellings ("Hip-Hop", "hip hop", "Rap").
    case genreGroup(name: String, genreIds: [String])
    /// A ready-made mix (Radio tab).
    case mixtape(Mixtape)
    /// Make your own mix with the dial.
    case mixDial
    /// Everything in one of Search's discovery rows.
    case discoverList(title: String, picks: [PublicMusic.Pick])
    /// A genre to explore through MusicBrainz and ListenBrainz (Search).
    case exploreGenre(name: String)
    /// Every upcoming show, as a timeline.
    case onTour(concerts: [Concert])
    /// Albums from a decade (1990 for the 90s).
    case decade(Int)
    /// Bring in playlists from Spotify (or a list of songs) and match them to your library.
    case importPlaylists
    case library(LibrarySection)
    case stations(RadioCategory)
    case dj
    case recentlyPlayed
    case equalizer
    case settings
}

struct PlaylistRequest: Identifiable {
    let id = UUID()
    let tracks: [BaseItem]
}

@MainActor
@Observable
final class Navigator {
    var tab: AppTab = .home
    /// iPad and Mac (wide windows): a sidebar like Apple Music, one stack of pages next to it.
    var isDesktop = false
    var sidebar: SidebarItem? = .home
    var desktopPath: [Route] = []
    /// The panel on the right (lyrics, queue, about) on iPad and Mac.
    var showInspector = false
    var inspectorTab: InspectorTab = .lyrics
    /// An artist you don't have, shown in the side drawer on iPad and Mac.
    var artistPreview: ArtistPreview?
    /// A song or album waiting for "Delete from server?" to be confirmed.
    var deletionRequest: BaseItem?
    var homePath: [Route] = []
    var radioPath: [Route] = []
    var libraryPath: [Route] = []
    var searchPath: [Route] = []
    var showNowPlaying = false
    /// Counts up each time something asks for the library search to be focused (the Search command, ⌘F, the search icon).
    var searchFocusRequest = 0
    /// True until the search field has taken the request (it may not exist yet when a tab is only just opening).
    var searchFocusPending = false

    /// Goes to the Library's big search bar and puts the cursor in it.
    /// Goes to the Discovery page.
    func openDiscovery() {
        showNowPlaying = false
        if isDesktop { sidebar = .search } else { tab = .search }
    }

    func openLibrarySearch() {
        showNowPlaying = false
        if isDesktop { sidebar = .librarySearch } else { tab = .library }
        searchFocusPending = true
        searchFocusRequest += 1
    }
    /// The device picker (where the music plays), from Home's toolbar or the player.
    var showDevices = false
    var playlistRequest: PlaylistRequest?
    /// The song whose details are shown in the Song Info sheet.
    var songInfo: BaseItem?

    /// Opens the full-screen player. If it is marked open but is not on screen (the two can get out of step after the app
    /// was in the background), it is closed and opened again, so a tap on the mini player always shows it.
    func openPlayer() {
        guard showNowPlaying else { showNowPlaying = true; return }
        showNowPlaying = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            showNowPlaying = true
        }
    }

    /// Opens a page in the current tab, closing the full-screen player if it's open.
    func open(_ route: Route) {
        showNowPlaying = false
        if isDesktop {
            desktopPath.append(route)
            return
        }
        switch tab {
        case .home: homePath.append(route)
        case .radio: radioPath.append(route)
        case .library: libraryPath.append(route)
        case .search: searchPath.append(route)
        }
    }

    /// Back one page in the current stack.
    func goBack() {
        if isDesktop { _ = desktopPath.popLast(); return }
        switch tab {
        case .home: _ = homePath.popLast()
        case .radio: _ = radioPath.popLast()
        case .library: _ = libraryPath.popLast()
        case .search: _ = searchPath.popLast()
        }
    }

    func addToPlaylist(_ tracks: [BaseItem]) {
        guard !tracks.isEmpty else { return }
        playlistRequest = PlaylistRequest(tracks: tracks)
    }

    func reset() {
        tab = .home
        homePath = []
        radioPath = []
        libraryPath = []
        searchPath = []
        showNowPlaying = false
        playlistRequest = nil
        songInfo = nil
    }
}

extension View {
    /// Every screen a navigation stack can open.
    func routeDestinations() -> some View {
        navigationDestination(for: Route.self) { RouteView(route: $0) }
    }
}

/// The screen for a route.
struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case .album(let id, let name):
            AlbumView(albumId: id, title: name)
                .zoomDestination(id)
        case .artist(let id, let name):
            ArtistView(artistId: id, name: name)
        case .publicArtist(let mbid, let name):
            PublicArtistView(mbid: mbid, name: name)
        case .playlist(let id, let name):
            PlaylistView(playlistId: id, name: name)
        case .genre(let id, let name):
            GenreView(genreId: id, name: name)
        case .decade(let start):
            DecadeView(start: start)
        case .exploreGenre(let name):
            GenreExploreView(name: name)
        case .onTour(let concerts):
            OnTourView(concerts: concerts)
        case .discoverList(let title, let picks):
            DiscoverListView(title: title, picks: picks)
        case .mixtape(let mixtape):
            MixtapeView(mixtape: mixtape)
        case .genreGroup(let name, let ids):
            GenreGroupView(name: name, genreIds: ids)
        case .stats:
            StatsView()
        case .libraryStats:
            LibraryStatsView()
        case .mixtapeList(let title, let mixtapes):
            MixtapeListView(title: title, mixtapes: mixtapes)
        case .mixDial:
            MixDialView()
        case .featuredArtist(let name):
            FeaturedArtistView(name: name)
        case .publicAlbum(let release, let artist, let artistId):
            PublicAlbumView(release: release, artist: artist, artistId: artistId)
        case .importPlaylists:
            ImportPlaylistsView()
        case .library(let section):
            section.destination
        case .stations(let category):
            StationListView(category: category)
        case .dj:
            DJRequestView()
        case .recentlyPlayed:
            RecentlyPlayedView()
        case .equalizer:
            EqualizerView()
        case .settings:
            SettingsView()
        }
    }
}
