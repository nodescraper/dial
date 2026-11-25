import Foundation

/// Your library as spreadsheets: artists.csv, albums.csv and tracks.csv, zipped into one file to save or share.
/// UTF-8 with a byte order mark, so Excel shows accented names (Bohócautó) correctly; Numbers and Google Sheets read it too.
enum LibraryExport {
    struct Counts: Sendable { var artists = 0; var albums = 0; var tracks = 0 }

    /// Builds the zip in a temporary folder and returns where it is, with how many of each went in.
    static func make(client: JellyfinClient) async throws -> (url: URL, counts: Counts) {
        let songs = try await client.songsWithGenres()
        let date = Date().formatted(.iso8601.year().month().day())
        let name = "Dial Library \(date)"
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("library-export-\(UUID().uuidString)")
        let folder = root.appendingPathComponent(name)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let (artists, albums, tracks, counts) = tables(songs)
        try csv(["Artist", "Albums", "Tracks"], artists).write(to: folder.appendingPathComponent("artists.csv"))
        try csv(["Album Artist", "Album", "Year", "Tracks", "Length"], albums).write(to: folder.appendingPathComponent("albums.csv"))
        try csv(["Album Artist", "Album", "Disc", "Track", "Title", "Artists", "Year", "Length"], tracks)
            .write(to: folder.appendingPathComponent("tracks.csv"))

        return (try zip(folder, as: root.appendingPathComponent("\(name).zip")), counts)
    }

    // MARK: Tables

    private static func tables(_ songs: [BaseItem]) -> ([[String]], [[String]], [[String]], Counts) {
        func albumArtist(_ song: BaseItem) -> String {
            ArtistNames.display(song.albumArtist ?? song.albumArtists?.first?.name ?? song.artists?.first ?? "Unknown artist")
        }
        let sorted = songs.sorted {
            (albumArtist($0).lowercased(), ($0.album ?? "").lowercased(), $0.parentIndexNumber ?? 1, $0.indexNumber ?? 0)
                < (albumArtist($1).lowercased(), ($1.album ?? "").lowercased(), $1.parentIndexNumber ?? 1, $1.indexNumber ?? 0)
        }

        let tracks = sorted.map { song in
            [albumArtist(song), song.album ?? "", song.parentIndexNumber.map(String.init) ?? "", song.indexNumber.map(String.init) ?? "",
             song.name, song.artistLine, song.year.map(String.init) ?? "", length(song.duration ?? 0)]
        }

        // Albums in the order their songs came, each once.
        var albumOrder: [String] = []
        var albumSongs: [String: [BaseItem]] = [:]
        for song in sorted {
            let key = song.albumId ?? "\(albumArtist(song))|\(song.album ?? "")"
            if albumSongs[key] == nil { albumOrder.append(key) }
            albumSongs[key, default: []].append(song)
        }
        let albums = albumOrder.compactMap { key -> [String]? in
            guard let list = albumSongs[key], let first = list.first else { return nil }
            return [albumArtist(first), first.album ?? "", list.compactMap(\.year).first.map(String.init) ?? "", String(list.count),
                    length(list.reduce(0) { $0 + ($1.duration ?? 0) })]
        }

        // Artists by album artist, the way the Library lists them.
        var artistOrder: [String] = []
        var artistTally: [String: (name: String, albums: Set<String>, tracks: Int)] = [:]
        for song in sorted {
            let name = albumArtist(song)
            let key = ArtistNames.key(name)
            if artistTally[key] == nil { artistOrder.append(key); artistTally[key] = (name, [], 0) }
            artistTally[key]?.tracks += 1
            artistTally[key]?.albums.insert(song.albumId ?? song.album ?? "")
        }
        let artists = artistOrder.compactMap { artistTally[$0] }.map { [$0.name, String($0.albums.count), String($0.tracks)] }

        return (artists, albums, tracks, Counts(artists: artists.count, albums: albums.count, tracks: tracks.count))
    }

    /// "3:45", or "1:02:07" for an hour or more.
    private static func length(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    // MARK: Files

    private static func csv(_ header: [String], _ rows: [[String]]) -> Data {
        func field(_ text: String) -> String {
            text.contains { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }
                ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        }
        let lines = ([header] + rows).map { $0.map(field).joined(separator: ",") }
        return Data([0xEF, 0xBB, 0xBF]) + Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    /// Zips a folder with the system's own zipping (asking for a folder "for uploading" hands back a zip of it).
    private static func zip(_ folder: URL, as destination: URL) throws -> URL {
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinatorError) { zipped in
            do { try FileManager.default.copyItem(at: zipped, to: destination) } catch { copyError = error }
        }
        if let error = coordinatorError ?? copyError { throw error }
        return destination
    }
}
