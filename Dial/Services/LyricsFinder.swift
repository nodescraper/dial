import Foundation

/// Finds lyrics for a song: first from your Jellyfin server, then, if it has none,
/// from LRCLIB (lrclib.net), a free community database of synced lyrics.
enum LyricsFinder {
    enum Source: Sendable { case server, lrclib }

    struct Result: Sendable {
        let lines: [LyricLine]
        let source: Source
    }

    static func lyrics(for track: BaseItem, client: JellyfinClient) async -> Result? {
        if let lines = try? await client.lyrics(for: track.id), !lines.isEmpty, !isSpam(lines) {
            return Result(lines: lines, source: .server)
        }
        if let lines = await fromLRCLIB(track), !lines.isEmpty {
            return Result(lines: lines, source: .lrclib)
        }
        return nil
    }

    /// Some downloaded files carry an ad where the lyrics should be ("Downloaded from www.musicduty.com"). That is not a lyric.
    private static func isSpam(_ lines: [LyricLine]) -> Bool {
        let text = lines.map(\.text).joined(separator: " ").lowercased()
        let markers = ["downloaded from", "www.", ".com", "http", "free mp3", "mp3 download", "visit "]
        return lines.count <= 6 && markers.contains { text.contains($0) }
    }

    // MARK: LRCLIB

    private struct Entry: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
        let duration: Double?
        let instrumental: Bool?
    }

    private static func fromLRCLIB(_ track: BaseItem) async -> [LyricLine]? {
        let artist = ArtistNames.primary(track.primaryArtist?.name ?? track.albumArtist ?? "")
        let title = cleanTitle(track.name)
        guard !artist.isEmpty, !title.isEmpty else { return nil }

        // Exact match first (artist, title, album and length), then a looser search.
        var exact = URLComponents(string: "https://lrclib.net/api/get")
        exact?.queryItems = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "album_name", value: track.album.map(cleanTitle) ?? ""),
            URLQueryItem(name: "duration", value: String(Int((track.duration ?? 0).rounded()))),
        ]
        if let url = exact?.url, let entry: Entry = await fetch(url), let lines = lines(from: entry) {
            return lines
        }
        var search = URLComponents(string: "https://lrclib.net/api/search")
        search?.queryItems = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title),
        ]
        guard let url = search?.url, let results: [Entry] = await fetch(url) else { return nil }
        // Prefer synced lyrics with a length close to this song's.
        let length = track.duration ?? 0
        let ranked = results.sorted { a, b in
            let aGap = abs((a.duration ?? 0) - length), bGap = abs((b.duration ?? 0) - length)
            if (a.syncedLyrics != nil) != (b.syncedLyrics != nil) { return a.syncedLyrics != nil }
            return aGap < bGap
        }
        for entry in ranked where length == 0 || abs((entry.duration ?? length) - length) < 8 {
            if let lines = lines(from: entry) { return lines }
        }
        return nil
    }

    private static func fetch<T: Decodable>(_ url: URL) async -> T? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        // LRCLIB asks apps to identify themselves.
        request.setValue("Dial/\(JellyfinClient.version) (https://github.com/)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func lines(from entry: Entry) -> [LyricLine]? {
        if entry.instrumental == true { return nil }
        if let synced = entry.syncedLyrics, !synced.isEmpty {
            let parsed = parseLRC(synced)
            if !parsed.isEmpty { return parsed }
        }
        if let plain = entry.plainLyrics, !plain.isEmpty {
            return plain.components(separatedBy: .newlines).map { LyricLine(text: $0, start: nil) }
        }
        return nil
    }

    /// "[01:23.45] Some words" → a line starting at 83.45 seconds.
    static func parseLRC(_ text: String) -> [LyricLine] {
        var result: [LyricLine] = []
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            var times: [Double] = []
            while line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                let stamp = line[line.index(after: line.startIndex)..<close]
                let parts = stamp.split(separator: ":")
                if parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) {
                    times.append(minutes * 60 + seconds)
                }
                line = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            }
            for time in times {
                result.append(LyricLine(text: line, start: Int64(time * 10_000_000)))
            }
        }
        return result.sorted { ($0.start ?? 0) < ($1.start ?? 0) }
    }

    /// "Congratulations (feat. Quavo) [Remastered]" → "Congratulations".
    private static func cleanTitle(_ name: String) -> String {
        var text = name
        for pattern in [#"\s*[\(\[](feat|ft|with)\.?\s[^\)\]]*[\)\]]"#, #"\s*[\(\[][^\)\]]*(remaster|version|edit|deluxe|mono|stereo)[^\)\]]*[\)\]]"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
