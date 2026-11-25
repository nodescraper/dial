import SwiftUI

/// A live radio genre, looked up by tag in the Radio Browser directory.
struct RadioCategory: Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let symbol: String
    let colors: [Color]
    /// More directory tags to merge in with `id` (stations are labelled "christmas" or "xmas", for example).
    var extraTags: [String] = []

    static let all: [RadioCategory] = [
        RadioCategory(id: "christmas", title: "Christmas", symbol: "snowflake",
                      colors: [Color(red: 0.55, green: 0.08, blue: 0.12), Color(red: 0.12, green: 0.45, blue: 0.25)],
                      extraTags: ["xmas", "christmas music", "holiday"]),
        RadioCategory(id: "lofi", title: "Lo-fi", symbol: "cup.and.saucer.fill",
                      colors: [Color(red: 0.55, green: 0.38, blue: 0.62), Color(red: 0.93, green: 0.6, blue: 0.47)]),
        RadioCategory(id: "jazz", title: "Jazz", symbol: "music.quarternote.3",
                      colors: [Color(red: 0.16, green: 0.24, blue: 0.45), Color(red: 0.85, green: 0.62, blue: 0.27)]),
        RadioCategory(id: "chillout", title: "Chill", symbol: "leaf.fill",
                      colors: [Color(red: 0.13, green: 0.47, blue: 0.47), Color(red: 0.56, green: 0.8, blue: 0.62)]),
        RadioCategory(id: "ambient", title: "Ambient", symbol: "moon.stars.fill",
                      colors: [Color(red: 0.1, green: 0.13, blue: 0.3), Color(red: 0.42, green: 0.45, blue: 0.75)]),
        RadioCategory(id: "classical", title: "Classical", symbol: "pianokeys",
                      colors: [Color(red: 0.42, green: 0.16, blue: 0.2), Color(red: 0.82, green: 0.68, blue: 0.5)]),
        RadioCategory(id: "hip hop", title: "Hip-Hop", symbol: "headphones",
                      colors: [Color(red: 0.2, green: 0.2, blue: 0.22), Color.dial]),
        RadioCategory(id: "electronic", title: "Electronic", symbol: "waveform",
                      colors: [Color(red: 0.12, green: 0.2, blue: 0.55), Color(red: 0.2, green: 0.75, blue: 0.85)]),
        RadioCategory(id: "soul", title: "Soul & Funk", symbol: "music.mic",
                      colors: [Color(red: 0.6, green: 0.2, blue: 0.12), Color(red: 0.95, green: 0.55, blue: 0.2)]),
        RadioCategory(id: "rock", title: "Rock", symbol: "guitars.fill",
                      colors: [Color(red: 0.3, green: 0.08, blue: 0.1), Color(red: 0.75, green: 0.2, blue: 0.2)]),
        RadioCategory(id: "80s", title: "80s", symbol: "recordingtape",
                      colors: [Color(red: 0.55, green: 0.15, blue: 0.5), Color(red: 0.25, green: 0.55, blue: 0.9)]),
    ]
}

struct RadioView: View {
    @Environment(AppModel.self) private var app
    @State private var artists: [BaseItem] = Snapshots.peek([BaseItem].self, "radio-artists") ?? []
    /// The mixtapes: the moods your library fits best, a fixed set of songs for the day.
    @State private var dailyMixes: [Mixtape] = DailyMixes.saved()
    /// Decades and genres, as stations by era and kind.
    @State private var filters = RadioFilters.saved()
    /// The mixes have been looked for at least once this visit (so none means none, not "still loading").
    @State private var mixesLoaded = false
    @State private var filtersLoaded = false
    @State private var query = ""
    @State private var results: [Station] = []
    @State private var searchState: LoadState = .loaded

    private let gridColumns = [GridItem(.adaptive(minimum: Theme.Size.gridTileMin), spacing: Theme.Spacing.m)]

    private var isSearching: Bool { query.trimmingCharacters(in: .whitespaces).count >= 2 }

    /// The DJ and the two library mixes: always here.
    private var yourStations: [RecentStation] {
        [.dj, .yourMix, .favoritesMix] + (app.audioMuse.canMakeYourSound ? [.yourSound] : [])
    }

    var body: some View {
        ScrollView {
            if isSearching {
                RowStack(data: results, dividerInset: Theme.Size.stationArtwork + Theme.Spacing.m + Theme.Spacing.l) { station in
                    Button { play(station, in: results) } label: { StationRow(station: station) }
                        .buttonStyle(.plain)
                        .contextMenu { SaveStationMenuItem(station: station) }
                }
            } else {
                browse
            }
        }
        .loadState(searchState, isEmpty: isSearching && results.isEmpty,
                   empty: EmptyState(title: "No stations found", symbol: "antenna.radiowaves.left.and.right",
                                     message: "Try a different name."),
                   retry: searchStations)
        .navigationTitle("Tune In")
        .offlineCover("Tune In needs a connection", "Live radio, your mixes and the stations need your server or the internet. Your downloads are on Home.")
        .searchable(text: $query, prompt: "Search live stations")
        .refreshable {
            if !isSearching {
                async let muse: () = app.audioMuse.check()
                async let stations: () = loadLibraryStations()
                async let tapes: () = loadMixes()
                async let sections: () = loadFilters()
                _ = await (muse, stations, tapes, sections)
            } else {
                await searchStations()
            }
        }
        // Your Sound and the mood stations need AudioMuse; if the first check missed it, look again whenever Tune In opens.
        .task { if !app.audioMuse.isConnected { await app.audioMuse.check() } }
        .task { await loadLibraryStations() }
        .task { await loadMixes() }
        .task { await loadFilters() }
        .task(id: query) { await searchStations() }
    }

    // MARK: Mixtapes, decades and genres

    /// A row of mixtapes that scrolls sideways, like Apple Music's shelves; the title opens them all when there are more.
    @ViewBuilder
    private func mixtapeGrid(_ title: String, _ tapes: [Mixtape]) -> some View {
        if !tapes.isEmpty {
            Shelf(title: title, route: tapes.count > Self.shelfLimit ? .mixtapeList(title: title, mixtapes: tapes) : nil) {
                ForEach(tapes.prefix(Self.shelfLimit)) { MixtapeTile(mixtape: $0, width: Theme.Size.shelfTile) }
            }
        }
    }

    private static let shelfLimit = 10

    private func loadFilters() async {
        guard let client = app.client else { return }
        await RadioFilters.load(client: client) { sections in
            if sections != filters { filters = sections }
        }
        filtersLoaded = true
    }

    /// A shelf's place while it is being made: grey tiles, so nothing below jumps when it arrives.
    private func skeletonShelf(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeader(title)
            HScroll {
                HStack(spacing: Theme.Spacing.m) {
                    ForEach(0..<4, id: \.self) { _ in SkeletonTile(width: Theme.Size.shelfTile) }
                }
                .padding(.horizontal, Theme.Spacing.l)
                .shimmering()
            }
            .scrollDisabled(true)
        }
    }

    /// Made once a day and saved, so coming back to Radio costs nothing.
    private func loadMixes() async {
        guard let client = app.client else { return }
        await DailyMixes.load(client: client, audioMuse: app.audioMuse, history: app.history,
                              isHidden: { app.library.isHidden($0) }) { mixes in
            if mixes != dailyMixes { dailyMixes = mixes }
        }
        mixesLoaded = true
    }

    /// A color pair per decade or genre, always the same for the same one.
    static func colors(for seed: Int) -> [Color] {
        let pairs: [[Color]] = [
            [Color(red: 0.55, green: 0.2, blue: 0.5), Color(red: 0.95, green: 0.5, blue: 0.4)],
            [Color(red: 0.15, green: 0.3, blue: 0.6), Color(red: 0.35, green: 0.75, blue: 0.85)],
            [Color(red: 0.6, green: 0.25, blue: 0.1), Color(red: 0.95, green: 0.7, blue: 0.3)],
            [Color(red: 0.15, green: 0.4, blue: 0.35), Color(red: 0.6, green: 0.85, blue: 0.55)],
            [Color(red: 0.35, green: 0.15, blue: 0.2), Color(red: 0.85, green: 0.35, blue: 0.4)],
            [Color(red: 0.2, green: 0.2, blue: 0.4), Color(red: 0.55, green: 0.45, blue: 0.85)],
            [Color(red: 0.5, green: 0.35, blue: 0.15), Color(red: 0.85, green: 0.75, blue: 0.5)],
        ]
        return pairs[(seed / 10 + seed) % pairs.count]
    }

    // MARK: Browse

    private var browse: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.section) {
            Shelf(title: "Your Stations") {
                ForEach(yourStations) { station in
                    RecentStationTile(station: station)
                }
            }

            // The mixtapes need AudioMuse (checked a moment after launch); decades and genres come from the library.
            if dailyMixes.isEmpty, !mixesLoaded { skeletonShelf("Made for You") }
            if dailyMixes.isEmpty, !mixesLoaded, !app.audioMuse.hasChecked || app.audioMuse.canSearchBySound {
                skeletonShelf("Mixtapes")
            }
            mixtapeGrid("Made for You", dailyMixes.filter { !$0.id.hasPrefix("daily-") })
            mixtapeGrid("Mixtapes", dailyMixes.filter { $0.id.hasPrefix("daily-") })
            if filters.decades.isEmpty, !filtersLoaded { skeletonShelf("Decades") }
            mixtapeGrid("Decades", filters.decades)
            if filters.genres.isEmpty, !filtersLoaded { skeletonShelf("Genres") }
            mixtapeGrid("Genres", filters.genres)

            if !artists.isEmpty {
                Shelf(title: "Artists", route: .library(.artists)) {
                    ForEach(artists) { artist in
                        ArtistTile(artist: artist)
                    }
                }
            }

            // Your favorite stations, above the live radio.
            if !app.stations.saved.isEmpty {
                Shelf(title: "Favorites") {
                    ForEach(app.stations.saved) { station in
                        RecentStationTile(station: .live(station), list: app.stations.saved)
                            .contextMenu { SaveStationMenuItem(station: station) }
                    }
                }
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                SectionHeader("Live Radio")
                LazyVGrid(columns: gridColumns, spacing: Theme.Spacing.m) {
                    ForEach(RadioCategory.all) { category in
                        NavigationLink(value: Route.stations(category)) {
                            CategoryCard(category: category)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.Spacing.l)
            }

            Text("Live stations come from radio-browser.info, a free community directory of internet radio.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Theme.Spacing.l)
        }
        .padding(.vertical, Theme.Spacing.l)
    }

    // MARK: Actions

    private func play(_ station: Station, in list: [Station]) {
        app.stations.markPlayed(station)
        app.player.playStation(station, in: list)
    }

    private func loadLibraryStations() async {
        guard let client = app.client else { return }
        if artists.isEmpty, let saved = await Snapshots.load([BaseItem].self, "radio-artists") { artists = saved }
        // Coming back from a mixtape shouldn't ask the server (and redraw the page) again.
        if !artists.isEmpty, Freshness.isFresh("radio-artists", maxAge: 600) { return }
        if let fresh = try? await client.stationArtists(limit: 12), !fresh.isEmpty {
            if fresh != artists { artists = fresh }
            Snapshots.save(fresh, "radio-artists")
            Freshness.mark("radio-artists")
        }
    }

    private func searchStations() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2 else {
            results = []
            searchState = .loaded
            return
        }
        searchState = .loading
        try? await Task.sleep(for: .milliseconds(350)) // wait until typing pauses
        guard !Task.isCancelled else { return }
        await runLoad($searchState) {
            results = try await RadioBrowser.shared.search(term)
        }
    }
}

// MARK: - Tiles and cards

struct CategoryCard: View {
    let category: RadioCategory

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: category.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(category.title)
                .font(.headline)
                .foregroundStyle(.white)
                .padding(Theme.Spacing.m)
            Image(systemName: category.symbol)
                .font(.largeTitle)
                .foregroundStyle(.white.opacity(0.35))
                .rotationEffect(.degrees(-12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(Theme.Spacing.s)
                .accessibilityHidden(true)
        }
        .frame(height: Theme.Size.categoryCard)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(category.title) stations")
    }
}

struct SaveStationMenuItem: View {
    let station: Station
    @Environment(AppModel.self) private var app

    var body: some View {
        Button {
            app.stations.toggleSaved(station)
        } label: {
            if app.stations.isSaved(station) {
                Label("Remove from Saved", systemImage: "star.slash")
            } else {
                Label("Save Station", systemImage: "star")
            }
        }
    }
}

// MARK: - Stations in a category

struct StationListView: View {
    let category: RadioCategory
    @Environment(AppModel.self) private var app
    @State private var stations: [Station] = []
    @State private var state: LoadState = .loading

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .regular { wide } else { list }
        }
        .loadState(state, isEmpty: stations.isEmpty,
                   empty: EmptyState(title: "No stations found", symbol: "antenna.radiowaves.left.and.right",
                                     message: "The station directory didn't return anything. Pull down to try again."),
                   retry: load)
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    /// iPad and Mac: the banner, then the stations as tiles, like the Stations row on Home.
    private var wide: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                banner
                if let first = stations.first {
                    PillButton(title: "Play Top Station", systemImage: "play.fill") { play(first) }
                        .frame(maxWidth: Theme.Size.formMaxWidth * 0.5)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.Size.gridTileMin), spacing: Theme.Spacing.l, alignment: .top)],
                          spacing: Theme.Spacing.xl) {
                    ForEach(stations) { station in
                        Button { play(station) } label: { StationGridTile(station: station) }
                            .buttonStyle(.plain)
                            .contextMenu { SaveStationMenuItem(station: station) }
                    }
                }
            }
            .padding(Theme.Spacing.l)
        }
    }

    private var banner: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: category.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(category.title)
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("Live stations, most popular first")
                        .font(.subheadline)
                }
                Spacer()
                Image(systemName: category.symbol)
                    .font(.largeTitle)
                    .imageScale(.large)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.white)
            .padding(Theme.Spacing.l)
        }
        .frame(height: Theme.Size.categoryHeader)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous))
    }

    /// iPhone: the banner and a list.
    private var list: some View {
        List {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: category.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                HStack {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(category.title)
                            .font(.largeTitle.bold())
                            .accessibilityAddTraits(.isHeader)
                        Text("Live stations, most popular first")
                            .font(.subheadline)
                    }
                    Spacer()
                    Image(systemName: category.symbol)
                        .font(.largeTitle)
                        .imageScale(.large)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(.white)
                .padding(Theme.Spacing.l)
            }
            .frame(height: Theme.Size.categoryHeader)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            if let first = stations.first {
                PillButton(title: "Play Top Station", systemImage: "play.fill") { play(first) }
                    .listRowSeparator(.hidden)
            }

            ForEach(stations) { station in
                Button { play(station) } label: { StationRow(station: station) }
                    .buttonStyle(.plain)
                    .contextMenu { SaveStationMenuItem(station: station) }
                    .swipeActions {
                        Button(app.stations.isSaved(station) ? "Unsave" : "Save") { app.stations.toggleSaved(station) }
                            .tint(Color.dial)
                    }
            }
        }
        .listStyle(.plain)
    }

    private func play(_ station: Station) {
        app.stations.markPlayed(station)
        app.player.playStation(station, in: stations)
    }

    private func load() async {
        await runLoad($state) {
            let found = try await RadioBrowser.shared.stations(tags: [category.id] + category.extraTags)
            // Under Lo-fi, Lofi Girl's own live streams come first, with their YouTube pictures.
            stations = category.id == "lofi" ? YouTubeLive.lofiStations + found : found
        }
    }
}

/// A station as a tile: its logo on a soft card, the name and where it's from; amber while it plays.
struct StationGridTile: View {
    let station: Station
    @Environment(AppModel.self) private var app

    private var isCurrent: Bool { app.player.liveStation?.id == station.id }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            StationArtwork(station: station)
                .squareArtwork(.rounded(Theme.Radius.tile))
                .overlay(alignment: .bottomTrailing) {
                    if isCurrent {
                        PlayingIndicator(isPlaying: app.player.isPlaying)
                            .padding(Theme.Spacing.s)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(Theme.Spacing.s)
                    }
                }
            Text(station.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isCurrent ? Color.dial : Color.primary)
                .lineLimit(1)
            Text(station.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A decade or genre from your library, with covers for its collage.
struct LibraryCategory: Codable, Sendable, Identifiable {
    let id: String
    let title: String
    let albums: Int
    let coverIds: [String]
    let colorSeed: Int
    var decade: Int? = nil
    var genreIds: [String] = []

    var route: Route {
        if let decade { return .decade(decade) }
        return .genreGroup(name: title, genreIds: genreIds)
    }
}
