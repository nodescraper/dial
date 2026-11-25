import SwiftUI

/// Narrow results to one kind, like the chips in most music apps.
enum LibrarySearchScope: String, CaseIterable, Identifiable {
    case all = "All", songs = "Songs", albums = "Albums", artists = "Artists", playlists = "Playlists"
    var id: String { rawValue }
}

/// What you search in your library: forgiving name matching, songs by how they sound, and artists and albums beyond it.
struct LibrarySearchResults: View {
    @Environment(AppModel.self) private var app
    let query: String
    @Binding var scope: LibrarySearchScope
    /// Also look beyond your library (Discovery's search); off for the Library's search.
    var outside = false
    @State private var results: [BaseItem] = []
    @State private var state: LoadState = .loaded
    /// Matches from MusicBrainz that aren't in your library.
    @State private var beyond: [PublicMusic.Pick] = []
    /// True from the moment a search starts until MusicBrainz has answered: the section shows a skeleton meanwhile.
    @State private var beyondLoading = false
    /// Songs from MusicBrainz that aren't in your library (the Songs filter).
    @State private var beyondSongs: [PublicMusic.SongPick] = []

    private func shows(_ kind: LibrarySearchScope) -> Bool { scope == .all || scope == kind }
    /// With a scope chosen, show everything of that kind; otherwise a few of each.
    private func limit(_ count: Int) -> Int { scope == .all ? count : 200 }

    private var term: String { query.trimmingCharacters(in: .whitespaces) }

    private func results(ofType type: String) -> [BaseItem] { results.filter { $0.type == type } }

    private enum TopHit { case library(BaseItem), beyond(PublicMusic.Pick) }

    /// The best match for what was typed: an artist or album whose name is exactly it (yours first), else your first artist or album.
    private var topHit: TopHit? {
        let wanted = LibraryMatcher.key(term)
        if let artist = results.first(where: { $0.type == "MusicArtist" && LibraryMatcher.key($0.name) == wanted }) { return .library(artist) }
        if let pick = beyond.first(where: { $0.kind == .artist && LibraryMatcher.key($0.title) == wanted }) { return .beyond(pick) }
        if let album = results.first(where: { $0.type == "MusicAlbum" && LibraryMatcher.key($0.name) == wanted }) { return .library(album) }
        return results.first { $0.type == "MusicArtist" || $0.type == "MusicAlbum" }.map { .library($0) }
    }

    @ViewBuilder
    private func topResultCard(_ hit: TopHit) -> some View {
        switch hit {
        case .library(let item):
            let isArtist = item.type == "MusicArtist"
            NavigationLink(value: isArtist ? Route.artist(id: item.id, name: item.name) : Route.album(id: item.id, name: item.name)) {
                topCardLabel(title: item.name, subtitle: isArtist ? "Artist" : (item.artistLine.isEmpty ? "Album" : item.artistLine),
                             round: isArtist) {
                    ArtworkView(itemId: item.id, placeholder: isArtist ? "music.mic" : "music.note")
                }
            }
            .buttonStyle(.plain)
        case .beyond(let pick):
            Button { openBeyondArtist(pick, app: app) } label: {
                topCardLabel(title: pick.title, subtitle: "Artist · not in your library", round: true) {
                    RemoteArtwork(url: pick.image, placeholder: "music.mic")
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func topCardLabel<Art: View>(title: String, subtitle: String, round: Bool, @ViewBuilder art: () -> Art) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            art()
                .frame(width: 84, height: 84)
                .clipShape(round ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 10, style: .continuous)))
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(title).font(.title2.weight(.bold)).lineLimit(2)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 14, style: .continuous))
        .contentShape(.rect)
    }

    /// An artist from outside the library, in the artist shelf.
    private func beyondArtistTile(_ pick: PublicMusic.Pick) -> some View {
        Button { openBeyondArtist(pick, app: app) } label: {
            MediaTile(title: pick.title, subtitle: "Not in library", width: 110, circular: true) {
                RemoteArtwork(url: pick.image, placeholder: "music.mic")
            }
        }
        .buttonStyle(.plain)
    }

    /// An album from outside the library, in the album shelf.
    private func beyondAlbumTile(_ pick: PublicMusic.Pick) -> some View {
        NavigationLink(value: Route.publicAlbum(pick.release, artist: pick.artist ?? "", artistId: nil)) {
            MediaTile(title: pick.title, subtitle: pick.artist, width: 140) {
                RemoteArtwork(url: pick.cover, placeholder: "music.note")
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            WishlistButton(item: .album(artist: pick.artist ?? "", title: pick.title, sourceId: pick.release.id, cover: pick.cover))
        }
    }

    /// "Show all" under a section on All: opens that kind as a full list (the scope chip).
    private func showAllButton(_ kind: LibrarySearchScope) -> some View {
        Button("Show all") { scope = kind }
            .buttonStyle(.borderless)
            .font(.subheadline.weight(.semibold))
            .listRowSeparator(.hidden)
    }

    var body: some View {
        Group {
            if outside { discoveryBody } else { libraryBody }
        }
        .listStyle(.plain)
        .loadState(state, isEmpty: term.count >= 2 && results.isEmpty && beyond.isEmpty && beyondSongs.isEmpty && !beyondLoading,
                   empty: EmptyState(title: "No results", symbol: "magnifyingglass",
                                     message: "Nothing in your library matches \u{201C}\(term)\u{201D}."),
                   skeleton: !outside ? .librarySearch : scope == .all ? .search : scope == .artists ? .circleGrid : (scope == .albums || scope == .playlists) ? .grid : .list,
                   retry: runSearch)
        // A new word, or a different filter (Songs, Artists...), looks everything up again.
        .task(id: "\(query)|\(scope.rawValue)") { await runSearch() }
    }

    /// Library search: one plain list with a header per kind, and the same rows as the songs. Nothing from outside.
    private var libraryBody: some View {
        let artists = results(ofType: "MusicArtist")
        let albums = results(ofType: "MusicAlbum")
        let songs = results(ofType: "Audio")
        let playlists = results(ofType: "Playlist").filter { !DailyMixes.isGenerated($0.name) }
        return List {
            if app.connectivity.isOffline {
                OfflineBanner()
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .padding(.vertical, Theme.Spacing.s)
            }
            if shows(.artists) && !artists.isEmpty {
                Section {
                    ForEach(artists) { artist in
                        NavigationLink(value: Route.artist(id: artist.id, name: artist.name)) { ArtistRow(artist: artist) }
                            .buttonStyle(.plain)
                    }
                } header: { sectionTitle("Artists") }
            }
            if shows(.albums) && !albums.isEmpty {
                Section {
                    ForEach(albums) { album in
                        NavigationLink(value: Route.album(id: album.id, name: album.name)) { AlbumRow(album: album) }
                            .buttonStyle(.plain)
                    }
                } header: { sectionTitle("Albums") }
            }
            if shows(.playlists) && !playlists.isEmpty {
                Section {
                    ForEach(playlists) { playlist in
                        NavigationLink(value: Route.playlist(id: playlist.id, name: playlist.name)) { PlaylistRow(playlist: playlist) }
                            .buttonStyle(.plain)
                    }
                } header: { sectionTitle("Playlists") }
            }
            if shows(.songs) && !songs.isEmpty {
                Section {
                    SongRows(tracks: songs)
                } header: { sectionTitle("Songs") }
            }
        }
    }

    /// Discovery's search: your library first, then music beyond it, as shelves (see the Top Result and Show all).
    private var discoveryBody: some View {
        let artists = results(ofType: "MusicArtist")
        let albums = results(ofType: "MusicAlbum")
        let songs = results(ofType: "Audio")
        let playlists = results(ofType: "Playlist").filter { !DailyMixes.isGenerated($0.name) }

        let beyondArtists = beyond.filter { $0.kind == .artist }
        let beyondAlbums = beyond.filter { $0.kind == .album }
        // On All, each kind is a shelf of a few; the rest are one tap away with "Show all". A chosen kind shows everything.
        let cap = scope == .all ? 10 : 200
        let libraryArtistsShown = Array(artists.prefix(cap))
        let beyondArtistsShown = Array(beyondArtists.prefix(max(0, cap - libraryArtistsShown.count)))
        let libraryAlbumsShown = Array(albums.prefix(cap))
        let beyondAlbumsShown = Array(beyondAlbums.prefix(max(0, cap - libraryAlbumsShown.count)))
        let playlistsShown = Array(playlists.prefix(cap))
        let songsCap = scope == .all ? 5 : 200

        // A scroll view, not a List: in a List a long press lifts the whole row (a whole shelf of covers), not the one cover.
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.l) {
                if app.connectivity.isOffline {
                    OfflineBanner()
                }
                if scope == .all, let hit = topHit {
                    block("Top Result") {
                        topResultCard(hit).padding(.horizontal, Theme.Spacing.l)
                    }
                }
                // Artists, albums and playlists as shelves of covers (a grid when one kind is chosen): your library first, then beyond it.
                if shows(.artists) && !(libraryArtistsShown.isEmpty && beyondArtistsShown.isEmpty) {
                    shelfSection("Artists", more: artists.count + beyondArtists.count > cap ? .artists : nil) {
                        ForEach(libraryArtistsShown) { artist in ArtistTile(artist: artist, width: 110) }
                        ForEach(beyondArtistsShown) { pick in beyondArtistTile(pick) }
                    }
                }
                if shows(.albums) && !(libraryAlbumsShown.isEmpty && beyondAlbumsShown.isEmpty) {
                    shelfSection("Albums", more: albums.count + beyondAlbums.count > cap ? .albums : nil) {
                        ForEach(libraryAlbumsShown) { album in
                            NavigationLink(value: Route.album(id: album.id, name: album.name)) { AlbumTile(album: album, width: 140) }
                                .buttonStyle(.plain)
                        }
                        ForEach(beyondAlbumsShown) { pick in beyondAlbumTile(pick) }
                    }
                }
                if !playlists.isEmpty && shows(.playlists) {
                    shelfSection("Playlists", more: playlists.count > cap ? .playlists : nil) {
                        ForEach(playlistsShown) { playlist in
                            NavigationLink(value: Route.playlist(id: playlist.id, name: playlist.name)) {
                                MediaTile(title: playlist.name, width: 140) { ArtworkView(itemId: playlist.id, placeholder: "music.note.list") }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if shows(.songs) && (!songs.isEmpty || !beyondSongs.isEmpty) {
                    let songsShown = Array(songs.prefix(songsCap))
                    block("Songs", more: scope == .all && songs.count + beyondSongs.count > 8 ? .songs : nil) {
                        VStack(spacing: 0) {
                            RowStack(data: songsShown) { track in
                                Button {
                                    app.player.play(songsShown, startAt: songsShown.firstIndex { $0.id == track.id } ?? 0, radio: true)
                                } label: { TrackRow(track: track) }
                                .buttonStyle(.plain)
                                .contextMenu { TrackMenu(track: track) }
                            }
                            RowStack(data: Array(beyondSongs.prefix(scope == .all ? 3 : 200)), dividerInset: Theme.Spacing.l) { song in
                                beyondSongRow(song)
                            }
                        }
                    }
                }
                if beyondLoading && beyond.isEmpty && beyondSongs.isEmpty && (scope == .all || scope == .artists || scope == .albums || scope == .songs) {
                    // The same shapes the results will have: circles for artists, covers for albums, rows for songs.
                    block("Beyond Your Library") {
                        if scope == .all || scope == .artists {
                            skeletonShelf(width: 110, circular: true)
                        }
                        if scope == .all || scope == .albums {
                            skeletonShelf(width: 130, circular: false)
                        }
                        if scope == .songs {
                            ForEach(0..<3, id: \.self) { _ in SkeletonRow().padding(.horizontal, Theme.Spacing.l) }
                        }
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.s)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    /// A row of tiles in the shape of a shelf of results, shimmering.
    private func skeletonShelf(width: CGFloat, circular: Bool) -> some View {
        // Not a scroll view: inside a list row it reported too little height, so the tile captions ran under the next shelf.
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            ForEach(0..<4, id: \.self) { _ in SkeletonTile(width: width, circular: circular).frame(width: width) }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.title3.weight(.semibold)).foregroundStyle(.primary).textCase(nil)
    }

    /// A titled part of Discovery's search, with "Show all" when there is more of it.
    private func block<Content: View>(_ title: String, more: LibrarySearchScope? = nil,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                sectionTitle(title)
                Spacer()
                if let more { showAllButton(more) }
            }
            .padding(.horizontal, Theme.Spacing.l)
            content()
        }
    }

    /// A kind of result as a shelf of covers; with one kind chosen, as a grid of them.
    private func shelfSection<Content: View>(_ title: String, more: LibrarySearchScope? = nil,
                                             @ViewBuilder _ content: @escaping () -> Content) -> some View {
        block(title, more: more) {
            Group {
                if scope == .all {
                    HScroll {
                        LazyHStack(alignment: .top, spacing: Theme.Spacing.m, content: content)
                            .padding(.horizontal, Theme.Spacing.l)
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: Theme.Spacing.m, alignment: .top)], spacing: Theme.Spacing.l, content: content)
                        .padding(.horizontal, Theme.Spacing.l)
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
    }

    /// A song you don't have: opens the album it is on (faded tracklist); long press to add it to your wishlist.
    @ViewBuilder
    private func beyondSongRow(_ song: PublicMusic.SongPick) -> some View {
        let label = VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(song.title).lineLimit(1)
            Text([song.artist, song.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .opacity(0.7)
        let wish = WishItem.song(artist: song.artist, title: song.title, album: song.album,
                                 albumSourceId: song.albumSourceId, cover: song.albumCover)
        if let album = song.album, !album.isEmpty {
            Button {
                openOutsideAlbum(artist: song.artist, title: album, sourceId: song.albumSourceId, cover: song.albumCover, app: app)
            } label: { label }
                .buttonStyle(.plain)
                .contextMenu {
                    WishlistButton(item: wish)
                }
        } else {
            label.contextMenu {
                WishlistButton(item: wish)
            }
        }
    }

    private func runSearch() async {
        let term = self.term
        guard term.count >= 2, let client = app.client else {
            results = []
            beyond = []
            beyondSongs = []
            beyondLoading = false
            state = .loaded
            return
        }
        if app.connectivity.isOffline {
            results = app.downloads.downloadedSongs.filter { song in
                [song.name, song.artistLine, song.album ?? ""].contains { $0.localizedStandardContains(term) }
            }
            state = .loaded
            return
        }
        state = .loading
        beyond = []
        beyondSongs = []
        beyondLoading = outside && term.count >= 3
        defer { if !Task.isCancelled { beyondLoading = false } }
        try? await Task.sleep(for: .milliseconds(150)) // wait until typing pauses
        guard !Task.isCancelled else { return }
        await runLoad($state) { results = try await client.search(term) }
        guard !Task.isCancelled else { return }
        // Then the wider world: what matches but isn't in your library.
        beyond = []
        beyondSongs = []
        guard outside, term.count >= 3 else { return }
        if scope == .all || scope == .songs {
            let found = await PublicMusic.searchSongs(term)
            guard !Task.isCancelled else { return }
            let yours = Set(results.filter { $0.type == "Audio" }.map { LibraryMatcher.key($0.name) })
            beyondSongs = found.filter { !yours.contains(LibraryMatcher.key($0.title)) }
        }
        if scope == .all || scope == .artists || scope == .albums {
            let found = await PublicMusic.search(term)
            guard !Task.isCancelled else { return }
            let yours = Set(results.map { LibraryMatcher.key($0.name) })
            beyond = found.filter { !yours.contains(LibraryMatcher.key($0.title)) }
        }
    }
}

// MARK: - Discovery

/// The Discovery tab, for a library you chose yourself: nothing global or random, only what concerns the artists you own.
/// New albums by them, who their fans also play and (with a free Ticketmaster key) their concerts.
/// Saved and shown at once, refreshed a part at a time (see `DiscoveryEngine`).
struct DiscoveryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var feed = DiscoveryEngine.saved()
    @State private var owned = OwnershipIndex()
    @State private var loaded = false
    @State private var preview: DiscoverPreview?
    /// True until the first refresh has finished (it usually has, long before the page is opened).
    @State private var refreshing = true
    @State private var tab: DiscoveryTab = .forYou
    /// Albums by the artists you play most that you do not have (from their saved discographies).
    @State private var gaps: [PublicMusic.Pick] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                if app.connectivity.isOffline { OfflineBanner() }

                DiscoveryTabBar(tab: $tab)

                switch tab {
                case .forYou: forYou
                case .calendar:
                    ReleaseCalendar(picks: (feed.fresh + feed.upcoming).uniqued(), owned: owned)
                case .following: FollowingTab()
                }
            }
            .padding(.vertical, Theme.Spacing.m)
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("Discovery")
        .offlineCover("Discovery needs a connection", "New releases, artist pages and Following look things up online. They are back as soon as the server can be reached.")
        .artistPreview($preview, app: app)
        .task { await load() }
        .task(id: feed.artists.count) { await loadGaps() }
        .refreshable { await load(force: true) }
    }

    /// For each artist you play most, their albums (not EPs, singles or live records) that are not in your library, newest first.
    private func loadGaps() async {
        var found: [PublicMusic.Pick] = []
        for artist in feed.artists.prefix(25) {
            guard let saved = await PublicMusic.savedDiscography(artistMBID: artist.mbid) else { continue }
            let picks = saved.releases.filter { $0.kind == .album }.prefix(8).map {
                PublicMusic.Pick(kind: .album, mbid: $0.id, title: $0.title, artist: artist.name, artistMbid: artist.mbid,
                                 year: $0.year, tags: [], releaseDate: $0.date)
            }.filter { owned.album($0) == nil }
            found += picks.prefix(2)
        }
        gaps = Array(found.uniqued().prefix(18))
    }

    // MARK: For You

    @ViewBuilder
    private func shelf(_ title: String, _ picks: [PublicMusic.Pick], limit: Int = 20) -> some View {
        let shown = picks.uniqued()
        if !shown.isEmpty {
            Shelf(title: title) {
                ForEach(shown.prefix(limit)) { pick in
                    DiscoveryReleaseTile(pick: pick, ownedArtist: owned.artist(of: pick))
                }
            }
        }
    }

    private func daysSince(_ pick: PublicMusic.Pick) -> Int {
        -(ReleaseDates.date(pick).map(ReleaseDates.days(from:)) ?? -400)
    }

    @ViewBuilder
    private var forYou: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.section) {
            // The biggest news first (the releases of the artists you play most), then the shelves, in the look of Recently Added.
            let heroes = DiscoveryHighlights.make(feed: feed, owned: owned)
            if !heroes.isEmpty { HighlightsRow(highlights: heroes, captioned: true) }

            if isLoading("releases", empty: feed.fresh.isEmpty && feed.upcoming.isEmpty, flag: feed.releasesLoading) {
                VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                    DiscoveryHeroSkeleton()
                    ReleasesSkeleton()
                }
            } else {
                shelf("Coming Soon", feed.upcoming)
                shelf("New This Week", feed.fresh.filter { daysSince($0) <= 7 })
                shelf("Recent Releases", feed.fresh.filter { (8...40).contains(daysSince($0)) })
                shelf("Complete Your Collection", gaps, limit: 18)
                shelf("Earlier", feed.fresh.filter { daysSince($0) > 40 })
                if feed.fresh.isEmpty && feed.upcoming.isEmpty && gaps.isEmpty {
                    ContentUnavailableView("Nothing new yet", systemImage: "sparkles",
                                           description: Text("When an artist you own puts something out, or announces a date, it shows up here."))
                }
            }

            if isLoading("fans", empty: feed.fans.isEmpty, flag: feed.fansLoading) {
                FansSkeleton()
            } else if !feed.fans.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    header("Because You Listen", "Artists that fit what you play")
                    ForEach(feed.fans.prefix(2)) { fans($0) }
                }
            }

            concerts
        }
    }

    /// A row is loading when it has nothing to show yet and has not been looked up since the app opened.
    private func isLoading(_ row: String, empty: Bool, flag: Bool) -> Bool {
        empty && (flag || refreshing)
    }

    // MARK: Building blocks

    /// A section title: big and bold for the main sections, quiet and grey for the rows under them.
    private func header(_ title: String, _ subtitle: String? = nil, light: Bool = false, seeAll picks: [PublicMusic.Pick]? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(light ? .headline : .title3.weight(.semibold))
                    .foregroundStyle(light ? .secondary : .primary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let picks, picks.count > 8 {
                    Button { app.navigator.open(.discoverList(title: title, picks: picks)) } label: {
                        Text("See All").font(.subheadline.weight(.semibold)).foregroundStyle(Color.dial)
                            .padding(.vertical, Theme.Spacing.xs).padding(.leading, Theme.Spacing.m).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, Theme.Spacing.l)
    }

    // MARK: Fans also play

    private func fans(_ group: DiscoverData.FanGroup) -> some View {
        // Artists with a photo first, so the row looks complete.
        let ordered = group.picks.filter { $0.image != nil } + group.picks.filter { $0.image == nil }
        let title = "Fans of \(group.seedName)"
        return VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            header(title, light: true, seeAll: ordered)
            HScroll {
                LazyHStack(alignment: .top, spacing: Theme.Spacing.l) {
                    ForEach(ordered.uniqued().prefix(14)) { pick in
                        PickArtistTile(pick: pick, owned: owned.artist(pick), width: 88) {
                            preview = DiscoverPreview(item: DiscoverItem(mbid: pick.mbid, name: pick.title, libraryArtist: nil), because: title)
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.l)
            }
        }
    }

    // MARK: Concerts

    @ViewBuilder
    private var concerts: some View {
        if feed.concertsEnabled {
            if isLoading("concerts", empty: feed.concerts.isEmpty, flag: feed.concertsLoading) {
                ConcertsSkeleton()
            } else if !feed.concerts.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("On Tour").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                            Text("Upcoming concerts by artists you own").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { app.navigator.open(.onTour(concerts: feed.concerts)) } label: {
                            Text("See All").font(.subheadline.weight(.semibold)).foregroundStyle(Color.dial)
                                .padding(.vertical, Theme.Spacing.xs).padding(.leading, Theme.Spacing.m).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, Theme.Spacing.l)
                    HScroll {
                        LazyHStack(spacing: Theme.Spacing.m) {
                            ForEach(feed.concerts.sorted { $0.date < $1.date }.prefix(10)) { concert in
                                Button { openURL(concert.url) } label: { ConcertCard(concert: concert) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.l)
                    }
                }
            }
        }
    }

    // MARK: Loading

    private func load(force: Bool = false) async {
        // What was saved last is shown at once; nothing below waits on the network.
        if feed.isEmpty, let saved = await Snapshots.load(DiscoveryFeed.self, DiscoveryEngine.snapshotKey) { feed = saved }
        loaded = true
        guard let client = app.client, !app.connectivity.isOffline else { refreshing = false; return }
        owned = await OwnershipIndex.load(client: client)
        await loadGaps()
        // The refresh runs in the background and updates the page as parts arrive (it has usually done its work already,
        // started soon after the app opened).
        await DiscoveryEngine.refresh(client: client, owned: owned, force: force) { updated in feed = updated }
        refreshing = false
    }
}

/// A grey bar of a section title, for the skeletons.
private func skeletonBar(_ width: CGFloat, _ height: CGFloat = 16) -> some View {
    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary.opacity(0.6)).frame(width: width, height: height)
}

/// "New From Your Artists" while it loads: a title bar and a row of cover-shaped boxes, shimmering. Only a loading indicator.
private struct ReleasesSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            skeletonBar(230, 22).padding(.horizontal, Theme.Spacing.l)
            HScroll {
                HStack(alignment: .top, spacing: Theme.Spacing.m) {
                    ForEach(0..<3, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).fill(.quaternary.opacity(0.6)).frame(width: 148, height: 148)
                            skeletonBar(110, 12)
                            skeletonBar(80, 10)
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.l)
                .shimmering()
            }
            .scrollDisabled(true)
        }
        .accessibilityHidden(true)
    }
}

/// The "Fans of ..." row while it loads: a title bar and a row of circles, shimmering.
private struct FansSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            skeletonBar(190, 22).padding(.horizontal, Theme.Spacing.l)
            skeletonBar(120, 14).padding(.horizontal, Theme.Spacing.l)
            HScroll {
                HStack(alignment: .top, spacing: Theme.Spacing.l) {
                    ForEach(0..<5, id: \.self) { _ in
                        VStack(spacing: Theme.Spacing.xs) {
                            Circle().fill(.quaternary.opacity(0.6)).frame(width: 88, height: 88)
                            skeletonBar(64, 10)
                            skeletonBar(44, 8)
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.l)
                .shimmering()
            }
            .scrollDisabled(true)
        }
        .accessibilityHidden(true)
    }
}

/// "On Tour" while it loads: a title bar and event-card-shaped boxes, shimmering.
private struct ConcertsSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            skeletonBar(130, 22).padding(.horizontal, Theme.Spacing.l)
            HScroll {
                HStack(spacing: Theme.Spacing.m) {
                    ForEach(0..<2, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.quaternary.opacity(0.6))
                            .frame(width: ConcertCard.width, height: ConcertCard.height)
                    }
                }
                .padding(.horizontal, Theme.Spacing.l)
                .shimmering()
            }
            .scrollDisabled(true)
        }
        .accessibilityHidden(true)
    }
}

/// A colour pair from a name, always the same for the same name: the stand-in cover for a release with no artwork yet.
private func discoveryColors(_ seed: String) -> [Color] {
    let palette: [[Color]] = [
        [Color(red: 0.45, green: 0.25, blue: 0.7), Color(red: 0.9, green: 0.45, blue: 0.55)],
        [Color(red: 0.15, green: 0.35, blue: 0.65), Color(red: 0.3, green: 0.75, blue: 0.8)],
        [Color(red: 0.7, green: 0.3, blue: 0.15), Color(red: 0.95, green: 0.7, blue: 0.3)],
        [Color(red: 0.12, green: 0.45, blue: 0.4), Color(red: 0.55, green: 0.85, blue: 0.55)],
        [Color(red: 0.5, green: 0.12, blue: 0.25), Color(red: 0.9, green: 0.4, blue: 0.4)],
        [Color(red: 0.2, green: 0.2, blue: 0.45), Color(red: 0.55, green: 0.5, blue: 0.9)],
    ]
    return palette[abs(seed.unicodeScalars.reduce(0) { $0 + Int($1.value) }) % palette.count]
}

/// A concert as a card, like Apple's event cards: the artwork across the whole card, the date in a frosted badge, the artist
/// and where over a soft gradient, and a Tickets button.
struct ConcertCard: View {
    let concert: Concert
    static let width: CGFloat = 300
    static let height: CGFloat = 220

    fileprivate var date: Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: concert.date)
    }

    private var place: String { [concert.venue, concert.city].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ") }
    private var detail: String { date?.formatted(.dateTime.weekday(.wide)) ?? "" }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            artwork
            LinearGradient(colors: [.black.opacity(0.0), .black.opacity(0.78)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    dateBadge
                    Spacer()
                }
                Spacer(minLength: 0)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(concert.artist).font(.title3.weight(.bold)).foregroundStyle(.white).lineLimit(1)
                        Label { Text(place).lineLimit(1) } icon: { Image(systemName: "mappin.and.ellipse") }
                            .font(.subheadline).foregroundStyle(.white.opacity(0.9))
                        Text(detail).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                    Spacer(minLength: Theme.Spacing.s)
                    // A circle that says it goes somewhere: to the tickets, or (for several shows) opens them in a row.
                    Image(systemName: "location.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
                }
            }
            .padding(14)
        }
        .frame(width: Self.width, height: Self.height)
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(concert.artist), \(concert.venue) \(concert.city), \(concert.date). Tickets")
    }

    @ViewBuilder
    private var artwork: some View {
        Color.clear.overlay {
            if let image = concert.image {
                RemoteImage(url: image) { stand }
            } else {
                stand
            }
        }
        .clipped()
    }

    private var stand: some View {
        ZStack {
            LinearGradient(colors: discoveryColors(concert.artist), startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.mic").font(.system(size: 54, weight: .light)).foregroundStyle(.white.opacity(0.35))
        }
    }

    private var dateBadge: some View {
        VStack(spacing: 0) {
            Text(date.map { $0.formatted(.dateTime.month(.abbreviated)).uppercased() } ?? "")
                .font(.caption2.weight(.bold)).foregroundStyle(Color.dial)
            Text(date.map { $0.formatted(.dateTime.day()) } ?? "")
                .font(.title3.weight(.bold)).foregroundStyle(.primary)
        }
        .frame(width: 48, height: 52)
        .background(.regularMaterial, in: .rect(cornerRadius: 12, style: .continuous))
    }
}

/// Discovery's settings: the optional concert key and city, and the saved data.
struct DiscoverySettingsView: View {
    @AppStorage(DiscoveryEngine.ticketmasterKeyDefaults) private var key = ""
    @AppStorage(DiscoveryEngine.cityDefaults) private var city = ""
    @AppStorage(DiscoveryEngine.countryDefaults) private var country = ""
    @State private var cleared = false

    var body: some View {
        Form {
            Section {
                SecureField("Ticketmaster API key", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("City (optional)", text: $city)
                TextField("Country code, like GB or US (optional)", text: $country)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
            } header: {
                Text("Concerts")
            } footer: {
                Text("Discovery can show upcoming concerts by artists you own. It needs a free key from developer.ticketmaster.com. With a key, the names of your most played artists are sent to Ticketmaster to look up their events; without one, nothing is sent.")
            }
            Section {
                Button(cleared ? "Cleared" : "Clear Discovery Cache") {
                    DiscoveryEngine.clearCache()
                    cleared = true
                }
                .disabled(cleared)
            } footer: {
                Text("Discovery keeps what it found, so it opens at once: concerts for twelve hours, releases for a day and each artist\u{2019}s albums for a few days. Clearing it makes Discovery look everything up again, which takes a minute.")
            }
        }
        .navigationTitle("Discovery")
        .onChange(of: key) { _, _ in Freshness.clear(DiscoveryEngine.concertsKey) }
        .onChange(of: city) { _, _ in Freshness.clear(DiscoveryEngine.concertsKey) }
        .onChange(of: country) { _, _ in Freshness.clear(DiscoveryEngine.concertsKey) }
    }
}

/// Everything on the discovery page, saved so it opens instantly next time.
struct DiscoverData: Codable, Sendable {
    struct FanGroup: Codable, Sendable, Identifiable {
        let seedName: String
        let picks: [PublicMusic.Pick]
        var id: String { seedName }
    }

    var fromYourArtists: [PublicMusic.Pick] = []
    var fans: [FanGroup] = []
    var popularArtists: [PublicMusic.Pick] = []
    var popularAlbums: [PublicMusic.Pick] = []
    var fresh: [PublicMusic.Pick] = []

    var isEmpty: Bool { fans.isEmpty && popularArtists.isEmpty && popularAlbums.isEmpty && fresh.isEmpty && fromYourArtists.isEmpty }
}

/// What's in your library, as a small lookup (names and ids only), to mark "In your library" fast.
struct OwnershipIndex: Codable, Sendable {
    struct Ref: Codable, Sendable, Hashable { let id: String; let name: String }
    var artistsByMbid: [String: Ref] = [:]
    var artistsByName: [String: Ref] = [:]
    var albumsByKey: [String: Ref] = [:]

    init() {}

    @MainActor init(artists: [BaseItem], albums: [BaseItem]) {
        for artist in artists {
            let ref = Ref(id: artist.id, name: artist.name)
            if let mbid = artist.musicBrainzId { artistsByMbid[mbid] = ref }
            artistsByName[ArtistNames.key(artist.name)] = ref
        }
        for album in albums {
            albumsByKey[Self.albumKey(album.name, album.albumArtistLine)] = Ref(id: album.id, name: album.name)
            albumsByKey[Self.albumKey(album.name, nil)] = albumsByKey[Self.albumKey(album.name, nil)] ?? Ref(id: album.id, name: album.name)
        }
    }

    @MainActor static func albumKey(_ title: String, _ artist: String?) -> String {
        LibraryMatcher.key(title) + "|" + (artist.map { ArtistNames.key(ArtistNames.primary($0)) } ?? "")
    }

    func artist(_ pick: PublicMusic.Pick) -> Ref? { artistsByMbid[pick.mbid] ?? artistsByName[ArtistNames.key(pick.title)] }

    func artist(of pick: PublicMusic.Pick) -> Ref? {
        if let mbid = pick.artistMbid, let ref = artistsByMbid[mbid] { return ref }
        return pick.artist.flatMap { artistsByName[ArtistNames.key(ArtistNames.primary($0))] }
    }

    @MainActor func album(_ pick: PublicMusic.Pick) -> Ref? {
        albumsByKey[Self.albumKey(pick.title, pick.artist)] ?? (pick.artist == nil ? albumsByKey[Self.albumKey(pick.title, nil)] : nil)
    }

    /// Built once in the background and saved; refreshed when the library changes.
    @MainActor static func load(client: JellyfinClient) async -> OwnershipIndex {
        if let memory = current { return memory }
        if let saved = await Snapshots.load(OwnershipIndex.self, "ownership"), !saved.artistsByName.isEmpty {
            current = saved
            // Quietly keep it current, at most once an hour.
            if !Freshness.isFresh("ownership", maxAge: 3600) { Task { await rebuild(client: client) } }
            return saved
        }
        return await rebuild(client: client)
    }

    /// Kept in memory once loaded, so every screen shares one copy.
    @MainActor private static var current: OwnershipIndex?

    @MainActor @discardableResult
    static func rebuild(client: JellyfinClient) async -> OwnershipIndex {
        async let artists = client.distinctArtists()
        async let albums = client.albums(sortedBy: .title)
        let index = OwnershipIndex(artists: (try? await artists) ?? [], albums: (try? await albums) ?? [])
        Snapshots.save(index, "ownership")
        Freshness.mark("ownership")
        current = index
        return index
    }
}

/// A round artist photo: yours open the artist page, new ones a preview.
private struct PickArtistTile: View {
    let pick: PublicMusic.Pick
    let owned: OwnershipIndex.Ref?
    var width: CGFloat? = Theme.Size.shelfTile * 0.8
    let onPreview: () -> Void

    var body: some View {
        if let owned {
            NavigationLink(value: Route.artist(id: owned.id, name: owned.name)) {
                label(subtitle: "In your library", tint: .secondary) { ArtworkView(itemId: owned.id, placeholder: "music.mic") }
            }
            .buttonStyle(.plain)
        } else {
            Button(action: onPreview) {
                label(subtitle: "", tint: .secondary) {
                    if let image = pick.image { RemoteArtwork(url: image, placeholder: "music.mic") }
                    else { PublicArtistPhoto(name: pick.title, mbid: pick.mbid) }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func label<Photo: View>(subtitle: String, tint: Color, @ViewBuilder photo: () -> Photo) -> some View {
        VStack(spacing: Theme.Spacing.xs) {
            // In a row (with a width) the photo is exactly that size; in a grid it fills its cell.
            if let width {
                photo().squareArtwork(.circle).frame(width: width, height: width)
            } else {
                photo().squareArtwork(.circle).frame(maxWidth: .infinity)
            }
            Text(pick.title).font(.caption.weight(.medium)).lineLimit(2).multilineTextAlignment(.center)
            if !subtitle.isEmpty { Text(subtitle).font(.caption2).foregroundStyle(tint) }
        }
        .frame(maxWidth: width ?? .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// An album cover: yours open the album, others a page with its tracklist (faded).
private struct PickAlbumTile: View {
    let pick: PublicMusic.Pick
    let owned: OwnershipIndex.Ref?
    let ownedArtist: OwnershipIndex.Ref?
    var width: CGFloat? = Theme.Size.shelfTile

    var body: some View {
        if let owned {
            NavigationLink(value: Route.album(id: owned.id, name: owned.name)) {
                AlbumTile(title: owned.name, subtitle: "In your library", imageId: owned.id, width: width)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: Route.publicAlbum(pick.release, artist: pick.artist ?? "", artistId: ownedArtist?.id)) {
                MediaTile(title: pick.title, subtitle: pick.artist, width: width) {
                    RemoteArtwork(url: pick.cover, placeholder: "music.note")
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                WishlistButton(item: .album(artist: pick.artist ?? "", title: pick.title, sourceId: pick.release.id, cover: pick.cover))
            }
        }
    }
}

/// Genres to explore, each opening the artists MusicBrainz tags with it and what's new in it.
private struct GenreGrid: View {
    static let genres: [(name: String, colors: [Color], symbol: String)] = [
        ("Hip Hop", [Color(red: 0.55, green: 0.2, blue: 0.15), Color(red: 0.95, green: 0.55, blue: 0.25)], "music.mic"),
        ("R&B", [Color(red: 0.45, green: 0.15, blue: 0.4), Color(red: 0.9, green: 0.45, blue: 0.55)], "heart.fill"),
        ("Pop", [Color(red: 0.85, green: 0.3, blue: 0.55), Color(red: 0.98, green: 0.7, blue: 0.4)], "sparkles"),
        ("Rock", [Color(red: 0.25, green: 0.25, blue: 0.3), Color(red: 0.75, green: 0.3, blue: 0.25)], "guitars.fill"),
        ("Electronic", [Color(red: 0.15, green: 0.2, blue: 0.55), Color(red: 0.35, green: 0.75, blue: 0.85)], "waveform"),
        ("Jazz", [Color(red: 0.2, green: 0.3, blue: 0.35), Color(red: 0.85, green: 0.65, blue: 0.3)], "music.quarternote.3"),
        ("Indie", [Color(red: 0.3, green: 0.45, blue: 0.3), Color(red: 0.85, green: 0.8, blue: 0.5)], "leaf.fill"),
        ("Soul", [Color(red: 0.5, green: 0.25, blue: 0.1), Color(red: 0.95, green: 0.7, blue: 0.3)], "sun.max.fill"),
        ("Latin", [Color(red: 0.75, green: 0.2, blue: 0.2), Color(red: 0.98, green: 0.75, blue: 0.2)], "flame.fill"),
        ("Metal", [Color(red: 0.1, green: 0.1, blue: 0.12), Color(red: 0.45, green: 0.45, blue: 0.5)], "bolt.fill"),
        ("Classical", [Color(red: 0.35, green: 0.3, blue: 0.25), Color(red: 0.85, green: 0.8, blue: 0.7)], "pianokeys"),
        ("Folk", [Color(red: 0.4, green: 0.3, blue: 0.2), Color(red: 0.75, green: 0.6, blue: 0.4)], "tree.fill"),
    ]

    private let columns = [GridItem(.adaptive(minimum: Theme.Size.gridTileMin), spacing: Theme.Spacing.m)]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeader("Explore Genres")
            LazyVGrid(columns: columns, spacing: Theme.Spacing.m) {
                ForEach(Self.genres, id: \.name) { genre in
                    NavigationLink(value: Route.exploreGenre(name: genre.name)) {
                        ZStack(alignment: .topLeading) {
                            LinearGradient(colors: genre.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                            Text(genre.name).font(.headline).foregroundStyle(.white).padding(Theme.Spacing.m)
                            Image(systemName: genre.symbol)
                                .font(.largeTitle)
                                .foregroundStyle(.white.opacity(0.3))
                                .rotationEffect(.degrees(-12))
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                                .padding(Theme.Spacing.s)
                                .accessibilityHidden(true)
                        }
                        .frame(height: Theme.Size.categoryCard)
                        .clipShape(.rounded(Theme.Radius.tile))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
        }
    }
}

/// One genre: what's new in it, and the artists MusicBrainz tags with it.
struct GenreExploreView: View {
    let name: String
    @Environment(AppModel.self) private var app
    @State private var artists: [PublicMusic.Pick] = []
    @State private var fresh: [PublicMusic.Pick] = []
    @State private var owned = OwnershipIndex()
    @State private var loading = true
    @State private var preview: DiscoverPreview?

    private let columns = [GridItem(.adaptive(minimum: Theme.Size.gridTileMin * 0.66), spacing: Theme.Spacing.l)]

    var body: some View {
        let lookup = owned
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                if !fresh.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                        SectionHeader("New in \(name)")
                        DiscoverAlbumGrid(picks: Array(fresh.prefix(8)), owned: lookup)
                    }
                }
                if loading && artists.isEmpty {
                    SkeletonView(style: .circleGrid)
                } else if !artists.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                        SectionHeader("Artists")
                        LazyVGrid(columns: columns, spacing: Theme.Spacing.xl) {
                            ForEach(artists) { pick in
                                PickArtistTile(pick: pick, owned: lookup.artist(pick), width: nil) {
                                    preview = DiscoverPreview(item: DiscoverItem(mbid: pick.mbid, name: pick.title, libraryArtist: nil), because: nil)
                                }
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.l)
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.m)
        }
        .navigationTitle(name)
        .artistPreview($preview, app: app)
        .task {
            if let client = app.client { owned = await OwnershipIndex.load(client: client) }
            let tag = name.lowercased()
            async let newOnes = PublicMusic.freshReleases()
            async let tagged = PublicMusic.artists(taggedWith: tag)
            fresh = await newOnes.filter { pick in pick.tags.contains { $0.contains(tag) } }
            artists = await PublicMusic.withPhotos(Array(await tagged.prefix(30)))
            loading = false
        }
    }
}

/// An artist's photo from Wikimedia Commons (through MusicBrainz and Wikidata).
struct PublicArtistPhoto: View {
    let name: String
    var mbid: String? = nil
    @State private var url: URL?

    var body: some View {
        RemoteArtwork(url: url, placeholder: "music.mic")
            .task(id: mbid ?? name) {
                if let mbid { url = await PublicMusic.artistImageURL(mbid: mbid) } else { url = await PublicMusic.artistImageURL(name: name) }
            }
    }
}

/// A new artist: photo, why they're suggested, and their albums.
/// A new artist: photo, why they're suggested, and their albums. On iPhone it's a sheet; on iPad and Mac it opens
/// in the side drawer on the right (see `ArtistPreviewDrawer`).
private struct DiscoverArtistSheet: View {
    let preview: DiscoverPreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ArtistPreviewContent(mbid: preview.item.mbid, name: preview.item.name, because: preview.because) { release in
                NavigationLink(value: release) { ReleaseTile(release: release) }.buttonStyle(.plain)
            }
            .navigationDestination(for: PublicMusic.Release.self) { release in
                PublicAlbumView(release: release, artist: preview.item.name, artistId: nil)
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
    }
}

/// The preview itself: photo, name, why, and the albums.
struct ArtistPreviewContent<AlbumLink: View>: View {
    let mbid: String
    let name: String
    let because: String?
    var columnsMin: CGFloat = Theme.Size.gridTileMin
    @ViewBuilder let albumLink: (PublicMusic.Release) -> AlbumLink
    @State private var releases: [PublicMusic.Release] = []
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.l) {
                PublicArtistPhoto(name: name, mbid: mbid)
                    .artworkFrame(size: Theme.Size.artistHero, .circle)
                    .artworkShadow()
                VStack(spacing: Theme.Spacing.xs) {
                    Text(name).font(.largeTitle.bold()).multilineTextAlignment(.center)
                    if let because {
                        Text(because).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    Text("Not in your library").font(.footnote.weight(.semibold)).foregroundStyle(Color.dial)
                }
                .padding(.horizontal, Theme.Spacing.l)

                let albums = releases.filter { $0.kind == .album }
                if loading {
                    SkeletonView(style: .grid)
                } else if !albums.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                        Text("Albums").font(.headline).foregroundStyle(.secondary).padding(.horizontal, Theme.Spacing.l)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: columnsMin), spacing: Theme.Spacing.l, alignment: .top)],
                                  spacing: Theme.Spacing.xl) {
                            ForEach(albums) { albumLink($0) }
                        }
                        .padding(.horizontal, Theme.Spacing.l)
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.l)
        }
        .task(id: mbid) {
            loading = true
            releases = await PublicMusic.discography(artistMBID: mbid)
            loading = false
        }
    }
}

private struct ReleaseTile: View {
    let release: PublicMusic.Release

    var body: some View {
        MediaTile(title: release.title, subtitle: release.year.map(String.init)) {
            RemoteArtwork(url: release.coverURL, placeholder: "music.note")
        }
    }
}

/// iPad and Mac: the artist preview in the drawer on the right, next to the page you came from.
/// Albums open in the main area.
struct ArtistPreviewDrawer: View {
    let preview: ArtistPreview
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    app.navigator.artistPreview = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.callout.weight(.semibold))
                        .frame(width: Theme.Size.tapTarget * 0.8, height: Theme.Size.tapTarget * 0.8)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
            }
            .padding(Theme.Spacing.m)
            ArtistPreviewContent(mbid: preview.mbid, name: preview.name, because: preview.because,
                                 columnsMin: Theme.Size.gridTileMin * 0.8) { release in
                Button {
                    app.navigator.open(.publicAlbum(release, artist: preview.name, artistId: nil))
                } label: { ReleaseTile(release: release) }
                .buttonStyle(.plain)
            }
        }
    }
}

/// An artist to preview in the drawer.
struct ArtistPreview: Hashable, Identifiable {
    let mbid: String
    let name: String
    let because: String?
    var id: String { mbid }
}

extension View {
    /// Opens an artist you tap in Discovery or search: the artist page, the same as for the artists you own.
    fileprivate func artistPreview(_ preview: Binding<DiscoverPreview?>, app: AppModel) -> some View {
        self.onChange(of: preview.wrappedValue?.id) {
            guard let value = preview.wrappedValue else { return }
            preview.wrappedValue = nil
            if let owned = value.item.libraryArtist {
                app.navigator.open(.artist(id: owned.id, name: owned.name))
            } else {
                app.navigator.open(.publicArtist(mbid: value.item.mbid, name: value.item.name))
            }
        }
    }
}

private struct DiscoverItem: Codable, Sendable, Identifiable {
    let mbid: String
    let name: String
    let libraryArtist: BaseItem?
    var id: String { mbid }
}

private struct DiscoverPreview: Identifiable {
    let item: DiscoverItem
    let because: String?
    var id: String { item.mbid }
}

// MARK: - Opening outside results

/// Opens an artist from outside the library: its MusicBrainz id is found by name first, then the artist page opens.
@MainActor
private func openBeyondArtist(_ pick: PublicMusic.Pick, app: AppModel) {
    Task { @MainActor in
        guard let mbid = await PublicMusic.artistMBID(name: pick.title) else { return }
        app.navigator.open(.publicArtist(mbid: mbid, name: pick.title))
    }
}

/// Opens an album from outside the library. With its id (MusicBrainz, Deezer or iTunes) it opens at once; otherwise it is
/// looked up by artist and title, on MusicBrainz first and then on Deezer, which has many albums MusicBrainz doesn't.
@MainActor
func openOutsideAlbum(artist: String, title: String, sourceId: String? = nil, cover: URL? = nil, app: AppModel) {
    func open(_ id: String) {
        app.navigator.open(.publicAlbum(PublicMusic.Release(id: id, title: title, year: nil, kind: .album, coverFile: cover),
                                        artist: artist, artistId: nil))
    }
    if let sourceId, !sourceId.isEmpty { open(sourceId); return }
    Task { @MainActor in
        if let id = await PublicMusic.releaseGroupId(artist: artist, title: title) { open(id); return }
        if let id = await DeezerSearch.albumSourceId(artist: artist, title: title) { open(id) }
    }
}

/// Opens a wishlist item's album (for a song, the album it is on).
@MainActor
func openOutsideAlbum(for item: WishItem, app: AppModel) {
    openOutsideAlbum(artist: item.artist, title: item.kind == .album ? item.title : (item.album ?? item.title),
                     sourceId: item.sourceId, cover: item.cover, app: app)
}

// MARK: - Short grids

/// Album covers in a grid: two columns on iPhone, more on wider screens.
struct DiscoverAlbumGrid: View {
    let picks: [PublicMusic.Pick]
    let owned: OwnershipIndex

    private let columns = [GridItem(.adaptive(minimum: Theme.Size.gridTileMin), spacing: Theme.Spacing.m, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Spacing.l) {
            ForEach(picks.uniqued()) { pick in
                PickAlbumTile(pick: pick, owned: owned.album(pick), ownedArtist: owned.artist(of: pick), width: nil)
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
    }
}

/// Round artist photos in a grid: three across on iPhone.
struct DiscoverArtistGrid: View {
    let picks: [PublicMusic.Pick]
    let owned: OwnershipIndex
    let onPreview: (PublicMusic.Pick) -> Void

    private let columns = [GridItem(.adaptive(minimum: Theme.Size.gridTileMin * 0.62), spacing: Theme.Spacing.m, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: Theme.Spacing.l) {
            ForEach(picks.uniqued()) { pick in
                PickArtistTile(pick: pick, owned: owned.artist(pick), width: nil) { onPreview(pick) }
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
    }
}

/// Everything in one discovery row, opened with See All.
struct DiscoverListView: View {
    let title: String
    let picks: [PublicMusic.Pick]
    @Environment(AppModel.self) private var app
    @State private var owned = OwnershipIndex()
    @State private var preview: PublicMusic.Pick?

    var body: some View {
        ScrollView {
            Group {
                if picks.first?.kind == .artist {
                    DiscoverArtistGrid(picks: picks, owned: owned) { preview = $0 }
                } else {
                    DiscoverAlbumGrid(picks: picks, owned: owned)
                }
            }
            .padding(.vertical, Theme.Spacing.l)
        }
        .navigationTitle(title)
        .artistPreview(Binding(
            get: { preview.map { DiscoverPreview(item: DiscoverItem(mbid: $0.mbid, name: $0.title, libraryArtist: nil), because: title) } },
            set: { if $0 == nil { preview = nil } }
        ), app: app)
        .task { if let client = app.client { owned = await OwnershipIndex.load(client: client) } }
    }
}

extension Array where Element: Identifiable {
    /// The same list without repeats (a repeated id shows as an empty cell in a grid).
    func uniqued() -> [Element] {
        var seen = Set<Element.ID>()
        return filter { seen.insert($0.id).inserted }
    }
}


// MARK: - On Tour page

/// Every upcoming show as a timeline, month by month: the date on the left, a line with a dot, and the show on the right.
struct OnTourView: View {
    let concerts: [Concert]
    @Environment(\.openURL) private var openURL

    private static func parse(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }

    private var months: [(title: String, shows: [Concert])] {
        let sorted = concerts.sorted { $0.date < $1.date }
        var order: [String] = []
        var groups: [String: [Concert]] = [:]
        for show in sorted {
            let key = String(show.date.prefix(7))
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(show)
        }
        return order.map { key in
            let date = Self.parse(key + "-01")
            return (date?.formatted(.dateTime.month(.wide).year()) ?? key, groups[key] ?? [])
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(months, id: \.title) { month in
                    Section {
                        ForEach(Array(month.shows.enumerated()), id: \.element.id) { index, show in
                            TimelineRow(concert: show, isLast: index == month.shows.count - 1)
                                .onTapGesture { openURL(show.url) }
                        }
                    } header: {
                        Text(month.title)
                            .font(.title3.weight(.bold))
                            .padding(.horizontal, Theme.Spacing.l).padding(.vertical, Theme.Spacing.s)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.bar)
                    }
                }
            }
            .padding(.bottom, Theme.Spacing.section)
        }
        .navigationTitle("On Tour")
        .navigationBarTitleDisplayMode(.large)
    }
}

private struct TimelineRow: View {
    let concert: Concert
    let isLast: Bool

    private var date: Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: concert.date)
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            // The day.
            VStack(spacing: 0) {
                Text(date.map { $0.formatted(.dateTime.weekday(.abbreviated)).uppercased() } ?? "")
                    .font(.caption2.weight(.bold)).foregroundStyle(Color.dial)
                Text(date.map { $0.formatted(.dateTime.day()) } ?? "")
                    .font(.title2.weight(.bold))
            }
            .frame(width: 44)
            .padding(.top, 14)

            // The line and its dot.
            ZStack(alignment: .top) {
                Rectangle().fill(.quaternary).frame(width: 2).padding(.top, 22).opacity(isLast ? 0 : 1)
                Circle().fill(Color.dial).frame(width: 12, height: 12).padding(.top, 18)
            }
            .frame(width: 12)

            // The show.
            HStack(spacing: Theme.Spacing.m) {
                Color.clear
                    .frame(width: 64, height: 64)
                    .overlay {
                        if let image = concert.image { RemoteImage(url: image) { Color(uiColor: .secondarySystemFill) } }
                        else { Color(uiColor: .secondarySystemFill) }
                    }
                    .clipShape(.rect(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(concert.artist).font(.headline).lineLimit(1)
                    Label { Text(concert.venue.isEmpty ? concert.city : concert.venue).lineLimit(1) } icon: { Image(systemName: "mappin.and.ellipse") }
                        .font(.subheadline).foregroundStyle(.secondary)
                    if !concert.venue.isEmpty, !concert.city.isEmpty {
                        Text(concert.city).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "location.fill")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Color.dial)
                    .frame(width: 36, height: 36)
                    .background(Color.dial.opacity(0.14), in: Circle())
            }
            .padding(10)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 18, style: .continuous))
            .padding(.bottom, Theme.Spacing.m)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(concert.artist), \(concert.venue) \(concert.city), \(concert.date). Tickets")
    }
}
