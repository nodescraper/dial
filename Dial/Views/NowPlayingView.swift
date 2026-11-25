import AVKit
import SwiftUI

/// The full-screen player. Apple Music's look (a background tinted from the cover, thin bars,
/// white controls) with Plexamp's order: artwork, progress, the song and its details, the file's
/// format and your rating, then the controls.
struct NowPlayingView: View {
    enum Panel { case artwork, lyrics, queue }

    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var panel: Panel = .artwork
    @State private var playlistRequest: PlaylistRequest? = nil
    @State private var songInfo: BaseItem? = nil
    @State private var showingDJRequest = false
    @State private var showingDevices = false
    @State private var showingEqualizer = false
    /// Full details of the current song (file format, rating, whether it has lyrics).
    @State private var details: BaseItem? = nil
    @ScaledMetric(relativeTo: .largeTitle) private var playSize: CGFloat = Theme.Player.playSize
    @ScaledMetric(relativeTo: .title) private var skipSize: CGFloat = Theme.Player.skipSize

    private var player: Player { app.player }

    /// The full player always keeps one column; on iPad and Mac the side panel in the main window is the split view.
    private let isSplit = false

    var body: some View {
        Group {
            if isSplit {
                HStack(spacing: Theme.Spacing.section) {
                    playerColumn(inlinePanel: false)
                        .frame(maxWidth: Theme.Size.playerMaxWidth)
                    if panel != .artwork && player.hasContent {
                        sidePanel
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, Theme.Spacing.section)
                .padding(.bottom, Theme.Spacing.s)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.spring(duration: 0.4, bounce: 0.15), value: panel)
            } else {
                playerColumn(inlinePanel: true)
                    .padding(.horizontal, Theme.Player.margin)
                    .padding(.bottom, Theme.Spacing.s)
                    .frame(maxWidth: Theme.Size.playerMaxWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Escape (or ⌘W on the Mac) closes the player, as swiping down does on iPhone.
        .background {
            Button("Close Player", action: close)
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
        // A background never changes the layout, so artwork can't push content off screen.
        .background { PlayerBackground() }
        .overlay(alignment: .topTrailing) {
            // The Mac has no swipe down: a close button in the window's corner.
            if Platform.isMac {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: Theme.Size.tapTarget, height: Theme.Size.tapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .playerSecondary()
                .padding(.trailing, Theme.Spacing.l)
                .accessibilityLabel("Close player")
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .sheet(item: $playlistRequest) { request in
            AddToPlaylistSheet(tracks: request.tracks).environment(app)
        }
        .sheet(item: $songInfo) { track in
            SongInfoSheet(track: track).environment(app)
        }
        .sheet(isPresented: $showingDJRequest) {
            NavigationStack { DJRequestView(showsDoneButton: true) }
                .environment(app)
        }
        .sheet(isPresented: $showingDevices) {
            DevicesSheet().environment(app)
        }
        .sheet(isPresented: $showingEqualizer) {
            NavigationStack { EqualizerView(showsDoneButton: true) }
                .environment(app)
        }
        .animation(.easeInOut(duration: 0.4), value: app.dj.isOnAir)
        .task(id: player.current?.id) {
            details = nil
            guard let id = player.current?.id else { return }
            details = try? await app.client?.details(id)
        }
        .onChange(of: player.isLive) { _, live in
            if live && panel == .lyrics { panel = .artwork }
        }
        .accessibilityAction(.escape) { close() }
        .onAppear { setWindowTitle(player.current.map { "\($0.name) \u{2014} \($0.artistLine)" } ?? "") }
        .onChange(of: player.current?.id) { _, _ in setWindowTitle(player.current.map { "\($0.name) \u{2014} \($0.artistLine)" } ?? "") }
        .onDisappear { setWindowTitle(nil) }
    }

    /// On the Mac the title bar would otherwise keep naming the page behind the player ("Home", "Radio").
    private func setWindowTitle(_ title: String?) {
        #if targetEnvironment(macCatalyst)
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.titlebar?.titleVisibility = title == nil ? .visible : .hidden
        }
        #endif
    }

    private func close() {
        app.navigator.showNowPlaying = false
    }

    /// The player itself. On iPhone lyrics and the queue replace the cover (`inlinePanel`); on iPad and Mac
    /// the cover stays and they open beside it.
    private func playerColumn(inlinePanel: Bool) -> some View {
        if (Platform.isMac || sizeClass == .regular), player.hasContent, panel == .artwork, !app.dj.isOnAir {
            return AnyView(centeredColumn)
        }
        return AnyView(standardColumn(inlinePanel: inlinePanel))
    }

    /// Mac and iPad: the cover sits in the middle of the window, and the song, progress and controls sit
    /// halfway between the cover and the row of buttons at the bottom.
    private var centeredColumn: some View {
        GeometryReader { geo in
            let height = geo.size.height
            // The controls and the button row need about this much; the cover gets everything above them.
            let lowerNeeded: CGFloat = 340
            let top: CGFloat = 56
            let upper = max(height - top - lowerNeeded, 160)
            let side = max(140, min(geo.size.width - 2 * Theme.Player.margin, upper - Theme.Spacing.l, 680))
            let centerY = top + upper / 2
            let lower = max(height - (centerY + side / 2), lowerNeeded - 40)
            ZStack(alignment: .top) {
                NowPlayingCover(lifted: player.isPlaying)
                    .scaleEffect(player.isPlaying ? 1 : Theme.Player.pausedArtworkScale)
                    .animation(.spring(duration: 0.5, bounce: 0.2), value: player.isPlaying)
                    .frame(width: side, height: side)
                    .position(x: geo.size.width / 2, y: centerY)
                grabber
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    VStack(spacing: 0) {
                        NowPlayingDetails(details: details)
                        // The controls, then the progress bar under them.
                        VStack(spacing: Theme.Spacing.l) {
                            controls
                            if !player.isLive { PlayerScrubber() }
                        }
                        .padding(.top, Theme.Spacing.xl)
                    }
                    Spacer(minLength: 0)
                    if let device = player.outputName {
                        RemoteOutputBar(device: device)
                            .padding(.bottom, Theme.Spacing.l)
                    }
                    bottomBar
                }
                .frame(height: lower)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    private func standardColumn(inlinePanel: Bool) -> some View {
        VStack(spacing: 0) {
            grabber

            if player.hasContent {
                switch inlinePanel ? panel : .artwork {
                case .artwork where app.dj.isOnAir:
                    DJOnAirPanel()
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                case .artwork:
                    Spacer(minLength: Theme.Spacing.l)
                    NowPlayingCover(lifted: player.isPlaying)
                        .scaleEffect(player.isPlaying ? 1 : Theme.Player.pausedArtworkScale)
                        .animation(.spring(duration: 0.5, bounce: 0.2), value: player.isPlaying)
                    Spacer(minLength: Theme.Spacing.xl)
                case .lyrics:
                    compactHeader
                    if let track = player.current {
                        LyricsPanel(track: track)
                    } else {
                        Spacer()
                    }
                case .queue:
                    // The queue starts with the song that's playing, so no header of its own here.
                    QueuePanel(onTalkToDJ: { showingDJRequest = true })
                }

                if (!inlinePanel || panel == .artwork) && !app.dj.isOnAir {
                    NowPlayingDetails(details: details)
                }
                // The controls, then the progress bar under them.
                VStack(spacing: Theme.Spacing.l) {
                    controls
                    if !player.isLive { PlayerScrubber() }
                }
                .padding(.vertical, Theme.Spacing.xl)
                if let device = player.outputName {
                    RemoteOutputBar(device: device)
                        .padding(.bottom, Theme.Spacing.l)
                }
                bottomBar
            } else {
                Spacer()
                ContentUnavailableView("Nothing playing", systemImage: "music.note")
                Spacer()
            }
        }
    }

    /// Lyrics or Up Next, beside the player on iPad and Mac.
    private var sidePanel: some View {
        VStack(spacing: Theme.Spacing.m) {
            Picker("Show", selection: $panel) {
                Text("Lyrics").tag(Panel.lyrics)
                Text("Up Next").tag(Panel.queue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: Theme.Size.formMaxWidth)
            .padding(.top, Theme.Spacing.xl)
            Group {
                switch panel {
                case .lyrics:
                    if let track = player.current, !player.isLive {
                        LyricsPanel(track: track)
                    } else {
                        Spacer()
                    }
                default:
                    QueuePanel(onTalkToDJ: { showingDJRequest = true })
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.bottom, Theme.Spacing.xl)
    }

    private var grabber: some View { grabberHandle }

    private var grabberHandle: some View {
        Button(action: close) {
            Capsule()
                .fill(.white.opacity(0.4))
                .frame(width: Theme.Size.grabber.width, height: Theme.Size.grabber.height)
                .frame(maxWidth: .infinity, minHeight: Theme.Player.grabberHitHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, Theme.Spacing.xs)
        .accessibilityLabel("Close player")
    }

    // MARK: Header (lyrics and queue)

    private var compactHeader: some View {
        HStack(spacing: Theme.Spacing.m) {
            NowPlayingArtwork(pixels: Theme.Pixels.thumb)
                .artworkFrame(size: Theme.Size.compactArtwork, .rounded(Theme.Radius.thumb))
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(player.nowTitle)
                    .font(.headline)
                    .lineLimit(1)
                subtitle
                    .font(.subheadline)
                    .lineLimit(1)
                    .playerSecondary()
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.m)
    }

    @ViewBuilder
    private var subtitle: some View {
        if let artist = player.current?.primaryArtist {
            Button {
                app.navigator.open(.artist(id: artist.id, name: artist.name ?? ""))
            } label: {
                Text(player.nowSubtitle)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the artist")
        } else {
            Text(player.nowSubtitle)
        }
    }

    @ViewBuilder
    private var favoriteButton: some View {
        if let track = player.current {
            let favorite = app.library.isFavorite(track.id)
            IconButton(symbol: favorite ? "heart.fill" : "heart",
                       label: favorite ? "Remove from Favorites" : "Favorite") {
                app.library.toggleFavorite(track)
            }
            .foregroundStyle(favorite ? Color.dial : Color.white)
            .blendMode(favorite ? .normal : .plusLighter)
        } else if let station = player.liveStation {
            let saved = app.stations.isSaved(station)
            IconButton(symbol: saved ? "star.fill" : "star",
                       label: saved ? "Remove from Saved Stations" : "Save Station") {
                app.stations.toggleSaved(station)
            }
            .foregroundStyle(saved ? Color.dial : Color.white)
        }
    }

    private var moreMenu: some View {
        Menu {
            if app.dj.isActive {
                Button {
                    Task { await app.dj.changeDirection() }
                } label: {
                    Label("DJ: Change Direction", systemImage: "arrow.triangle.branch")
                }
                Button(role: .destructive) {
                    app.dj.stop()
                } label: {
                    Label("Stop DJ", systemImage: "stop.circle")
                }
                Divider()
            }
            if let track = player.current {
                TrackMenu(track: track,
                          onAddToPlaylist: { playlistRequest = PlaylistRequest(tracks: $0) },
                          onShowInfo: { songInfo = $0 })
                Divider()
            }
            Button {
                showingEqualizer = true
            } label: {
                Label("Equalizer", systemImage: "slider.vertical.3")
            }

            Menu {
                Button("15 Minutes") { player.setSleepTimer(minutes: 15) }
                Button("30 Minutes") { player.setSleepTimer(minutes: 30) }
                Button("45 Minutes") { player.setSleepTimer(minutes: 45) }
                Button("1 Hour") { player.setSleepTimer(minutes: 60) }
                if !player.isLive {
                    Button("End of Song") { player.sleepAtEndOfCurrentTrack() }
                }
                if player.sleepTimerOn {
                    Divider()
                    Button("Turn Off Timer", role: .destructive) { player.cancelSleepTimer() }
                }
            } label: {
                Label(sleepLabel, systemImage: "moon.zzz")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.title3)
                .frame(width: Theme.Size.tapTarget, height: Theme.Size.tapTarget)
                .contentShape(Rectangle())
        }
        .plainMenu()
        .accessibilityLabel("More")
    }

    private var sleepLabel: String {
        if let end = player.sleepEndsAt {
            return "Sleep Timer: stops at \(end.formatted(date: .omitted, time: .shortened))"
        }
        if player.sleepAtEndOfTrack { return "Sleep Timer: end of song" }
        return "Sleep Timer"
    }

    // MARK: Scrubber, controls, volume

    private var controls: some View {
        let canSkip = !player.isLive || player.stationContext.count > 1
        return HStack {
            Spacer()
            IconButton(symbol: "backward.fill", label: player.isLive ? "Previous station" : "Previous",
                       font: .system(size: skipSize)) {
                player.previous()
            }
            .disabled(!canSkip)
            .opacity(canSkip ? 1 : 0.35)
            Spacer()
            // The button keeps its place while loading (the spinner sits where its icon was), so nothing around it moves.
            // A song just opening (nothing has played yet) counts too, not only a jump or a start from a list.
            let loading = player.isStarting || player.isLoadingAudio || (player.isBuffering && player.currentTime < 0.5 && !player.isLive)
            IconButton(symbol: player.isPlaying ? "pause.fill" : "play.fill",
                       label: loading ? "Loading" : (player.isPlaying ? "Pause" : "Play"), font: .system(size: playSize)) {
                player.togglePlayPause()
            }
            .opacity(loading ? 0 : 1)
            .allowsHitTesting(!loading)
            .overlay {
                if loading {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                        .accessibilityHidden(true)
                }
            }
            Spacer()
            IconButton(symbol: "forward.fill", label: player.isLive ? "Next station" : "Next",
                       font: .system(size: skipSize)) {
                player.next()
            }
            .disabled(!canSkip)
            .opacity(canSkip ? 1 : 0.35)
            Spacer()
        }
        .disabled(player.isStarting)
    }

    /// Favorite, lyrics, AirPlay, queue, the DJ (while it's on) and more, evenly spaced.
    private var bottomBar: some View {
        // Every button gets an equal share of the width, so the row is centered whatever is in it.
        HStack(spacing: 0) {
            favoriteButton
                .playerSecondary()
                .frame(maxWidth: .infinity)
            panelButton(.lyrics, symbol: "quote.bubble", label: "Lyrics")
                .disabled(!lyricsAvailable)
                .opacity(lyricsAvailable ? 1 : 0.35)
                .frame(maxWidth: .infinity)
            IconButton(symbol: player.isRemote ? "hifispeaker.fill" : "laptopcomputer.and.iphone",
                       label: player.outputName.map { "Playing on \($0). Choose a device" } ?? "Choose where to play") {
                showingDevices = true
            }
            .foregroundStyle(player.isRemote ? Color.dial : Color.white)
            .blendMode(player.isRemote ? .normal : .plusLighter)
            .frame(maxWidth: .infinity)
            panelButton(.queue, symbol: "list.bullet", label: "Queue")
                .frame(maxWidth: .infinity)
            if app.dj.isActive {
                DJButton(name: app.dj.name) { showingDJRequest = true }
                    .frame(maxWidth: .infinity)
            }
            moreMenu
                .playerSecondary()
                .frame(maxWidth: .infinity)
        }
        .disabled(player.isStarting)
    }

    /// Lyrics need a song with lyrics on the server. Until the details arrive, assume they might.
    private var lyricsAvailable: Bool {
        !player.isLive && player.current != nil
    }

    /// Lyrics and Queue: white when open, blended into the background when closed.
    @ViewBuilder
    private func panelButton(_ target: Panel, symbol: String, label: String) -> some View {
        let open = panel == target
        let button = IconButton(symbol: open && target == .lyrics ? "quote.bubble.fill" : symbol, label: label) {
            withAnimation(.easeInOut(duration: 0.25)) {
                panel = open ? .artwork : target
            }
        }
        .accessibilityAddTraits(open ? .isSelected : [])
        if open {
            button.foregroundStyle(.white)
        } else {
            button.playerSecondary()
        }
    }
}

/// The player's background: a gradient made from the cover's colors, changing smoothly with each song.
struct PlayerBackground: View {
    @Environment(AppModel.self) private var app
    @State private var colors: [Color] = ArtworkPalette.fallback

    private var artworkURL: URL? {
        if app.dj.isOnAir { return nil }
        if let pending = app.player.pending {
            if case .item(let id) = pending.artwork { return app.client?.imageURL(for: id, size: Theme.Pixels.thumb) }
            return nil
        }
        if let station = app.player.liveStation { return station.faviconURL }
        guard let track = app.player.current else { return nil }
        return app.client?.imageURL(for: track.imageItemId, size: Theme.Pixels.thumb)
    }

    var body: some View {
        LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .task(id: BackgroundKey(url: artworkURL, onAir: app.dj.isOnAir)) {
                guard let url = artworkURL else {
                    let fallback = app.dj.isOnAir ? ArtworkPalette.onAir : ArtworkPalette.fallback
                    withAnimation(.easeInOut(duration: 0.6)) { colors = fallback }
                    return
                }
                let palette = await ArtworkPalette.colors(for: url)
                withAnimation(.easeInOut(duration: 0.6)) { colors = palette ?? ArtworkPalette.fallback }
            }
            .accessibilityHidden(true)
    }
}

/// The progress bar. Its own view, so only it redraws as the song plays.
private struct PlayerScrubber: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrubberBar(currentTime: app.player.currentTime, duration: app.player.duration) { app.player.seek(to: $0) }
    }
}

/// Under the cover: song, artist, album and year, then the file's format,
/// your rating and the quality ("FLAC  ★★★★☆  44.1 kHz / 16-bit").
private struct NowPlayingDetails: View {
    let details: BaseItem?
    @Environment(AppModel.self) private var app
    /// The block is always this tall, whatever the song (one or two artists, an album or not, details loaded or not),
    /// so the controls below never move between songs.
    @ScaledMetric(relativeTo: .body) private var blockHeight: CGFloat = 138

    var body: some View {
        let player = app.player
        VStack(spacing: Theme.Spacing.xxs) {
            if let pending = player.pending {
                Text(pending.subtitle).font(.subheadline).lineLimit(1).playerSecondary()
                Text(pending.title).font(.title3.weight(.semibold)).lineLimit(1)
                skeletonLine
            } else if let track = player.current {
                let item = details?.id == track.id ? details! : track
                // The DJ line has its place even when the DJ is off, so the rest keeps still.
                Text(app.dj.isActive ? (app.dj.currentBlock.map { "\(app.dj.name): \($0.title)" } ?? " ") : " ")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.dial)
                    .lineLimit(1)
                    .padding(.bottom, Theme.Spacing.xxs)
                // Title first and biggest, then who made it, then which album (smallest).
                Text(track.name)
                    .font(.title2.weight(.bold))
                    .marquee(id: track.id)
                let credited = app.credits.credits(for: track)
                if credited.count > 1 {
                    Menu {
                        ForEach(credited, id: \.self) { name in
                            Button(name) { app.navigator.open(app.credits.route(for: name)) }
                        }
                    } label: {
                        Text(track.artistLine).marquee(id: track.id)
                    }
                    .buttonStyle(.plain)
                    .font(.title3)
                    .playerSecondary()
                    .accessibilityHint("Choose an artist to open")
                } else if let artist = track.primaryArtist {
                    Button {
                        app.navigator.open(.artist(id: artist.id, name: artist.name ?? ""))
                    } label: {
                        Text(track.artistLine).marquee(id: track.id)
                    }
                    .buttonStyle(.plain)
                    .font(.title3)
                    .playerSecondary()
                    .accessibilityHint("Opens the artist")
                } else {
                    Text(track.artistLine).font(.title3).playerSecondary()
                }
                Button {
                    if let albumId = track.albumId { app.navigator.open(.album(id: albumId, name: track.album ?? "")) }
                } label: {
                    Text([track.album, item.year.map(String.init)].compactMap { $0 }.joined(separator: " \u{00B7} "))
                        .marquee(id: track.id)
                }
                .buttonStyle(.plain)
                .disabled(track.albumId == nil)
                .accessibilityHint("Opens the album")
                .font(.footnote)
                .playerSecondary()
                .opacity(0.8)
                .padding(.top, Theme.Spacing.xxs)
                if details?.id == track.id {
                    fileRow(item)
                        .padding(.top, Theme.Spacing.xs)
                } else {
                    skeletonLine
                }
            } else if let station = player.liveStation {
                Text(station.subtitle).font(.subheadline).lineLimit(1).playerSecondary()
                Text(player.nowTitle).font(.title3.weight(.semibold)).lineLimit(1)
                Text(player.liveTitle == nil ? " " : station.name).font(.subheadline).lineLimit(1).playerSecondary()
                liveRow(station)
                    .padding(.top, Theme.Spacing.xs)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .frame(height: blockHeight, alignment: .top)
    }

    /// While the file details load: a quiet placeholder where they'll appear.
    private var skeletonLine: some View {
        SkeletonBlock(width: Theme.Size.shelfTile * 1.4, height: Theme.Spacing.m)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .opacity(0.6)
            .shimmering()
    }

    /// "FLAC · 44.1 kHz / 16-bit" and your rating, small and centered.
    private func fileRow(_ item: BaseItem) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            if let format = item.formatLabel { FormatBadge(text: format) }
            if let quality = item.qualityLabel {
                Text(quality).font(.caption.weight(.medium))
            }
            StarRating(item: item, size: .caption2, tint: .white)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .playerSecondary()
    }

    private func liveRow(_ station: Station) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            LiveBadge()
            if let details = streamDetails(station) {
                Text(details).font(.caption.weight(.medium)).playerSecondary()
            }
            if app.player.isBuffering { ProgressView().controlSize(.small).tint(.white) }
        }
        .frame(minHeight: Theme.Size.tapTarget)
    }

    /// "Connecting…" while it buffers, then the stream's quality.
    private func streamDetails(_ station: Station) -> String? {
        if app.player.isBuffering { return "Connecting…" }
        let format = station.codec.map { $0.uppercased() }.flatMap { $0.isEmpty || $0 == "UNKNOWN" ? nil : $0 }
        let bitrate = station.bitrate.flatMap { $0 > 0 ? "\($0) kbps" : nil }
        let parts = [format, bitrate].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// While the music plays on another device: its name.
private struct RemoteOutputBar: View {
    let device: String

    var body: some View {
        Label("Playing on \(device)", systemImage: "hifispeaker.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.dial)
    }
}

private struct BackgroundKey: Equatable {
    let url: URL?
    let onAir: Bool
}

/// The DJ button in the player: opens a chat to tell the DJ your vibe.
/// Opens the chat with the DJ.
private struct DJButton: View {
    let name: String
    let action: () -> Void

    var body: some View {
        IconButton(symbol: "bubble.left.and.text.bubble.right", label: "Talk to \(name)", action: action)
            .foregroundStyle(Color.dial)
            .accessibilityHint("Ask \(name) for music, or ask about what's playing")
    }
}

// MARK: - Lyrics

/// Shows the lyrics your server has for this song. Synced lyrics (.lrc files with
/// timestamps) follow along and can be tapped to jump to that line.
/// Shown when a song has no lyrics, in the player's colors.
private struct NoLyricsPlaceholder: View {
    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: "quote.bubble")
                .font(.system(size: Theme.Player.playSize))
                .playerSecondary()
                .accessibilityHidden(true)
            Text("No lyrics for this song")
                .font(.title3.weight(.semibold))
            Text("Neither your server nor LRCLIB has them. Lyrics are easier to find when the song\u{2019}s title and artist are tagged correctly.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .playerSecondary()
                .frame(maxWidth: Theme.Size.formMaxWidth * 0.8)
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct LyricsPanel: View {
    let track: BaseItem
    @Environment(AppModel.self) private var app
    @State private var lines: [LyricLine] = []
    @State private var source: LyricsFinder.Source?
    @State private var state: LoadState = .loading

    private var synced: Bool { lines.contains { $0.start != nil } }

    private var activeLine: Int? {
        guard synced else { return nil }
        let now = app.player.currentTime + 0.3
        return lines.lastIndex { ($0.startSeconds ?? .infinity) <= now }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { position, line in
                        Button {
                            if let start = line.startSeconds { app.player.seek(to: start) }
                        } label: {
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.title2.bold())
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(lineColor(position))
                        }
                        .buttonStyle(.plain)
                        .disabled(line.startSeconds == nil)
                        .id(position)
                    }
                }
                .padding(.vertical, Theme.Spacing.section)
                if source == .lrclib {
                    Text("Lyrics from LRCLIB")
                        .font(.footnote)
                        .playerSecondary()
                        .padding(.bottom, Theme.Spacing.section)
                }
            }
            .onChange(of: activeLine) { _, newLine in
                guard let newLine else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(newLine, anchor: .center)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .overlay {
            if lines.isEmpty {
                if state == .loading {
                    SkeletonView(style: .lines)
                        .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    NoLyricsPlaceholder()
                }
            }
        }
        .task(id: track.id) { await load() }
    }

    private func load() async {
        guard let client = app.client else { return }
        state = .loading
        lines = []
        source = nil
        let found = await LyricsFinder.lyrics(for: track, client: client)
        lines = found?.lines ?? []
        source = found?.source
        state = .loaded
    }

    private func lineColor(_ position: Int) -> Color {
        guard synced else { return .white.opacity(0.9) }
        return position == activeLine ? .white : .white.opacity(0.35)
    }
}

// MARK: - Queue

/// While Marlo runs the music, the queue is Marlo's: no shuffle or repeat, and no list of
/// songs Marlo hasn't announced yet. You can ask for something else or skip ahead.
private struct DJQueueNote: View {
    let onTalk: () -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            Spacer()
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.largeTitle)
                .playerSecondary()
                .accessibilityHidden(true)
            if let block = app.dj.currentBlock {
                Text("Now: \(block.title)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.dial)
            }
            Text("\(app.dj.name) is picking what\u{2019}s next")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Ask for something different, or let \(app.dj.name) change it up.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .playerSecondary()
            HStack(spacing: Theme.Spacing.s) {
                PillButton(title: "Talk to \(app.dj.name)", systemImage: "bubble.left.fill", action: onTalk)
                PillButton(title: "Something Different", systemImage: "arrow.triangle.branch") {
                    Task { await app.dj.changeDirection() }
                }
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct QueuePanel: View {
    var onTalkToDJ: () -> Void = {}
    @Environment(AppModel.self) private var app

    private var player: Player { app.player }

    private var repeatTitle: String {
        switch player.repeatMode {
        case .off: return "Repeat"
        case .all: return "Repeat All"
        case .one: return "Repeat One"
        }
    }

    var body: some View {
        if app.dj.isActive && !player.isLive {
            DJQueueNote(onTalk: onTalkToDJ)
        } else {
            queue
        }
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            if let track = player.current, !player.isLive {
                // What's playing, for context.
                HStack(spacing: Theme.Spacing.m) {
                    NowPlayingArtwork(pixels: Theme.Pixels.thumb)
                        .artworkFrame(size: Theme.Size.miniArtwork, .rounded(Theme.Radius.thumb))
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(track.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(track.artistLine).font(.caption).playerSecondary().lineLimit(1)
                    }
                    Spacer(minLength: Theme.Spacing.s)
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                        .font(.caption)
                        .foregroundStyle(Color.dial)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, Theme.Spacing.s)
            }

            // "Up Next", and the three modes as small round toggles beside it.
            HStack(spacing: Theme.Spacing.s) {
                Text(player.isLive ? "More Stations" : "Up Next").font(.headline)
                Spacer()
                if !player.isLive {
                    ModeToggle(symbol: "shuffle", label: "Shuffle", isOn: player.shuffleOn) { player.toggleShuffle() }
                    ModeToggle(symbol: player.repeatMode == .one ? "repeat.1" : "repeat", label: repeatTitle,
                               isOn: player.repeatMode != .off) { player.cycleRepeat() }
                }
            }
            .padding(.horizontal, Theme.Spacing.s)

            List {
                if player.isLive {
                    ForEach(player.stationContext) { station in
                        Button { player.playStation(station) } label: { StationRow(station: station) }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                    }
                } else {
                    let firstRadio = player.upNext.firstIndex { player.radioTrackIds.contains($0.id) }
                    ForEach(Array(player.upNext.enumerated()), id: \.offset) { offset, track in
                        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                            // Where radio takes over, a quiet label instead of an icon on every song.
                            if offset == firstRadio {
                                Text(offset == 0 ? "From Radio" : "Then, From Radio")
                                    .font(.caption.weight(.semibold))
                                    .playerSecondary()
                                    .padding(.top, offset == 0 ? 0 : Theme.Spacing.m)
                            }
                            Button {
                                player.jump(to: player.index + 1 + offset)
                            } label: {
                                QueueRow(track: track)
                            }
                            .buttonStyle(.plain)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: Theme.Spacing.xs, leading: Theme.Spacing.s,
                                                   bottom: Theme.Spacing.xs, trailing: Theme.Spacing.s))
                    }
                    .onMove { player.moveUpNext(from: $0, to: $1) }
                    .onDelete { player.removeUpNext(at: $0) }

                    if player.radioLoading {
                        HStack(spacing: Theme.Spacing.m) {
                            ProgressView()
                            Text("Finding similar songs\u{2026}").font(.subheadline).playerSecondary()
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    } else if player.upNext.isEmpty {
                        Text(player.radioOn ? "Radio will add similar songs." : "Nothing up next.")
                            .font(.subheadline)
                            .playerSecondary()
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } else {
                        Button("Clear Up Next") { player.clearUpNext() }
                            .font(.subheadline)
                            .playerSecondary()
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                            .padding(.top, Theme.Spacing.s)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .frame(maxHeight: .infinity)
    }
}

/// One song in the queue: small cover, title and artist, the length kept quiet.
private struct QueueRow: View {
    let track: BaseItem

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            ArtworkView(itemId: track.imageItemId, pixels: Theme.Pixels.thumb)
                .artworkFrame(size: Theme.Size.miniArtwork, .rounded(Theme.Radius.thumb))
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(track.name).font(.subheadline).lineLimit(1)
                Text(track.artistLine).font(.caption).playerSecondary().lineLimit(1)
            }
            Spacer(minLength: Theme.Spacing.s)
            if let duration = track.duration {
                Text(formatTime(duration)).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.4))
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A small round toggle: quiet when off, amber when on.
private struct ModeToggle: View {
    let symbol: String
    let label: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isOn ? Color.dial : Color.white.opacity(0.75))
                .frame(width: Theme.Size.tapTarget * 0.72, height: Theme.Size.tapTarget * 0.72)
                .background(isOn ? Color.dial.opacity(0.22) : Color.white.opacity(0.1), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .help(label)
    }
}

// MARK: - System controls

/// Lets a larger row open the system AirPlay and Bluetooth picker, which is otherwise only opened by the small icon.
@MainActor
final class AirPlayTrigger {
    fileprivate weak var picker: AVRoutePickerView?

    func present() {
        func button(in view: UIView) -> UIButton? {
            if let button = view as? UIButton { return button }
            for subview in view.subviews { if let found = button(in: subview) { return found } }
            return nil
        }
        if let picker, let button = button(in: picker) { button.sendActions(for: .touchUpInside) }
    }
}

struct AirPlayButton: UIViewRepresentable {
    var trigger: AirPlayTrigger?

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        trigger?.picker = view
        view.tintColor = UIColor.white.withAlphaComponent(Theme.Player.secondaryOpacity)
        view.activeTintColor = UIColor(Color.dial)
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
