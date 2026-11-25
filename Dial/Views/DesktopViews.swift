import SwiftUI

// iPad and Mac (and any wide window): a sidebar like Apple Music, a full player bar along the bottom
// like Spotify, and a panel on the right for lyrics, the queue and the artist, like both.

/// What the sidebar can show.
enum SidebarItem: Hashable {
    case search, home, radio, librarySearch
    case recentlyAdded, artists, albums, songs, genres, decades, favorites, downloaded, wishlist, importPlaylists, stats, libraryStats
    case playlist(id: String, name: String)
}

/// The right-hand panel's tabs.
enum InspectorTab: String, CaseIterable, Identifiable {
    case lyrics = "Lyrics", queue = "Up Next", about = "About"
    var id: String { rawValue }
}

struct DesktopRoot: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var nav = app.navigator
        NavigationSplitView {
            Sidebar(selection: $nav.sidebar)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            NavigationStack(path: $nav.desktopPath) {
                ZoomScope { root(for: nav.sidebar ?? .home).routeDestinations() }
            }
            .modifier(NoScrollEdgeBlur())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if app.player.hasContent {
                    DesktopPlayerBar()
                        .padding(.horizontal, Theme.Spacing.l)
                        .padding(.bottom, Theme.Spacing.m)
                }
            }
            .inspector(isPresented: Binding(
                get: { nav.showInspector || nav.artistPreview != nil },
                set: { open in if !open { nav.showInspector = false; nav.artistPreview = nil } }
            )) {
                Group {
                    // An artist preview takes the drawer while it's open; closing it brings back lyrics or the queue.
                    if let preview = nav.artistPreview {
                        ArtistPreviewDrawer(preview: preview)
                    } else {
                        InspectorPanel()
                    }
                }
                .inspectorColumnWidth(min: 300, ideal: 360, max: 460)
            }
        }
        .toolbar {
            // Next to the sidebar button, in its own bubble like it: where the music plays.
            ToolbarItem(placement: .navigation) {
                Button { nav.showDevices = true } label: {
                    Image(systemName: app.player.isRemote ? "hifispeaker.fill" : "laptopcomputer.and.iphone")
                }
                .foregroundStyle(app.player.isRemote ? Color.dial : Color.primary)
                .accessibilityLabel(app.player.outputName.map { "Playing on \($0). Choose a device" } ?? "Devices")
            }
        }
        .onChange(of: nav.sidebar) { nav.desktopPath = [] }
    }

    @ViewBuilder
    private func root(for item: SidebarItem) -> some View {
        switch item {
        case .search: LibrarySearchContainer(outside: true) { DiscoveryView() }
        case .librarySearch: LibrarySearchPage()
        case .home: HomeView()
        case .radio: RadioView()
        case .recentlyAdded: AlbumsView()
        case .artists: LibrarySection.artists.destination
        case .albums: LibrarySection.albums.destination
        case .songs: LibrarySection.songs.destination
        case .genres: LibrarySection.genres.destination
        case .decades: LibrarySection.decades.destination
        case .favorites: LibrarySection.favorites.destination
        case .downloaded: LibrarySection.downloaded.destination
        case .wishlist: LibrarySection.wishlist.destination
        case .importPlaylists: ImportPlaylistsView()
        case .stats: StatsView()
        case .libraryStats: LibraryStatsView()
        case .playlist(let id, let name): PlaylistView(playlistId: id, name: name)
        }
    }
}

/// The sidebar: where to go, your library, and your playlists.
private struct Sidebar: View {
    @Binding var selection: SidebarItem?
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            mainList
            // Settings stays at the bottom of the sidebar: a row styled exactly like the others, under a separator.
            Divider()
            List {
                Button { app.navigator.open(.settings) } label: {
                    Label("Settings", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.sidebar)
            .scrollDisabled(true)
            .frame(height: 64)
        }
        .navigationTitle("Dial")
    }

    private var mainList: some View {
        List(selection: $selection) {
            Label("Home", systemImage: "house").tag(SidebarItem.home)
            Label("Tune In", systemImage: "dot.radiowaves.left.and.right").tag(SidebarItem.radio)
            Label("Discovery", systemImage: "safari").tag(SidebarItem.search)
            Label("Search", systemImage: "magnifyingglass").tag(SidebarItem.librarySearch)

            Section("Library") {
                Label("Recently Added", systemImage: "clock").tag(SidebarItem.recentlyAdded)
                Label("Artists", systemImage: "music.mic").tag(SidebarItem.artists)
                Label("Albums", systemImage: "square.stack").tag(SidebarItem.albums)
                Label("Favorites", systemImage: "star.square").tag(SidebarItem.favorites)
                Label("Downloaded", systemImage: "arrow.down.circle").tag(SidebarItem.downloaded)
                if app.hasPlugin {
                    Label("Wishlist", systemImage: "bookmark").tag(SidebarItem.wishlist)
                }
                Label("Your Stats", systemImage: "chart.bar.xaxis").tag(SidebarItem.stats)
                Label("Library Stats", systemImage: "chart.pie").tag(SidebarItem.libraryStats)
            }

            Section("Playlists") {
                ForEach(app.library.playlists) { playlist in
                    Label(playlist.name, systemImage: "music.note.list")
                        .lineLimit(1)
                        .help(playlist.name)
                        .tag(SidebarItem.playlist(id: playlist.id, name: playlist.name))
                }
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Player bar

/// The player along the bottom, one slim capsule: the controls on the left, the song in the middle with a thin
/// progress line under it, and a few quiet buttons on the right. Clicking the song opens the full player.
struct DesktopPlayerBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        // The widest layout that fits: everything; then without shuffle, repeat and the extra buttons;
        // then just play, the song and the queue. The song's title always keeps room.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.l) {
                controls
                song.frame(minWidth: Theme.Size.barSongMin, maxWidth: .infinity)
                trailing
            }
            HStack(spacing: Theme.Spacing.m) {
                compactControls
                song.frame(minWidth: Theme.Size.barSongMin, maxWidth: .infinity)
                compactTrailing
            }
            HStack(spacing: Theme.Spacing.s) {
                BarButton(symbol: app.player.isPlaying ? "pause.fill" : "play.fill", label: app.player.isPlaying ? "Pause" : "Play",
                          font: .title3) { app.player.togglePlayPause() }
                song.frame(maxWidth: .infinity)
                panelToggle(.queue, symbol: "list.bullet")
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.s)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(.separator.opacity(0.4)) }
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }

    private var controls: some View {
        let player = app.player
        let modesOff = player.isLive || app.dj.isActive
        return HStack(spacing: Theme.Spacing.s) {
            small("shuffle", "Shuffle", on: player.shuffleOn, disabled: modesOff) { player.toggleShuffle() }
            BarButton(symbol: "backward.fill", label: "Previous", font: .body) { player.previous() }
            BarButton(symbol: player.isPlaying ? "pause.fill" : "play.fill", label: player.isPlaying ? "Pause" : "Play",
                      font: .title2) { player.togglePlayPause() }
            BarButton(symbol: "forward.fill", label: "Next", font: .body) { player.next() }
            small(player.repeatMode == .one ? "repeat.1" : "repeat", "Repeat", on: player.repeatMode != .off, disabled: modesOff) {
                player.cycleRepeat()
            }
        }
    }

    /// Cover, title, and artist (or where it's playing), with the progress line underneath.
    private var song: some View {
        let player = app.player
        return HStack(spacing: Theme.Spacing.m) {
            Button { app.navigator.showNowPlaying = true } label: {
                NowPlayingArtwork(pixels: Theme.Pixels.thumb)
                    .artworkFrame(size: Theme.Size.miniArtwork, .rounded(Theme.Radius.thumb))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open the player")
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(player.nowTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                    .layoutPriority(1)
                if let device = player.outputName {
                    Text("Playing on \(device)").font(.caption).foregroundStyle(Color.dial).lineLimit(1)
                } else {
                    HStack(spacing: Theme.Spacing.xs) {
                        if let source = player.source { SourceBadge(text: source) }
                        Text(player.nowSubtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if !player.isLive {
                    ThinProgress(current: player.currentTime, total: player.duration) { player.seek(to: $0) }
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
        }
    }

    private var compactControls: some View {
        let player = app.player
        return HStack(spacing: Theme.Spacing.xs) {
            BarButton(symbol: "backward.fill", label: "Previous", font: .body) { player.previous() }
            BarButton(symbol: player.isPlaying ? "pause.fill" : "play.fill", label: player.isPlaying ? "Pause" : "Play",
                      font: .title2) { player.togglePlayPause() }
            BarButton(symbol: "forward.fill", label: "Next", font: .body) { player.next() }
        }
    }

    private var compactTrailing: some View {
        HStack(spacing: Theme.Spacing.xs) {
            moreMenu
            panelToggle(.lyrics, symbol: "quote.bubble")
            panelToggle(.queue, symbol: "list.bullet")
            BarButton(symbol: "xmark", label: "Close player", font: .body) { app.player.close() }
        }
    }

    private var trailing: some View {
        HStack(spacing: Theme.Spacing.s) {
            moreMenu
            panelToggle(.lyrics, symbol: "quote.bubble")
            panelToggle(.queue, symbol: "list.bullet")
            BarButton(symbol: app.player.isRemote ? "hifispeaker.fill" : "laptopcomputer.and.iphone", label: "Devices", font: .body) {
                app.navigator.showDevices = true
            }
            .foregroundStyle(app.player.isRemote ? Color.dial : Color.primary)
            AirPlayButton()
                .frame(width: Theme.Size.tapTarget * 0.8, height: Theme.Size.tapTarget * 0.8)
                .accessibilityLabel("AirPlay")
            BarButton(symbol: "xmark", label: "Close player", font: .body) { app.player.close() }
        }
    }

    /// Favorite, the album, the artists and About: things you need now and then, kept out of the way.
    private var moreMenu: some View {
        Menu {
            if let track = app.player.current, !app.player.isLive {
                let favorite = app.library.isFavorite(track.id)
                Button { app.library.toggleFavorite(track) } label: {
                    Label(favorite ? "Remove from Favorites" : "Favorite", systemImage: favorite ? "heart.slash" : "heart")
                }
                if let album = track.album, let albumId = track.albumId {
                    Button { app.navigator.open(.album(id: albumId, name: album)) } label: { Label("Go to Album", systemImage: "square.stack") }
                }
                ForEach(app.credits.credits(for: track), id: \.self) { name in
                    Button { app.navigator.open(app.credits.route(for: name)) } label: { Label("Go to \(name)", systemImage: "music.mic") }
                }
                Divider()
                Button {
                    app.navigator.inspectorTab = .about
                    app.navigator.showInspector = true
                } label: { Label("About This Song", systemImage: "info.circle") }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(width: Theme.Size.tapTarget * 0.8, height: Theme.Size.tapTarget * 0.8)
                .contentShape(Rectangle())
        }
        .plainMenu()
        .accessibilityLabel("More")
    }

    private func small(_ symbol: String, _ label: String, on: Bool, disabled: Bool, action: @escaping () -> Void) -> some View {
        BarButton(symbol: symbol, label: label, font: .caption.weight(.semibold), action: action)
            .foregroundStyle(on ? Color.dial : Color.secondary)
            .disabled(disabled)
            .opacity(disabled ? 0.4 : 1)
    }

    /// Opens the right panel on that tab, or closes it when it's already showing.
    private func panelToggle(_ tab: InspectorTab, symbol: String) -> some View {
        @Bindable var nav = app.navigator
        let active = nav.showInspector && nav.inspectorTab == tab
        return BarButton(symbol: symbol, label: tab.rawValue, font: .body) {
            if active { nav.showInspector = false } else {
                nav.inspectorTab = tab
                nav.showInspector = true
            }
        }
        .foregroundStyle(active ? Color.dial : Color.primary)
    }
}

/// A quiet icon button for the bar.
private struct BarButton: View {
    let symbol: String
    let label: String
    let font: Font
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(font)
                .frame(width: Theme.Size.tapTarget * 0.8, height: Theme.Size.tapTarget * 0.8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// A hairline progress bar under the title. Drag or click to seek; times show while you hover or drag.
private struct ThinProgress: View {
    let current: TimeInterval
    let total: TimeInterval
    let onSeek: (TimeInterval) -> Void
    @State private var dragging: Double?
    @State private var hovering = false

    var body: some View {
        let fraction = dragging ?? (total > 0 ? min(current / total, 1) : 0)
        VStack(spacing: Theme.Spacing.xxs) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.15))
                    Capsule().fill(.primary.opacity(0.7)).frame(width: geometry.size.width * fraction)
                }
                .frame(height: hovering || dragging != nil ? Theme.Spacing.xs + 1 : Theme.Spacing.xxs)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { dragging = min(max($0.location.x / geometry.size.width, 0), 1) }
                        .onEnded { _ in
                            if let dragging { onSeek(dragging * total) }
                            dragging = nil
                        }
                )
            }
            .frame(height: Theme.Spacing.s)
            if hovering || dragging != nil {
                HStack {
                    Text(formatTime(fraction * total))
                    Spacer()
                    Text("-" + formatTime(max(total - fraction * total, 0)))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .transition(.opacity)
            }
        }
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
        .accessibilityElement()
        .accessibilityLabel("Song position")
        .accessibilityValue("\(formatTime(current)) of \(formatTime(total))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek(min(current + 10, total))
            case .decrement: onSeek(max(current - 10, 0))
            @unknown default: break
            }
        }
    }
}

// MARK: - Right panel

/// Lyrics, the queue, or about the artist and the song, next to whatever page you're on.
struct InspectorPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var nav = app.navigator
        VStack(spacing: 0) {
            Picker("Show", selection: $nav.inspectorTab) {
                ForEach(InspectorTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(Theme.Spacing.m)

            Group {
                switch nav.inspectorTab {
                case .lyrics:
                    if let track = app.player.current, !app.player.isLive {
                        LyricsPanel(track: track).padding(.horizontal, Theme.Spacing.m)
                    } else {
                        ContentUnavailableView("No lyrics", systemImage: "quote.bubble", description: Text("Play a song to see its lyrics here."))
                    }
                case .queue:
                    QueuePanel().padding(.horizontal, Theme.Spacing.s)
                case .about:
                    AboutPanel()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.colorScheme, .dark)
        }
        .background { PlayerBackground().ignoresSafeArea() }
    }
}

/// About what's playing: the artist (photo, bio, page), everyone credited, the album and the file.
private struct AboutPanel: View {
    @Environment(AppModel.self) private var app
    @State private var artist: BaseItem?

    var body: some View {
        if let track = app.player.current, !app.player.isLive {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    if let artistId = track.primaryArtist?.id {
                        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                            Text("About the artist").font(.headline)
                            ArtworkView(itemId: artistId, pixels: Theme.Pixels.tile, placeholder: "music.mic")
                                .squareArtwork(.rounded(Theme.Radius.tile))
                            Button {
                                app.navigator.open(.artist(id: artistId, name: track.primaryArtist?.name ?? ""))
                            } label: {
                                Text(ArtistNames.primary(track.albumArtist ?? track.artistLine)).font(.title3.bold())
                            }
                            .buttonStyle(.plain)
                            if let bio = artist?.overview, !bio.isEmpty {
                                ExpandableText(text: bio, lines: 5).font(.subheadline)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        Text("Credits").font(.headline)
                        ForEach(Array(app.credits.credits(for: track).enumerated()), id: \.element) { index, name in
                            Button { app.navigator.open(app.credits.route(for: name)) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                        Text(name)
                                        Text(index == 0 ? "Main artist" : "Featured").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if let album = track.album, let albumId = track.albumId {
                        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                            Text("Album").font(.headline)
                            Button { app.navigator.open(.album(id: albumId, name: album)) } label: {
                                HStack(spacing: Theme.Spacing.m) {
                                    ArtworkView(itemId: albumId, pixels: Theme.Pixels.thumb).artworkFrame(size: Theme.Size.rowArtwork)
                                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                        Text(album).lineLimit(2)
                                        if let year = track.productionYear { Text(String(year)).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if let format = [track.formatLabel, track.qualityLabel].compactMap({ $0 }).joined(separator: ", ").nilIfEmpty {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            Text("File").font(.headline)
                            Text(format).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(Theme.Spacing.l)
            }
            .task(id: track.primaryArtist?.id) {
                artist = nil
                guard let id = track.primaryArtist?.id else { return }
                artist = try? await app.client?.details(id)
            }
        } else {
            ContentUnavailableView("Nothing playing", systemImage: "music.note", description: Text("Play a song to see more about it."))
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}


/// Switches off the soft blur macOS 26 draws over the top of a scrolling list (it was blurring whole sections of rows under a
/// pinned letter or section header, in the search results and the Artists list).
private struct NoScrollEdgeBlur: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .all)
        } else {
            content
        }
        #else
        content
        #endif
    }
}
