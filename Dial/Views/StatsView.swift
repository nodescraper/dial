import Charts
import SwiftUI

/// Your listening, any time you want it, not just once a year: a story of big cards to scroll through.
struct StatsView: View {
    @Environment(AppModel.self) private var app
    @State private var range: StatsRange = .year
    @State private var stats: ListeningStats?
    @State private var collection: CollectionStats?
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.l) {
                if app.history.isAvailable {
                    Picker("Period", selection: $range) {
                        ForEach(StatsRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: Theme.Size.formMaxWidth)
                }

                if loading && stats == nil {
                    SkeletonView(style: .grid)
                } else if let stats {
                    if stats.isEmpty {
                        ContentUnavailableView("Nothing played yet", systemImage: "chart.bar",
                                               description: Text("Play some music and your stats appear here."))
                    } else {
                        cards(stats)
                    }
                }
                if let collection { CollectionCard(stats: collection) }
                if stats?.fromHistory == false {
                    Text("Install the Playback Reporting plugin on your Jellyfin server to see your stats by week, month and year, when you listen, and what\u{2019}s new to you.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Theme.Spacing.l)
                }
            }
            .frame(maxWidth: Theme.Size.heroMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(Theme.Spacing.l)
        }
        .navigationTitle("Your Stats")
        .task(id: range) { await load() }
    }

    @ViewBuilder
    private func cards(_ stats: ListeningStats) -> some View {
        HeroStatCard(stats: stats)
        if let top = stats.topArtists.first { TopArtistCard(artist: top, stats: stats) }
        if stats.topArtists.count > 1 { RankedCard(title: "Top Artists", entries: Array(stats.topArtists.prefix(5)), round: true, colors: [Color.dial, .red]) }
        if !stats.topSongs.isEmpty { RankedCard(title: "Top Songs", entries: Array(stats.topSongs.prefix(5)), round: false, colors: [.pink, .orange]) }
        if !stats.topAlbums.isEmpty { AlbumsCard(albums: stats.topAlbums) }
        if !stats.topGenres.isEmpty { GenresCard(genres: stats.topGenres) }
        if stats.byHour.reduce(0, +) > 0 { WhenCard(stats: stats) }
        if stats.fromHistory { HighlightsCard(stats: stats) }
        if !stats.newArtists.isEmpty { DiscoveryCard(stats: stats) }
    }

    private func load() async {
        guard let client = app.client else { return }
        let key = "stats-\(range.rawValue)"
        if let saved = await Snapshots.load(ListeningStats.self, key) { stats = saved }
        if collection == nil, let saved = await Snapshots.load(CollectionStats.self, "stats-collection") { collection = saved }
        loading = true
        if stats == nil || !Freshness.isFresh(key, maxAge: 1800) {
            let fresh = await StatsEngine.listening(range, client: client, history: app.history)
            withAnimation { stats = fresh }
            Snapshots.save(fresh, key)
            Freshness.mark(key)
        }
        loading = false
        if collection == nil || !Freshness.isFresh("stats-collection", maxAge: 6 * 3600) {
            let fresh = await StatsEngine.collection(client: client, library: app.library)
            withAnimation { collection = fresh }
            Snapshots.save(fresh, "stats-collection")
            Freshness.mark("stats-collection")
        }
    }
}

// MARK: - Cards

/// A big rounded card with a color wash, white text. Every card in Stats is one of these.
struct StatCard<Content: View>: View {
    let colors: [Color]
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.xl)
            .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: .rounded(Theme.Radius.hero))
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
    }
}

struct CardTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.75))
    }
}

private struct HeroStatCard: View {
    let stats: ListeningStats

    var body: some View {
        StatCard(colors: [Color.dial, Color(red: 0.75, green: 0.3, blue: 0.2)]) {
            CardTitle(text: stats.range.heading)
            Text(stats.minutes.formatted())
                .font(.system(size: 64, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .contentTransition(.numericText())
            Text("minutes of music").font(.title3.weight(.semibold))
            HStack(spacing: Theme.Spacing.xl) {
                fact("\(stats.plays.formatted())", "plays")
                if stats.activeDays > 0 { fact("\(stats.activeDays)", stats.activeDays == 1 ? "day" : "days") }
                if let personality = stats.personality { fact(personality, "you are") }
            }
            .padding(.top, Theme.Spacing.s)
        }
    }

    private func fact(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(value).font(.headline)
            Text(label).font(.caption).foregroundStyle(.white.opacity(0.75))
        }
    }
}

/// Your number one artist, big, with their picture.
private struct TopArtistCard: View {
    let artist: ListeningStats.Ranked
    let stats: ListeningStats
    @Environment(AppModel.self) private var app

    var body: some View {
        Button(action: open) {
            ZStack(alignment: .bottomLeading) {
                Color.clear
                    .aspectRatio(1.2, contentMode: .fit)
                    .background {
                        if let id = artist.imageItemId { ArtworkView(itemId: id, pixels: Theme.Pixels.hero, placeholder: "music.mic") }
                    }
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    CardTitle(text: "Your number one artist")
                    Text(artist.name).font(.largeTitle.weight(.heavy)).lineLimit(2).minimumScaleFactor(0.6)
                    Text("\(artist.plays) plays" + (artist.minutes > 0 ? ", \(hours(artist.minutes))" : ""))
                        .font(.headline).foregroundStyle(.white.opacity(0.85))
                    if stats.plays > 0 {
                        Text("That\u{2019}s \(Int(Double(artist.plays) / Double(stats.plays) * 100))% of everything you played.")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.75))
                    }
                }
                .padding(Theme.Spacing.xl)
            }
            .foregroundStyle(.white)
            .clipShape(.rounded(Theme.Radius.hero))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func open() {
        if let route = artist.route { app.navigator.open(.artist(id: route.id, name: route.name)) }
    }
}

/// Ranked lists: top artists or top songs, with a big number for each place.
private struct RankedCard: View {
    let title: String
    let entries: [ListeningStats.Ranked]
    let round: Bool
    let colors: [Color]
    @Environment(AppModel.self) private var app

    var body: some View {
        StatCard(colors: colors) {
            CardTitle(text: title)
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                Button { open(entry) } label: {
                    HStack(spacing: Theme.Spacing.m) {
                        Text("\(index + 1)").font(.title2.weight(.heavy)).frame(width: Theme.Spacing.xl, alignment: .leading)
                        if let id = entry.imageItemId {
                            ArtworkView(itemId: id, pixels: Theme.Pixels.thumb, placeholder: round ? "music.mic" : "music.note")
                                .artworkFrame(size: Theme.Size.rowArtwork, round ? .circle : .rounded(Theme.Radius.thumb))
                        }
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text(entry.name).font(.headline).lineLimit(1)
                            Text(entry.detail.isEmpty ? "\(entry.plays) plays" : "\(entry.detail), \(entry.plays) plays")
                                .font(.subheadline).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func open(_ entry: ListeningStats.Ranked) {
        if let route = entry.route {
            app.navigator.open(route.kind == "album" ? .album(id: route.id, name: route.name) : .artist(id: route.id, name: route.name))
        }
    }
}

private struct AlbumsCard: View {
    let albums: [ListeningStats.Ranked]
    @Environment(AppModel.self) private var app

    private let columns = [GridItem(.adaptive(minimum: Theme.Size.gridTileMin * 0.8), spacing: Theme.Spacing.m, alignment: .top)]

    var body: some View {
        StatCard(colors: [Color(red: 0.1, green: 0.45, blue: 0.45), Color(red: 0.15, green: 0.2, blue: 0.35)]) {
            CardTitle(text: "Top Albums")
            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Spacing.l) {
                ForEach(albums.prefix(6)) { album in
                    Button {
                        if let route = album.route { app.navigator.open(.album(id: route.id, name: route.name)) }
                    } label: {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            ArtworkView(itemId: album.id, pixels: Theme.Pixels.tile).squareArtwork(.rounded(Theme.Radius.tile))
                            Text(album.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text("\(album.plays) plays").font(.caption).foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct GenresCard: View {
    let genres: [ListeningStats.Ranked]

    var body: some View {
        StatCard(colors: [Color(red: 0.35, green: 0.2, blue: 0.6), Color(red: 0.15, green: 0.1, blue: 0.3)]) {
            CardTitle(text: "Your Sound")
            if let top = genres.first {
                Text("Mostly \(top.name)").font(.title.weight(.heavy))
            }
            Chart(genres) { genre in
                BarMark(x: .value("Plays", genre.plays), y: .value("Genre", genre.name), height: .ratio(0.55))
                    .foregroundStyle(genre.id == genres.first?.id ? Color.dial : Color.white.opacity(0.45))
                    .cornerRadius(Theme.Radius.tile)
                    .annotation(position: .top, alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(genre.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    }
                    .annotation(position: .trailing, alignment: .center, spacing: Theme.Spacing.s) {
                        Text(genre.plays.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.75))
                    }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartXScale(domain: 0...(Double(genres.map(\.plays).max() ?? 1) * 1.15))
            .chartLegend(.hidden)
            .frame(height: CGFloat(genres.count) * Theme.Size.tapTarget * 1.1)
            .accessibilityChartDescriptor(BarsDescriptor(title: "Plays by genre", bars: genres.map { ($0.name, $0.plays) }))
        }
    }
}

/// When you listen: by hour and by day of the week.
private struct WhenCard: View {
    let stats: ListeningStats
    private let days = Calendar.current.shortWeekdaySymbols

    var body: some View {
        StatCard(colors: [Color(red: 0.08, green: 0.1, blue: 0.25), Color(red: 0.25, green: 0.2, blue: 0.5)]) {
            CardTitle(text: "When You Listen")
            if let personality = stats.personality { Text(personality).font(.title.weight(.heavy)) }
            let peak = stats.byHour.firstIndex(of: stats.byHour.max() ?? 0) ?? 0
            Text("Your favorite hour is \(hourName(peak)).").font(.subheadline).foregroundStyle(.white.opacity(0.8))
            Chart(Array(stats.byHour.enumerated()), id: \.offset) { entry in
                BarMark(x: .value("Hour", hourLabel(entry.offset)), y: .value("Plays", entry.element), width: .ratio(0.7))
                    .foregroundStyle(entry.offset == peak ? Color.dial : Color.white.opacity(0.35))
                    .cornerRadius(Theme.Radius.thumb / 2)
            }
            .chartXScale(domain: (0..<24).map(hourLabel))
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18].map(hourLabel)) { value in
                    AxisValueLabel {
                        if let label = value.as(String.self), let hour = Int(label) { Text(hourName(hour)) }
                    }
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                }
            }
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .frame(height: Theme.Size.shelfTile * 0.8)
            .accessibilityChartDescriptor(BarsDescriptor(title: "Plays by hour",
                                                         bars: stats.byHour.enumerated().map { (hourName($0.offset), $0.element) }))

            let topDay = stats.byWeekday.firstIndex(of: stats.byWeekday.max() ?? 0) ?? 0
            Text("Your biggest day of the week is \(Calendar.current.weekdaySymbols[topDay]).")
                .font(.subheadline).foregroundStyle(.white.opacity(0.8))
                .padding(.top, Theme.Spacing.m)
            Chart(Array(stats.byWeekday.enumerated()), id: \.offset) { entry in
                BarMark(x: .value("Day", days[entry.offset]), y: .value("Plays", entry.element), width: .ratio(0.6))
                    .foregroundStyle(entry.offset == topDay ? Color.dial : Color.white.opacity(0.35))
                    .cornerRadius(Theme.Radius.thumb)
            }
            .chartXScale(domain: days)
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel().font(.caption2).foregroundStyle(.white.opacity(0.7))
                }
            }
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .frame(height: Theme.Size.shelfTile * 0.6)
            .accessibilityChartDescriptor(BarsDescriptor(title: "Plays by day",
                                                         bars: stats.byWeekday.enumerated().map { (days[$0.offset], $0.element) }))
            .padding(.top, Theme.Spacing.m)
        }
    }

    /// Hours as category names ("0" to "23"), so every bar gets its own slot.
    private func hourLabel(_ hour: Int) -> String { String(hour) }

    private func hourName(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? .now
        return date.formatted(.dateTime.hour())
    }
}

private struct HighlightsCard: View {
    let stats: ListeningStats

    var body: some View {
        StatCard(colors: [Color(red: 0.6, green: 0.15, blue: 0.3), Color(red: 0.3, green: 0.08, blue: 0.2)]) {
            CardTitle(text: "Highlights")
            if let day = stats.biggestDay {
                highlight("Your biggest day", day.formatted(.dateTime.weekday(.wide).month(.wide).day()),
                          "\(stats.biggestDayMinutes) minutes of music")
            }
            if stats.longestStreak > 1 {
                highlight("Longest streak", "\(stats.longestStreak) days in a row", "with music every day")
            }
            if let first = stats.firstSong {
                highlight("Where it started", first.name, first.detail)
            }
        }
    }

    private func highlight(_ label: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(label).font(.subheadline).foregroundStyle(.white.opacity(0.75))
            Text(value).font(.title2.weight(.heavy)).lineLimit(2)
            Text(detail).font(.subheadline).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
        }
        .padding(.vertical, Theme.Spacing.xs)
    }
}

private struct DiscoveryCard: View {
    let stats: ListeningStats

    var body: some View {
        StatCard(colors: [Color(red: 0.15, green: 0.5, blue: 0.35), Color(red: 0.05, green: 0.25, blue: 0.2)]) {
            CardTitle(text: "New to You")
            Text("\(stats.newSongs) songs").font(.system(size: 44, weight: .heavy, design: .rounded))
            Text("you played for the first time").font(.subheadline).foregroundStyle(.white.opacity(0.8))
            FlowLayout(spacing: Theme.Spacing.s) {
                ForEach(stats.newArtists) { artist in
                    Text(artist.name)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, Theme.Spacing.m)
                        .padding(.vertical, Theme.Spacing.xs + 2)
                        .background(.white.opacity(0.18), in: Capsule())
                }
            }
            .padding(.top, Theme.Spacing.s)
        }
    }
}

/// Your collection: how much music you have, from which decades, in which genres.
private struct CollectionCard: View {
    let stats: CollectionStats
    @Environment(AppModel.self) private var app

    var body: some View {
        StatCard(colors: [Color(red: 0.2, green: 0.2, blue: 0.24), Color(red: 0.08, green: 0.08, blue: 0.1)]) {
            CardTitle(text: "Your Collection")
            Text("\(stats.hours.formatted()) hours").font(.system(size: 44, weight: .heavy, design: .rounded))
            Text("of music, if you played it all back to back").font(.subheadline).foregroundStyle(.white.opacity(0.8))
            HStack(spacing: Theme.Spacing.xl) {
                count(stats.songs, "songs")
                count(stats.albums, "albums")
                count(stats.artists, "artists")
                count(stats.favorites, "favorites")
            }
            .padding(.vertical, Theme.Spacing.s)

            if !stats.decades.isEmpty {
                let decades = stats.decades.sorted { $0.key < $1.key }.map { (name: DecadeView.name($0.key), albums: $0.value) }
                Text("Your albums by decade").font(.subheadline).foregroundStyle(.white.opacity(0.8))
                Chart(decades, id: \.name) { decade in
                    BarMark(x: .value("Decade", decade.name), y: .value("Albums", decade.albums), width: .ratio(0.6))
                        .foregroundStyle(Color.dial.gradient)
                        .cornerRadius(Theme.Radius.thumb)
                        .annotation(position: .top, spacing: Theme.Spacing.xxs) {
                            Text("\(decade.albums)").font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.75))
                        }
                }
                .chartXScale(domain: decades.map(\.name))
                .chartYScale(domain: 0...(Double(decades.map(\.albums).max() ?? 1) * 1.2))
                .chartXAxis {
                    AxisMarks { _ in AxisValueLabel().font(.caption2).foregroundStyle(.white.opacity(0.7)) }
                }
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .frame(height: Theme.Size.shelfTile * 0.8)
                .accessibilityChartDescriptor(BarsDescriptor(title: "Albums by decade", bars: decades.map { ($0.name, $0.albums) }))
            }
            if stats.addedThisYear > 0 {
                Text("\(stats.addedThisYear) albums added this year.").font(.subheadline).foregroundStyle(.white.opacity(0.8))
            }
            if let oldest = stats.oldest {
                Button {
                    if let route = oldest.route { app.navigator.open(.album(id: route.id, name: route.name)) }
                } label: {
                    HStack(spacing: Theme.Spacing.m) {
                        ArtworkView(itemId: oldest.id, pixels: Theme.Pixels.thumb).artworkFrame(size: Theme.Size.rowArtwork)
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text("Your oldest album").font(.caption).foregroundStyle(.white.opacity(0.7))
                            Text(oldest.name).font(.headline).lineLimit(1)
                            Text(oldest.detail).font(.subheadline).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func count(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(value.formatted()).font(.headline)
            Text(label).font(.caption).foregroundStyle(.white.opacity(0.7))
        }
    }
}

private func hours(_ minutes: Int) -> String {
    minutes >= 120 ? "\(minutes / 60) hours" : "\(minutes) minutes"
}

/// Describes a bar chart to VoiceOver (Audio Graphs), so the numbers are there for everyone.
struct BarsDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let bars: [(String, Int)]

    func makeChartDescriptor() -> AXChartDescriptor {
        let x = AXCategoricalDataAxisDescriptor(title: "Category", categoryOrder: bars.map(\.0))
        let top = Double(bars.map(\.1).max() ?? 1)
        let y = AXNumericDataAxisDescriptor(title: "Plays", range: 0...max(top, 1), gridlinePositions: []) { "\(Int($0))" }
        let series = AXDataSeriesDescriptor(name: title, isContinuous: false,
                                            dataPoints: bars.map { AXDataPoint(x: $0.0, y: Double($0.1)) })
        return AXChartDescriptor(title: title, summary: nil, xAxis: x, yAxis: y, additionalAxes: [], series: [series])
    }
}
