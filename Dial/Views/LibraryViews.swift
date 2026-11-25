import SwiftUI

enum LibrarySection: String, CaseIterable, Identifiable, Hashable {
    case playlists, artists, albums, songs, genres, decades, favorites, downloaded, wishlist

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playlists: return "Playlists"
        case .artists: return "Artists"
        case .albums: return "Albums"
        case .songs: return "Songs"
        case .genres: return "Genres"
        case .decades: return "Decades"
        case .favorites: return "Favorites"
        case .downloaded: return "Downloaded"
        case .wishlist: return "Wishlist"
        }
    }

    var symbol: String {
        switch self {
        case .playlists: return "music.note.list"
        case .artists: return "music.mic"
        case .albums: return "square.stack"
        case .songs: return "music.note"
        case .genres: return "guitars"
        case .decades: return "calendar"
        case .favorites: return "heart"
        case .downloaded: return "arrow.down.circle"
        case .wishlist: return "bookmark"
        }
    }

    @ViewBuilder
    var destination: some View {
        switch self {
        case .playlists: PlaylistsView()
        case .artists: ArtistsView()
        case .albums: AlbumsView()
        case .songs: SongsView()
        case .genres: GenresView()
        case .decades: DecadesView()
        case .favorites: FavoriteSongsView()
        case .downloaded: DownloadsView()
        case .wishlist: WishlistView()
        }
    }
}

// MARK: - Library

struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var recent: [BaseItem] = []

    var body: some View {
        LibrarySearchContainer { libraryPage }
            .navigationTitle("Library")
    }

    /// What the Library lists: your music, then your stats as one more row. Genres and decades live on the Tune In tab; there is no all-songs list.
    private enum Entry: Identifiable {
        case section(LibrarySection), stats, libraryStats
        var id: String { switch self { case .section(let section): section.rawValue; case .stats: "stats"; case .libraryStats: "library-stats" } }
    }

    private static let entries: [Entry] = LibrarySection.allCases.filter { ![.genres, .decades, .songs].contains($0) }.map(Entry.section) + [.stats, .libraryStats]

    private var libraryPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                if app.connectivity.isOffline { OfflineBanner() }
                // Offline, only what is on this iPhone can be opened.
                // The wishlist is kept by the Dial plugin, so it is listed only when the server has it.
                RowStack(data: app.connectivity.isOffline ? Self.entries.filter { if case .section(.downloaded) = $0 { true } else { false } }
                            : Self.entries.filter { if case .section(.wishlist) = $0 { app.hasPlugin } else { true } },
                         dividerInset: Theme.Size.trackNumber + Theme.Spacing.l * 2) { entry in
                    switch entry {
                    case .section(let section):
                        NavigationLink(value: Route.library(section)) {
                            NavigationRow(title: section.title, symbol: section.symbol,
                                          trailing: section == .downloaded && app.downloads.isWorking ? "Downloading…" : nil)
                        }
                        .buttonStyle(.plain)
                    case .stats:
                        NavigationLink(value: Route.stats) {
                            NavigationRow(title: "Your Stats", symbol: "chart.bar.xaxis")
                        }
                        .buttonStyle(.plain)
                    case .libraryStats:
                        NavigationLink(value: Route.libraryStats) {
                            NavigationRow(title: "Library Stats", symbol: "chart.pie")
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !recent.isEmpty && !app.connectivity.isOffline {
                    VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                        SectionHeader("Recently Added")
                        AlbumGrid(albums: recent)
                    }
                }
            }
            .padding(.bottom, Theme.Spacing.l)
        }
        .task { await load() }
        .refreshable {
            await JellyfinClient.clearCache()
            await load()
            await app.library.refresh()
        }
    }

    private func load() async {
        guard let client = app.client else { return }
        if recent.isEmpty, let saved = await Snapshots.load([BaseItem].self, "library-recent") { recent = saved }
        if let fresh = try? await client.recentAlbums(limit: 12) {
            recent = fresh
            Snapshots.save(fresh, "library-recent")
        }
    }
}

// MARK: - Playlists

struct PlaylistsView: View {
    @Environment(AppModel.self) private var app
    @State private var creating = false
    @State private var newName = ""
    @State private var renaming: BaseItem? = nil
    @State private var state: LoadState = .loading

    var body: some View {
        List {
            Button {
                newName = ""
                creating = true
            } label: {
                Label("New Playlist…", systemImage: "plus")
                    .foregroundStyle(Color.dial)
            }

            ForEach(app.library.playlists) { playlist in
                NavigationLink(value: Route.playlist(id: playlist.id, name: playlist.name)) {
                    PlaylistRow(playlist: playlist)
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { Task { await delete(playlist) } }
                }
                .contextMenu {
                    Button {
                        newName = playlist.name
                        renaming = playlist
                    } label: { Label("Rename\u{2026}", systemImage: "pencil") }
                    Button(role: .destructive) { Task { await delete(playlist) } } label: { Label("Delete Playlist", systemImage: "trash") }
                }
            }
        }
        .listStyle(.plain)
        .loadState(state, isEmpty: app.library.playlists.isEmpty,
                   empty: EmptyState(title: "No playlists yet", symbol: "music.note.list",
                                     message: "Tap New Playlist, or long-press any song and choose Add to Playlist."),
                   retry: load)
        .navigationTitle("Playlists")
        .alert("New Playlist", isPresented: $creating) {
            TextField("Name", text: $newName)
            Button("Create") { Task { await create() } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Playlist", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let playlist = renaming { Task { await rename(playlist) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        await runLoad($state) { try await app.library.loadPlaylists() }
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            try await app.library.createPlaylist(named: name, with: [])
        } catch {
            app.library.errorMessage = "Couldn't create the playlist: \(error.localizedDescription)"
        }
    }

    private func rename(_ playlist: BaseItem) async {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            try await app.library.renamePlaylist(playlist.id, to: trimmed)
        } catch {
            app.library.errorMessage = "Couldn't rename the playlist: \(error.localizedDescription)"
        }
    }

    private func delete(_ playlist: BaseItem) async {
        do {
            try await app.library.deletePlaylist(playlist)
        } catch {
            app.library.errorMessage = "Couldn't delete the playlist: \(error.localizedDescription)"
        }
    }
}

/// Picks a playlist to add songs to, or makes a new one.
struct AddToPlaylistSheet: View {
    let tracks: [BaseItem]
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var newName = ""
    @State private var working = false

    private var title: String {
        tracks.count == 1 ? "Add \u{201C}\(tracks[0].name)\u{201D}" : "Add \(tracks.count) Songs"
    }

    var body: some View {
        NavigationStack {
            List {
                Button {
                    newName = ""
                    creating = true
                } label: {
                    Label("New Playlist…", systemImage: "plus")
                        .foregroundStyle(Color.dial)
                }
                ForEach(app.library.playlists) { playlist in
                    Button { Task { await add(to: playlist) } } label: { PlaylistRow(playlist: playlist) }
                        .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .disabled(working)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("New Playlist", isPresented: $creating) {
                TextField("Name", text: $newName)
                Button("Create") { Task { await create() } }
                Button("Cancel", role: .cancel) {}
            }
            .task { try? await app.library.loadPlaylists() }
        }
        .presentationDetents([.medium, .large])
    }

    private func add(to playlist: BaseItem) async {
        working = true
        defer { working = false }
        do {
            try await app.library.add(tracks, to: playlist)
            dismiss()
        } catch {
            app.library.errorMessage = "Couldn't add to \(playlist.name): \(error.localizedDescription)"
        }
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        working = true
        defer { working = false }
        do {
            try await app.library.createPlaylist(named: name, with: tracks)
            dismiss()
        } catch {
            app.library.errorMessage = "Couldn't create the playlist: \(error.localizedDescription)"
        }
    }
}

// MARK: - Artists

struct ArtistsView: View {
    @Environment(AppModel.self) private var app
    @State private var artists: [BaseItem] = []
    @State private var filter = ""
    @State private var state: LoadState = .loading

    private var shown: [BaseItem] {
        filter.isEmpty ? artists : artists.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        let groups = AlphaGroups.group(shown) { ArtistNames.primary($0.name) }
        ScrollViewReader { proxy in
            artistList(groups)
                .alphabetIndex(groups, enabled: filter.isEmpty, proxy: proxy)
        }
    }

    private func artistList(_ groups: [(letter: String, items: [BaseItem])]) -> some View {
        List {
            ForEach(groups, id: \.letter) { group in
                Section {
                    ForEach(group.items) { artist in
                        NavigationLink(value: Route.artist(id: artist.id, name: artist.name)) {
                            ArtistRow(artist: artist)
                        }
                    }
                } header: {
                    Text(group.letter).font(.headline).id("alpha-\(group.letter)")
                }
            }
            // Artists on your songs as features, without albums of their own.
            let featured = app.credits.featuredOnly.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
            if !featured.isEmpty {
                Section("Featured Artists") {
                    ForEach(featured, id: \.name) { entry in
                        NavigationLink(value: Route.featuredArtist(name: entry.name)) {
                            HStack(spacing: Theme.Spacing.m) {
                                PublicArtistPhoto(name: entry.name)
                                    .artworkFrame(size: Theme.Size.rowArtwork, .circle)
                                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                    Text(entry.name)
                                    Text(entry.songs.count == 1 ? "On 1 song" : "On \(entry.songs.count) songs")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .contentMargins(.trailing, 20, for: .scrollContent)
        .loadState(state, isEmpty: artists.isEmpty,
                   empty: EmptyState(title: "No artists", symbol: "music.mic",
                                     message: "Artists appear here once your library has albums."),
                   skeleton: .circleList, retry: load)
        .navigationTitle("Artists")
        .searchable(text: $filter, prompt: "Filter artists")
        .task { await load() }
        .refreshable {
            await JellyfinClient.clearCache()
            await load()
        }
    }

    private func load() async {
        guard let client = app.client else { return }
        if artists.isEmpty, let saved = await Snapshots.load([BaseItem].self, "artists") {
            artists = saved
            state = .loaded
        }
        await runLoad($state) {
            artists = try await client.distinctArtists()
            Snapshots.save(artists, "artists")
        }
    }
}

// MARK: - Albums

struct AlbumsView: View {
    @Environment(AppModel.self) private var app
    @State private var albums: [BaseItem] = []
    @State private var sort: AlbumSort = .recentlyAdded
    @State private var filter = ""
    @State private var state: LoadState = .loading

    private var shown: [BaseItem] {
        guard !filter.isEmpty else { return albums }
        return albums.filter {
            $0.name.localizedCaseInsensitiveContains(filter) || $0.albumArtistLine.localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        // Sorted by title or artist, the albums are filed under A to Z with the index on the side.
        let indexed = (sort == .title || sort == .artist) && filter.isEmpty
        let groups: [(letter: String, items: [BaseItem])] = indexed
            ? AlphaGroups.group(shown) { sort == .title ? $0.name : ArtistNames.primary($0.albumArtistLine) } : []
        ScrollViewReader { proxy in
            ScrollView {
                if indexed {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.l) {
                        ForEach(groups, id: \.letter) { group in
                            Text(group.letter).font(.headline).padding(.horizontal, Theme.Spacing.l).id("alpha-\(group.letter)")
                            AlbumGrid(albums: group.items)
                        }
                    }
                    .padding(.vertical, Theme.Spacing.l)
                    .padding(.trailing, 14)
                } else {
                    AlbumGrid(albums: shown)
                        .padding(.vertical, Theme.Spacing.l)
                }
            }
            .alphabetIndex(groups, enabled: indexed, proxy: proxy)
        }
        .loadState(state, isEmpty: albums.isEmpty,
                   empty: EmptyState(title: "No albums", symbol: "square.stack",
                                     message: "Add music to your Jellyfin library, then pull down to refresh."),
                   skeleton: .grid, retry: load)
        .navigationTitle("Albums")
        .searchable(text: $filter, prompt: "Filter albums")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort by", selection: $sort) {
                        ForEach(AlbumSort.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel("Sort albums")
            }
        }
        .task(id: sort) {
            albums = []
            await load()
        }
        .refreshable {
            await JellyfinClient.clearCache()
            await load()
        }
    }

    private func load() async {
        guard let client = app.client else { return }
        let key = "albums-\(sort.rawValue)"
        if albums.isEmpty, let saved = await Snapshots.load([BaseItem].self, key) {
            albums = saved
            state = .loaded
        }
        await runLoad($state) {
            albums = try await client.albums(sortedBy: sort)
            Snapshots.save(albums, key)
        }
    }
}

// MARK: - Songs

struct SongsView: View {
    @Environment(AppModel.self) private var app
    @State private var songs: [BaseItem] = []
    @State private var filter = ""
    @State private var state: LoadState = .loading

    private var shown: [BaseItem] {
        guard !filter.isEmpty else { return songs }
        return songs.filter {
            $0.name.localizedCaseInsensitiveContains(filter) || $0.artistLine.localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        let groups = AlphaGroups.group(shown) { $0.name }
        ScrollViewReader { proxy in
            List {
                if !songs.isEmpty {
                    PlayShuffleButtons(tracks: shown)
                        .listRowSeparator(.hidden)
                }
                ForEach(groups, id: \.letter) { group in
                    Section {
                        SongRows(tracks: group.items, queue: shown)
                    } header: {
                        Text(group.letter).font(.headline).id("alpha-\(group.letter)")
                    }
                }
            }
            .listStyle(.plain)
            .contentMargins(.trailing, 20, for: .scrollContent)
            .alphabetIndex(groups, enabled: filter.isEmpty, proxy: proxy)
            .modifier(SongsChrome(state: state, empty: songs.isEmpty, retry: load))
        }
        .navigationTitle("Songs")
        .searchable(text: $filter, prompt: "Filter songs")
        .task { await load() }
        .refreshable {
            await JellyfinClient.clearCache()
            await load()
        }
    }

    private struct SongsChrome: ViewModifier {
        let state: LoadState
        let empty: Bool
        let retry: () async -> Void
        func body(content: Content) -> some View {
            content.loadState(state, isEmpty: empty,
                              empty: EmptyState(title: "No songs", symbol: "music.note",
                                                message: "Add music to your Jellyfin library, then pull down to refresh."),
                              retry: retry)
        }
    }

    private func load() async {
        guard let client = app.client else { return }
        if songs.isEmpty, let saved = await Snapshots.load([BaseItem].self, "songs") {
            songs = saved
            state = .loaded
        }
        await runLoad($state) {
            songs = try await client.allSongs()
            Snapshots.save(songs, "songs")
        }
    }
}

// MARK: - Genres

struct GenresView: View {
    @Environment(AppModel.self) private var app
    @State private var genres: [BaseItem] = []
    @State private var state: LoadState = .loading

    var body: some View {
        List(genres) { genre in
            NavigationLink(value: Route.genre(id: genre.id, name: genre.name)) {
                Label(genre.name, systemImage: "guitars")
            }
        }
        .listStyle(.plain)
        .loadState(state, isEmpty: genres.isEmpty,
                   empty: EmptyState(title: "No genres", symbol: "guitars",
                                     message: "Genres come from your music's tags. Tag your files with MusicBrainz Picard to fill them in."),
                   retry: load)
        .navigationTitle("Genres")
        .task { await load() }
    }

    private func load() async {
        guard let client = app.client else { return }
        await runLoad($state) { genres = try await client.genres() }
    }
}

// MARK: - Favorites

struct FavoriteSongsView: View {
    @Environment(AppModel.self) private var app
    @State private var songs: [BaseItem] = []
    @State private var state: LoadState = .loading

    /// The server's list, minus songs unfavorited since (until the next reload catches up).
    private var shown: [BaseItem] {
        guard app.library.hasLoadedFavorites else { return songs }
        return songs.filter { app.library.isFavorite($0.id) }
    }

    var body: some View {
        List {
            if !app.stations.saved.isEmpty {
                Section("Stations") {
                    ForEach(app.stations.saved) { station in
                        Button {
                            app.stations.markPlayed(station)
                            app.player.playStation(station, in: app.stations.saved)
                        } label: { StationRow(station: station) }
                            .buttonStyle(.plain)
                            .contextMenu { SaveStationMenuItem(station: station) }
                    }
                }
            }
            Section(app.stations.saved.isEmpty ? "" : "Songs") {
                if !shown.isEmpty {
                    PlayShuffleButtons(tracks: shown)
                        .listRowSeparator(.hidden)
                }
                SongRows(tracks: shown)
            }
        }
        .listStyle(.plain)
        .loadState(state, isEmpty: shown.isEmpty && app.stations.saved.isEmpty,
                   empty: EmptyState(title: "No favorites yet", symbol: "heart",
                                     message: "Tap the heart in the player, or long-press a song and choose Favorite. Save a radio station from its menu to see it here."),
                   retry: load)
        .navigationTitle("Favorites")
        .task { await load() }
        .refreshable { await load() }
        // Favorites changed (here or on another device): reload quietly, keeping the list on screen.
        .task(id: app.library.favoritesVersion) {
            guard !songs.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let fresh = try? await app.client?.favoriteSongs() else { return }
            songs = fresh
            Snapshots.save(fresh, "favorite-songs")
        }
    }

    private func load() async {
        guard let client = app.client else { return }
        if songs.isEmpty, let saved = await Snapshots.load([BaseItem].self, "favorite-songs") {
            songs = saved
            state = .loaded
        }
        await runLoad($state) {
            songs = try await client.favoriteSongs()
            Snapshots.save(songs, "favorite-songs")
        }
    }
}

// MARK: - Downloads

/// Your downloaded songs: Play and Shuffle, the songs, and how much space they take. The Downloaded page and offline Home show this.
struct DownloadedList: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let songs = app.downloads.downloadedSongs

        List {
            if app.downloads.isWorking {
                HStack(spacing: Theme.Spacing.m) {
                    ProgressView()
                    Text("Downloading \(app.downloads.pending.count) songs…")
                        .foregroundStyle(.secondary)
                }
            }
            if !songs.isEmpty {
                PlayShuffleButtons(tracks: songs)
                    .listRowSeparator(.hidden)
            }
            SongRows(tracks: songs, removeLabel: "Remove Download") { song in
                app.downloads.delete(song.id)
            }
            if !songs.isEmpty {
                Text("\(songCountLine(songs)), \(ByteCountFormatter.string(fromByteCount: app.downloads.totalBytes, countStyle: .file))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .loadState(.loaded, isEmpty: songs.isEmpty && !app.downloads.isWorking,
                   empty: EmptyState(title: "Nothing downloaded", symbol: "arrow.down.circle",
                                     message: "Download albums or songs to play them without a connection to your server."),
                   retry: {})
    }
}

struct DownloadsView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmingDeleteAll = false

    var body: some View {
        let songs = app.downloads.downloadedSongs

        DownloadedList()
        .navigationTitle("Downloaded")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Remove All", role: .destructive) { confirmingDeleteAll = true }
                    .disabled(songs.isEmpty)
            }
        }
        .confirmationDialog("Remove all downloaded songs from this \(Platform.deviceKind)?", isPresented: $confirmingDeleteAll,
                            titleVisibility: .visible) {
            Button("Remove All Downloads", role: .destructive) { app.downloads.deleteAll() }
        }
    }
}

// MARK: - Wishlist

/// Albums and songs you want but don't have, newest first. Tap to open the album; long press or swipe to remove.
struct WishlistView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            ForEach(app.wishlist.items) { item in
                Button { openOutsideAlbum(for: item, app: app) } label: {
                    MediaRow(title: item.title,
                             subtitle: item.kind == .song ? "Song \u{00B7} \(item.artist)" : item.artist) {
                        RemoteArtwork(url: item.coverURL, placeholder: "music.note")
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) {
                        Task { await app.wishlist.remove(item.id, client: app.client) }
                    } label: { Label("Remove from Wishlist", systemImage: "bookmark.slash") }
                }
                .swipeActions {
                    Button("Remove", role: .destructive) {
                        Task { await app.wishlist.remove(item.id, client: app.client) }
                    }
                }
            }
        }
        .listStyle(.plain)
        .loadState(.loaded, isEmpty: app.wishlist.items.isEmpty,
                   empty: EmptyState(title: "Your wishlist is empty", symbol: "bookmark",
                                     message: "Long-press an album or song you don\u{2019}t have and choose Add to Wishlist."),
                   retry: {})
        .navigationTitle("Wishlist")
        .task { await app.wishlist.refresh(client: app.client) }
        .refreshable { await app.wishlist.refresh(client: app.client) }
    }
}

// MARK: - Decades

/// Every decade in the library with how many albums came out in it, counted by the server.
struct DecadesView: View {
    struct Row: Identifiable { let start: Int; let count: Int; var id: Int { start } }

    @Environment(AppModel.self) private var app
    @State private var rows: [Row] = []
    @State private var state: LoadState = .loading

    var body: some View {
        ScrollView {
            RowStack(data: rows, dividerInset: Theme.Size.trackNumber + Theme.Spacing.l * 2) { row in
                NavigationLink(value: Route.decade(row.start)) {
                    NavigationRow(title: "The \(DecadeView.name(row.start))", symbol: "calendar",
                                  trailing: "\(row.count) album\(row.count == 1 ? "" : "s")")
                }
                .buttonStyle(.plain)
            }
        }
        .loadState(state, isEmpty: rows.isEmpty,
                   empty: EmptyState(title: "No decades", symbol: "calendar", message: "Your albums have no release years."),
                   retry: load)
        .navigationTitle("Decades")
        .task { await load() }
    }

    private func load() async {
        guard let client = app.client else { return }
        await runLoad($state) {
            let thisDecade = Calendar.current.component(.year, from: .now) / 10 * 10
            var found: [Row] = []
            try await withThrowingTaskGroup(of: Row?.self) { group in
                for decade in stride(from: 1900, through: thisDecade, by: 10) {
                    group.addTask {
                        let result = try await client.albumsInDecade(decade, covers: 1)
                        return result.count > 0 ? Row(start: decade, count: result.count) : nil
                    }
                }
                for try await row in group { if let row { found.append(row) } }
            }
            rows = found.sorted { $0.start > $1.start }
        }
    }
}
