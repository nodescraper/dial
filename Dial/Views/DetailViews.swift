import SwiftUI

// MARK: - Album

struct AlbumView: View {
    let albumId: String
    let title: String
    @Environment(AppModel.self) private var app
    @State private var album: BaseItem? = nil
    @State private var tracks: [BaseItem] = []
    @State private var state: LoadState = .loading
    /// Genres worked out from the artist (MusicBrainz) when the album has no tags.
    @State private var inferredGenres: [String] = []
    /// Songs the album should have according to MusicBrainz but your library doesn't.
    @State private var missing: [PublicMusic.Track] = []
    /// Where the songs you own sit on that edition (disc, track), so the gaps fall in the right place.
    @State private var positions: [String: [Int]] = [:]

    /// Songs grouped by disc, in order.
    private var discs: [(number: Int, tracks: [BaseItem])] {
        let owned = Dictionary(grouping: tracks) { disc(of: $0) }
        let numbers = Set(owned.keys).union(missing.map(\.disc))
        return numbers.sorted().map { (number: $0, tracks: owned[$0] ?? []) }
    }

    private func disc(of song: BaseItem) -> Int { positions[song.id]?[0] ?? song.parentIndexNumber ?? 1 }
    private func number(of song: BaseItem) -> Int { positions[song.id]?[1] ?? song.indexNumber ?? 9999 }

    /// One disc's songs with the ones you don't have between them, faded, in track order.
    @ViewBuilder
    private func rows(_ discTracks: [BaseItem], disc: Int) -> some View {
        let gaps = missing.filter { $0.disc == disc }
        if gaps.isEmpty && positions.isEmpty {
            SongRows(tracks: discTracks, queue: tracks, numbered: true, showGoToAlbum: false)
        } else {
            ForEach(merge(discTracks, gaps)) { segment in
                switch segment.content {
                case .owned(let run):
                    SongRows(tracks: run, queue: tracks, numbered: true, showGoToAlbum: false)
                case .missing(let track):
                    // The same row as a song you own, only faded and not playable (long press to add it to your wishlist).
                    Group {
                        MediaRow(title: track.title, subtitle: album?.albumArtistLine, artworkSize: Theme.Size.trackNumber) {
                            Text("\(track.number)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        } accessory: {
                            if let ms = track.lengthMs {
                                Text(formatTime(Double(ms) / 1000))
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .contextMenu {
                        WishlistButton(item: .song(artist: album?.albumArtistLine ?? "", title: track.title, album: album?.name))
                    }
                    .opacity(0.4)
                    .accessibilityLabel("\(track.title), not in your library")
                }
            }
        }
    }

    private struct Segment: Identifiable {
        enum Content { case owned([BaseItem]), missing(PublicMusic.Track) }
        let id: String
        let content: Content
    }

    /// Owned songs and missing ones in track-number order; neighbouring owned songs stay together in one run.
    private func merge(_ owned: [BaseItem], _ gaps: [PublicMusic.Track]) -> [Segment] {
        enum Entry { case have(BaseItem), gap(PublicMusic.Track) }
        let entries = (owned.map { (number: number(of: $0), entry: Entry.have($0)) }
                       + gaps.map { (number: $0.number, entry: Entry.gap($0)) }).sorted { $0.number < $1.number }
        var segments: [Segment] = []
        var run: [BaseItem] = []
        func flush() { if !run.isEmpty { segments.append(Segment(id: "run-" + run[0].listId, content: .owned(run))); run = [] } }
        for item in entries {
            switch item.entry {
            case .have(let song): run.append(song)
            case .gap(let track): flush(); segments.append(Segment(id: "gap-" + track.id, content: .missing(track)))
            }
        }
        flush()
        return segments
    }

    private var allDownloaded: Bool { !tracks.isEmpty && tracks.allSatisfy { app.downloads.isDownloaded($0.id) } }
    private var downloading: Bool { tracks.contains { app.downloads.isDownloading($0.id) } }

    /// Genre families from the album's tags (or, when untagged, its artist's), like Apple Music's "HIP-HOP · 2019".
    private var genreLine: String {
        var parts: [String] = []
        let genres = GenreNames.families(album?.genres ?? []).isEmpty ? inferredGenres : GenreNames.families(album?.genres ?? [])
        if let genre = genres.first { parts.append(genre) }
        if let year = album?.year { parts.append(String(year)) }
        return parts.joined(separator: " · ").uppercased()
    }

    /// Badges for the quality of the files, in Apple's wording.
    private var badges: [String] {
        guard let first = tracks.first else { return [] }
        var result: [String] = []
        if first.isLossless {
            let rate = first.audioStream?.sampleRate ?? 0
            let depth = first.audioStream?.bitDepth ?? 16
            result.append(rate > 48_000 || depth > 16 ? "Hi-Res Lossless" : "Lossless")
        } else if let format = first.formatLabel {
            result.append(format)
        }
        if (first.audioStream?.channels ?? 2) > 2 { result.append("Surround") }
        if let quality = first.qualityLabel { result.append(quality) }
        return result
    }

    private var artistLinkName: String? {
        let name = album?.primaryArtist?.name ?? tracks.first?.primaryArtist?.name ?? album?.albumArtist ?? tracks.first?.albumArtist
            ?? tracks.first?.artists?.first
        return (name?.isEmpty ?? true) ? nil : name
    }

    private func openArtist(named name: String) async {
        if let artist = album?.primaryArtist ?? tracks.first?.primaryArtist {
            app.navigator.open(.artist(id: artist.id, name: artist.name ?? name))
        } else if let found = try? await app.client?.artist(named: ArtistNames.primary(name)) {
            app.navigator.open(.artist(id: found.id, name: found.name))
        }
    }

    private var releaseDate: String? {
        guard let text = album?.premiereDate, let date = JellyfinDates.parse(text) else { return nil }
        return date.formatted(.dateTime.day().month(.wide).year())
    }

    private var totalSize: String? {
        let bytes = tracks.compactMap { $0.mediaSources?.first?.size }.reduce(0, +)
        return bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : nil
    }

    var body: some View {
        List {
            DetailHeader(imageId: albumId, title: album?.name ?? title, tracks: tracks, jewelCase: true) {
                if let name = artistLinkName {
                    // Always a link: by the artist's id when the album has one, else by looking the name up.
                    Button { Task { await openArtist(named: name) } } label: {
                        Text(album?.albumArtistLine ?? name)
                            .font(.title3)
                            .foregroundStyle(Color.dial)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the artist")
                }
                if !genreLine.isEmpty {
                    Text(genreLine)
                        .font(.caption.weight(.semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if !badges.isEmpty {
                    HStack(spacing: Theme.Spacing.xs) {
                        ForEach(badges, id: \.self) { badge in
                            Text(badge)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.quaternary, in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let album {
                    StarRating(item: album)
                }
            }

            if let overview = album?.overview, !overview.isEmpty {
                ExpandableText(text: overview)
                    .listRowSeparator(.hidden)
            }

            if discs.count > 1 {
                ForEach(discs, id: \.number) { disc in
                    Section("Disc \(disc.number)") { rows(disc.tracks, disc: disc.number) }
                }
            } else {
                rows(tracks, disc: discs.first?.number ?? 1)
            }

            if !tracks.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if let releaseDate { Text(releaseDate) }
                    Text(songCountLine(tracks))
                    if let label = album?.studios?.first?.name {
                        Text("\u{2117} \(album?.year.map(String.init) ?? "") \(label)".replacingOccurrences(of: "  ", with: " "))
                    }
                    if let size = totalSize, let format = tracks.first?.formatLabel { Text("\(format) \u{00B7} \(size)") }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .loadState(state, isEmpty: tracks.isEmpty,
                   empty: EmptyState(title: "No songs", symbol: "square.stack", message: "This album has no songs."),
                   retry: load)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: Theme.Spacing.m) {
                    if downloading {
                        ProgressView().accessibilityLabel("Downloading")
                    } else if allDownloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Downloaded")
                    }
                    albumMenu
                }
            }
        }
        .task { await load() }
    }

    private var albumMenu: some View {
        Menu {
            Button {
                if let album { app.player.startRadio(from: album) } else if let first = tracks.first { app.player.startRadio(from: first) }
            } label: {
                Label("Start Radio", systemImage: "dot.radiowaves.left.and.right")
            }
            Button {
                app.player.playNext(tracks)
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button {
                app.player.addToQueue(tracks)
            } label: {
                Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
            Divider()
            Button {
                app.navigator.addToPlaylist(tracks)
            } label: {
                Label("Add to Playlist…", systemImage: "text.badge.plus")
            }
            if let album {
                FavoriteMenuItem(item: album, title: "Favorite Album")
                Button {
                    Task { await refreshMetadata(album) }
                } label: {
                    Label("Refresh Metadata", systemImage: "arrow.clockwise")
                }
                if app.library.canDelete {
                    Button(role: .destructive) {
                        app.navigator.deletionRequest = album
                    } label: {
                        Label("Delete Album from Server\u{2026}", systemImage: "trash")
                    }
                }
            }
            if allDownloaded {
                Button(role: .destructive) {
                    app.downloads.delete(tracks)
                } label: {
                    Label("Remove Download", systemImage: "trash")
                }
            } else {
                Button {
                    app.downloads.download(tracks)
                } label: {
                    Label("Download Album", systemImage: "arrow.down.circle")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .disabled(tracks.isEmpty)
        .accessibilityLabel("More")
    }

    private func load() async {
        guard let client = app.client else { return }
        if tracks.isEmpty, let saved = await Snapshots.load(AlbumSnapshot.self, "album-\(albumId)") {
            album = saved.album
            tracks = saved.tracks
            state = .loaded
        }
        await runLoad($state) {
            async let info = client.details(albumId)
            tracks = try await client.tracks(inAlbum: albumId)
            album = (try? await info) ?? album
            Snapshots.save(AlbumSnapshot(album: album, tracks: tracks), "album-\(albumId)")
        }
        if GenreNames.families(album?.genres ?? []).isEmpty, let artist = album?.albumArtistLine {
            let found = await PublicMusic.artistGenres(name: ArtistNames.primary(artist)) ?? []
            inferredGenres = GenreNames.families(found)
        }
        if let album, !tracks.isEmpty {
            let gaps = await PublicMusic.missingTracks(album: album, owned: tracks)
            missing = gaps.missing
            positions = gaps.positions
        }
    }

    /// Asks the server to look this album up again (administrators only).
    private func refreshMetadata(_ album: BaseItem) async {
        do {
            try await app.client?.refreshMetadata(album.id)
            app.library.errorMessage = nil
            await JellyfinClient.clearCache()
        } catch JellyfinError.http(403) {
            app.library.errorMessage = "Only server administrators can refresh metadata."
        } catch {
            app.library.errorMessage = "Couldn't refresh \(album.name): \(error.localizedDescription)"
        }
    }
}

// MARK: - Artist

struct ArtistView: View {
    let artistId: String
    let name: String
    @Environment(AppModel.self) private var app
    @State private var artist: BaseItem? = nil
    @State private var topSongs: [BaseItem] = []
    @State private var albums: [BaseItem] = []
    @State private var releases: [PublicMusic.Release] = []
    @State private var similar: [BaseItem] = []
    @State private var showAllSongs = false
    @State private var state: LoadState = .loading
    /// The artist's most played songs worldwide, and the songs of theirs you have (to tell which of those you can play).
    @State private var popular: [PublicMusic.TopTrack] = []
    @State private var ownedSongs: [BaseItem] = []
    /// The discography is still being looked up (first visit only; it's saved afterwards).
    @State private var discographyLoading = true
    /// The MusicBrainz id used to follow this artist (looked up by name when Jellyfin has none).
    @State private var followId: String?

    private var shownSongs: [BaseItem] { showAllSongs ? topSongs : Array(topSongs.prefix(5)) }

    var body: some View {
        // A scrolling page, not a list: every album tile is its own link, so taps open the album
        // you touched and Back returns here.
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                header

                if let overview = artist?.overview, !overview.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        SectionHeader("About")
                        ExpandableText(text: overview, lines: 4)
                            .padding(.horizontal, Theme.Spacing.l)
                    }
                }

                if !popular.isEmpty {
                    PopularSongs(tracks: popular, artistName: artist.map { ArtistNames.primary($0.name) } ?? name, owned: ownedSongs)
                }

                if !topSongs.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        SectionHeader(title: popular.isEmpty ? "Top Songs" : "Your Top Songs") {
                            if topSongs.count > 5 {
                                Button(showAllSongs ? "Show Less" : "See All") {
                                    withAnimation { showAllSongs.toggle() }
                                }
                                .font(.subheadline.weight(.semibold))
                            }
                        }
                        RowStack(data: shownSongs) { track in
                            Button {
                                app.player.play(topSongs, startAt: topSongs.firstIndex { $0.id == track.id } ?? 0)
                            } label: {
                                TrackRow(track: track)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { TrackMenu(track: track) }
                        }
                    }
                }

                if discographyLoading && releases.isEmpty {
                    // A placeholder in the shape of the discography, instead of showing your albums
                    // and then reshuffling them when the rest arrives.
                    VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                        SectionHeader("Discography")
                        // Inside a (fixed) horizontal scroll view, so the placeholder tiles can run past the
                        // screen edge like real tiles do, without making the whole page wider.
                        HScroll {
                            HStack(spacing: Theme.Spacing.m) {
                                ForEach(0..<4, id: \.self) { _ in SkeletonTile(width: Theme.Size.shelfTile) }
                            }
                            .padding(.horizontal, Theme.Spacing.l)
                            .shimmering()
                        }
                        .scrollDisabled(true)
                    }
                } else {
                    DiscographySection(libraryAlbums: albums, releases: releases,
                                       artistName: artist.map { ArtistNames.primary($0.name) } ?? name, artistId: artistId)
                        .transition(.opacity)
                }

                // Songs by other artists that feature this one.
                let featuredOn = app.credits.songs(featuring: artist?.name ?? name)
                if !featuredOn.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        SectionHeader("Featured On")
                        RowStack(data: Array(featuredOn.prefix(10))) { track in
                            Button {
                                app.player.play(featuredOn, startAt: featuredOn.firstIndex { $0.id == track.id } ?? 0)
                            } label: {
                                TrackRow(track: track)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { TrackMenu(track: track) }
                        }
                    }
                }

                if !similar.isEmpty {
                    Shelf(title: "Similar Artists") {
                        ForEach(similar) { other in
                            ArtistTile(artist: other, width: Theme.Size.shelfTile * 0.8)
                        }
                    }
                }
            }
            .padding(.bottom, Theme.Spacing.section)
        }
        .loadState(state, isEmpty: topSongs.isEmpty && albums.isEmpty,
                   empty: EmptyState(title: "Nothing here yet", symbol: "music.mic",
                                     message: "This artist has no songs in your library."),
                   retry: load)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let artist {
                    let following = app.follows.isFollowing(followId ?? artist.musicBrainzId)
                    Button {
                        Task { await toggleFollow(artist) }
                    } label: {
                        Label(following ? "Following" : "Follow", systemImage: following ? "bell.fill" : "bell")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(Color.dial)
                    .accessibilityHint("Tells you when this artist releases something new")
                }
            }
        }
        .task { await load() }
    }

    /// Follow or unfollow: new releases of a followed artist are announced. Needs the artist's MusicBrainz id; when Jellyfin
    /// has none, the exact name is looked up.
    private func toggleFollow(_ artist: BaseItem) async {
        let display = ArtistNames.primary(artist.name)
        var id = followId ?? artist.musicBrainzId
        if id == nil {
            let found = await PublicMusic.search(display)
            id = found.first { $0.kind == .artist && ArtistNames.key($0.title) == ArtistNames.key(display) }?.mbid
        }
        guard let id else { return }
        followId = id
        await app.follows.toggleFollow(artistMbid: id, name: display)
    }

    private var header: some View {
        VStack(spacing: Theme.Spacing.m) {
            ArtworkView(itemId: artistId, pixels: Theme.Pixels.hero, placeholder: "music.mic")
                .artworkFrame(size: Theme.Size.artistHero, .circle)
                .artworkShadow()
            Text(artist.map { ArtistNames.primary($0.name) } ?? name)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if let genres = artist?.genres, !genres.isEmpty {
                Text(genres.prefix(3).joined(separator: ", "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: Theme.Spacing.m) {
                PillButton(title: "Play", systemImage: "play.fill") { app.player.play(topSongs) }
                PillButton(title: "Shuffle", systemImage: "shuffle") { app.player.play(topSongs, shuffle: true) }
                PillButton(title: "Radio", systemImage: "dot.radiowaves.left.and.right") {
                    app.player.startArtistRadio(id: artistId, name: artist.map { ArtistNames.primary($0.name) } ?? name)
                }
            }
            .disabled(topSongs.isEmpty)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.top, Theme.Spacing.m)
    }

    private func load() async {
        guard let client = app.client else { return }
        // What this page showed last time appears instantly; then everything refreshes.
        if topSongs.isEmpty, let saved = await Snapshots.load(ArtistSnapshot.self, "artist-\(artistId)") {
            artist = saved.artist
            topSongs = saved.topSongs
            albums = saved.albums
            releases = saved.releases
            similar = saved.similar
            discographyLoading = false
            state = .loaded
        }
        await runLoad($state) {
            async let info = client.details(artistId)
            async let records = client.albums(byArtist: artistId)
            topSongs = try await client.topSongs(byArtist: artistId)
            albums = (try? await records) ?? []
            artist = try? await info
        }
        guard let artist else {
            discographyLoading = false
            return
        }
        async let publicReleases = Self.discography(artist.musicBrainzId)
        async let alike = similarArtists(for: artist, client: client)
        async let worldwide: [PublicMusic.TopTrack] = {
            guard let mbid = artist.musicBrainzId else { return [] }
            return await PublicMusic.topTracks(artistMBID: mbid)
        }()
        async let theirSongs = try? await client.songs(byArtist: artistId, limit: 500)
        let top = await worldwide
        if !top.isEmpty { popular = top }
        ownedSongs = (await theirSongs) ?? []
        let fetched = await publicReleases
        withAnimation(.easeOut(duration: 0.25)) {
            if !fetched.isEmpty || releases.isEmpty { releases = fetched }
            discographyLoading = false
        }
        let found = await alike
        if !found.isEmpty || similar.isEmpty { similar = found }
        Snapshots.save(ArtistSnapshot(artist: artist, topSongs: topSongs, albums: albums, releases: releases, similar: similar),
                       "artist-\(artistId)")
    }

    private static func discography(_ mbid: String?) async -> [PublicMusic.Release] {
        guard let mbid else { return [] }
        return await PublicMusic.discography(artistMBID: mbid)
    }

    /// Sound-alike artists from AudioMuse if it's installed, then artists people listen to together
    /// (ListenBrainz) that are in your library, then Jellyfin's genre-based matches.
    private func similarArtists(for artist: BaseItem, client: JellyfinClient) async -> [BaseItem] {
        let audioMuse = app.audioMuse
        if audioMuse.canFindSimilarArtists, let bySound = try? await audioMuse.similarArtists(to: artist.id), !bySound.isEmpty {
            return ArtistNames.distinct(bySound).filter { $0.id != artist.id }
        }
        let library = (try? await client.distinctArtists()) ?? []
        let listened = await PublicMusic.similar(to: artist, library: library).inLibrary
        if !listened.isEmpty { return Array(listened.prefix(15)) }
        let tagged = (try? await client.similar(to: artist.id)) ?? []
        return ArtistNames.distinct(tagged).filter { $0.id != artist.id }
    }
}

private struct ArtistSnapshot: Codable, Sendable {
    let artist: BaseItem?
    let topSongs: [BaseItem]
    let albums: [BaseItem]
    let releases: [PublicMusic.Release]
    let similar: [BaseItem]
}

/// An artist's releases, grouped by kind and newest first. Releases you have open their album;
/// the rest of the artist's discography (from MusicBrainz) is shown dimmed.
struct DiscographySection: View {
    let libraryAlbums: [BaseItem]
    let releases: [PublicMusic.Release]
    var artistName: String = ""
    var artistId: String? = nil
    /// The All / In Library switch (not for an artist you have nothing of).
    var showsFilter = true
    @State private var onlyMine = true

    private struct Entry: Identifiable {
        let id: String
        let title: String
        let year: Int?
        let kind: PublicMusic.Release.Kind
        let album: BaseItem?
        let coverURL: URL?
    }

    private static func normalized(_ title: String) -> String {
        title.lowercased()
            .replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
            .folding(options: [.diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    private var entries: [Entry] {
        var unmatched = libraryAlbums
        var result: [Entry] = []
        for release in releases {
            let match = unmatched.firstIndex { album in
                album.musicBrainzReleaseGroupId == release.id
                    || (!Self.normalized(album.name).isEmpty && Self.normalized(album.name) == Self.normalized(release.title))
            }
            let album = match.map { unmatched.remove(at: $0) }
            if onlyMine && !libraryAlbums.isEmpty && album == nil { continue }
            result.append(Entry(id: release.id, title: album?.name ?? release.title,
                                year: album?.productionYear ?? release.year, kind: release.kind,
                                album: album, coverURL: release.coverURL))
        }
        // Albums MusicBrainz doesn't list (or no MusicBrainz data at all).
        for album in unmatched {
            result.append(Entry(id: album.id, title: album.name, year: album.productionYear, kind: .album, album: album, coverURL: nil))
        }
        return result.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    }

    private static let groups: [(String, [PublicMusic.Release.Kind])] = [
        ("Albums", [.album, .other]), ("Singles & EPs", [.single, .ep]), ("Live", [.live]), ("Compilations", [.compilation]),
    ]

    var body: some View {
        let all = entries
        if !all.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                SectionHeader(title: "Discography") {
                    if !releases.isEmpty && showsFilter {
                        Picker("Show", selection: $onlyMine) {
                            Text("All").tag(false)
                            Text("In Library").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                }
                ForEach(Self.groups, id: \.0) { group in
                    let items = all.filter { group.1.contains($0.kind) }
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                            Text(group.0)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, Theme.Spacing.l)
                            HScroll {
                                LazyHStack(alignment: .top, spacing: Theme.Spacing.m) {
                                    ForEach(items) { entry in tile(entry) }
                                }
                                .padding(.horizontal, Theme.Spacing.l)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tile(_ entry: Entry) -> some View {
        let year = entry.year.map(String.init) ?? ""
        if let album = entry.album {
            NavigationLink(value: Route.album(id: album.id, name: album.name)) {
                AlbumTile(title: entry.title, subtitle: year, imageId: album.id, width: Theme.Size.shelfTile)
            }
            .buttonStyle(.plain)
        } else {
            let release = releases.first { $0.id == entry.id }
            NavigationLink(value: release.map { Route.publicAlbum($0, artist: artistName, artistId: artistId) }) {
                MediaTile(title: entry.title, subtitle: year.isEmpty ? nil : year, width: Theme.Size.shelfTile,
                          showsCase: true, jewelCaseURL: entry.coverURL, muted: true) {
                    RemoteArtwork(url: entry.coverURL, placeholder: "music.note")
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                WishlistButton(item: .album(artist: artistName, title: entry.title, sourceId: release?.id, cover: entry.coverURL))
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint("Not in your library")
        }
    }
}

// MARK: - Playlist

struct PlaylistView: View {
    let playlistId: String
    let name: String
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var playlist: BaseItem? = nil
    @State private var tracks: [BaseItem] = []
    @State private var state: LoadState = .loading
    @State private var confirmingDelete = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var editMode: EditMode = .inactive

    var body: some View {
        List {
            DetailHeader(imageId: playlistId, placeholder: "music.note.list", title: playlist?.name ?? name, tracks: tracks) {
                if !tracks.isEmpty {
                    Text(songCountLine(tracks))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            SongRows(tracks: tracks, keepsOrder: true, removeLabel: "Remove from Playlist", onRemove: { track in
                Task { await remove(track) }
            }, onMove: { from, to in move(from, to) })
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .loadState(state, isEmpty: tracks.isEmpty,
                   empty: EmptyState(title: "Empty playlist", symbol: "music.note.list",
                                     message: "Long-press any song and choose Add to Playlist."),
                   retry: load)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        if let playlist { app.player.startRadio(from: playlist) }
                    } label: {
                        Label("Start Radio", systemImage: "dot.radiowaves.left.and.right")
                    }
                    Button {
                        app.downloads.download(tracks)
                    } label: {
                        Label("Download Playlist", systemImage: "arrow.down.circle")
                    }
                    Divider()
                    Button {
                        newName = playlist?.name ?? name
                        renaming = true
                    } label: {
                        Label("Rename\u{2026}", systemImage: "pencil")
                    }
                    Button {
                        withAnimation { editMode = editMode == .active ? .inactive : .active }
                    } label: {
                        Label(editMode == .active ? "Done Reordering" : "Reorder Songs", systemImage: "arrow.up.arrow.down")
                    }
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("Delete Playlist", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
            }
        }
        .alert("Rename Playlist", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { Task { await rename() } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this playlist? The songs stay in your library.",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) { Task { await deletePlaylist() } }
        }
        .task { await load() }
        .refreshable {
            await JellyfinClient.clearCache()
            await load()
        }
    }

    private func load() async {
        guard let client = app.client else { return }
        await runLoad($state) {
            async let info = client.item(playlistId)
            tracks = try await client.playlistItems(playlistId).filter(\.isSong)
            playlist = try? await info
        }
    }

    private func remove(_ track: BaseItem) async {
        do {
            try await app.library.remove(track, from: playlistId)
            tracks.removeAll { $0.listId == track.listId }
        } catch {
            app.library.errorMessage = "Couldn't remove the song: \(error.localizedDescription)"
        }
    }

    private func rename() async {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            try await app.library.renamePlaylist(playlistId, to: trimmed)
            await load()
        } catch {
            app.library.errorMessage = "Couldn't rename the playlist: \(error.localizedDescription)"
        }
    }

    /// Reorders the list on screen at once, then tells the server; if that fails the list is read again.
    private func move(_ from: IndexSet, _ to: Int) {
        guard let index = from.first, tracks.indices.contains(index), let entryId = tracks[index].playlistItemId else { return }
        let destination = to > index ? to - 1 : to
        tracks.move(fromOffsets: from, toOffset: to)
        Task {
            do {
                try await app.library.move(entryId: entryId, inPlaylist: playlistId, to: destination)
            } catch {
                app.library.errorMessage = "Couldn't move the song: \(error.localizedDescription)"
                await load()
            }
        }
    }

    private func deletePlaylist() async {
        guard let playlist else { return }
        do {
            try await app.library.deletePlaylist(playlist)
            dismiss()
        } catch {
            app.library.errorMessage = "Couldn't delete the playlist: \(error.localizedDescription)"
        }
    }
}

// MARK: - Genre

struct GenreView: View {
    let genreId: String
    let name: String
    @Environment(AppModel.self) private var app
    @State private var albums: [BaseItem] = []
    @State private var state: LoadState = .loading

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                HStack(spacing: Theme.Spacing.m) {
                    PillButton(title: "Shuffle", systemImage: "shuffle") { Task { await play(radio: false) } }
                    PillButton(title: "Radio", systemImage: "dot.radiowaves.left.and.right") { Task { await play(radio: true) } }
                }
                .padding(.horizontal, Theme.Spacing.l)

                AlbumGrid(albums: albums)
            }
            .padding(.vertical, Theme.Spacing.l)
        }
        .loadState(state, isEmpty: albums.isEmpty,
                   empty: EmptyState(title: "No albums", symbol: "square.stack",
                                     message: "No albums are tagged with this genre."),
                   skeleton: .grid, retry: load)
        .navigationTitle(name)
        .task { await load() }
    }

    private func load() async {
        guard let client = app.client else { return }
        await runLoad($state) { albums = try await client.albums(inGenre: genreId) }
    }

    /// Shuffles the genre's songs, or plays them as a radio that keeps adding similar songs.
    private func play(radio: Bool) async {
        guard let client = app.client else { return }
        do {
            let songs = try await client.songs(inGenre: genreId)
            guard !songs.isEmpty else { return }
            if radio {
                app.player.play(songs, radio: true)
            } else {
                app.player.play(songs, shuffle: true)
            }
        } catch {
            app.player.errorMessage = "Couldn't play \(name): \(error.localizedDescription)"
        }
    }
}

private struct AlbumSnapshot: Codable, Sendable {
    let album: BaseItem?
    let tracks: [BaseItem]
}

// MARK: - Decade

/// Albums from one decade of your library, with Play and Shuffle for the whole decade.
struct DecadeView: View {
    let start: Int
    @Environment(AppModel.self) private var app
    @State private var albums: [BaseItem] = []
    @State private var state: LoadState = .loading

    static func name(_ start: Int) -> String {
        start >= 2000 ? "\(start)s" : "\(String(start).suffix(2))s"
    }

    private var years: [Int] { Array(start...(start + 9)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                HStack(spacing: Theme.Spacing.m) {
                    PillButton(title: "Play", systemImage: "play.fill") { play(shuffle: false) }
                    PillButton(title: "Shuffle", systemImage: "shuffle") { play(shuffle: true) }
                }
                .padding(.horizontal, Theme.Spacing.l)
                .disabled(albums.isEmpty)
                AlbumGrid(albums: albums) { album in
                    [album.albumArtistLine, album.productionYear.map(String.init)].compactMap { $0 }.joined(separator: ", ")
                }
            }
            .padding(.vertical, Theme.Spacing.m)
        }
        .loadState(state, isEmpty: albums.isEmpty,
                   empty: EmptyState(title: "No albums", symbol: "calendar", message: "Nothing in your library from the \(Self.name(start))."),
                   skeleton: .grid, retry: load)
        .navigationTitle(start >= 2000 ? "The \(start)s" : "The \(Self.name(start))")
        .task { await load() }
    }

    private func load() async {
        guard let client = app.client else { return }
        await runLoad($state) { albums = try await client.albums(years: years) }
    }

    private func play(shuffle: Bool) {
        guard let client = app.client else { return }
        let years = self.years
        app.player.play(PendingPlayback(title: "The \(Self.name(start))", subtitle: "From your library", artwork: .symbol("calendar")),
                        loading: { try await client.songsFromYears(years, limit: 1500) }, shuffle: shuffle)
    }
}

// MARK: - Featured artist

/// An artist your library only has as a feature: their photo (public data), the songs they're on,
/// and their discography from MusicBrainz when it can be found.
struct FeaturedArtistView: View {
    let name: String
    @Environment(AppModel.self) private var app

    private var songs: [BaseItem] { app.credits.songs(featuring: name) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                VStack(spacing: Theme.Spacing.m) {
                    PublicArtistPhoto(name: name)
                        .artworkFrame(size: Theme.Size.artistHero, .circle)
                        .artworkShadow()
                    Text(name)
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(songs.count == 1 ? "Featured on 1 song in your library" : "Featured on \(songs.count) songs in your library")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(spacing: Theme.Spacing.m) {
                        PillButton(title: "Play", systemImage: "play.fill") { app.player.play(songs) }
                        PillButton(title: "Shuffle", systemImage: "shuffle") { app.player.play(songs, shuffle: true) }
                    }
                    .disabled(songs.isEmpty)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.top, Theme.Spacing.m)

                if !songs.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        SectionHeader("Featured On")
                        RowStack(data: songs) { track in
                            Button {
                                app.player.play(songs, startAt: songs.firstIndex { $0.id == track.id } ?? 0)
                            } label: {
                                TrackRow(track: track)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { TrackMenu(track: track) }
                        }
                    }
                }
            }
            .padding(.bottom, Theme.Spacing.section)
        }
        .overlay {
            if songs.isEmpty {
                ContentUnavailableView(name, systemImage: "music.mic", description: Text("No songs featuring \(name) in your library yet."))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Album you don't have

/// An album from the artist's discography that isn't in your library: the cover and tracklist
/// from MusicBrainz, faded. Songs from it that you do have (on a single or another album) play.
struct PublicAlbumView: View {
    let release: PublicMusic.Release
    let artist: String
    let artistId: String?
    @Environment(AppModel.self) private var app
    @State private var tracks: [PublicMusic.Track] = []
    @State private var owned: [String: BaseItem] = [:] // track id → your copy of that song
    @State private var loading = true
    /// The lookup itself failed (as opposed to MusicBrainz having no songs): shows a retry.
    @State private var lookupFailed = false

    private var playable: [BaseItem] { tracks.compactMap { owned[$0.id] } }
    private var discs: [Int] { Array(Set(tracks.map(\.disc))).sorted() }
    private var albumWish: WishItem { .album(artist: artist, title: release.title, sourceId: release.id, cover: release.coverURL) }
    /// Where the songs come from: MusicBrainz, or Deezer or iTunes for albums MusicBrainz doesn't have.
    private var source: String { release.id.hasPrefix("dz-") ? "Deezer" : release.id.hasPrefix("it-") ? "iTunes" : "MusicBrainz" }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.l) {
                VStack(spacing: Theme.Spacing.m) {
                    RemoteArtwork(url: release.coverURL, placeholder: "music.note")
                        .squareArtwork(.rounded(Theme.Radius.hero))
                        .frame(width: Theme.Size.artistHero * 1.2)
                        .grayscale(1)
                        .opacity(0.5)
                        .artworkShadow()
                        .contextMenu {
                            WishlistButton(item: albumWish)
                        }
                    Text(release.title)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    if let artistId {
                        NavigationLink(value: Route.artist(id: artistId, name: artist)) {
                            Text(artist).font(.title3).foregroundStyle(Color.dial)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(artist).font(.title3).foregroundStyle(.secondary)
                    }
                    Text([release.year.map(String.init), "Not in your library"].compactMap { $0 }.joined(separator: ", "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if !playable.isEmpty {
                        PillButton(title: playable.count == 1 ? "Play the 1 Song You Have" : "Play the \(playable.count) Songs You Have",
                                   systemImage: "play.fill") { app.player.play(playable) }
                    }
                }
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.top, Theme.Spacing.m)

                if loading {
                    SkeletonView(style: .list)
                } else if tracks.isEmpty && lookupFailed {
                    VStack(spacing: Theme.Spacing.m) {
                        Text("Couldn\u{2019}t reach \(source) for the songs on this release.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Try Again") { Task { await load() } }
                            .buttonStyle(.bordered)
                    }
                    .padding(Theme.Spacing.l)
                } else if tracks.isEmpty {
                    Text("\(source) doesn\u{2019}t have the songs on this release.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(Theme.Spacing.l)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(discs, id: \.self) { disc in
                            if discs.count > 1 {
                                Text("Disc \(disc)")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, Theme.Spacing.l)
                                    .padding(.top, Theme.Spacing.l)
                                    .padding(.bottom, Theme.Spacing.xs)
                            }
                            ForEach(tracks.filter { $0.disc == disc }) { track in
                                row(track)
                                Divider().padding(.leading, Theme.Size.trackNumber + Theme.Spacing.l * 2)
                            }
                        }
                    }
                }
            }
            .padding(.bottom, Theme.Spacing.section)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if app.hasPlugin {
                ToolbarItem(placement: .topBarTrailing) {
                    let on = app.wishlist.contains(albumWish.id)
                    Button {
                        Task { await app.wishlist.toggle(albumWish, client: app.client) }
                    } label: {
                        Image(systemName: on ? "bookmark.fill" : "bookmark")
                    }
                    .accessibilityLabel(on ? "Remove from Wishlist" : "Add to Wishlist")
                }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private func row(_ track: PublicMusic.Track) -> some View {
        let song = owned[track.id]
        let content = HStack(spacing: Theme.Spacing.m) {
            Text("\(track.number)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: Theme.Size.trackNumber, alignment: .trailing)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(track.title).lineLimit(1)
                if let song, song.albumId != nil {
                    Text("In your library on \(song.album ?? "another release")")
                        .font(.caption)
                        .foregroundStyle(Color.dial)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Spacing.s)
            if let length = track.lengthMs {
                Text(formatTime(Double(length) / 1000))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .frame(minHeight: Theme.Size.tapTarget + Theme.Spacing.s)
        .contentShape(Rectangle())

        if let song {
            Button {
                app.player.play(playable, startAt: playable.firstIndex { $0.id == song.id } ?? 0)
            } label: { content }
            .buttonStyle(.plain)
            .contextMenu { TrackMenu(track: song) }
        } else {
            content
                .opacity(0.45)
                .contextMenu {
                    WishlistButton(item: .song(artist: artist, title: track.title, album: release.title,
                                               albumSourceId: release.id, cover: release.coverFile))
                }
                .accessibilityElement(children: .combine)
                .accessibilityHint("Not in your library")
        }
    }

    private func load() async {
        loading = tracks.isEmpty
        lookupFailed = false
        var result = await PublicMusic.tracklistChecked(releaseGroupId: release.id)
        // A hiccup (server busy, no connection for a moment) gets two more tries before it is called a failure.
        for _ in 0..<2 where result.tracks.isEmpty && result.failed {
            try? await Task.sleep(for: .seconds(3))
            result = await PublicMusic.tracklistChecked(releaseGroupId: release.id)
        }
        tracks = result.tracks
        lookupFailed = result.tracks.isEmpty && result.failed
        loading = false
        // Songs from this album you have elsewhere (a single, a compilation, a deluxe edition).
        guard let client = app.client, let artistId,
              let yours = try? await client.songs(byArtist: artistId, limit: 500) else { return }
        var byTitle: [String: BaseItem] = [:]
        for song in yours { byTitle[LibraryMatcher.key(song.name)] = byTitle[LibraryMatcher.key(song.name)] ?? song }
        var found: [String: BaseItem] = [:]
        for track in tracks {
            if let song = byTitle[LibraryMatcher.key(track.title)] { found[track.id] = song }
        }
        owned = found
    }
}


// MARK: - What the world plays

/// An artist's most played songs worldwide: the ones you have play, the others are faded, with Spotify in their menu.
struct PopularSongs: View {
    let tracks: [PublicMusic.TopTrack]
    let artistName: String
    let owned: [BaseItem]
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var showAll = false

    private func mine(_ track: PublicMusic.TopTrack) -> BaseItem? {
        owned.first { LibraryMatcher.key($0.name) == LibraryMatcher.key(track.title) }
    }

    var body: some View {
        let shown = showAll ? tracks : Array(tracks.prefix(5))
        let playable = tracks.compactMap(mine)
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionHeader(title: "Popular") {
                if tracks.count > 5 {
                    Button(showAll ? "Show Less" : "See All") { withAnimation { showAll.toggle() } }
                        .font(.subheadline.weight(.semibold))
                }
            }
            RowStack(data: shown) { track in
                if let song = mine(track) {
                    Button {
                        app.player.play(playable, startAt: playable.firstIndex { $0.id == song.id } ?? 0)
                    } label: {
                        HStack {
                            TrackRow(track: song)
                            Text(track.listens.formatted(.number.notation(.compactName)))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu { TrackMenu(track: song) }
                } else {
                    HStack(spacing: Theme.Spacing.m) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text(track.title).lineLimit(1)
                            if let album = track.album { Text(album).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer(minLength: 0)
                        Text(track.listens.formatted(.number.notation(.compactName)))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .opacity(0.5)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button {
                            let term = "\(artistName) \(track.title)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
                            if let url = URL(string: "https://open.spotify.com/search/\(term)") { openURL(url) }
                        } label: { Label("Open in Spotify", systemImage: "arrow.up.right.square") }
                        WishlistButton(item: .song(artist: artistName, title: track.title, album: track.album))
                    }
                    .accessibilityHint("Not in your library")
                }
            }
        }
    }
}

// MARK: - An artist you don't have

/// The artist page for someone who isn't in your library: the same page as for the artists you own (photo, name, what the world
/// plays, discography, similar artists), with everything faded or marked "not yours" and Follow in the corner.
struct PublicArtistView: View {
    let mbid: String
    let name: String
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var releases: [PublicMusic.Release] = []
    @State private var popular: [PublicMusic.TopTrack] = []
    @State private var similar: [PublicMusic.SimilarArtist] = []
    @State private var genres: [String] = []
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                VStack(spacing: Theme.Spacing.m) {
                    PublicArtistPhoto(name: name, mbid: mbid)
                        .artworkFrame(size: Theme.Size.artistHero, .circle)
                        .artworkShadow()
                    Text(ArtistNames.primary(name)).font(.largeTitle.bold()).multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
                    Text(([genres.prefix(3).joined(separator: ", ")].filter { !$0.isEmpty } + ["Not in your library"]).joined(separator: " \u{00B7} "))
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack(spacing: Theme.Spacing.m) {
                        PillButton(title: app.follows.isFollowing(mbid) ? "Following" : "Follow",
                                   systemImage: app.follows.isFollowing(mbid) ? "bell.fill" : "bell") {
                            Task { await app.follows.toggleFollow(artistMbid: mbid, name: ArtistNames.primary(name)) }
                        }
                        PillButton(title: "Spotify", systemImage: "arrow.up.right.square") {
                            let term = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
                            if let url = URL(string: "https://open.spotify.com/search/\(term)") { openURL(url) }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.top, Theme.Spacing.m)

                if popular.isEmpty && loading {
                    // The shape of the Popular rows while they load.
                    VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                        SkeletonBlock(width: Theme.Size.shelfTile * 0.8, height: Theme.Spacing.l + Theme.Spacing.xs)
                        ForEach(0..<4, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                                SkeletonBlock(width: Theme.Size.shelfTile * 1.3)
                                SkeletonBlock(width: Theme.Size.shelfTile * 0.8, height: Theme.Spacing.s + Theme.Spacing.xxs)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.l)
                    .shimmering()
                }
                if !popular.isEmpty { PopularSongs(tracks: popular, artistName: ArtistNames.primary(name), owned: []) }

                if loading && releases.isEmpty {
                    HScroll {
                        HStack(spacing: Theme.Spacing.m) { ForEach(0..<4, id: \.self) { _ in SkeletonTile(width: Theme.Size.shelfTile) } }
                            .padding(.horizontal, Theme.Spacing.l).shimmering()
                    }
                    .scrollDisabled(true)
                } else {
                    DiscographySection(libraryAlbums: [], releases: releases, artistName: ArtistNames.primary(name), artistId: nil, showsFilter: false)
                }

                if !similar.isEmpty {
                    Shelf(title: "Similar Artists") {
                        ForEach(similar.prefix(15)) { other in
                            NavigationLink(value: Route.publicArtist(mbid: other.mbid, name: other.name)) {
                                MediaTile(title: other.name, width: Theme.Size.shelfTile * 0.8, circular: true) {
                                    PublicArtistPhoto(name: other.name, mbid: other.mbid)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.bottom, Theme.Spacing.section)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                let following = app.follows.isFollowing(mbid)
                Button {
                    Task { await app.follows.toggleFollow(artistMbid: mbid, name: ArtistNames.primary(name)) }
                } label: {
                    Label(following ? "Following" : "Follow", systemImage: following ? "bell.fill" : "bell")
                        .labelStyle(.titleAndIcon).font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(Color.dial)
            }
        }
        .task {
            async let found = PublicMusic.discography(artistMBID: mbid)
            async let top = PublicMusic.topTracks(artistMBID: mbid)
            async let alike = PublicMusic.similarArtists(artistMBID: mbid)
            async let tags = PublicMusic.artistGenres(name: name)
            releases = await found
            loading = false
            popular = await top
            similar = await alike
            genres = (await tags) ?? []
        }
    }
}
