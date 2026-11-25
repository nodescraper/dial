import AVFoundation
import SwiftUI

// MARK: - Formatting

func formatTime(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    if total >= 3600 {
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
    return String(format: "%d:%02d", total / 60, total % 60)
}

func songCountLine(_ tracks: [BaseItem]) -> String {
    let minutes = Int((tracks.compactMap(\.duration).reduce(0, +) / 60).rounded())
    let songs = tracks.count == 1 ? "1 song" : "\(tracks.count) songs"
    return minutes > 0 ? "\(songs), \(minutes) minutes" : songs
}

// MARK: - Loading, empty and error states

enum LoadState: Equatable {
    case loading, loaded, failed(String)
}

struct EmptyState {
    let title: String
    let symbol: String
    let message: String
}

/// Runs a load and records the result. Leaving a screen mid-load isn't treated as an error.
@MainActor
func runLoad(_ state: Binding<LoadState>, _ work: () async throws -> Void) async {
    if case .failed = state.wrappedValue { state.wrappedValue = .loading }
    do {
        try await work()
        state.wrappedValue = .loaded
    } catch is CancellationError {
        return
    } catch let error as URLError where error.code == .cancelled {
        return
    } catch {
        state.wrappedValue = .failed(error.localizedDescription)
    }
}

struct LoadStateView: View {
    let state: LoadState
    let empty: EmptyState
    var skeleton: SkeletonStyle = .list
    let retry: () async -> Void

    var body: some View {
        switch state {
        case .loading:
            ScrollView {
                SkeletonView(style: skeleton)
            }
            .scrollDisabled(true)
            .background(Color(uiColor: .systemBackground))
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't load", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await retry() } }
                    .buttonStyle(.bordered)
            }
        case .loaded:
            ContentUnavailableView(empty.title, systemImage: empty.symbol, description: Text(empty.message))
        }
    }
}

extension View {
    /// When there's nothing to show yet: a spinner while loading, an error with Try Again, or an empty message.
    /// While loading, a skeleton in the shape of the screen's content; nothing ever just spins.
    func loadState(_ state: LoadState, isEmpty: Bool, empty: EmptyState, skeleton: SkeletonStyle = .list,
                   retry: @escaping () async -> Void) -> some View {
        modifier(LoadStateModifier(state: state, isEmpty: isEmpty, empty: empty, skeleton: skeleton, retry: retry))
    }
}

/// `loadState`, except offline: a failed load is not "Couldn't load, Try Again" (trying again can't help) but a plain note.
private struct LoadStateModifier: ViewModifier {
    let state: LoadState
    let isEmpty: Bool
    let empty: EmptyState
    let skeleton: SkeletonStyle
    let retry: () async -> Void
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content.overlay {
            if isEmpty {
                if app.connectivity.isOffline, case .failed = state {
                    ContentUnavailableView("You\u{2019}re offline", systemImage: "wifi.slash",
                                           description: Text("This needs your server. Your downloads are on Home."))
                        .background(Color(uiColor: .systemBackground))
                } else {
                    LoadStateView(state: state, empty: empty, skeleton: skeleton, retry: retry)
                }
            }
        }
    }
}

// MARK: - Artwork

enum ArtworkShape {
    case rounded(CGFloat)
    case circle

    var shape: AnyShape {
        switch self {
        case .rounded(let radius): return AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        case .circle: return AnyShape(Circle())
        }
    }
}

/// Cover art from your Jellyfin server.
struct ArtworkView: View {
    let itemId: String
    var pixels: Int = Theme.Pixels.tile
    var placeholder = "music.note"
    @Environment(AppModel.self) private var app

    var body: some View {
        RemoteArtwork(url: app.client?.imageURL(for: itemId, size: pixels), placeholder: placeholder)
    }
}

struct RemoteArtwork: View {
    let url: URL?
    var placeholder = "music.note"

    var body: some View {
        RemoteImage(url: url) { ArtworkPlaceholder(symbol: placeholder) }
    }
}

/// The one placeholder for any picture that is missing or still loading: a calm grey tile with the kind of thing in it (a note for
/// songs and albums, a microphone for artists, an antenna for stations). The symbol grows and shrinks with the tile.
struct ArtworkPlaceholder: View {
    let symbol: String

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(uiColor: .secondarySystemFill)
                Image(systemName: symbol)
                    .font(.system(size: min(geo.size.width, geo.size.height) * 0.36, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// A station's logo fills its tile like an album cover: no frame or colored background around it.
/// Only a station without a logo gets a soft card with an antenna.
struct StationArtwork: View {
    let station: Station

    var body: some View {
        RemoteImage(url: station.faviconURL, contentMode: .fill) {
            ArtworkPlaceholder(symbol: "dot.radiowaves.left.and.right")
        }
        .accessibilityHidden(true)
    }
}

/// Whatever is playing now: a song cover or a station logo.
struct NowPlayingArtwork: View {
    var pixels: Int = Theme.Pixels.hero
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.dj.isOnAir {
            DJArtwork()
        } else if let pending = app.player.pending {
            switch pending.artwork {
            case .item(let id): ArtworkView(itemId: id, pixels: pixels)
            case .dj: DJArtwork()
            case .symbol(let symbol):
                MixArtwork(symbol: symbol, colors: [Color.dial, Color(red: 0.36, green: 0.16, blue: 0.62)])
            }
        } else if let station = app.player.liveStation {
            StationArtwork(station: station)
        } else if let track = app.player.current {
            ArtworkView(itemId: track.imageItemId, pixels: pixels)
        } else {
            ArtworkPlaceholder(symbol: "music.note")
        }
    }
}

/// The expanded player's cover: a song from the library shows in its album's jewel case; stations, the DJ
/// and anything still loading keep the flat cover.
struct NowPlayingCover: View {
    /// Lifts the flat cover's shadow while playing.
    var lifted = true
    @Environment(AppModel.self) private var app

    var body: some View {
        if !app.dj.isOnAir, app.player.pending == nil, app.player.liveStation == nil,
           let albumId = app.player.current?.albumId {
            JewelCase(itemId: albumId) { ArtworkView(itemId: albumId, pixels: Theme.Pixels.hero) }
        } else {
            NowPlayingArtwork()
                .squareArtwork(.rounded(Theme.Radius.hero))
                .playerArtworkShadow(lifted: lifted)
        }
    }
}

extension View {
    /// Square artwork that fills the available width.
    func squareArtwork(_ shape: ArtworkShape = .rounded(Theme.Radius.tile)) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { self }
            .clipShape(shape.shape)
    }

    /// Fixed-size artwork for rows and headers.
    func artworkFrame(size: CGFloat, _ shape: ArtworkShape = .rounded(Theme.Radius.thumb)) -> some View {
        frame(width: size, height: size).clipShape(shape.shape)
    }
}

// MARK: - Rows

/// The one row layout used everywhere: artwork, a title, a subtitle, and optional details on the right.
struct MediaRow<Artwork: View, Accessory: View>: View {
    let title: String
    let subtitle: String?
    let highlighted: Bool
    let artworkSize: CGFloat
    let shape: ArtworkShape
    let artwork: Artwork
    let accessory: Accessory
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    init(title: String, subtitle: String? = nil, highlighted: Bool = false,
         artworkSize: CGFloat = Theme.Size.rowArtwork, shape: ArtworkShape = .rounded(Theme.Radius.thumb),
         @ViewBuilder artwork: () -> Artwork, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.highlighted = highlighted
        self.artworkSize = artworkSize
        self.shape = shape
        self.artwork = artwork()
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            artwork.artworkFrame(size: artworkSize * scale, shape)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(title)
                    .lineLimit(1)
                    .foregroundStyle(highlighted ? Color.dial : Color.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Spacing.s)
            accessory
        }
        // A Mac list gives rows almost no room above and below, so covers touch the lines between them.
        .padding(.vertical, Platform.isMac ? Theme.Spacing.xs : 0)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

extension MediaRow where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, highlighted: Bool = false,
         artworkSize: CGFloat = Theme.Size.rowArtwork, shape: ArtworkShape = .rounded(Theme.Radius.thumb),
         @ViewBuilder artwork: () -> Artwork) {
        self.init(title: title, subtitle: subtitle, highlighted: highlighted, artworkSize: artworkSize,
                  shape: shape, artwork: artwork, accessory: { EmptyView() })
    }
}

/// Animated bars shown next to whatever is playing.
struct PlayingIndicator: View {
    let isPlaying: Bool

    var body: some View {
        Image(systemName: "waveform")
            .foregroundStyle(Color.dial)
            .symbolEffect(.variableColor.iterative, isActive: isPlaying)
            .accessibilityLabel("Now playing")
    }
}

struct TrackRow: View {
    let track: BaseItem
    /// Album pages show track numbers instead of artwork.
    var numbered = false
    @Environment(AppModel.self) private var app

    private var isCurrent: Bool { app.player.current?.id == track.id }

    var body: some View {
        row
            .opacity(app.library.isHidden(track.id) ? 0.4 : 1)
            .accessibilityHint(app.library.isHidden(track.id) ? "Hidden: radio and mixes skip this song" : "")
    }

    private var row: some View {
        MediaRow(title: track.name, subtitle: track.artistLine, highlighted: isCurrent,
                 artworkSize: numbered ? Theme.Size.trackNumber : Theme.Size.rowArtwork) {
            if numbered {
                if isCurrent {
                    PlayingIndicator(isPlaying: app.player.isPlaying)
                } else {
                    Text(track.indexNumber.map { String($0) } ?? "")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                ArtworkView(itemId: track.imageItemId, pixels: Theme.Pixels.thumb)
                    .overlay {
                        if isCurrent {
                            ZStack {
                                Color.black.opacity(0.45)
                                PlayingIndicator(isPlaying: app.player.isPlaying)
                            }
                        }
                    }
            }
        } accessory: {
            HStack(spacing: Theme.Spacing.s) {
                if app.library.isFavorite(track.id) {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.dial)
                        .accessibilityLabel("Favorite")
                }
                if app.downloads.isDownloaded(track.id) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Downloaded")
                }
                if let duration = track.duration {
                    Text(formatTime(duration))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct AlbumRow: View {
    let album: BaseItem
    @Environment(AppModel.self) private var app

    var body: some View {
        MediaRow(title: album.name, subtitle: album.albumArtistLine) {
            ArtworkView(itemId: album.id, pixels: Theme.Pixels.thumb)
                .zoomSource(album.id)
        }
        .contextMenu {
            if let artist = album.primaryArtist {
                Button { app.navigator.open(.artist(id: artist.id, name: artist.name ?? "")) } label: {
                    Label("Go to Artist", systemImage: "music.mic")
                }
            }
        }
    }
}

struct ArtistRow: View {
    let artist: BaseItem

    var body: some View {
        MediaRow(title: ArtistNames.primary(artist.name), shape: .circle) {
            ArtworkView(itemId: artist.id, pixels: Theme.Pixels.thumb, placeholder: "music.mic")
        }
    }
}

struct PlaylistRow: View {
    let playlist: BaseItem

    private var count: String? {
        playlist.childCount.map { $0 == 1 ? "1 song" : "\($0) songs" }
    }

    var body: some View {
        MediaRow(title: playlist.name, subtitle: count) {
            ArtworkView(itemId: playlist.id, pixels: Theme.Pixels.thumb, placeholder: "music.note.list")
        }
    }
}

struct StationRow: View {
    let station: Station
    @Environment(AppModel.self) private var app

    private var isCurrent: Bool { app.player.liveStation?.id == station.id }

    var body: some View {
        MediaRow(title: station.name, subtitle: station.subtitle, highlighted: isCurrent,
                 artworkSize: Theme.Size.stationArtwork, shape: .rounded(Theme.Radius.tile)) {
            StationArtwork(station: station)
        } accessory: {
            if isCurrent {
                PlayingIndicator(isPlaying: app.player.isPlaying)
            } else if let bitrate = station.bitrate, bitrate > 0 {
                Text("\(bitrate) kbps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A row that opens another screen, with a chevron.
struct NavigationRow: View {
    let title: String
    let symbol: String
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: Theme.Spacing.l) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.dial)
                .frame(width: Theme.Size.trackNumber)
                .accessibilityHidden(true)
            Text(title).font(.title3)
            Spacer()
            if let trailing {
                Text(trailing).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, Theme.Spacing.m)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Rows with inset dividers, for screens that mix rows with shelves and grids.
struct RowStack<Data: RandomAccessCollection, Row: View>: View where Data.Element: Identifiable {
    let data: Data
    var dividerInset: CGFloat = Theme.Size.rowArtwork + Theme.Spacing.m + Theme.Spacing.l
    @ViewBuilder let row: (Data.Element) -> Row

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(data) { item in
                row(item)
                    .padding(.horizontal, Theme.Spacing.l)
                    .padding(.vertical, Theme.Spacing.xs)
                Divider().padding(.leading, dividerInset)
            }
        }
    }
}

// MARK: - Song lists

/// Songs inside a List: tap to play from that song, long-press for the song menu,
/// and optionally swipe to remove.
struct SongRows: View {
    let tracks: [BaseItem]
    /// The full list to play, when `tracks` is only part of it (one disc of an album, say).
    var queue: [BaseItem]? = nil
    var numbered = false
    /// Playlists and mixtapes play in the order they were made, not "like this song".
    var keepsOrder = false
    var showGoToAlbum = true
    var removeLabel = "Remove"
    var onRemove: ((BaseItem) -> Void)? = nil
    /// Lets the list be reordered (in edit mode): the song's place and where it goes.
    var onMove: ((IndexSet, Int) -> Void)? = nil
    /// What the list is (a mixtape, say), shown small in the mini player while it plays.
    var source: String? = nil
    @Environment(AppModel.self) private var app

    var body: some View {
        ForEach(tracks.filter { !app.library.deletedIds.contains($0.id) }, id: \.listId) { track in
            Button {
                if numbered || keepsOrder {
                    // Album tracks, playlists and mixtapes keep their order.
                    let list = queue ?? tracks
                    let start = list.firstIndex { $0.listId == track.listId } ?? 0
                    app.player.play(list, startAt: start, radio: true, source: source)
                } else {
                    app.player.playLike(track, source: source)
                }
            } label: {
                TrackRow(track: track, numbered: numbered)
            }
            .buttonStyle(.plain)
            .contextMenu {
                TrackMenu(track: track, showGoToAlbum: showGoToAlbum)
                if let onRemove {
                    Divider()
                    Button(role: .destructive) { onRemove(track) } label: { Label(removeLabel, systemImage: "minus.circle") }
                }
            }
            .swipeActions {
                if let onRemove {
                    Button(removeLabel, role: .destructive) { onRemove(track) }
                }
            }
        }
        .onMove(perform: onMove)
    }
}

/// The long-press menu for a song, identical everywhere in the app.
struct TrackMenu: View {
    let track: BaseItem
    var showGoToAlbum = true
    /// Replace the default sheets (used inside the full-screen player, which has its own).
    var onAddToPlaylist: (([BaseItem]) -> Void)? = nil
    var onShowInfo: ((BaseItem) -> Void)? = nil
    @Environment(AppModel.self) private var app

    var body: some View {
        Button {
            app.player.playNext([track])
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button {
            app.player.addToQueue([track])
        } label: {
            Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
        }
        Button {
            app.player.startRadio(from: track)
        } label: {
            Label("Start Radio", systemImage: "dot.radiowaves.left.and.right")
        }
        if app.library.isHidden(track.id) {
            Button {
                app.library.setHidden(track, false)
            } label: {
                Label("Allow This Song", systemImage: "eye")
            }
        } else {
            Button {
                app.library.setHidden(track, true)
            } label: {
                Label("Don\u{2019}t Play This Song", systemImage: "eye.slash")
            }
        }

        Divider()

        Button {
            if let onAddToPlaylist { onAddToPlaylist([track]) } else { app.navigator.addToPlaylist([track]) }
        } label: {
            Label("Add to Playlist…", systemImage: "text.badge.plus")
        }
        Button {
            if let onShowInfo { onShowInfo(track) } else { app.navigator.songInfo = track }
        } label: {
            Label("Song Info", systemImage: "info.circle")
        }
        FavoriteMenuItem(item: track, title: "Favorite")
        if app.downloads.isDownloaded(track.id) {
            Button(role: .destructive) {
                app.downloads.delete(track.id)
            } label: {
                Label("Remove Download", systemImage: "trash")
            }
        } else {
            Button {
                app.downloads.download([track])
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        }

        Divider()

        if showGoToAlbum, let albumId = track.albumId {
            Button {
                app.navigator.open(.album(id: albumId, name: track.album ?? ""))
            } label: {
                Label("Go to Album", systemImage: "square.stack")
            }
        }
        if app.library.canDelete {
            Divider()
            Button(role: .destructive) {
                // Let the menu finish closing first; a prompt raised while it is still closing can be dropped.
                Task {
                    // From the full player, close it first: the prompt belongs to the screen underneath.
                    if app.navigator.showNowPlaying { app.navigator.showNowPlaying = false; try? await Task.sleep(for: .milliseconds(600)) }
                    try? await Task.sleep(for: .milliseconds(400))
                    app.navigator.deletionRequest = track
                }
            } label: {
                Label("Delete from Server\u{2026}", systemImage: "trash")
            }
        }
        let credited = app.credits.credits(for: track)
        if credited.count > 1 {
            Menu {
                ForEach(credited, id: \.self) { name in
                    Button(name) { app.navigator.open(app.credits.route(for: name)) }
                }
            } label: {
                Label("Go to Artist", systemImage: "music.mic")
            }
        } else if let artist = track.primaryArtist {
            Button {
                app.navigator.open(.artist(id: artist.id, name: artist.name ?? ""))
            } label: {
                Label("Go to Artist", systemImage: "music.mic")
            }
        }
    }
}

struct FavoriteMenuItem: View {
    let item: BaseItem
    let title: String
    @Environment(AppModel.self) private var app

    var body: some View {
        Button {
            app.library.toggleFavorite(item)
        } label: {
            if app.library.isFavorite(item.id) {
                Label("Remove from Favorites", systemImage: "heart.slash")
            } else {
                Label(title, systemImage: "heart")
            }
        }
    }
}

// MARK: - Tiles, shelves and grids

/// Square (or round) artwork with a title and subtitle underneath.
struct MediaTile<Artwork: View>: View {
    let title: String
    let subtitle: String?
    let width: CGFloat?
    let circular: Bool
    /// Shows the artwork inside a CD jewel case; the id is the album, for the case's spine.
    let jewelCaseId: String?
    /// Shows the artwork in a CD jewel case whose spine uses this picture (for albums not in the library).
    var showsCase = false
    var jewelCaseURL: URL? = nil
    /// Greys the whole tile out, for albums you don't have.
    var muted = false
    let artwork: Artwork

    init(title: String, subtitle: String? = nil, width: CGFloat? = nil, circular: Bool = false,
         jewelCaseId: String? = nil, showsCase: Bool = false, jewelCaseURL: URL? = nil, muted: Bool = false,
         @ViewBuilder artwork: () -> Artwork) {
        self.title = title
        self.subtitle = subtitle
        self.width = width
        self.circular = circular
        self.jewelCaseId = jewelCaseId
        self.showsCase = showsCase
        self.jewelCaseURL = jewelCaseURL
        self.muted = muted
        self.artwork = artwork()
    }

    var body: some View {
        VStack(alignment: circular ? .center : .leading, spacing: Theme.Spacing.xs) {
            Group {
                if let jewelCaseId {
                    JewelCase(itemId: jewelCaseId) { artwork }
                } else if showsCase {
                    JewelCase(trayURL: jewelCaseURL) { artwork }
                } else {
                    artwork.squareArtwork(circular ? .circle : .rounded(Theme.Radius.tile))
                }
            }
            .grayscale(muted ? 1 : 0)
            .opacity(muted ? 0.45 : 1)
            .padding(.bottom, Theme.Spacing.xxs)
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: circular ? .center : .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Any station as a tile: the DJ, a live station, or a radio from the library. Tapping plays it.
struct RecentStationTile: View {
    let station: RecentStation
    var list: [Station] = []
    /// nil fills the space it's given, for grids.
    var width: CGFloat? = Theme.Size.shelfTile
    @Environment(AppModel.self) private var app

    var body: some View {
        Button { app.play(station, in: list) } label: {
            switch station {
            case .dj:
                MediaTile(title: app.dj.name, subtitle: app.dj.isActive ? "On air" : "Your DJ", width: width) {
                    DJArtwork()
                }
            case .live(let live):
                MediaTile(title: live.name, subtitle: "Live radio", width: width) {
                    StationArtwork(station: live)
                }
            case .yourMix:
                MediaTile(title: "Your Mix", subtitle: "Your whole library", width: width) {
                    MixArtwork(symbol: "dot.radiowaves.left.and.right",
                               colors: [Color.dial, Color(red: 0.36, green: 0.16, blue: 0.62)])
                }
            case .favoritesMix:
                MediaTile(title: "Favorites Mix", subtitle: "Songs you love, and more like them", width: width) {
                    MixArtwork(symbol: "heart.fill",
                               colors: [Color(red: 0.85, green: 0.25, blue: 0.4), Color(red: 0.5, green: 0.15, blue: 0.45)])
                }
            case .artist(let id, let name):
                MediaTile(title: name, subtitle: "Artist radio", width: width, circular: true) {
                    ArtworkView(itemId: id, placeholder: "music.mic")
                }
            case .genre(_, let name):
                MediaTile(title: name, subtitle: "Genre radio", width: width) {
                    MixArtwork(symbol: "guitars", colors: [Color(red: 0.25, green: 0.3, blue: 0.5), Color(red: 0.12, green: 0.14, blue: 0.25)])
                }
            case .mood(let id):
                let mood = SoundMood.all.first { $0.id == id }
                MediaTile(title: mood?.title ?? "Mood", subtitle: "Mood station", width: width) {
                    MixArtwork(symbol: mood?.symbol ?? "waveform", colors: mood?.gradient ?? [Color.dial, Color.dial.opacity(0.6)])
                }
            case .yourSound:
                MediaTile(title: "Your Sound", subtitle: "Matches what you play most", width: width) {
                    MixArtwork(symbol: "waveform", colors: [Color(red: 0.2, green: 0.55, blue: 0.5), Color(red: 0.1, green: 0.2, blue: 0.35)])
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if case .live(let live) = station { SaveStationMenuItem(station: live) }
        }
    }
}

/// Gradient artwork with a symbol, for stations that have no cover.
struct MixArtwork: View {
    let symbol: String
    let colors: [Color]

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: symbol)
                .font(.title.weight(.semibold))
                .foregroundStyle(.white.opacity(0.95))
                .padding(Theme.Spacing.m)
                .accessibilityHidden(true)
        }
    }
}

/// The jewel case's plastic, drawn once and shared by every case.
private enum JewelCaseStyle {
    /// The clear plastic: one gradient for the hinge ridges, one for the glare, one stroke for the lit edge.
    static let hinge = LinearGradient(stops: [.init(color: .clear, location: 0),
                                                      .init(color: .white.opacity(0.55), location: 0.14),
                                                      .init(color: .black.opacity(0.28), location: 0.30),
                                                      .init(color: .white.opacity(0.32), location: 0.48),
                                                      .init(color: .black.opacity(0.22), location: 0.68),
                                                      .init(color: .white.opacity(0.5), location: 0.84),
                                                      .init(color: .clear, location: 1)],
                                              startPoint: .leading, endPoint: .trailing)
    static let glare = LinearGradient(stops: [.init(color: .white.opacity(0.06), location: 0),
                                                      .init(color: .clear, location: 0.16),
                                                      .init(color: .white.opacity(0.18), location: 0.29),
                                                      .init(color: .white.opacity(0.05), location: 0.41),
                                                      .init(color: .clear, location: 0.50),
                                                      .init(color: .clear, location: 0.63),
                                                      .init(color: .white.opacity(0.08), location: 0.67),
                                                      .init(color: .clear, location: 0.73)],
                                              startPoint: UnitPoint(x: 0, y: 0.35), endPoint: UnitPoint(x: 1, y: 0.65))
    static let litEdge = LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.15), .black.opacity(0.35)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing)
    static let spine = LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0),
                                                      .init(color: .black.opacity(0.2), location: 0.4),
                                                      .init(color: .black.opacity(0.3), location: 1)],
                                              startPoint: .leading, endPoint: .trailing)
}

/// An album cover inside a CD jewel case, shaped like a real one (142 × 125 mm): the tray card showing
/// through the spine, the ridged hinge, the lid's raised lip and the reflections on the clear plastic.
struct JewelCase<Cover: View>: View {
    /// The album, for the tray card: its cover, blurred, so every case gets a matching spine. Albums not in the
    /// library have no item, so their picture comes from `trayURL`.
    let itemId: String?
    let trayURL: URL?
    /// Mixtapes have no single album: the tray takes the mix's colours instead of a picture.
    var trayColors: [Color]? = nil
    let cover: Cover

    init(itemId: String? = nil, trayURL: URL? = nil, trayColors: [Color]? = nil, @ViewBuilder cover: () -> Cover) {
        self.itemId = itemId
        self.trayURL = trayURL
        self.trayColors = trayColors
        self.cover = cover()
    }

    static var aspectRatio: CGFloat { 142.0 / 125.0 }

    // Kept cheap for grids of hundreds: no blur, no blend modes, no shadows on images. The tray card is the
    // same cover image (already loaded and cached at the same size), zoomed and darkened; the tray and the
    // plastic are each flattened into one layer, and the shadow is drawn from a plain shape.
    var body: some View {
        Color.clear
            .aspectRatio(Self.aspectRatio, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    let w = geo.size.width, h = geo.size.height
                    let side = h * 0.956
                    ZStack(alignment: .topLeading) {
                        // The tray card behind the spine and edges, flattened into one layer.
                        ZStack(alignment: .topLeading) {
                            // The cover, blurred: the tray card seen through the plastic.
                            Group {
                                if let trayColors {
                                    LinearGradient(colors: trayColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                                } else if let itemId {
                                    ArtworkView(itemId: itemId, pixels: Theme.Pixels.thumb)
                                } else {
                                    RemoteArtwork(url: trayURL)
                                }
                            }
                            .frame(width: w * 1.2, height: h * 1.2)
                            .blur(radius: w * 0.03)
                                .offset(x: -w * 0.1, y: -h * 0.1)
                            JewelCaseStyle.spine.frame(width: w * 0.128, height: h)
                            Color.black.opacity(0.15)
                        }
                        .frame(width: w, height: h, alignment: .topLeading)
                        .clipped()
                        .drawingGroup()
                        // The booklet, square, under the lid (its own layer, so the page can zoom out of it).
                        cover
                            .frame(width: side, height: side)
                            .clipped()
                            .overlay { Rectangle().strokeBorder(.black.opacity(0.4), lineWidth: 0.5) }
                            .offset(x: w * 0.98 - side, y: (h - side) / 2)
                        // The plastic on top, flattened into one layer: the lid's edge along the spine, the
                        // hinge, the lid's raised lip, the glare and the lit outer edge.
                        ZStack(alignment: .topLeading) {
                            Rectangle().fill(.white.opacity(0.4)).frame(width: 1, height: h).offset(x: w * 0.014)
                            JewelCaseStyle.hinge.frame(width: w * 0.036, height: h).offset(x: w * 0.086)
                            RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(.white.opacity(0.28), lineWidth: 1)
                                .frame(width: w * (1 - 0.124 - 0.009), height: h * (1 - 0.022))
                                .offset(x: w * 0.124, y: h * 0.011)
                            JewelCaseStyle.glare
                            RoundedRectangle(cornerRadius: 3).strokeBorder(JewelCaseStyle.litEdge, lineWidth: 1)
                        }
                        .frame(width: w, height: h, alignment: .topLeading)
                        .drawingGroup()
                    }
                    .frame(width: w, height: h, alignment: .topLeading)
                }
            }
            .background(Color(white: 0.13))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .background {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.black.opacity(0.35))
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 4)
            }
    }
}

/// A song row with its "•••" menu, for scrolling song grids.
struct CompactSongRow: View {
    let track: BaseItem
    let queue: [BaseItem]
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Button {
                app.player.playLike(track)
            } label: {
                // Cover, title and artist only, like Apple Music's song shelves: no length, one menu.
                MediaRow(title: track.name, subtitle: track.artistLine, highlighted: app.player.current?.id == track.id) {
                    ArtworkView(itemId: track.imageItemId, pixels: Theme.Pixels.thumb)
                }
            }
            .buttonStyle(.plain)
            Menu {
                TrackMenu(track: track)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: Theme.Size.tapTarget, height: Theme.Size.tapTarget)
                    .contentShape(Rectangle())
            }
            .plainMenu()
            .accessibilityLabel("More for \(track.name)")
        }
        .contextMenu { TrackMenu(track: track) }
    }
}

struct AlbumTile: View {
    let title: String
    let subtitle: String
    let imageId: String
    var width: CGFloat? = nil
    /// The artist, so the tile's menu can open their page.
    var artist: NameId? = nil
    /// Shows the cover inside a CD jewel case.
    var jewelCase = true
    @Environment(AppModel.self) private var app

    var body: some View {
        MediaTile(title: title, subtitle: subtitle, width: width, jewelCaseId: jewelCase ? imageId : nil) {
            ArtworkView(itemId: imageId)
                .zoomSource(imageId)
        }
        .contextMenu {
            if let artist {
                Button { app.navigator.open(.artist(id: artist.id, name: artist.name ?? "")) } label: {
                    Label("Go to Artist", systemImage: "music.mic")
                }
            }
        }
    }
}

extension AlbumTile {
    init(album: BaseItem, width: CGFloat? = nil) {
        self.init(title: album.name, subtitle: album.albumArtistLine, imageId: album.id, width: width, artist: album.primaryArtist)
    }
}

/// A titled, horizontally scrolling row of tiles. With a route, the title gets a chevron
/// that opens the full list.
struct Shelf<Content: View>: View {
    let title: String
    var route: Route? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            if let route {
                LinkedSectionHeader(title: title, route: route)
            } else {
                SectionHeader(title)
            }
            HScroll {
                LazyHStack(alignment: .top, spacing: Theme.Spacing.m) {
                    content
                }
                .padding(.horizontal, Theme.Spacing.l)
            }
        }
    }
}

/// Albums in a two-column grid, each opening its album page.
struct AlbumGrid: View {
    let albums: [BaseItem]
    /// Shown under each title instead of the artist (artist pages show the year).
    var subtitle: ((BaseItem) -> String)? = nil
    /// Shows each cover inside a CD jewel case.
    var jewelCases = true

    private let columns = [GridItem(.adaptive(minimum: Theme.Size.gridTileMin), spacing: Theme.Spacing.l)]

    @Environment(AppModel.self) private var app

    var body: some View {
        LazyVGrid(columns: columns, spacing: Theme.Spacing.xl) {
            ForEach(albums.filter { !app.library.deletedIds.contains($0.id) }) { album in
                NavigationLink(value: Route.album(id: album.id, name: album.name)) {
                    AlbumTile(title: album.name, subtitle: subtitle?(album) ?? album.albumArtistLine, imageId: album.id,
                              jewelCase: jewelCases)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
    }
}

/// The big artwork, title and buttons at the top of album and playlist pages.
struct DetailHeader<Subtitle: View>: View {
    let imageId: String
    let placeholder: String
    let title: String
    let tracks: [BaseItem]
    /// Shows the cover as a CD jewel case (album pages).
    let jewelCase: Bool
    let subtitle: Subtitle

    init(imageId: String, placeholder: String = "music.note", title: String, tracks: [BaseItem],
         jewelCase: Bool = false, @ViewBuilder subtitle: () -> Subtitle) {
        self.imageId = imageId
        self.placeholder = placeholder
        self.title = title
        self.tracks = tracks
        self.jewelCase = jewelCase
        self.subtitle = subtitle()
    }

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .regular {
                // iPad and Mac: the cover on the left, the details beside it, like Apple Music.
                HStack(alignment: .bottom, spacing: Theme.Spacing.xl) {
                    artwork
                        .frame(width: Theme.Size.albumHeaderArtwork)
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        Text(title)
                            .font(.largeTitle.bold())
                            .lineLimit(3)
                            .accessibilityAddTraits(.isHeader)
                        subtitle
                            .multilineTextAlignment(.leading)
                        PlayShuffleButtons(tracks: tracks)
                            .frame(maxWidth: Theme.Size.formMaxWidth * 0.75)
                            .padding(.top, Theme.Spacing.m)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, Theme.Spacing.l)
            } else {
                VStack(spacing: Theme.Spacing.s) {
                    artwork
                        .padding(.horizontal, Theme.Size.heroInset)
                        .padding(.bottom, Theme.Spacing.s)
                    Text(title)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    subtitle
                    PlayShuffleButtons(tracks: tracks)
                        .padding(.top, Theme.Spacing.s)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.bottom, Theme.Spacing.xs)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    @ViewBuilder private var artwork: some View {
        if jewelCase {
            JewelCase(itemId: imageId) { ArtworkView(itemId: imageId, pixels: Theme.Pixels.hero) }
        } else {
            ArtworkView(itemId: imageId, pixels: Theme.Pixels.hero, placeholder: placeholder)
                .squareArtwork(.rounded(Theme.Radius.hero))
                .artworkShadow()
        }
    }
}

// MARK: - Buttons and headers

struct PillButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: Theme.Size.tapTarget)
                .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.dial)
    }
}

/// The app's main call-to-action button: amber, full width.
struct PrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.s) {
                if busy {
                    ProgressView().tint(.black)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: Theme.Size.tapTarget + Theme.Spacing.s)
            .background(Color.dial, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .foregroundStyle(.black)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// The look of every text field in the app.
    func inputField() -> some View {
        padding(.horizontal, Theme.Spacing.m)
            .frame(minHeight: Theme.Size.tapTarget + Theme.Spacing.s)
            .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}

/// An icon-only button with a proper tap target and a VoiceOver label.
struct IconButton: View {
    let symbol: String
    let label: String
    var font: Font = .title3
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(font)
                .frame(minWidth: Theme.Size.tapTarget, minHeight: Theme.Size.tapTarget)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Play and Shuffle, used at the top of albums, playlists, artists and song lists.
struct PlayShuffleButtons: View {
    let tracks: [BaseItem]
    var source: String? = nil
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            PillButton(title: "Play", systemImage: "play.fill") { app.player.play(tracks, source: source) }
            PillButton(title: "Shuffle", systemImage: "shuffle") { app.player.play(tracks, shuffle: true, source: source) }
        }
        .disabled(tracks.isEmpty)
        .opacity(tracks.isEmpty ? 0.5 : 1)
    }
}

struct SectionHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            trailing
        }
        .padding(.horizontal, Theme.Spacing.l)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// A section title with a chevron that opens the full list, like "Recently Played ›".
struct LinkedSectionHeader: View {
    let title: String
    let route: Route

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: Theme.Spacing.xs) {
                Text(title).font(.title3.weight(.semibold))
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.l)
        .accessibilityAddTraits(.isHeader)
        .accessibilityHint("Shows all")
    }
}

struct LiveBadge: View {
    var body: some View {
        Text("LIVE")
            .font(.caption2.weight(.heavy))
            .padding(.horizontal, Theme.Spacing.xs)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(Color.red, in: RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
            .foregroundStyle(.white)
            .accessibilityLabel("Live")
    }
}

// MARK: - Scrubber

/// An Apple Music style progress bar: thin while playing, thicker while you drag it.
struct ScrubberBar: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void
    @State private var dragFraction: Double? = nil
    @ScaledMetric(relativeTo: .caption) private var barHeight: CGFloat = Theme.Player.barHeight

    private var fraction: Double {
        dragFraction ?? (duration > 0 ? min(currentTime / duration, 1) : 0)
    }

    private var shownTime: TimeInterval { dragFraction.map { $0 * duration } ?? currentTime }
    private var dragging: Bool { dragFraction != nil }

    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(Theme.Player.trackOpacity))
                    Capsule()
                        .fill(.white.opacity(dragging ? 1 : Theme.Player.fillOpacity))
                        .frame(width: max(geo.size.width * fraction, 0))
                }
                .blendMode(.plusLighter)
                .frame(height: dragging ? barHeight * 1.8 : barHeight)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragFraction = min(max(value.location.x / max(geo.size.width, 1), 0), 1)
                        }
                        .onEnded { _ in
                            if let dragFraction { onSeek(dragFraction * duration) }
                            dragFraction = nil
                        }
                )
            }
            .frame(height: Theme.Spacing.xl)
            .animation(.easeOut(duration: 0.15), value: dragging)

            HStack {
                Text(formatTime(shownTime))
                Spacer()
                Text("-" + formatTime(max(duration - shownTime, 0)))
            }
            .font(.caption.monospacedDigit().weight(.medium))
            .playerSecondary()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(formatTime(currentTime)) of \(formatTime(duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek(min(currentTime + 10, duration))
            case .decrement: onSeek(max(currentTime - 10, 0))
            @unknown default: break
            }
        }
    }
}

// MARK: - Ratings, file details and descriptions

/// Five stars you can tap. Tapping the current rating again clears it.
struct StarRating: View {
    let item: BaseItem
    var size: Font = .subheadline
    var tint: Color = Color.dial
    @Environment(AppModel.self) private var app

    var body: some View {
        let rating = app.library.rating(for: item)
        HStack(spacing: Theme.Spacing.xs) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(size)
                    .foregroundStyle(star <= rating ? tint : tint.opacity(0.5))
                    .frame(minWidth: Theme.Size.tapTarget / 2, minHeight: Theme.Size.tapTarget)
                    .contentShape(Rectangle())
                    .onTapGesture { app.library.setRating(star == rating ? 0 : star, for: item) }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Rating")
        .accessibilityValue(rating == 0 ? "Not rated" : "\(rating) of 5 stars")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: app.library.setRating(min(rating + 1, 5), for: item)
            case .decrement: app.library.setRating(max(rating - 1, 0), for: item)
            @unknown default: break
            }
        }
    }
}

/// A small outlined label like "FLAC".
struct FormatBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, Theme.Spacing.xs)
            .padding(.vertical, Theme.Spacing.xxs)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous).stroke(lineWidth: 1))
    }
}

/// A description that shows a few lines and expands when tapped, like Apple Music's album notes.
struct ExpandableText: View {
    let text: String
    var lines = 3
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : lines)
            Button(expanded ? "Less" : "More") {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.dial)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A round artist tile that opens the artist's page (the same page as in Library).
struct ArtistTile: View {
    let artist: BaseItem
    var width: CGFloat? = Theme.Size.shelfTile

    var body: some View {
        NavigationLink(value: Route.artist(id: artist.id, name: artist.name)) {
            MediaTile(title: ArtistNames.primary(artist.name), width: width, circular: true) {
                ArtworkView(itemId: artist.id, placeholder: "music.mic")
            }
        }
        .buttonStyle(.plain)
    }
}

/// Everything known about a song: tags, file details, plays and your rating.
struct SongInfoSheet: View {
    let track: BaseItem
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var details: BaseItem? = nil

    private var item: BaseItem { details ?? track }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: Theme.Spacing.m) {
                        ArtworkView(itemId: item.imageItemId, pixels: Theme.Pixels.thumb)
                            .artworkFrame(size: Theme.Size.compactArtwork, .rounded(Theme.Radius.thumb))
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text(item.name).font(.headline)
                            Text(item.artistLine).foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Your Rating") { StarRating(item: item) }
                }
                Section("Song") {
                    row("Album", item.album)
                    row("Album Artist", item.albumArtistLine)
                    row("Year", item.year.map(String.init))
                    row("Genre", item.genres?.joined(separator: ", "))
                    row("Track", item.indexNumber.map(String.init))
                    row("Disc", item.parentIndexNumber.map(String.init))
                    row("Length", item.duration.map(formatTime))
                }
                Section("File") {
                    row("Format", item.formatLabel)
                    row("Quality", item.qualityLabel)
                    row("Channels", item.audioStream?.channels.map { $0 == 2 ? "Stereo" : $0 == 1 ? "Mono" : "\($0)" })
                    row("Size", item.mediaSources?.first?.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) })
                    row("Downloaded", app.downloads.isDownloaded(item.id) ? "Yes" : "No")
                }
                SignalPathSection(item: item)
                Section("Listening") {
                    row("Plays", item.userData?.playCount.map(String.init))
                    row("Last Played", item.userData?.lastPlayedDate.flatMap(Self.date))
                    row("Added", item.dateCreated.flatMap(Self.date))
                }
            }
            .navigationTitle("Song Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { details = try? await app.client?.details(track.id) }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(title, value: value)
        }
    }

    /// Jellyfin dates ("2024-05-01T12:00:00.0000000Z"), shown the way the iPhone shows dates.
    static func date(_ text: String) -> String? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withFullDate]
        return parser.date(from: String(text.prefix(10)))?.formatted(date: .abbreviated, time: .omitted)
    }
}

// MARK: - Skeletons (shown while content loads)

/// A soft light that sweeps across placeholder shapes while something loads.
struct Shimmer: ViewModifier {
    var active = true
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if active && !reduceMotion {
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, .white.opacity(0.35), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.5)
                            .offset(x: phase * geo.size.width * 1.5)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard active else { return }
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

extension View {
    func shimmering(_ active: Bool = true) -> some View {
        modifier(Shimmer(active: active))
    }
}

/// One placeholder shape.
struct SkeletonBlock: View {
    var width: CGFloat? = nil
    /// nil fills the height it's given.
    var height: CGFloat? = Theme.Spacing.m
    var radius: CGFloat = Theme.Radius.badge

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color(uiColor: .tertiarySystemFill))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, maxHeight: height == nil ? .infinity : nil, alignment: .leading)
    }
}

/// The shape of a song or album row while it loads.
struct SkeletonRow: View {
    var circular = false

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            SkeletonBlock(width: Theme.Size.rowArtwork, height: Theme.Size.rowArtwork,
                          radius: circular ? Theme.Size.rowArtwork / 2 : Theme.Radius.thumb)
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                SkeletonBlock(width: Theme.Size.shelfTile * 1.2)
                SkeletonBlock(width: Theme.Size.shelfTile * 0.8, height: Theme.Spacing.s + Theme.Spacing.xxs)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The shape of a tile while it loads.
struct SkeletonTile: View {
    var width: CGFloat? = nil
    var circular = false

    var body: some View {
        VStack(alignment: circular ? .center : .leading, spacing: Theme.Spacing.s) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { SkeletonBlock(height: nil, radius: 0) }
                .clipShape(circular ? AnyShape(Circle()) : AnyShape(.rounded(Theme.Radius.tile)))
            SkeletonBlock(width: (width ?? Theme.Size.shelfTile) * 0.7)
            SkeletonBlock(width: (width ?? Theme.Size.shelfTile) * 0.45, height: Theme.Spacing.s + Theme.Spacing.xxs)
        }
        .frame(width: width)
    }
}

/// Which skeleton a screen shows while its content loads.
enum SkeletonStyle {
    case list, circleList, grid, circleGrid, home, lines
    /// Search results: a shelf of circles, a shelf of covers, then song rows.
    case search
    /// Library search: category headers, each over a few rows (like the results list).
    case librarySearch
}

/// The sweep over a skeleton, or nothing.
private struct SkeletonMotion: ViewModifier {
    let moving: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if moving { content.shimmering() } else { content }
    }
}

struct SkeletonView: View {
    let style: SkeletonStyle

    private let twoColumns = [GridItem(.adaptive(minimum: Theme.Size.gridTileMin), spacing: Theme.Spacing.l)]
    private let threeColumns = [GridItem(.adaptive(minimum: Theme.Size.gridTileMin * 0.66), spacing: Theme.Spacing.l)]

    var body: some View {
        Group {
            switch style {
            case .list, .circleList:
                VStack(spacing: Theme.Spacing.l) {
                    ForEach(0..<9, id: \.self) { _ in SkeletonRow(circular: style == .circleList) }
                }
                .padding(Theme.Spacing.l)
            case .grid:
                LazyVGrid(columns: twoColumns, spacing: Theme.Spacing.xl) {
                    ForEach(0..<6, id: \.self) { _ in SkeletonTile() }
                }
                .padding(Theme.Spacing.l)
            case .circleGrid:
                LazyVGrid(columns: threeColumns, spacing: Theme.Spacing.xl) {
                    ForEach(0..<9, id: \.self) { _ in SkeletonTile(circular: true) }
                }
                .padding(Theme.Spacing.l)
            case .home:
                VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                    SkeletonBlock(height: nil, radius: Theme.Radius.hero)
                        .aspectRatio(16 / 9, contentMode: .fit)
                    VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                        SkeletonBlock(width: Theme.Size.shelfTile, height: Theme.Spacing.l + Theme.Spacing.xs)
                        ForEach(0..<4, id: \.self) { _ in SkeletonRow() }
                    }
                    // In a fixed horizontal scroll view, so the tiles run past the edge without widening the page.
                    HScroll {
                        HStack(spacing: Theme.Spacing.m) {
                            ForEach(0..<3, id: \.self) { _ in SkeletonTile(width: Theme.Size.shelfTile) }
                        }
                    }
                    .scrollDisabled(true)
                }
                .padding(Theme.Spacing.l)
            case .search:
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    SkeletonBlock(width: Theme.Size.shelfTile * 0.7, height: Theme.Spacing.l + Theme.Spacing.xs)
                    HScroll {
                        HStack(alignment: .top, spacing: Theme.Spacing.m) {
                            ForEach(0..<4, id: \.self) { _ in SkeletonTile(width: 110, circular: true).frame(width: 110) }
                        }
                    }
                    .scrollDisabled(true)
                    SkeletonBlock(width: Theme.Size.shelfTile * 0.7, height: Theme.Spacing.l + Theme.Spacing.xs)
                    HScroll {
                        HStack(alignment: .top, spacing: Theme.Spacing.m) {
                            ForEach(0..<3, id: \.self) { _ in SkeletonTile(width: 140).frame(width: 140) }
                        }
                    }
                    .scrollDisabled(true)
                    SkeletonBlock(width: Theme.Size.shelfTile * 0.5, height: Theme.Spacing.l + Theme.Spacing.xs)
                    ForEach(0..<3, id: \.self) { _ in SkeletonRow() }
                }
                .padding(Theme.Spacing.l)
            case .librarySearch:
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    SkeletonBlock(width: Theme.Size.shelfTile * 0.5, height: Theme.Spacing.l + Theme.Spacing.xs)
                    ForEach(0..<3, id: \.self) { _ in SkeletonRow(circular: true) }
                    SkeletonBlock(width: Theme.Size.shelfTile * 0.5, height: Theme.Spacing.l + Theme.Spacing.xs)
                    ForEach(0..<4, id: \.self) { _ in SkeletonRow() }
                }
                .padding(Theme.Spacing.l)
            case .lines:
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    ForEach(0..<8, id: \.self) { index in
                        SkeletonBlock(width: index % 3 == 0 ? Theme.Size.shelfTile * 1.4 : nil, height: Theme.Spacing.l + Theme.Spacing.xs)
                    }
                }
                .padding(.vertical, Theme.Spacing.section)
            }
        }
        .modifier(SkeletonMotion(moving: style != .search)) // search results sit still
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }
}

// MARK: - Offline

/// Shown at the top of Home, Library and Search when the server can't be reached: one quiet line, not a card.
struct OfflineBanner: View {
    @Environment(AppModel.self) private var app
    @State private var checking = false

    private var detail: String {
        var parts: [String] = [app.downloads.records.isEmpty ? "nothing downloaded" : "playing your downloads"]
        if app.playLog.pending > 0 { parts.append("\(app.playLog.pending) \(app.playLog.pending == 1 ? "play" : "plays") to sync") }
        return parts.joined(separator: " \u{00B7} ")
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "wifi.slash")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.dial)
                .accessibilityHidden(true)
            (Text("Offline").fontWeight(.semibold) + Text(" \u{00B7} \(detail)").foregroundStyle(.secondary))
                .font(.subheadline)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: Theme.Spacing.s)
            Button {
                Task {
                    checking = true
                    await app.connectivity.check()
                    checking = false
                }
            } label: {
                if checking { ProgressView().controlSize(.small) } else { Text("Retry").font(.subheadline.weight(.semibold)) }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.dial)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
        .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
        .padding(.horizontal, Theme.Spacing.l)
        .accessibilityElement(children: .combine)
    }
}

/// Covers a screen that only works with a connection (live radio, Discovery) while the server can't be reached.
struct OfflineCover: ViewModifier {
    @Environment(AppModel.self) private var app
    let title: String
    let message: String

    func body(content: Content) -> some View {
        content.overlay {
            if app.connectivity.isOffline {
                VStack(spacing: Theme.Spacing.m) {
                    OfflineBanner().padding(.top, Theme.Spacing.l)
                    Spacer()
                    ContentUnavailableView(title, systemImage: "wifi.slash", description: Text(message))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemBackground))
            }
        }
    }
}

extension View {
    func offlineCover(_ title: String, _ message: String) -> some View { modifier(OfflineCover(title: title, message: message)) }
}

/// Your downloaded music, for Home while offline.
struct DownloadedSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let songs = app.downloads.downloadedSongs
        if !songs.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                LinkedSectionHeader(title: "Downloaded", route: .library(.downloaded))
                PlayShuffleButtons(tracks: songs)
                    .padding(.horizontal, Theme.Spacing.l)
                SongGrid(tracks: Array(songs.prefix(16)))
            }
        }
    }
}

// MARK: - Zoom into albums (iOS 18 and later)

private struct ZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    /// Shared by an album's cover and its page, so the page grows out of the cover you tapped.
    var zoomNamespace: Namespace.ID? {
        get { self[ZoomNamespaceKey.self] }
        set { self[ZoomNamespaceKey.self] = newValue }
    }
}

/// Wraps a navigation stack's root so its album covers can zoom into album pages.
struct ZoomScope<Content: View>: View {
    @Namespace private var namespace
    @ViewBuilder let content: Content

    var body: some View {
        content.environment(\.zoomNamespace, namespace)
    }
}

private struct ZoomSource: ViewModifier {
    let id: String
    @Environment(\.zoomNamespace) private var namespace

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let namespace {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}

private struct ZoomDestination: ViewModifier {
    let id: String
    @Environment(\.zoomNamespace) private var namespace

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let namespace {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
    }
}

extension View {
    /// Marks an album cover as the place its page zooms out of.
    func zoomSource(_ id: String) -> some View { modifier(ZoomSource(id: id)) }
    /// Makes a page zoom out of the cover marked with the same id.
    func zoomDestination(_ id: String) -> some View { modifier(ZoomDestination(id: id)) }
}

// MARK: - Signal path

/// How a song gets from the file on your server to your ears, step by step:
/// the file, how it's delivered, the equalizer and leveling, and where the sound comes out.
struct SignalPathSection: View {
    let item: BaseItem
    @Environment(AppModel.self) private var app

    private struct Step: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let detail: String
        var highlight = false
    }

    private var isPlayingHere: Bool { app.player.current?.id == item.id && !app.player.isRemote && !app.player.isLive }

    private var steps: [Step] {
        var steps: [Step] = []
        let format = [item.formatLabel, item.qualityLabel].compactMap { $0 }.joined(separator: ", ")
        steps.append(Step(symbol: "externaldrive.fill", title: "Source", detail: format.isEmpty ? "File on your server" : "\(format) on your server",
                          highlight: item.isLossless))

        let delivery: String
        if app.downloads.isDownloaded(item.id) {
            delivery = "Downloaded file, played from this \(Platform.deviceKind)"
        } else if isPlayingHere && app.player.playMethod == "Transcode" || (!isPlayingHere && app.player.qualityLimit != nil) {
            delivery = "Converted by your server to \(app.player.qualityLimit.map { "\($0 / 1000) kbps" } ?? "a compressed format")"
        } else {
            delivery = item.isLossless ? "Streamed bit for bit, as stored" : "Streamed as stored"
        }
        steps.append(Step(symbol: "arrow.down.circle.fill", title: "Delivery", detail: delivery))

        let eq = app.equalizer
        steps.append(Step(symbol: "slider.vertical.3", title: "Equalizer",
                          detail: eq.isEnabled ? (eq.presetName ?? "Custom") : "Off"))
        let leveling = app.settings.volumeLeveling ? app.player.levelingDecibels(for: item) : 0
        steps.append(Step(symbol: "speaker.wave.2.fill", title: "Volume Leveling",
                          detail: app.settings.volumeLeveling
                            ? (abs(leveling) < 0.1 ? "On, no change for this song" : String(format: "On, %.1f dB", leveling))
                            : "Off"))
        if app.player.crossfadeLength > 0 {
            steps.append(Step(symbol: "wave.3.right", title: "Crossfade", detail: "\(Int(app.player.crossfadeLength)) seconds"))
        }

        if app.player.isRemote, let device = app.player.outputName {
            steps.append(Step(symbol: "hifispeaker.fill", title: "Output", detail: "Playing on \(device)"))
        } else {
            let session = AVAudioSession.sharedInstance()
            let output = session.currentRoute.outputs.first
            let rate = String(format: "%.1f kHz", session.sampleRate / 1000).replacingOccurrences(of: ".0 kHz", with: " kHz")
            let kind: String
            switch output?.portType {
            case .bluetoothA2DP?: kind = "Bluetooth (AAC)"
            case .bluetoothLE?: kind = "Bluetooth LE"
            case .airPlay?: kind = "AirPlay"
            case .headphones?: kind = "Wired headphones"
            case .usbAudio?: kind = "USB audio"
            case .HDMI?: kind = "HDMI"
            case .carAudio?: kind = "CarPlay"
            case .builtInSpeaker?: kind = "Built-in speaker"
            default: kind = output?.portName ?? "Speaker"
            }
            let name = output.map { $0.portName != kind ? "\($0.portName), " : "" } ?? ""
            steps.append(Step(symbol: "headphones", title: "Output", detail: "\(name)\(kind), \(rate)"))
        }
        return steps
    }

    var body: some View {
        Section {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                HStack(alignment: .top, spacing: Theme.Spacing.m) {
                    VStack(spacing: 0) {
                        Image(systemName: step.symbol)
                            .font(.footnote)
                            .foregroundStyle(step.highlight ? Color.dial : Color.secondary)
                            .frame(width: Theme.Size.tapTarget * 0.6, height: Theme.Size.tapTarget * 0.6)
                            .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                    }
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(step.title).font(.subheadline.weight(.semibold))
                        Text(step.detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if index < steps.count - 1 {
                        Image(systemName: "arrow.down").font(.caption2).foregroundStyle(.tertiary).accessibilityHidden(true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Signal Path")
        } footer: {
            Text(isPlayingHere || app.downloads.isDownloaded(item.id)
                 ? "From the file on your server to where you hear it."
                 : "How this song plays with your current settings.")
        }
    }
}

extension BaseItem {
    /// FLAC, ALAC, WAV and similar files that keep every bit of the original.
    var isLossless: Bool {
        guard let format = formatLabel?.lowercased() else { return false }
        return ["flac", "alac", "wav", "aiff", "aif", "ape", "wv", "dsf", "dff"].contains(format)
    }
}

extension View {
    /// A menu that looks like a plain icon on every platform (on the Mac, menus otherwise get a box and a chevron).
    func plainMenu() -> some View {
        self.menuIndicator(.hidden).menuStyle(.button).buttonStyle(.borderless)
    }
}

// MARK: - Sideways rows that work with a mouse

/// A row that scrolls sideways. With a mouse or trackpad (Mac, iPad), arrows appear at the ends on hover and move a
/// page at a time, and you can click and drag the row. With touch it's a normal swipe.
struct HScroll<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var scroller = ScrollerHandle()
    @State private var hovering = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            content.background(ScrollViewFinder(handle: scroller))
        }
        .overlay(alignment: .leading) { arrow(.backward) }
        .overlay(alignment: .trailing) { arrow(.forward) }
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
    }

    private enum Direction { case backward, forward }

    @ViewBuilder
    private func arrow(_ direction: Direction) -> some View {
        let possible = direction == .backward ? scroller.canGoBack : scroller.canGoForward
        if hovering && possible {
            Button {
                scroller.page(direction == .forward ? 1 : -1)
            } label: {
                Image(systemName: direction == .forward ? "chevron.right" : "chevron.left")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: Theme.Size.tapTarget * 0.8, height: Theme.Size.tapTarget * 0.8)
                    .background(.regularMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Theme.Spacing.s)
            .transition(.opacity)
            .accessibilityLabel(direction == .forward ? "Scroll right" : "Scroll left")
        }
    }
}

/// Holds the row's scroll view, to move it a page and to know whether there's more on either side.
@Observable
final class ScrollerHandle {
    @ObservationIgnored weak var scrollView: UIScrollView?
    var canGoBack = false
    var canGoForward = false
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var sizeObservation: NSKeyValueObservation?

    func attach(_ view: UIScrollView) {
        guard scrollView !== view else { return }
        scrollView = view
        // Click and drag with a mouse, not just swipe with a finger or two fingers on a trackpad.
        view.panGestureRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.indirect.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
        ]
        observation = view.observe(\.contentOffset, options: [.initial, .new]) { [weak self] view, _ in
            DispatchQueue.main.async { self?.update(view) }
        }
        sizeObservation = view.observe(\.contentSize, options: [.new]) { [weak self] view, _ in
            DispatchQueue.main.async { self?.update(view) }
        }
    }

    private func update(_ view: UIScrollView) {
        let maxX = view.contentSize.width - view.bounds.width + view.adjustedContentInset.right
        let back = view.contentOffset.x > -view.adjustedContentInset.left + 1
        let forward = view.contentOffset.x < maxX - 1
        if back != canGoBack { canGoBack = back }
        if forward != canGoForward { canGoForward = forward }
    }

    /// Moves most of a screen's width, so the last item stays in view for context.
    func page(_ direction: CGFloat) {
        guard let view = scrollView else { return }
        let minX = -view.adjustedContentInset.left
        let maxX = max(view.contentSize.width - view.bounds.width + view.adjustedContentInset.right, minX)
        let target = min(max(view.contentOffset.x + direction * view.bounds.width * 0.85, minX), maxX)
        view.setContentOffset(CGPoint(x: target, y: view.contentOffset.y), animated: true)
    }
}

/// Finds the UIScrollView SwiftUI uses for a ScrollView, from inside its content.
private struct ScrollViewFinder: UIViewRepresentable {
    let handle: ScrollerHandle

    func makeUIView(context: Context) -> FinderView { FinderView(handle: handle) }
    func updateUIView(_ view: FinderView, context: Context) { view.find() }

    final class FinderView: UIView {
        let handle: ScrollerHandle
        init(handle: ScrollerHandle) {
            self.handle = handle
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }
        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            find()
        }

        func find() {
            var view = superview
            while let current = view {
                if let scroll = current as? UIScrollView {
                    handle.attach(scroll)
                    return
                }
                view = current.superview
            }
        }
    }
}


// MARK: - Wishlist

/// "Add to Wishlist" (or "Remove from Wishlist") in the menu of an album or song you don't have. Needs the Dial plugin,
/// which keeps the list.
struct WishlistButton: View {
    let item: WishItem
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.hasPlugin {
            let on = app.wishlist.contains(item.id)
            Button {
                Task { await app.wishlist.toggle(item, client: app.client) }
            } label: {
                Label(on ? "Remove from Wishlist" : "Add to Wishlist", systemImage: on ? "bookmark.slash" : "bookmark")
            }
        }
    }
}

// MARK: - Scrolling text

/// One line of text that fits stays as it is (and centered, if its parent centers it). A line that is too long for the room slowly
/// scrolls to its end, waits, and comes back, like the title in a music player. `id` restarts it when the text changes.
private struct MarqueeText: ViewModifier {
    let id: AnyHashable
    @State private var contentWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    func body(content: Content) -> some View {
        ViewThatFits(in: .horizontal) {
            content.lineLimit(1).fixedSize(horizontal: true, vertical: false)
            // The hidden copy (cut to the room, so it never widens its parent) gives the box its height; the visible one scrolls inside it.
            content.lineLimit(1)
                .hidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    GeometryReader { box in
                        content.lineLimit(1).fixedSize(horizontal: true, vertical: false)
                            .background(GeometryReader { inner in
                                Color.clear.onAppear { contentWidth = inner.size.width; boxWidth = box.size.width }
                                    .onChange(of: inner.size.width) { _, now in contentWidth = now }
                            })
                            .offset(x: offset)
                            .task(id: "\(id.hashValue)-\(Int(contentWidth))-\(Int(box.size.width))") { await scroll(box.size.width) }
                    }
                }
                .clipShape(Rectangle())
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
        }
    }

    private func scroll(_ box: CGFloat) async {
        offset = 0
        let distance = contentWidth - box + 16
        guard distance > 1, contentWidth > 0 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
            let seconds = max(distance / 28, 1.5)
            withAnimation(.linear(duration: seconds)) { offset = -distance }
            try? await Task.sleep(for: .seconds(seconds + 1.5))
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: 0.6)) { offset = 0 }
            try? await Task.sleep(for: .seconds(0.6))
        }
    }
}

extension View {
    /// Scrolls a one-line text sideways when it is too long to fit (see `MarqueeText`).
    func marquee(id: some Hashable) -> some View { modifier(MarqueeText(id: AnyHashable(id))) }
}
