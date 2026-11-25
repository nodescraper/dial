import Foundation

/// The period your stats cover. Any time, not just at the end of the year.
enum StatsRange: String, CaseIterable, Identifiable, Codable, Sendable {
    case week = "Week", month = "Month", year = "Year", all = "All Time"
    var id: String { rawValue }

    var start: Date? {
        let calendar = Calendar.current
        let now = Date()
        switch self {
        case .week: return calendar.date(byAdding: .day, value: -7, to: now)
        case .month: return calendar.date(byAdding: .day, value: -30, to: now)
        case .year: return calendar.date(from: calendar.dateComponents([.year], from: now))
        case .all: return nil
        }
    }

    /// "This Year", "The Last 30 Days".
    var heading: String {
        switch self {
        case .week: "The Last 7 Days"
        case .month: "The Last 30 Days"
        case .year: "Your \(Calendar.current.component(.year, from: .now)) So Far"
        case .all: "All Time"
        }
    }
}

struct ListeningStats: Codable, Sendable {
    struct Ranked: Codable, Sendable, Identifiable {
        let id: String
        let name: String
        let detail: String
        let imageItemId: String?
        let plays: Int
        let minutes: Int
        var route: RouteRef? = nil
    }

    /// Where a ranked entry leads (kept simple so it can be saved).
    struct RouteRef: Codable, Sendable, Hashable {
        let kind: String // "artist" or "album"
        let id: String
        let name: String
    }

    var range: StatsRange
    var minutes = 0
    var plays = 0
    var activeDays = 0
    var longestStreak = 0
    var biggestDay: Date?
    var biggestDayMinutes = 0
    var topSongs: [Ranked] = []
    var topArtists: [Ranked] = []
    var topAlbums: [Ranked] = []
    var topGenres: [Ranked] = []
    /// Plays per hour of the day (0–23) and per weekday (Sunday first).
    var byHour: [Int] = Array(repeating: 0, count: 24)
    var byWeekday: [Int] = Array(repeating: 0, count: 7)
    var firstSong: Ranked?
    var newSongs = 0
    var newArtists: [Ranked] = []
    /// False when Playback Reporting isn't installed: all-time play counts only.
    var fromHistory = true

    var isEmpty: Bool { plays == 0 }

    /// A one-line description of how you listen.
    var personality: String? {
        guard byHour.reduce(0, +) > 0 else { return nil }
        let night = byHour[22...23].reduce(0, +) + byHour[0...3].reduce(0, +)
        let morning = byHour[5...9].reduce(0, +)
        let total = byHour.reduce(0, +)
        if Double(night) / Double(total) > 0.3 { return "Night Owl" }
        if Double(morning) / Double(total) > 0.3 { return "Early Bird" }
        let weekend = byWeekday[0] + byWeekday[6]
        if Double(weekend) / Double(max(byWeekday.reduce(0, +), 1)) > 0.45 { return "Weekend Listener" }
        let peak = byHour.firstIndex(of: byHour.max() ?? 0) ?? 12
        return peak < 12 ? "Morning Listener" : peak < 18 ? "Afternoon Listener" : "Evening Listener"
    }
}

struct CollectionStats: Codable, Sendable {
    var songs = 0
    var albums = 0
    var artists = 0
    var hours = 0
    var favorites = 0
    var decades: [Int: Int] = [:]
    var genres: [ListeningStats.Ranked] = []
    var addedThisYear = 0
    var oldest: ListeningStats.Ranked?
}

enum StatsEngine {
    // MARK: Listening

    @MainActor
    static func listening(_ range: StatsRange, client: JellyfinClient, history: ListeningHistory?) async -> ListeningStats {
        guard let history, history.isAvailable else { return await fromPlayCounts(client: client) }
        var stats = ListeningStats(range: range)
        let since = range.start.map { "AND DateCreated >= '\(DateFormatter.sqlDate.string(from: $0))'" } ?? ""
        let base = "FROM PlaybackActivity WHERE {user} AND ItemType = 'Audio' \(since)"

        async let totals = history.rows("SELECT COUNT(*), COALESCE(SUM(PlayDuration), 0) \(base)")
        async let items = history.rows("SELECT ItemId, COUNT(*) AS n, COALESCE(SUM(PlayDuration), 0) \(base) GROUP BY ItemId ORDER BY n DESC LIMIT 400")
        async let hours = history.rows("SELECT strftime('%H', DateCreated) AS h, COUNT(*) \(base) GROUP BY h")
        async let weekdays = history.rows("SELECT strftime('%w', DateCreated) AS d, COUNT(*) \(base) GROUP BY d")
        async let days = history.rows("SELECT date(DateCreated) AS d, COALESCE(SUM(PlayDuration), 0) \(base) GROUP BY d ORDER BY d")
        async let first = history.rows("SELECT ItemId \(base) ORDER BY DateCreated ASC LIMIT 1")

        if let row = await totals.first, row.count >= 2 {
            stats.plays = Int(row[0]) ?? 0
            stats.minutes = (Int(Double(row[1]) ?? 0)) / 60
        }
        for row in await hours where row.count >= 2 {
            if let hour = Int(row[0]), (0..<24).contains(hour) { stats.byHour[hour] = Int(row[1]) ?? 0 }
        }
        for row in await weekdays where row.count >= 2 {
            if let day = Int(row[0]), (0..<7).contains(day) { stats.byWeekday[day] = Int(row[1]) ?? 0 }
        }
        let dayRows = await days
        stats.activeDays = dayRows.count
        var streak = 0, best = 0
        var previous: Date?
        for row in dayRows where row.count >= 2 {
            guard let date = DateFormatter.sqlDate.date(from: row[0]) else { continue }
            if let previous, Calendar.current.dateComponents([.day], from: previous, to: date).day == 1 { streak += 1 } else { streak = 1 }
            best = max(best, streak)
            previous = date
            let minutes = Int(Double(row[1]) ?? 0) / 60
            if minutes > stats.biggestDayMinutes { stats.biggestDayMinutes = minutes; stats.biggestDay = date }
        }
        stats.longestStreak = best

        // Who and what: the top songs, then artists, albums and genres from them.
        let itemRows = await items
        let ids = itemRows.compactMap { $0.first }
        let songs = await resolve(ids, client: client)
        var playsById: [String: (plays: Int, seconds: Int)] = [:]
        for row in itemRows where row.count >= 3 {
            playsById[row[0]] = (Int(row[1]) ?? 0, Int(Double(row[2]) ?? 0))
        }
        aggregate(songs.compactMap { song in playsById[song.id].map { (song, $0.plays, $0.seconds / 60) } }, into: &stats)

        if let firstId = await first.first?.first, let song = await resolve([firstId], client: client).first {
            stats.firstSong = ranked(song, plays: 1, minutes: 0)
        }
        // Songs you played for the first time in this period.
        var newIds: [String] = []
        if let start = range.start {
            newIds = await history.rows(
                "SELECT ItemId FROM PlaybackActivity WHERE {user} AND ItemType = 'Audio' GROUP BY ItemId HAVING MIN(DateCreated) >= '\(DateFormatter.sqlDate.string(from: start))'"
            ).compactMap { $0.first }
        }
        stats.newSongs = newIds.count
        if !newIds.isEmpty {
            let discovered = await resolve(Array(newIds.prefix(300)), client: client)
            var artistPlays: [String: (Int, BaseItem)] = [:]
            for song in discovered {
                let name = ArtistNames.primary(song.albumArtist ?? song.artistLine)
                artistPlays[name] = ((artistPlays[name]?.0 ?? 0) + (playsById[song.id]?.plays ?? 1), artistPlays[name]?.1 ?? song)
            }
            stats.newArtists = artistPlays.sorted { $0.value.0 > $1.value.0 }.prefix(6).map { name, value in
                artistEntry(name: name, sample: value.1, plays: value.0, minutes: 0)
            }
        }
        return stats
    }

    /// Without Playback Reporting: your all-time play counts from Jellyfin.
    @MainActor
    private static func fromPlayCounts(client: JellyfinClient) async -> ListeningStats {
        var stats = ListeningStats(range: .all)
        stats.fromHistory = false
        let songs = ((try? await client.songs(sortedBy: "PlayCount", limit: 500)) ?? []).filter { $0.plays > 0 }
        stats.plays = songs.reduce(0) { $0 + $1.plays }
        stats.minutes = Int(songs.reduce(0.0) { $0 + Double($1.plays) * ($1.duration ?? 0) } / 60)
        aggregate(songs.map { ($0, $0.plays, Int(Double($0.plays) * ($0.duration ?? 0) / 60)) }, into: &stats)
        return stats
    }

    private static func aggregate(_ entries: [(song: BaseItem, plays: Int, minutes: Int)], into stats: inout ListeningStats) {
        stats.topSongs = entries.sorted { $0.plays > $1.plays }.prefix(10).map { ranked($0.song, plays: $0.plays, minutes: $0.minutes) }

        var artists: [String: (plays: Int, minutes: Int, sample: BaseItem)] = [:]
        var albums: [String: (plays: Int, minutes: Int, sample: BaseItem)] = [:]
        var genres: [String: Int] = [:]
        for entry in entries {
            let name = ArtistNames.primary(entry.song.albumArtist ?? entry.song.artistLine)
            let artist = artists[name]
            artists[name] = ((artist?.plays ?? 0) + entry.plays, (artist?.minutes ?? 0) + entry.minutes, artist?.sample ?? entry.song)
            if let albumId = entry.song.albumId {
                let album = albums[albumId]
                albums[albumId] = ((album?.plays ?? 0) + entry.plays, (album?.minutes ?? 0) + entry.minutes, album?.sample ?? entry.song)
            }
            for tag in entry.song.genres ?? [] {
                for genre in GenreNames.canonical(tag) { genres[genre, default: 0] += entry.plays }
            }
        }
        stats.topArtists = artists.sorted { $0.value.plays > $1.value.plays }.prefix(10).map { name, value in
            artistEntry(name: name, sample: value.sample, plays: value.plays, minutes: value.minutes)
        }
        stats.topAlbums = albums.sorted { $0.value.plays > $1.value.plays }.prefix(8).map { id, value in
            ListeningStats.Ranked(id: id, name: value.sample.album ?? "", detail: value.sample.albumArtist ?? value.sample.artistLine,
                                  imageItemId: id, plays: value.plays, minutes: value.minutes,
                                  route: .init(kind: "album", id: id, name: value.sample.album ?? ""))
        }
        stats.topGenres = genres.sorted { $0.value > $1.value }.prefix(6).map { name, plays in
            ListeningStats.Ranked(id: name, name: name, detail: "", imageItemId: nil, plays: plays, minutes: 0)
        }
    }

    private static func ranked(_ song: BaseItem, plays: Int, minutes: Int) -> ListeningStats.Ranked {
        ListeningStats.Ranked(id: song.id, name: song.name, detail: song.artistLine, imageItemId: song.imageItemId,
                              plays: plays, minutes: minutes)
    }

    private static func artistEntry(name: String, sample: BaseItem, plays: Int, minutes: Int) -> ListeningStats.Ranked {
        let artistId = sample.primaryArtist?.id
        return ListeningStats.Ranked(id: "artist-\(name)", name: name, detail: "", imageItemId: artistId ?? sample.imageItemId,
                                     plays: plays, minutes: minutes,
                                     route: artistId.map { .init(kind: "artist", id: $0, name: name) })
    }

    /// Songs by id, in chunks the server accepts.
    @MainActor
    private static func resolve(_ ids: [String], client: JellyfinClient) async -> [BaseItem] {
        var result: [BaseItem] = []
        for start in stride(from: 0, to: ids.count, by: 150) {
            let chunk = Array(ids[start..<min(start + 150, ids.count)])
            result += (try? await client.items(ids: chunk)) ?? []
        }
        return result
    }

    // MARK: Collection

    @MainActor
    static func collection(client: JellyfinClient, library: LibraryStore) async -> CollectionStats {
        var stats = CollectionStats()
        async let songs = client.count("Audio")
        async let albums = client.count("MusicAlbum")
        async let artists = client.count("MusicArtist")
        async let allSongs = client.allSongs()
        async let browsing = client.albumsForBrowsing(limit: 3000)
        stats.songs = await songs
        stats.albums = await albums
        stats.artists = await artists
        stats.hours = Int(((try? await allSongs) ?? []).reduce(0.0) { $0 + ($1.duration ?? 0) } / 3600)
        stats.favorites = library.favoriteIds.count
        let albumList = (try? await browsing) ?? []
        var genres: [String: Int] = [:]
        for album in albumList {
            if let year = album.productionYear, year > 1900 { stats.decades[year / 10 * 10, default: 0] += 1 }
            for tag in album.genres ?? [] { for genre in GenreNames.canonical(tag) { genres[genre, default: 0] += 1 } }
        }
        stats.genres = genres.sorted { $0.value > $1.value }.prefix(6).map {
            ListeningStats.Ranked(id: $0.key, name: $0.key, detail: "", imageItemId: nil, plays: $0.value, minutes: 0)
        }
        if let oldest = albumList.filter({ ($0.productionYear ?? 0) > 1900 }).min(by: { ($0.productionYear ?? 0) < ($1.productionYear ?? 0) }) {
            stats.oldest = ListeningStats.Ranked(id: oldest.id, name: oldest.name, detail: "\(oldest.albumArtistLine), \(oldest.productionYear ?? 0)",
                                                 imageItemId: oldest.id, plays: 0, minutes: 0,
                                                 route: .init(kind: "album", id: oldest.id, name: oldest.name))
        }
        let yearStart = StatsRange.year.start ?? .distantPast
        stats.addedThisYear = ((try? await client.recentAlbums(limit: 500)) ?? []).filter { ($0.added ?? .distantPast) >= yearStart }.count
        return stats
    }
}

extension DateFormatter {
    /// Dates as the Playback Reporting database writes them.
    static let sqlDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
