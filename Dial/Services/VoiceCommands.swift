import Foundation

/// What Siri asks Dial to play, found in your library and started. Shared by the App Shortcuts ("Hey Siri, play my
/// favorites in Dial") and the play-anything requests ("Hey Siri, play Ariana Grande on Dial"). The search is the
/// Library's own forgiving one, so a slightly misheard name still finds the right thing.
@MainActor
enum VoiceCommands {
    enum Kind: String, Sendable { case artist, album, song, playlist, mixtape, genre, mood, library }

    struct Match: Hashable, Sendable {
        let kind: Kind
        let id: String
        let title: String
        var subtitle: String? = nil

        /// "artist:1234…", kept by Siri between finding and playing.
        var identifier: String { "\(kind.rawValue):\(id)" }

        init(kind: Kind, id: String, title: String, subtitle: String? = nil) {
            self.kind = kind
            self.id = id
            self.title = title
            self.subtitle = subtitle
        }

        init?(identifier: String, title: String?) {
            guard let colon = identifier.firstIndex(of: ":"), let kind = Kind(rawValue: String(identifier[..<colon])) else { return nil }
            self.init(kind: kind, id: String(identifier[identifier.index(after: colon)...]), title: title ?? "")
        }
    }

    private static var app: AppModel { AppModel.shared }
    /// Songs found by the last search, so playing one doesn't look it up again.
    private static var found: [String: BaseItem] = [:]

    // MARK: Finding

    /// The best matches for what was said, best first. `kind` narrows it ("the album Thriller"); `artist` helps pick
    /// between songs or albums with the same name ("Hello by Adele").
    static func find(_ text: String, kind: Kind? = nil, artist: String? = nil, limit: Int = 5) async -> [Match] {
        guard let client = app.client else { return [] }
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return kind == nil ? [library] : [] }
        let key = LibraryMatcher.key(wanted)
        var matches: [Match] = []

        // Mixtapes and moods by their names ("Daily Mix 1", "Chill").
        if kind == nil || kind == .playlist || kind == .mixtape {
            for mix in DailyMixes.saved() where !mix.tracks.isEmpty && LibraryMatcher.key(mix.title) == key {
                matches.append(Match(kind: .mixtape, id: mix.id, title: mix.title, subtitle: mix.subtitle))
            }
        }
        if kind == nil || kind == .mood, let mood = SoundMood.all.first(where: { LibraryMatcher.key($0.title) == key }) {
            matches.append(Match(kind: .mood, id: mood.id, title: mood.title))
        }
        if kind == .genre || kind == nil, let genres = try? await client.genres(),
           let genre = genres.first(where: { LibraryMatcher.key($0.name) == key }) {
            matches.append(Match(kind: .genre, id: genre.id, title: genre.name))
        }
        if kind == .genre || kind == .mood { return matches }

        let types: [String] = switch kind {
        case .artist: ["MusicArtist"]
        case .album: ["MusicAlbum"]
        case .song: ["Audio"]
        case .playlist: ["Playlist"]
        default: ["MusicArtist", "MusicAlbum", "Playlist", "Audio"]
        }
        let term = [wanted, artist ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        let results = await LibraryIndex.shared.search(term, client: client, limit: 60)
            .filter { types.contains($0.item.type ?? "") }
        // The name said exactly first, then the better score; on a tie, artists before albums, playlists and songs.
        let ranked = results.sorted { a, b in
            let exactA = LibraryMatcher.key(a.item.name) == key, exactB = LibraryMatcher.key(b.item.name) == key
            if exactA != exactB { return exactA }
            if abs(a.score - b.score) > 0.05 { return a.score > b.score }
            return (types.firstIndex(of: a.item.type ?? "") ?? 9) < (types.firstIndex(of: b.item.type ?? "") ?? 9)
        }
        for (item, _) in ranked.prefix(limit) {
            switch item.type {
            case "MusicArtist": matches.append(Match(kind: .artist, id: item.id, title: ArtistNames.display(item.name)))
            case "MusicAlbum": matches.append(Match(kind: .album, id: item.id, title: item.name, subtitle: item.albumArtistLine))
            case "Playlist": matches.append(Match(kind: .playlist, id: item.id, title: item.name))
            default:
                found[item.id] = item
                matches.append(Match(kind: .song, id: item.id, title: item.name, subtitle: item.artistLine))
            }
        }
        return Array(matches.prefix(limit))
    }

    /// "Play music on Dial": a mix of your whole library.
    nonisolated static let library = Match(kind: .library, id: "all", title: "Your Library")

    // MARK: Playing

    /// Starts it. False when it couldn't be found or loaded.
    @discardableResult
    static func play(_ match: Match, shuffle: Bool = false) async -> Bool {
        guard let client = app.client else { return false }
        let player = app.player
        do {
            switch match.kind {
            case .artist:
                let songs = try await client.songs(byArtist: match.id, limit: 300)
                guard !songs.isEmpty else { return false }
                player.play(songs, shuffle: true, source: match.title)
            case .album:
                let songs = try await client.tracks(inAlbum: match.id)
                guard !songs.isEmpty else { return false }
                player.play(songs, shuffle: shuffle, source: match.title)
            case .playlist:
                let songs = try await client.playlistItems(match.id)
                guard !songs.isEmpty else { return false }
                player.play(songs, shuffle: shuffle, source: match.title)
            case .song:
                let song: BaseItem
                if let known = found[match.id] {
                    song = known
                } else if let fetched = try await client.items(ids: [match.id]).first {
                    song = fetched
                } else {
                    return false
                }
                // The song, then more like it.
                player.play([song], radio: true)
            case .mixtape:
                guard let mix = DailyMixes.saved().first(where: { $0.id == match.id }), !mix.tracks.isEmpty else { return false }
                player.play(mix.tracks, shuffle: shuffle, source: mix.title)
            case .genre:
                app.play(.genre(id: match.id, name: match.title))
            case .mood:
                app.play(.mood(id: match.id))
            case .library:
                app.play(.yourMix)
            }
            return true
        } catch {
            return false
        }
    }

    /// The song playing now, with "more like this" from it.
    static func moreLikeThis() -> Bool {
        guard let song = app.player.current else { return false }
        app.player.play([song], radio: true)
        return true
    }
}
