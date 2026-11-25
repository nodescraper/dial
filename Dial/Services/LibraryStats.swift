import Foundation

/// Your library in numbers: how big it is, how it grew, what quality it's in, what's in it, what you've never played and
/// what's missing from it. Worked out from every song and album at once, and saved so the page opens instantly.
struct LibraryStats: Codable, Sendable {
    /// One bar, row or tile: a month, a format, an artist, an album…
    struct Entry: Codable, Sendable, Identifiable {
        let id: String
        let name: String
        var detail: String = ""
        var value: Int = 0
        var imageItemId: String? = nil
        var route: ListeningStats.RouteRef? = nil
    }

    // Totals
    var songs = 0
    var albums = 0
    var artists = 0
    var seconds: Double = 0
    var bytes: Int64 = 0

    // Growth
    /// Songs added in each of the last 12 months, oldest first ("Dec", "Jan"…).
    var addedByMonth: [Entry] = []
    var addedThisMonth = 0
    var biggestMonth: Entry?
    var firstAdded: Date?

    // Quality
    var formats: [Entry] = []
    var lossless = 0
    var hiRes = 0
    /// Compressed songs by bitrate, lowest first.
    var bitrates: [Entry] = []
    /// Albums whose files are all compressed and below 256 kbps on average, worst first.
    var weakestAlbums: [Entry] = []

    // Eras and genres
    var decades: [Entry] = []
    var genres: [Entry] = []

    // Biggest artists
    var topArtists: [Entry] = []

    // Unplayed
    var unplayedSongs = 0
    var unplayedAlbums = 0
    var unplayedAlbumList: [Entry] = []

    // Health
    var noCover = 0
    var noYear = 0
    var noGenre = 0
    var songsWithoutMusicBrainz = 0
    /// Albums with something missing, with what it is (the worst few), and how many there are in all.
    var problemAlbums: [Entry] = []
    var problemAlbumCount = 0

    var hours: Int { Int(seconds / 3600) }
    var losslessShare: Int { songs == 0 ? 0 : Int((Double(lossless) / Double(songs) * 100).rounded()) }
    var unplayedShare: Int { songs == 0 ? 0 : Int((Double(unplayedSongs) / Double(songs) * 100).rounded()) }
    var isEmpty: Bool { songs == 0 }
}

enum LibraryStatsEngine {
    static let snapshotKey = "library-stats-v1"

    /// Nil when the library couldn't be read.
    static func make(client: JellyfinClient) async -> LibraryStats? {
        async let songList = client.songsForLibraryStats()
        async let albumList = client.albumsForLibraryStats()
        guard let songs = try? await songList else { return nil }
        let albums = (try? await albumList) ?? []

        var stats = LibraryStats()
        stats.songs = songs.count
        stats.albums = albums.count
        stats.seconds = songs.reduce(0) { $0 + ($1.duration ?? 0) }
        stats.bytes = songs.reduce(0) { $0 + ($1.mediaSources?.first?.size ?? 0) }

        growth(songs, into: &stats)
        quality(songs, albums: albums, into: &stats)
        erasAndGenres(songs, into: &stats)
        artists(songs, into: &stats)
        unplayed(songs, albums: albums, into: &stats)
        health(songs, albums: albums, into: &stats)
        return stats
    }

    // MARK: Growth

    private static func growth(_ songs: [BaseItem], into stats: inout LibraryStats) {
        let calendar = Calendar.current
        let now = Date()
        let thisMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
        var counts: [Date: Int] = [:]
        var first: Date?
        for song in songs {
            guard let added = song.added else { continue }
            first = min(first ?? added, added)
            if let month = calendar.dateInterval(of: .month, for: added)?.start { counts[month, default: 0] += 1 }
        }
        stats.firstAdded = first
        stats.addedThisMonth = counts[thisMonth] ?? 0
        let monthName = Date.FormatStyle().month(.abbreviated)
        stats.addedByMonth = (0..<12).reversed().compactMap { back in
            calendar.date(byAdding: .month, value: -back, to: thisMonth).map { month in
                LibraryStats.Entry(id: ISO8601DateFormatter().string(from: month), name: month.formatted(monthName),
                                   value: counts[month] ?? 0)
            }
        }
        if let biggest = counts.max(by: { $0.value < $1.value }), biggest.value > 0 {
            stats.biggestMonth = .init(id: "biggest", name: biggest.key.formatted(.dateTime.month(.wide).year()), value: biggest.value)
        }
    }

    // MARK: Quality

    private static func bitrate(_ song: BaseItem) -> Int? {
        (song.audioStream?.bitRate ?? song.mediaSources?.first?.bitrate).map { $0 / 1000 }
    }

    private static func quality(_ songs: [BaseItem], albums: [BaseItem], into stats: inout LibraryStats) {
        var formats: [String: Int] = [:]
        var buckets = [0, 0, 0, 0] // under 192, 192–255, 256–319, 320 and up
        var lossyByAlbum: [String: (total: Int, count: Int, all: Bool)] = [:]
        for song in songs {
            formats[song.formatLabel ?? "Other", default: 0] += 1
            let albumId = song.albumId ?? ""
            if song.isLossless {
                stats.lossless += 1
                if (song.audioStream?.sampleRate ?? 0) > 48000 || (song.audioStream?.bitDepth ?? 0) > 16 { stats.hiRes += 1 }
                lossyByAlbum[albumId, default: (0, 0, true)].all = false
            } else if let kbps = bitrate(song) {
                buckets[kbps < 192 ? 0 : kbps < 256 ? 1 : kbps < 320 ? 2 : 3] += 1
                var album = lossyByAlbum[albumId, default: (0, 0, true)]
                album.total += kbps
                album.count += 1
                lossyByAlbum[albumId] = album
            }
        }
        stats.formats = formats.sorted { $0.value > $1.value }.map { .init(id: $0.key, name: $0.key, value: $0.value) }
        stats.bitrates = zip(["Under 192 kbps", "192\u{2013}255 kbps", "256\u{2013}319 kbps", "320 kbps"], buckets)
            .map { .init(id: $0.0, name: $0.0, value: $0.1) }
        let names = Dictionary(albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        stats.weakestAlbums = lossyByAlbum
            .compactMap { id, album -> (BaseItem, Int)? in
                guard album.all, album.count > 0, let item = names[id] else { return nil }
                let average = album.total / album.count
                return average < 256 ? (item, average) : nil
            }
            .sorted { $0.1 < $1.1 }
            .prefix(5)
            .map { album, kbps in
                .init(id: album.id, name: album.name, detail: "\(album.albumArtistLine), \(kbps) kbps", value: kbps,
                      imageItemId: album.id, route: .init(kind: "album", id: album.id, name: album.name))
            }
    }

    // MARK: Eras and genres

    private static func erasAndGenres(_ songs: [BaseItem], into stats: inout LibraryStats) {
        var decades: [Int: Int] = [:]
        var genres: [String: Int] = [:]
        for song in songs {
            if let year = song.year, year > 1900 { decades[year / 10 * 10, default: 0] += 1 }
            var seen = Set<String>()
            for tag in song.genres ?? [] {
                for genre in GenreNames.canonical(tag) where seen.insert(genre).inserted { genres[genre, default: 0] += 1 }
            }
        }
        stats.decades = decades.sorted { $0.key < $1.key }.map { .init(id: String($0.key), name: DecadeView.name($0.key), value: $0.value) }
        stats.genres = genres.sorted { $0.value > $1.value }.prefix(8).map { .init(id: $0.key, name: $0.key, value: $0.value) }
    }

    // MARK: Biggest artists

    private static func artists(_ songs: [BaseItem], into stats: inout LibraryStats) {
        struct Tally { var id: String?; var name: String; var songs = 0; var albums = Set<String>(); var seconds = 0.0 }
        var byArtist: [String: Tally] = [:]
        for song in songs {
            let name = ArtistNames.display(song.albumArtist ?? song.albumArtists?.first?.name ?? song.artists?.first ?? "")
            guard !name.isEmpty else { continue }
            let key = ArtistNames.key(name)
            var tally = byArtist[key] ?? Tally(id: song.albumArtists?.first?.id ?? song.artistItems?.first?.id, name: name)
            tally.songs += 1
            if let album = song.albumId { tally.albums.insert(album) }
            tally.seconds += song.duration ?? 0
            byArtist[key] = tally
        }
        stats.artists = byArtist.count
        stats.topArtists = byArtist.values.sorted { $0.songs > $1.songs }.prefix(5).map { artist in
            let hours = artist.seconds >= 3600 ? "\(Int(artist.seconds / 3600)) h" : "\(Int(artist.seconds / 60)) min"
            let albums = artist.albums.count == 1 ? "1 album" : "\(artist.albums.count) albums"
            return .init(id: artist.id ?? artist.name, name: artist.name, detail: "\(albums), \(hours)", value: artist.songs,
                         imageItemId: artist.id, route: artist.id.map { .init(kind: "artist", id: $0, name: artist.name) })
        }
    }

    // MARK: Unplayed

    private static func unplayed(_ songs: [BaseItem], albums: [BaseItem], into stats: inout LibraryStats) {
        func played(_ song: BaseItem) -> Bool { (song.userData?.playCount ?? 0) > 0 || song.userData?.lastPlayedDate != nil }
        stats.unplayedSongs = songs.filter { !played($0) }.count
        let playedAlbums = Set(songs.filter(played).compactMap(\.albumId))
        let untouched = albums.filter { !playedAlbums.contains($0.id) }
        stats.unplayedAlbums = untouched.count
        stats.unplayedAlbumList = untouched
            .sorted { ($0.added ?? .distantPast) > ($1.added ?? .distantPast) }
            .prefix(6)
            .map { .init(id: $0.id, name: $0.name, detail: $0.albumArtistLine, imageItemId: $0.id,
                         route: .init(kind: "album", id: $0.id, name: $0.name)) }
    }

    // MARK: Health

    private static func health(_ songs: [BaseItem], albums: [BaseItem], into stats: inout LibraryStats) {
        var problems: [(BaseItem, [String])] = []
        for album in albums {
            var missing: [String] = []
            if album.imageTags?["Primary"] == nil { stats.noCover += 1; missing.append("no cover") }
            if album.year == nil { stats.noYear += 1; missing.append("no year") }
            if (album.genres ?? []).isEmpty { stats.noGenre += 1; missing.append("no genre") }
            if !missing.isEmpty { problems.append((album, missing)) }
        }
        stats.songsWithoutMusicBrainz = songs.filter { song in
            !(song.providerIds ?? [:]).keys.contains { $0 == "MusicBrainzTrack" || $0 == "MusicBrainzRecording" }
        }.count
        stats.problemAlbumCount = problems.count
        // The worst first: most things missing, and a missing cover before the rest.
        stats.problemAlbums = problems
            .sorted { ($0.1.count, $0.1.contains("no cover") ? 1 : 0) > ($1.1.count, $1.1.contains("no cover") ? 1 : 0) }
            .prefix(6)
            .map { album, missing in
                .init(id: album.id, name: album.name, detail: missing.joined(separator: ", ").capitalizedFirst, imageItemId: album.id,
                      route: .init(kind: "album", id: album.id, name: album.name))
            }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
