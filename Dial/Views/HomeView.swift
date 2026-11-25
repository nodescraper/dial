import SwiftUI

/// Home, laid out like Apple Music: a hero carousel of new albums, a scrolling list of
/// what you played recently, your stations (with the DJ first), and favorite albums.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var recentlyPlayed: [BaseItem] = HomeView.remembered?.played ?? []
    @State private var recentlyAdded: [BaseItem] = HomeView.remembered?.added ?? []
    /// Two or three cards that each say something (new from your artists, just added, on repeat...).
    @State private var highlights: [Highlight] = Snapshots.peek([Highlight].self, "home-highlights-v2") ?? []
    /// False until the highlights have been tried once, so the hero shows a ghost card instead of jumping between cards.
    @State private var highlightsSettled = false
    /// The daily mixes, the same ones as on the Tune In tab.
    @State private var mixtapes: [Mixtape] = Snapshots.peek([Mixtape].self, "home-mixtapes") ?? []
    @State private var favorites: [BaseItem] = HomeView.remembered?.favorites ?? []
    @State private var state: LoadState = HomeView.remembered == nil ? .loading : .loaded

    /// What Home showed last time, if it is still in memory.
    private static var remembered: HomeSnapshot? { Snapshots.peek(HomeSnapshot.self, "home") }

    /// The DJ always comes first, then whatever stations were played most recently.
    private var stations: [RecentStation] {
        [.dj] + app.stations.recent.filter { $0 != .dj }
    }

    private var onlineContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                if !highlights.isEmpty {
                    HighlightsRow(highlights: highlights)
                } else if !highlightsSettled && !app.connectivity.isOffline {
                    // A ghost card in the hero's shape while the highlights load.
                    HomeHeroSkeleton()
                } else if !recentlyAdded.isEmpty {
                    // If there are no highlights at all: the newest albums.
                    HeroCarousel(albums: Array(recentlyAdded.prefix(3)))
                } else if case .loading = state {
                    HomeHeroSkeleton()
                }

                if !recentlyPlayed.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        LinkedSectionHeader(title: "Recently Played", route: .recentlyPlayed)
                        SongGrid(tracks: recentlyPlayed)
                    }
                }

                Shelf(title: "Stations") {
                    ForEach(stations) { station in
                        RecentStationTile(station: station)
                    }
                }

                if !mixtapes.isEmpty {
                    Shelf(title: "Mixtapes") {
                        ForEach(mixtapes) { MixtapeTile(mixtape: $0, width: Theme.Size.shelfTile) }
                    }
                }

                if !recentlyAdded.isEmpty {
                    Shelf(title: "Recently Added", route: .library(.albums)) {
                        ForEach(recentlyAdded) { album in
                            NavigationLink(value: Route.album(id: album.id, name: album.name)) {
                                AlbumTile(album: album, width: Theme.Size.shelfTile)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !favorites.isEmpty {
                    Shelf(title: "Favorite Albums") {
                        ForEach(favorites) { album in
                            NavigationLink(value: Route.album(id: album.id, name: album.name)) {
                                AlbumTile(album: album, width: Theme.Size.shelfTile)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.l)
        }
        .loadState(state, isEmpty: recentlyAdded.isEmpty && recentlyPlayed.isEmpty,
                   empty: EmptyState(title: "Your library is empty", symbol: "music.note.house",
                                     message: "Add albums to your Jellyfin music library, then pull down to refresh."),
                   skeleton: .home, retry: { await load() })
    }

    var body: some View {
        Group {
            if app.connectivity.isOffline {
                // Offline there is one thing to show: what is on this iPhone, laid out like the Downloaded page.
                VStack(spacing: Theme.Spacing.s) {
                    OfflineBanner()
                    DownloadedList()
                }
            } else {
                onlineContent
            }
        }
        .onChange(of: app.connectivity.isOffline) { _, offline in
            if !offline { Task { await load() } }
        }
        .navigationTitle("Home")
        .toolbar {
            // The phone: one group, which the system draws as one rounded bar. Plain colors: only the device button turns
            // amber, while the music plays on another device.
            #if !targetEnvironment(macCatalyst)
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !app.connectivity.isOffline {
                    Button { app.navigator.showDevices = true } label: {
                        Image(systemName: app.player.isRemote ? "hifispeaker.fill" : "laptopcomputer.and.iphone")
                            .foregroundStyle(app.player.isRemote ? Color.dial : Color.primary)
                    }
                    .accessibilityLabel(app.player.outputName.map { "Playing on \($0). Choose a device" } ?? "Devices")
                }
                NavigationLink(value: Route.settings) {
                    Image(systemName: "person.crop.circle").foregroundStyle(Color.primary)
                }
                .accessibilityLabel("Settings")
            }
            #endif
        }
        .task { await load() }
        .refreshable {
            await JellyfinClient.clearCache()
            await load(force: true)
        }
    }

    private func load(force: Bool = false) async {
        guard let client = app.client else { return }
        // Show what was there last time immediately, then refresh.
        if recentlyAdded.isEmpty, let saved = await Snapshots.load(HomeSnapshot.self, "home") {
            recentlyAdded = saved.added
            recentlyPlayed = saved.played
            favorites = saved.favorites
            state = .loaded
        }
        // Coming back from an album shouldn't reload the whole page (and make it jump): once a minute is plenty.
        let recent = !force && !recentlyAdded.isEmpty && Freshness.isFresh("home-refresh", maxAge: 60)
        if !recent {
            await runLoad($state) {
                async let played = client.recentlyPlayedSongs(limit: 24)
                async let favs = client.favoriteAlbums()
                let added = try await client.recentAlbums(limit: 10)
                let playedNow = (try? await played) ?? recentlyPlayed
                let favsNow = (try? await favs) ?? favorites
                if added != recentlyAdded { recentlyAdded = added }
                if playedNow != recentlyPlayed { recentlyPlayed = playedNow }
                if favsNow != favorites { favorites = favsNow }
                Snapshots.save(HomeSnapshot(added: recentlyAdded, played: recentlyPlayed, favorites: favorites), "home")
                Freshness.mark("home-refresh")
            }
        }
        await loadHighlights(client: client)
        await DailyMixes.load(client: client, audioMuse: app.audioMuse, history: app.history,
                              isHidden: { app.library.isHidden($0) }) { mixes in
            if mixes != mixtapes { mixtapes = mixes }
            Snapshots.save(mixes, "home-mixtapes")
        }
    }

    private func loadHighlights(client: JellyfinClient) async {
        defer { highlightsSettled = true }
        if highlights.isEmpty, let saved = await Snapshots.load([Highlight].self, "home-highlights-v2") {
            highlights = saved
        }
        guard !app.connectivity.isOffline else { return }
        // At most once an hour (new releases and listening don't change faster than that).
        if !highlights.isEmpty, Freshness.isFresh("home-highlights-v2", maxAge: 3600) { return }
        let fresh = await HighlightBuilder.build(client: client, history: app.history)
        if !fresh.isEmpty {
            if fresh != highlights { highlights = fresh }
            Snapshots.save(fresh, "home-highlights-v2")
            Freshness.mark("home-highlights-v2")
        }
    }
}

// MARK: - Hero carousel

/// Big, swipeable cards for the newest albums, with the next card peeking in.
private struct HeroCarousel: View {
    let albums: [BaseItem]

    var body: some View {
        HScroll {
            LazyHStack(spacing: Theme.Spacing.m) {
                ForEach(albums) { album in
                    HeroCard(album: album)
                        .containerRelativeFrame(.horizontal) { width, _ in min(width * Theme.Size.carouselFraction, Theme.Size.heroMaxWidth) }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.horizontal, Theme.Spacing.l, for: .scrollContent)
    }
}

/// A 16:9 card: the artist's backdrop, with the album's cover, title and a play button
/// laid over a soft shadow at the bottom. Without a backdrop, a blurred cover fills in.
private struct HeroCard: View {
    let album: BaseItem
    @Environment(AppModel.self) private var app

    private var backdropURL: URL? {
        album.wideImage.flatMap { app.client?.imageURL(for: $0.itemId, type: $0.type, width: Theme.Pixels.wide) }
    }

    private var logoURL: URL? {
        album.logoImage.flatMap { app.client?.imageURL(for: $0.itemId, type: $0.type, width: Theme.Pixels.logo) }
    }

    var body: some View {
        NavigationLink(value: Route.album(id: album.id, name: album.name)) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .background { background }
                .overlay(alignment: .topLeading) { logo }
                .overlay(alignment: .bottom) { caption }
                .clipShape(.rounded(Theme.Radius.hero))
                .zoomSource(album.id)
                .artworkShadow()
                .contentShape(.rounded(Theme.Radius.hero))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(album.name), \(album.albumArtistLine), recently added")
        .accessibilityAction(named: "Play") { play() }
    }

    private var background: some View {
        RemoteImage(url: backdropURL) {
            // No backdrop on the server: the cover, enlarged and softened.
            ArtworkView(itemId: album.id, pixels: Theme.Pixels.tile)
                .blur(radius: 24)
                .scaleEffect(1.3)
        }
    }

    private var logo: some View {
        RemoteImage(url: logoURL, contentMode: .fit) { EmptyView() }
            .frame(maxWidth: Theme.Size.shelfTile, maxHeight: Theme.Size.heroLogo, alignment: .topLeading)
            .shadow(color: .black.opacity(0.4), radius: 6)
            .padding(Theme.Spacing.l)
    }

    private var caption: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.m) {
            ArtworkView(itemId: album.id, pixels: Theme.Pixels.thumb)
                .artworkFrame(size: Theme.Size.compactArtwork,
                              .rounded(Theme.Radius.nested(in: Theme.Radius.hero, padding: Theme.Spacing.m)))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text("Recently added")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.75))
                Text(album.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(album.albumArtistLine)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Spacing.s)
            IconButton(symbol: "play.fill", label: "Play \(album.name)", font: .title3) { play() }
            .foregroundStyle(.white)
            .background(.ultraThinMaterial, in: Circle())
        }
        .padding(Theme.Spacing.m)
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
        }
    }

    private func play() {
        guard let client = app.client else { return }
        let id = album.id
        app.player.play(PendingPlayback(title: album.name, subtitle: album.albumArtistLine, artwork: .item(id)),
                        loading: { try await client.tracks(inAlbum: id) })
    }
}

// MARK: - Song grid

/// Songs in columns of four that scroll sideways, each with its own "•••" menu.
struct SongGrid: View {
    let tracks: [BaseItem]
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Columns visible at once: one on iPhone (with the next peeking), two side by side on iPad and Mac,
    /// like Apple Music's "Best New Songs".
    private func columnWidth(_ width: CGFloat) -> CGFloat {
        sizeClass == .regular ? (width - Theme.Spacing.xl) / 2 : width * Theme.Size.carouselFraction
    }

    private var rows: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Theme.Spacing.s), count: Theme.Size.songGridRows)
    }

    var body: some View {
        if tracks.count <= Theme.Size.songGridRows {
            // Fewer songs than rows (a short list, say two downloads): a plain list. The grid squeezed such a short column into overlapping rows.
            VStack(spacing: 0) {
                ForEach(tracks, id: \.listId) { track in
                    CompactSongRow(track: track, queue: tracks)
                    Divider().padding(.leading, Theme.Size.rowArtwork + Theme.Spacing.m)
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
        } else {
            grid
        }
    }

    private var grid: some View {
        HScroll {
            LazyHGrid(rows: rows, spacing: sizeClass == .regular ? Theme.Spacing.xl : Theme.Spacing.m) {
                ForEach(tracks, id: \.listId) { track in
                    VStack(spacing: 0) {
                        CompactSongRow(track: track, queue: tracks)
                        Divider().padding(.leading, Theme.Size.rowArtwork + Theme.Spacing.m)
                    }
                    .containerRelativeFrame(.horizontal) { width, _ in columnWidth(width) }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.horizontal, Theme.Spacing.l, for: .scrollContent)
    }
}

// MARK: - Recently played (full list)

struct RecentlyPlayedView: View {
    @Environment(AppModel.self) private var app
    @State private var songs: [BaseItem] = []
    @State private var state: LoadState = .loading

    var body: some View {
        List {
            if !songs.isEmpty {
                PlayShuffleButtons(tracks: songs)
                    .listRowSeparator(.hidden)
            }
            SongRows(tracks: songs)
        }
        .listStyle(.plain)
        .loadState(state, isEmpty: songs.isEmpty,
                   empty: EmptyState(title: "Nothing played yet", symbol: "clock",
                                     message: "Songs you play appear here."),
                   retry: load)
        .navigationTitle("Recently Played")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let client = app.client else { return }
        await runLoad($state) { songs = try await client.recentlyPlayedSongs(limit: 100) }
    }
}

/// What Home showed last time, so it opens with content.
private struct HomeSnapshot: Codable, Sendable {
    let added: [BaseItem]
    let played: [BaseItem]
    let favorites: [BaseItem]
}


/// The hero while it loads: ghost cards built like the real ones (a scroll row, 16:9, the same width), the next one peeking in.
struct HomeHeroSkeleton: View {
    var body: some View {
        HScroll {
            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                ForEach(0..<2, id: \.self) { _ in
                    Color.clear
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .overlay { SkeletonBlock(height: nil, radius: Theme.Radius.hero) }
                        .clipShape(.rounded(Theme.Radius.hero))
                        .containerRelativeFrame(.horizontal) { width, _ in
                            min(width * Theme.Size.carouselFraction, Theme.Size.heroMaxWidth)
                        }
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
        }
        .scrollDisabled(true)
        .shimmering()
        .accessibilityHidden(true)
    }
}
