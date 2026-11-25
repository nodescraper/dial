import Charts
import SwiftUI

/// Your library in numbers, as the same big cards as Your Stats: size, growth, quality, eras and genres, biggest artists,
/// what you've never played, and what's missing. Shows the saved numbers at once, then works them out again in the background.
struct LibraryStatsView: View {
    @Environment(AppModel.self) private var app
    @State private var stats: LibraryStats?
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.l) {
                if let stats, !stats.isEmpty {
                    TotalsCard(stats: stats)
                    GrowthCard(stats: stats)
                    QualityCard(stats: stats)
                    if !stats.decades.isEmpty || !stats.genres.isEmpty { ErasCard(stats: stats) }
                    if !stats.topArtists.isEmpty { BiggestArtistsCard(artists: stats.topArtists) }
                    UnplayedCard(stats: stats)
                    HealthCard(stats: stats)
                } else if loading {
                    SkeletonView(style: .grid)
                } else {
                    ContentUnavailableView("No music yet", systemImage: "square.stack",
                                           description: Text("Once your server has music, its numbers show up here."))
                }
            }
            .frame(maxWidth: Theme.Size.heroMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(Theme.Spacing.l)
        }
        .navigationTitle("Library Stats")
        .task { await load(force: false) }
        .refreshable { await load(force: true) }
    }

    private func load(force: Bool) async {
        guard let client = app.client else { loading = false; return }
        let key = LibraryStatsEngine.snapshotKey
        if stats == nil, let saved = await Snapshots.load(LibraryStats.self, key) { stats = saved }
        guard force || stats == nil || !Freshness.isFresh(key, maxAge: 3600) else { loading = false; return }
        loading = true
        if let fresh = await LibraryStatsEngine.make(client: client) {
            withAnimation { stats = fresh }
            Snapshots.save(fresh, key)
            Freshness.mark(key)
        }
        loading = false
    }
}

// MARK: - Cards

private let dim = Color.white.opacity(0.75)

/// A number with a word under it, in a row of facts.
private func fact(_ value: String, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
        Text(value).font(.headline).monospacedDigit()
        Text(label).font(.caption).foregroundStyle(.white.opacity(0.7))
    }
}

private struct TotalsCard: View {
    let stats: LibraryStats

    var body: some View {
        StatCard(colors: [Color.dial, Color(red: 0.75, green: 0.3, blue: 0.2)]) {
            CardTitle(text: "Your Library")
            Text("\(stats.hours.formatted()) hours")
                .font(.system(size: 56, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(days).font(.title3.weight(.semibold))
            HStack(spacing: Theme.Spacing.xl) {
                fact(stats.songs.formatted(), "songs")
                fact(stats.albums.formatted(), "albums")
                fact(stats.artists.formatted(), "artists")
                if stats.bytes > 0 { fact(ByteCountFormatter.string(fromByteCount: stats.bytes, countStyle: .file), "on disk") }
            }
            .padding(.top, Theme.Spacing.s)
        }
    }

    private var days: String {
        let days = stats.seconds / 86400
        return days >= 1 ? "That\u{2019}s \(String(format: days >= 10 ? "%.0f" : "%.1f", days)) days of music back to back"
            : "of music, back to back"
    }
}

private struct GrowthCard: View {
    let stats: LibraryStats

    var body: some View {
        StatCard(colors: [Color(red: 0.15, green: 0.5, blue: 0.35), Color(red: 0.05, green: 0.25, blue: 0.2)]) {
            CardTitle(text: "How It Grew")
            Text("+\(stats.addedThisMonth.formatted()) songs").font(.system(size: 44, weight: .heavy, design: .rounded))
            Text("added this month").font(.subheadline).foregroundStyle(dim)
            if stats.addedByMonth.contains(where: { $0.value > 0 }) {
                let peak = stats.addedByMonth.map(\.value).max() ?? 0
                Chart(stats.addedByMonth) { month in
                    BarMark(x: .value("Month", month.id), y: .value("Songs", month.value), width: .ratio(0.65))
                        .foregroundStyle(month.value == peak && peak > 0 ? Color.white : Color.white.opacity(0.4))
                        .cornerRadius(Theme.Radius.thumb / 2)
                }
                .chartXAxis {
                    AxisMarks(values: stats.addedByMonth.enumerated().filter { $0.offset % 3 == 2 }.map(\.element.id)) { value in
                        AxisValueLabel {
                            if let id = value.as(String.self), let month = stats.addedByMonth.first(where: { $0.id == id }) {
                                Text(month.name)
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .frame(height: Theme.Size.shelfTile * 0.7)
                .accessibilityChartDescriptor(BarsDescriptor(title: "Songs added by month",
                                                             bars: stats.addedByMonth.map { ($0.name, $0.value) }))
            }
            HStack(spacing: Theme.Spacing.xl) {
                if let biggest = stats.biggestMonth { fact(biggest.name, "biggest month, \(biggest.value) songs") }
                if let first = stats.firstAdded { fact(first.formatted(.dateTime.month(.abbreviated).year()), "collecting since") }
            }
            .padding(.top, Theme.Spacing.s)
        }
    }
}

private struct QualityCard: View {
    let stats: LibraryStats

    var body: some View {
        StatCard(colors: [Color(red: 0.1, green: 0.45, blue: 0.45), Color(red: 0.15, green: 0.2, blue: 0.35)]) {
            CardTitle(text: "Sound Quality")
            Text("\(stats.losslessShare)% lossless").font(.system(size: 44, weight: .heavy, design: .rounded))
            Text(stats.hiRes > 0 ? "\(stats.lossless.formatted()) songs, \(stats.hiRes.formatted()) of them hi-res"
                 : "\(stats.lossless.formatted()) of \(stats.songs.formatted()) songs")
                .font(.subheadline).foregroundStyle(dim)
            FlowLayout(spacing: Theme.Spacing.s) {
                ForEach(stats.formats) { format in
                    Text("\(format.name)  \(format.value.formatted())")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, Theme.Spacing.m)
                        .padding(.vertical, Theme.Spacing.xs + 2)
                        .background(.white.opacity(0.18), in: Capsule())
                }
            }
            if stats.bitrates.contains(where: { $0.value > 0 }) {
                Text("Compressed songs by bitrate").font(.subheadline).foregroundStyle(dim).padding(.top, Theme.Spacing.s)
                HorizontalBars(entries: stats.bitrates, highlight: stats.bitrates.last?.id, title: "Compressed songs by bitrate")
            }
            if !stats.weakestAlbums.isEmpty {
                Text("Weakest albums, worth fetching again").font(.subheadline).foregroundStyle(dim).padding(.top, Theme.Spacing.s)
                AlbumRows(entries: stats.weakestAlbums)
            }
        }
    }
}

private struct ErasCard: View {
    let stats: LibraryStats

    var body: some View {
        StatCard(colors: [Color(red: 0.35, green: 0.2, blue: 0.6), Color(red: 0.15, green: 0.1, blue: 0.3)]) {
            CardTitle(text: "Eras and Genres")
            if let top = stats.decades.max(by: { $0.value < $1.value }) {
                Text("Mostly the \(top.name)").font(.title.weight(.heavy))
                Chart(stats.decades) { decade in
                    BarMark(x: .value("Decade", decade.name), y: .value("Songs", decade.value), width: .ratio(0.6))
                        .foregroundStyle(decade.id == top.id ? Color.dial : Color.white.opacity(0.45))
                        .cornerRadius(Theme.Radius.thumb)
                        .annotation(position: .top, spacing: Theme.Spacing.xxs) {
                            Text("\(decade.value)").font(.caption2.monospacedDigit()).foregroundStyle(dim)
                        }
                }
                .chartXScale(domain: stats.decades.map(\.name))
                .chartYScale(domain: 0...(Double(top.value) * 1.2))
                .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.caption2).foregroundStyle(.white.opacity(0.7)) } }
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .frame(height: Theme.Size.shelfTile * 0.8)
                .accessibilityChartDescriptor(BarsDescriptor(title: "Songs by decade", bars: stats.decades.map { ($0.name, $0.value) }))
            }
            if !stats.genres.isEmpty {
                Text("Top genres, by songs").font(.subheadline).foregroundStyle(dim).padding(.top, Theme.Spacing.m)
                HorizontalBars(entries: stats.genres, highlight: stats.genres.first?.id, title: "Songs by genre")
            }
        }
    }
}

private struct BiggestArtistsCard: View {
    let artists: [LibraryStats.Entry]
    @Environment(AppModel.self) private var app

    var body: some View {
        StatCard(colors: [Color(red: 0.6, green: 0.15, blue: 0.3), Color(red: 0.3, green: 0.08, blue: 0.2)]) {
            CardTitle(text: "Biggest Artists")
            ForEach(Array(artists.enumerated()), id: \.element.id) { index, artist in
                Button {
                    if let route = artist.route { app.navigator.open(.artist(id: route.id, name: route.name)) }
                } label: {
                    HStack(spacing: Theme.Spacing.m) {
                        Text("\(index + 1)").font(.title2.weight(.heavy)).frame(width: Theme.Spacing.xl, alignment: .leading)
                        if let id = artist.imageItemId {
                            ArtworkView(itemId: id, pixels: Theme.Pixels.thumb, placeholder: "music.mic")
                                .artworkFrame(size: Theme.Size.rowArtwork, .circle)
                        }
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text(artist.name).font(.headline).lineLimit(1)
                            Text("\(artist.value) songs, \(artist.detail)").font(.subheadline).foregroundStyle(dim).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct UnplayedCard: View {
    let stats: LibraryStats
    @Environment(AppModel.self) private var app
    private let columns = [GridItem(.adaptive(minimum: Theme.Size.gridTileMin * 0.8), spacing: Theme.Spacing.m, alignment: .top)]

    var body: some View {
        StatCard(colors: [Color(red: 0.08, green: 0.1, blue: 0.25), Color(red: 0.25, green: 0.2, blue: 0.5)]) {
            CardTitle(text: "Never Played")
            Text("\(stats.unplayedShare)%").font(.system(size: 56, weight: .heavy, design: .rounded))
            Text(stats.unplayedSongs == 0 ? "You\u{2019}ve played every song you have."
                 : "of your songs you\u{2019}ve never played: \(stats.unplayedSongs.formatted()) songs, \(stats.unplayedAlbums) whole albums")
                .font(.subheadline).foregroundStyle(dim)
            if !stats.unplayedAlbumList.isEmpty {
                Text("Waiting for you").font(.subheadline).foregroundStyle(dim).padding(.top, Theme.Spacing.s)
                LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Spacing.l) {
                    ForEach(stats.unplayedAlbumList) { album in
                        Button {
                            if let route = album.route { app.navigator.open(.album(id: route.id, name: route.name)) }
                        } label: {
                            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                                ArtworkView(itemId: album.id, pixels: Theme.Pixels.tile).squareArtwork(.rounded(Theme.Radius.tile))
                                Text(album.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(album.detail).font(.caption).foregroundStyle(dim).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct HealthCard: View {
    let stats: LibraryStats

    var body: some View {
        StatCard(colors: [Color(red: 0.2, green: 0.2, blue: 0.24), Color(red: 0.08, green: 0.08, blue: 0.1)]) {
            CardTitle(text: "Library Health")
            Text(stats.problemAlbumCount == 0 ? "All in order"
                 : stats.problemAlbumCount == 1 ? "1 album needs a look" : "\(stats.problemAlbumCount) albums need a look")
                .font(.title.weight(.heavy))
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                check(stats.noCover, "albums without a cover")
                check(stats.noYear, "albums without a year")
                check(stats.noGenre, "albums without a genre")
                check(stats.songsWithoutMusicBrainz, "songs without a MusicBrainz ID")
            }
            if !stats.problemAlbums.isEmpty {
                AlbumRows(entries: stats.problemAlbums).padding(.top, Theme.Spacing.s)
            }
        }
    }

    private func check(_ count: Int, _ label: String) -> some View {
        Label {
            Text(count == 0 ? "No \(label)" : "\(count.formatted()) \(label)")
        } icon: {
            Image(systemName: count == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(count == 0 ? Color.green : Color.orange)
        }
        .font(.subheadline)
    }
}

// MARK: - Pieces

/// Rows of albums with their cover and a line under the name; tap to open the album.
private struct AlbumRows: View {
    let entries: [LibraryStats.Entry]
    @Environment(AppModel.self) private var app

    var body: some View {
        ForEach(entries) { album in
            Button {
                if let route = album.route { app.navigator.open(.album(id: route.id, name: route.name)) }
            } label: {
                HStack(spacing: Theme.Spacing.m) {
                    ArtworkView(itemId: album.imageItemId ?? album.id, pixels: Theme.Pixels.thumb).artworkFrame(size: Theme.Size.rowArtwork)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(album.name).font(.headline).lineLimit(1)
                        Text(album.detail).font(.subheadline).foregroundStyle(dim).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// Labeled horizontal bars with their counts, like Your Sound in Your Stats.
private struct HorizontalBars: View {
    let entries: [LibraryStats.Entry]
    let highlight: String?
    let title: String

    var body: some View {
        Chart(entries) { entry in
            BarMark(x: .value("Songs", entry.value), y: .value("Name", entry.name), height: .ratio(0.55))
                .foregroundStyle(entry.id == highlight ? Color.dial : Color.white.opacity(0.45))
                .cornerRadius(Theme.Radius.tile)
                .annotation(position: .top, alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(entry.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                }
                .annotation(position: .trailing, alignment: .center, spacing: Theme.Spacing.s) {
                    Text(entry.value.formatted()).font(.caption.monospacedDigit()).foregroundStyle(dim)
                }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartXScale(domain: 0...(Double(entries.map(\.value).max() ?? 1) * 1.15))
        .chartLegend(.hidden)
        .frame(height: CGFloat(entries.count) * Theme.Size.tapTarget * 1.1)
        .accessibilityChartDescriptor(BarsDescriptor(title: title, bars: entries.map { ($0.name, $0.value) }))
    }
}
