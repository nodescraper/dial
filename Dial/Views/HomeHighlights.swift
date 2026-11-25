import SwiftUI

/// What Home leads with: two or three cards that each tell you something, instead of an endless row of
/// recent albums. Chosen in this order, from what's actually true right now:
/// 1. New from your artists: a fresh release (MusicBrainz) by an artist in your library.
/// 2. Just added: the newest album in your library, when it arrived in the last two weeks.
/// 3. On repeat this week: the artist you've played most (Playback Reporting).
/// 4. Rediscover: an album you used to play a lot but haven't in months (fills in when one above is missing).
struct Highlight: Codable, Sendable, Identifiable, Hashable {
    enum Kind: String, Codable, Sendable { case newRelease, justAdded, onRepeat, rediscover }
    enum Action: Codable, Sendable, Hashable {
        case album(id: String, name: String)
        case publicAlbum(PublicMusic.Release, artist: String, artistId: String?)
        case artistRadio(id: String, name: String)
        /// The Discovery page (the card for new releases from your artists).
        case discovery
    }

    let kind: Kind
    let label: String
    let title: String
    let subtitle: String
    /// The one line that makes the card worth reading ("Out Friday", "32 plays this week").
    let detail: String
    /// The cover: a library item, or a cover from the Cover Art Archive.
    var coverItemId: String? = nil
    var coverURL: URL? = nil
    /// The artist whose backdrop fills the card, when they're in your library.
    var artistId: String? = nil
    /// Covers blended into the card's picture (the new-releases card), instead of one cover and a backdrop.
    var collage: [URL]? = nil
    let action: Action

    var id: String { kind.rawValue + title }
}

enum HighlightBuilder {
    @MainActor
    static func build(client: JellyfinClient, history: ListeningHistory?) async -> [Highlight] {
        async let newRelease = newFromYourArtists(client: client)
        async let justAdded = justAdded(client: client)
        async let onRepeat = onRepeat(client: client, history: history)
        async let rediscover = rediscover(client: client)
        let first = [await newRelease, await justAdded, await onRepeat].compactMap { $0 }
        let fill = first.count < 3 ? [await rediscover].compactMap { $0 } : []
        return Array((first + fill).prefix(3))
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    /// New releases from your artists, as one card that leads to the Discovery page: a blend of their covers.
    @MainActor
    private static func newFromYourArtists(client: JellyfinClient) async -> Highlight? {
        // The saved Discovery page, or (if it was never opened yet) the server's feed.
        var feed = await Snapshots.load(DiscoveryFeed.self, DiscoveryEngine.snapshotKey)
        if feed?.fresh.isEmpty ?? true, let made = await client.dialDiscovery(), made.ready {
            feed = made.feed
            Snapshots.save(made.feed, DiscoveryEngine.snapshotKey)
        }
        guard let feed else { return nil }
        let picks = feed.fresh.uniqued()
        // Some releases have no cover on the Cover Art Archive, or it is slow: check a dozen, keep five that really load,
        // so the card never shows empty ghost squares.
        let candidates = Array(picks.prefix(14).compactMap(\.cover))
        var loads = [Bool](repeating: false, count: candidates.count)
        await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, url) in candidates.enumerated() {
                group.addTask { (index, await PublicMusic.fetchData(url) != nil) }
            }
            for await (index, ok) in group { loads[index] = ok }
        }
        let working = candidates.enumerated().filter { loads[$0.offset] }.map(\.element)
        let covers = Array((working.count >= 3 ? working : candidates).prefix(5))
        guard picks.count >= 3, covers.count >= 3 else { return nil }
        var seen = Set<String>()
        let artists = picks.compactMap { $0.artist.map(ArtistNames.primary) }.filter { seen.insert($0).inserted }
        let names = artists.prefix(3).joined(separator: ", ") + (artists.count > 3 ? " and more" : "")
        return Highlight(kind: .newRelease, label: "New from your artists", title: "\(picks.count) new releases",
                         subtitle: names, detail: "", collage: covers, action: .discovery)
    }

    /// The newest album, if it arrived in the last two weeks.
    @MainActor
    private static func justAdded(client: JellyfinClient) async -> Highlight? {
        guard let album = try? await client.recentAlbums(limit: 1).first, let added = album.added,
              Date().timeIntervalSince(added) < 14 * 24 * 3600 else { return nil }
        let tracks = (try? await client.tracks(inAlbum: album.id)) ?? []
        let minutes = Int(tracks.compactMap(\.duration).reduce(0, +) / 60)
        let size = tracks.isEmpty ? "" : ", \(tracks.count) songs, \(minutes) min"
        return Highlight(kind: .justAdded, label: "Recently added", title: album.name, subtitle: album.albumArtistLine,
                         detail: "Added \(relative.localizedString(for: added, relativeTo: .now))\(size)",
                         coverItemId: album.id, artistId: album.primaryArtist?.id, action: .album(id: album.id, name: album.name))
    }

    /// The artist you've played most this week.
    @MainActor
    private static func onRepeat(client: JellyfinClient, history: ListeningHistory?) async -> Highlight? {
        guard let history, history.isAvailable else { return nil }
        let top = await history.topSongs(days: 7, limit: 60)
        guard !top.isEmpty, let songs = try? await client.items(ids: top.map(\.id)) else { return nil }
        let plays = Dictionary(top.map { ($0.id, $0.plays) }, uniquingKeysWith: { a, _ in a })
        var byArtist: [String: (artist: NameId, plays: Int, song: BaseItem)] = [:]
        for song in songs {
            guard let artist = song.primaryArtist, let id = Optional(artist.id) else { continue }
            let count = plays[song.id] ?? 0
            let current = byArtist[id]
            byArtist[id] = (artist, (current?.plays ?? 0) + count, current?.song ?? song)
        }
        guard let best = byArtist.values.max(by: { $0.plays < $1.plays }), best.plays >= 3 else { return nil }
        let name = ArtistNames.primary(best.artist.name ?? "")
        return Highlight(kind: .onRepeat, label: "On repeat this week", title: name,
                         subtitle: "Your most played artist", detail: "",
                         coverItemId: best.song.imageItemId, artistId: best.artist.id, action: .artistRadio(id: best.artist.id, name: name))
    }

    /// An album you loved but haven't played in months.
    @MainActor
    private static func rediscover(client: JellyfinClient) async -> Highlight? {
        guard let songs = try? await client.songs(sortedBy: "PlayCount", limit: 300) else { return nil }
        let cutoff = Calendar.current.date(byAdding: .month, value: -4, to: .now) ?? .now
        var albums: [String: (song: BaseItem, plays: Int, last: Date)] = [:]
        for song in songs {
            guard let albumId = song.albumId, let last = song.userData?.lastPlayed, song.plays >= 2 else { continue }
            let current = albums[albumId]
            albums[albumId] = (current?.song ?? song, (current?.plays ?? 0) + song.plays, max(current?.last ?? .distantPast, last))
        }
        guard let pick = albums.filter({ $0.value.last < cutoff }).max(by: { $0.value.plays < $1.value.plays }) else { return nil }
        let song = pick.value.song
        let when = pick.value.last.formatted(.dateTime.month(.wide).year())
        return Highlight(kind: .rediscover, label: "Rediscover", title: song.album ?? song.name, subtitle: song.albumArtist ?? song.artistLine,
                         detail: "You played it \(pick.value.plays) times, last in \(when)",
                         coverItemId: pick.key, artistId: song.primaryArtist?.id, action: .album(id: pick.key, name: song.album ?? ""))
    }
}

extension DateFormatter {
    static let yearMonthDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

/// The highlights row: big cards side by side, at most three.
struct HighlightsRow: View {
    let highlights: [Highlight]
    /// The text sits under the picture (Discovery) instead of on it (Home).
    var captioned = false

    var body: some View {
        HScroll {
            LazyHStack(alignment: .top, spacing: Theme.Spacing.m) {
                ForEach(highlights) { highlight in
                    HighlightCard(highlight: highlight, captioned: captioned)
                        .containerRelativeFrame(.horizontal) { width, _ in
                            min(width * (highlights.count == 1 ? 1 : Theme.Size.carouselFraction), Theme.Size.heroMaxWidth)
                        }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.horizontal, Theme.Spacing.l, for: .scrollContent)
    }
}

/// One card, in Home's original style: the artist's backdrop (or the cover, softened), their logo, and the
/// cover, a short label, the title and artist at the bottom, with one round button.
private struct HighlightCard: View {
    let highlight: Highlight
    var captioned = false
    @Environment(AppModel.self) private var app

    private var backdropURL: URL? {
        highlight.artistId.flatMap { app.client?.imageURL(for: $0, type: "Backdrop/0", width: Theme.Pixels.wide) }
    }

    private var logoURL: URL? {
        highlight.artistId.flatMap { app.client?.imageURL(for: $0, type: "Logo", width: Theme.Pixels.logo) }
    }

    var body: some View {
        Button(action: open) {
            if captioned {
                // The picture alone, with the round button on it; label, title and artist set under it.
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    Color.clear
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .background { background }
                        .overlay(alignment: .topLeading) { logo }
                        .overlay(alignment: .bottomTrailing) {
                            IconButton(symbol: actionSymbol, label: actionLabel, font: .title3) { act() }
                                .foregroundStyle(.white)
                                .background(.ultraThinMaterial, in: Circle())
                                .padding(Theme.Spacing.m)
                        }
                        .clipShape(.rounded(Theme.Radius.hero))
                        .artworkShadow()
                        .contentShape(.rounded(Theme.Radius.hero))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(highlight.label.uppercased())
                            .font(.caption.weight(.semibold)).tracking(0.6)
                            .foregroundStyle(.secondary).lineLimit(1)
                        Text(highlight.title)
                            .font(.title3.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                        Text(highlight.subtitle)
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.horizontal, 2)
                }
            } else {
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .background { background }
                    .overlay(alignment: .topLeading) { logo }
                    .overlay(alignment: .bottom) { caption }
                    .clipShape(.rounded(Theme.Radius.hero))
                    .artworkShadow()
                    .contentShape(.rounded(Theme.Radius.hero))
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(highlight.label): \(highlight.title), \(highlight.subtitle)")
        .accessibilityAction(named: actionLabel) { act() }
    }

    @ViewBuilder
    private var cover: some View {
        if let id = highlight.coverItemId {
            ArtworkView(itemId: id, pixels: Theme.Pixels.tile)
        } else {
            RemoteArtwork(url: highlight.coverURL, placeholder: "music.note")
        }
    }

    /// Several covers, tilted and overlapping over a blurred, darkened copy of the first: a blend, not a grid.
    private func collageView(_ urls: [URL]) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let side = height * 0.56
            let xs: [CGFloat] = [0.13, 0.31, 0.50, 0.69, 0.87]
            let ys: [CGFloat] = [0.40, 0.33, 0.43, 0.34, 0.41]
            let tilt: [Double] = [-7, 4, -3, 6, -5]
            ZStack {
                // The base is cut to the card, so its blur never changes the size the covers are placed in.
                RemoteImage(url: urls.first) { Color.black }
                    .frame(width: width, height: height)
                    .blur(radius: 34).scaleEffect(1.7)
                    .overlay(Color.black.opacity(0.5))
                    .frame(width: width, height: height)
                    .clipped()
                ForEach(Array(urls.prefix(5).enumerated()), id: \.offset) { index, url in
                    RemoteImage(url: url) { Color.white.opacity(0.14).shimmering() }
                        .frame(width: side, height: side)
                        .clipShape(.rect(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
                        .rotationEffect(.degrees(tilt[index % 5]))
                        .position(x: width * xs[index % 5], y: height * ys[index % 5])
                }
            }
            .frame(width: width, height: height)
        }
    }

    @ViewBuilder
    private var background: some View {
        if let urls = highlight.collage, !urls.isEmpty {
            collageView(urls)
        } else {
            backdrop
        }
    }

    private var backdrop: some View {
        RemoteImage(url: backdropURL) {
            // No backdrop on the server: the cover, enlarged and softened.
            cover.blur(radius: 24).scaleEffect(1.3)
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
            if highlight.collage == nil {
                cover
                    .artworkFrame(size: Theme.Size.compactArtwork,
                                  .rounded(Theme.Radius.nested(in: Theme.Radius.hero, padding: Theme.Spacing.m)))
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(highlight.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                Text(highlight.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(highlight.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Spacing.s)
            IconButton(symbol: actionSymbol, label: actionLabel, font: .title3) { act() }
                .foregroundStyle(.white)
                .background(.ultraThinMaterial, in: Circle())
        }
        .padding(Theme.Spacing.m)
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
        }
    }

    private var actionSymbol: String {
        switch highlight.action {
        case .album: "play.fill"
        case .publicAlbum: "list.bullet"
        case .artistRadio: "dot.radiowaves.left.and.right"
        case .discovery: "chevron.right"
        }
    }

    private var actionLabel: String {
        switch highlight.action {
        case .album: "Play \(highlight.title)"
        case .publicAlbum: "See the songs on \(highlight.title)"
        case .artistRadio: "Start \(highlight.title) radio"
        case .discovery: "Open Discovery"
        }
    }

    private func open() {
        switch highlight.action {
        case .album(let id, let name): app.navigator.open(.album(id: id, name: name))
        case .publicAlbum(let release, let artist, let artistId): app.navigator.open(.publicAlbum(release, artist: artist, artistId: artistId))
        case .artistRadio(let id, let name): app.navigator.open(.artist(id: id, name: name))
        case .discovery: app.navigator.openDiscovery()
        }
    }

    private func act() {
        switch highlight.action {
        case .album(let id, _):
            guard let client = app.client else { return }
            app.player.play(PendingPlayback(title: highlight.title, subtitle: highlight.subtitle, artwork: .item(id)),
                            loading: { try await client.tracks(inAlbum: id) })
        case .publicAlbum, .discovery: open()
        case .artistRadio(let id, let name): app.player.startArtistRadio(id: id, name: name)
        }
    }
}
