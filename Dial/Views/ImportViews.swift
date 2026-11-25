import SwiftUI
import UniformTypeIdentifiers

// MARK: - Reading playlists from files

/// A playlist read from a file: a name and the songs in it.
struct ImportedList: Identifiable, Sendable {
    struct Song: Sendable, Hashable {
        let title: String
        let artist: String
        var album: String? = nil
    }

    let id = UUID()
    let name: String
    let source: String
    let songs: [Song]
    /// For listening history: how often each song was played (history comes in several files).
    var playCounts: [Song: Int]? = nil
}

/// Reads the files people have: Spotify's data download (playlists, liked songs and listening history),
/// Exportify's CSV files, and plain lists of "Artist - Title".
enum PlaylistFileReader {
    static func read(_ url: URL) -> [ImportedList] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let name = url.deletingPathExtension().lastPathComponent
        if url.pathExtension.lowercased() == "json", let json = try? JSONSerialization.jsonObject(with: data) {
            return fromJSON(json, fileName: name)
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return [] }
        if url.pathExtension.lowercased() == "csv" { return fromCSV(text, name: name) }
        return fromText(text, name: name)
    }

    // Spotify's data download
    private static func fromJSON(_ json: Any, fileName: String) -> [ImportedList] {
        // Playlist1.json: { "playlists": [ { "name", "items": [ { "track": { trackName, artistName, albumName } } ] } ] }
        if let root = json as? [String: Any], let playlists = root["playlists"] as? [[String: Any]] {
            return playlists.compactMap { playlist in
                let items = playlist["items"] as? [[String: Any]] ?? []
                let songs = items.compactMap { item -> ImportedList.Song? in
                    guard let track = item["track"] as? [String: Any],
                          let title = track["trackName"] as? String, let artist = track["artistName"] as? String else { return nil }
                    return .init(title: title, artist: artist, album: track["albumName"] as? String)
                }
                guard !songs.isEmpty else { return nil }
                return ImportedList(name: playlist["name"] as? String ?? "Playlist", source: "Spotify playlist", songs: songs)
            }
        }
        // YourLibrary.json: { "tracks": [ { artist, album, track } ] }
        if let root = json as? [String: Any], let tracks = root["tracks"] as? [[String: Any]] {
            let songs = tracks.compactMap { track -> ImportedList.Song? in
                guard let title = track["track"] as? String, let artist = track["artist"] as? String else { return nil }
                return .init(title: title, artist: artist, album: track["album"] as? String)
            }
            return songs.isEmpty ? [] : [ImportedList(name: "Liked Songs", source: "Spotify library", songs: songs)]
        }
        // Listening history: your most played songs.
        if let plays = json as? [[String: Any]] {
            var counts: [ImportedList.Song: Int] = [:]
            for play in plays {
                let title = (play["master_metadata_track_name"] ?? play["trackName"]) as? String
                let artist = (play["master_metadata_album_artist_name"] ?? play["artistName"]) as? String
                let played = (play["ms_played"] ?? play["msPlayed"]) as? Int ?? 0
                guard let title, let artist, played >= 30_000 else { continue } // a real listen, not a skip
                let album = play["master_metadata_album_album_name"] as? String
                counts[.init(title: title, artist: artist, album: album), default: 0] += 1
            }
            return counts.isEmpty ? [] : [topList(counts)]
        }
        return []
    }

    /// Your most played songs from listening history, up to 500.
    static func topList(_ counts: [ImportedList.Song: Int]) -> ImportedList {
        let top = counts.sorted { $0.value > $1.value }.prefix(500).map(\.key)
        return ImportedList(name: "Your Spotify Top \(top.count)", source: "Spotify listening history", songs: top, playCounts: counts)
    }

    // Exportify and similar: a header row with "Track Name" and "Artist Name(s)".
    private static func fromCSV(_ text: String, name: String) -> [ImportedList] {
        let rows = parseCSV(text)
        guard let header = rows.first?.map({ $0.lowercased() }) else { return [] }
        guard let titleIndex = header.firstIndex(where: { $0.contains("track name") || $0 == "title" || $0 == "name" }),
              let artistIndex = header.firstIndex(where: { $0.contains("artist") }) else { return fromText(text, name: name) }
        let albumIndex = header.firstIndex(where: { $0.contains("album name") || $0 == "album" })
        let songs = rows.dropFirst().compactMap { row -> ImportedList.Song? in
            guard row.count > max(titleIndex, artistIndex) else { return nil }
            let artist = row[artistIndex].components(separatedBy: CharacterSet(charactersIn: ",;")).first ?? row[artistIndex]
            return .init(title: row[titleIndex], artist: artist.trimmingCharacters(in: .whitespaces),
                         album: albumIndex.flatMap { row.indices.contains($0) ? row[$0] : nil })
        }
        return songs.isEmpty ? [] : [ImportedList(name: name, source: "CSV file", songs: songs)]
    }

    // One song per line: "Artist - Title".
    private static func fromText(_ text: String, name: String) -> [ImportedList] {
        let songs = text.components(separatedBy: .newlines).compactMap { line -> ImportedList.Song? in
            let parts = line.components(separatedBy: " - ")
            guard parts.count >= 2 else { return nil }
            return .init(title: parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces),
                         artist: parts[0].trimmingCharacters(in: .whitespaces))
        }
        return songs.isEmpty ? [] : [ImportedList(name: name, source: "Song list", songs: songs)]
    }

    private static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            switch character {
            case "\"":
                quoted.toggle()
            case "," where !quoted:
                row.append(field); field = ""
            case "\n" where !quoted, "\r\n" where !quoted:
                row.append(field); field = ""
                if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                row = []
            default:
                field.append(character)
            }
        }
        row.append(field)
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        return rows
    }
}

// MARK: - Matching songs to your library

/// Finds each imported song in your Jellyfin library by title and artist.
@MainActor
enum LibraryMatcher {
    static func key(_ text: String) -> String {
        // "Congratulations (feat. Quavo) - Remastered" → "congratulations"
        var clean = text.lowercased()
        for pattern in [#"\s*[\(\[][^\)\]]*[\)\]]"#, #"\s+-\s+.*(remaster|version|edit|mix|live).*$"#] {
            clean = clean.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return ArtistNames.key(clean).filter { $0.isLetter || $0.isNumber }
    }

    static func find(_ song: ImportedList.Song, client: JellyfinClient) async -> BaseItem? {
        let candidates = ((try? await client.search(song.title)) ?? []).filter { $0.isSong }
        let wantedTitle = key(song.title)
        let wantedArtist = ArtistNames.key(ArtistNames.primary(song.artist))
        let sameTitle = candidates.filter { key($0.name) == wantedTitle }
        let sameArtist: (BaseItem) -> Bool = { item in
            let artists = [item.albumArtist ?? "", item.artistLine] + (item.artists ?? [])
            return artists.contains { ArtistNames.key(ArtistNames.primary($0)) == wantedArtist || ArtistNames.key($0).contains(wantedArtist) }
        }
        return sameTitle.first(where: sameArtist)
            ?? candidates.first { sameArtist($0) && (key($0.name).contains(wantedTitle) || wantedTitle.contains(key($0.name))) }
    }
}

// MARK: - Screens

/// Bring in playlists from Spotify (or anywhere) and turn them into playlists of the songs you have.
struct ImportPlaylistsView: View {
    @State private var lists: [ImportedList] = []
    @State private var choosing = false

    var body: some View {
        List {
            Section {
                Text("Choose files from Spotify\u{2019}s data download, an Exportify CSV, or a text file with one \u{201C}Artist - Title\u{201D} per line. Dial finds those songs in your library and can save them as a playlist.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    choosing = true
                } label: {
                    Label("Choose Files", systemImage: "folder")
                }
            } footer: {
                Text("To get your Spotify data, go to spotify.com, Account, Privacy settings, and request your data. Playlist1.json has your playlists, YourLibrary.json your liked songs, and the StreamingHistory files your most played songs.")
            }

            if !lists.isEmpty {
                Section("Found") {
                    ForEach(lists) { list in
                        NavigationLink {
                            ImportMatchView(list: list)
                        } label: {
                            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                Text(list.name)
                                Text("\(list.songs.count) songs, \(list.source)").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Import Playlists")
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.json, .commaSeparatedText, .plainText, .text],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            var found: [ImportedList] = []
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                found += PlaylistFileReader.read(url)
                if access { url.stopAccessingSecurityScopedResource() }
            }
            // Listening history comes split over several files: combine them into one top list.
            let histories = found.compactMap(\.playCounts)
            var lists = found.filter { $0.playCounts == nil }
            if !histories.isEmpty {
                let combined = histories.reduce(into: [ImportedList.Song: Int]()) { total, counts in
                    total.merge(counts, uniquingKeysWith: +)
                }
                lists.insert(PlaylistFileReader.topList(combined), at: 0)
            }
            self.lists = lists
        }
    }
}

/// Matches one imported playlist against your library, then plays it or saves it.
struct ImportMatchView: View {
    let list: ImportedList
    @Environment(AppModel.self) private var app
    @State private var matched: [BaseItem] = []
    @State private var missing: [ImportedList.Song] = []
    @State private var checked = 0
    @State private var name = ""
    @State private var saving = false
    @State private var saved = false

    private var done: Bool { checked >= list.songs.count }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    ProgressView(value: Double(checked), total: Double(max(list.songs.count, 1)))
                        .tint(Color.dial)
                    Text(done
                         ? "Found \(matched.count) of \(list.songs.count) songs in your library."
                         : "Looking through your library\u{2026} \(checked) of \(list.songs.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, Theme.Spacing.xs)
                if done && !matched.isEmpty {
                    TextField("Playlist name", text: $name)
                    Button {
                        Task { await save() }
                    } label: {
                        Label(saved ? "Saved to Your Playlists" : "Save as Playlist", systemImage: saved ? "checkmark" : "plus")
                    }
                    .disabled(saving || saved || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button {
                        app.player.play(matched)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                }
            }
            if !matched.isEmpty {
                Section("In Your Library") {
                    SongRows(tracks: matched, keepsOrder: true)
                }
            }
            if done && !missing.isEmpty {
                Section {
                    ForEach(missing, id: \.self) { song in
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text(song.title)
                            Text(song.artist).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .opacity(0.6)
                    }
                } header: {
                    Text("Not in Your Library")
                } footer: {
                    Text("Add these to your music folder and Jellyfin picks them up on its next scan.")
                }
            }
        }
        .navigationTitle(list.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            name = list.name
            await match()
        }
    }

    private func match() async {
        guard let client = app.client, matched.isEmpty, checked == 0 else { return }
        // A few at a time, in order.
        for start in stride(from: 0, to: list.songs.count, by: 4) {
            let batch = Array(list.songs[start..<min(start + 4, list.songs.count)])
            let results = await withTaskGroup(of: (Int, BaseItem?).self) { group in
                for (offset, song) in batch.enumerated() {
                    group.addTask { @MainActor in (offset, await LibraryMatcher.find(song, client: client)) }
                }
                var found: [(Int, BaseItem?)] = []
                for await result in group { found.append(result) }
                return found.sorted { $0.0 < $1.0 }
            }
            for (offset, item) in results {
                if let item {
                    if !matched.contains(where: { $0.id == item.id }) { matched.append(item) }
                } else {
                    missing.append(batch[offset])
                }
            }
            checked += batch.count
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await app.library.createPlaylist(named: name.trimmingCharacters(in: .whitespaces), with: matched)
            saved = true
        } catch {
            app.library.errorMessage = "Couldn\u{2019}t save the playlist: \(error.localizedDescription)"
        }
    }
}
