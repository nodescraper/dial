import Foundation
import Observation

/// Who's on each song, like Spotify and Apple Music show it: "Post Malone feat. Justin Bieber"
/// credits both, so Justin Bieber gets an artist page (with the songs he's featured on) even when
/// your library has no album of his.
///
/// Featured names come from the song's artist tags, from artist names like "A feat. B" or "A & B",
/// and from titles like "Song (feat. B)". Dial reads your songs once, saves the result on the phone,
/// and refreshes it in the background.
@MainActor
@Observable
final class Credits {
    struct Entry: Codable, Sendable {
        let name: String
        var songs: [BaseItem]
    }

    /// Featured artist (by name key) → the songs they're featured on.
    private(set) var featured: [String: Entry] = [:]
    /// Library artists by name key, to tell "has a page in Jellyfin" from "featured only".
    private(set) var libraryArtists: [String: BaseItem] = [:]
    /// Every artist name known to stand on its own, to tell "Quavo & Future" (two) from "Simon & Garfunkel" (one).
    @ObservationIgnored private var knownArtists: Set<String> = []

    @ObservationIgnored var client: JellyfinClient? {
        didSet { Task { await refresh() } }
    }

    // MARK: Lookups

    /// Everyone credited on a song, main artist first.
    func credits(for track: BaseItem) -> [String] {
        let main = ArtistNames.primary(track.albumArtist ?? track.artistLine)
        var names = [main]
        for name in Self.featuredNames(in: track, known: knownArtists) where !names.contains(where: { ArtistNames.key($0) == ArtistNames.key(name) }) {
            names.append(name)
        }
        return names.filter { !$0.isEmpty }
    }

    /// Where an artist's name should lead: their Jellyfin page, or a page of the songs they're featured on.
    func route(for name: String) -> Route {
        if let artist = libraryArtists[ArtistNames.key(name)] {
            return .artist(id: artist.id, name: artist.name)
        }
        return .featuredArtist(name: name)
    }

    /// Songs this artist is featured on (not their own songs).
    func songs(featuring name: String) -> [BaseItem] {
        featured[ArtistNames.key(ArtistNames.primary(name))]?.songs ?? []
    }

    /// Artists who only appear as features, for the Artists list.
    var featuredOnly: [Entry] {
        featured.filter { libraryArtists[$0.key] == nil }.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Building the index

    func refresh() async {
        if featured.isEmpty, let saved = await Snapshots.load(CreditsSnapshot.self, "credits") {
            featured = saved.featured
            libraryArtists = Dictionary(saved.artists.map { (ArtistNames.key($0.name), $0) }, uniquingKeysWith: { a, _ in a })
        }
        guard let client else { return }
        guard let artists = try? await client.distinctArtists(),
              let songs = try? await client.allSongs() else { return }
        // Artists known on their own: your library's, and anyone credited alone on a song.
        var known = Set(artists.map { ArtistNames.key($0.name) })
        for song in songs {
            for name in Self.featuredNames(in: song, known: nil) where !name.contains("&") && !name.lowercased().contains(" and ") {
                known.insert(ArtistNames.key(name))
            }
        }
        knownArtists = known
        var index: [String: Entry] = [:]
        for song in songs {
            let main = ArtistNames.key(ArtistNames.primary(song.albumArtist ?? song.artistLine))
            for name in Self.featuredNames(in: song, known: known) {
                let key = ArtistNames.key(name)
                guard key != main, key.count > 1 else { continue }
                index[key, default: Entry(name: name, songs: [])].songs.append(song)
            }
        }
        featured = index
        libraryArtists = Dictionary(artists.map { (ArtistNames.key($0.name), $0) }, uniquingKeysWith: { a, _ in a })
        Snapshots.save(CreditsSnapshot(featured: index, artists: artists), "credits")
    }

    /// The featured artists on a song. Only what's marked as a feature counts: "feat.", "ft.",
    /// "featuring" or "with", in the artist credit or the title. Separate artist tags count as they are.
    /// `known` is the set of artists known on their own; nil reads names without splitting on "&".
    static func featuredNames(in song: BaseItem, known: Set<String>?) -> [String] {
        var names: [String] = []
        let main = ArtistNames.key(ArtistNames.primary(song.albumArtist ?? song.artistLine))
        // Separate artist tags: each tag is one artist, whatever its name contains.
        for artist in song.artists ?? [] where !artist.isEmpty {
            if artist.range(of: featuringPattern, options: [.regularExpression, .caseInsensitive]) != nil {
                names += featuresIn(credit: artist, known: known) // a tag like "A feat. B"
            } else {
                // One tag holding several artists ("A; B; C"): each is its own artist.
                names += artist.components(separatedBy: ";")
            }
        }
        // "A feat. B", "A ft. B & C", "A with B"; "A; B; C" is three artists.
        for credit in [song.artistLine, song.albumArtist ?? ""] {
            names += featuresIn(credit: credit, known: known)
            if credit.contains(";") { names += credit.components(separatedBy: ";") }
        }
        // "Song (feat. B)", "Song [with B & C]"
        if let match = song.name.range(of: #"[\(\[]\s*(feat\.?|ft\.?|featuring|with)\s+[^\)\]]+[\)\]]"#,
                                       options: [.regularExpression, .caseInsensitive]) {
            var inner = String(song.name[match]).dropFirst().dropLast()
            if let prefix = inner.range(of: #"^\s*(feat\.?|ft\.?|featuring|with)\s+"#, options: [.regularExpression, .caseInsensitive]) {
                inner = inner[prefix.upperBound...]
            }
            names += split(String(inner), known: known)
        }
        var seen = Set<String>()
        return names
            .map { ArtistNames.primary($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.isEmpty && ArtistNames.key($0) != main && seen.insert(ArtistNames.key($0)).inserted }
    }

    private static let featuringPattern = #"\s+(feat\.?|ft\.?|featuring|with)\s+"#

    /// The names after "feat." in a credit like "A feat. B & C".
    private static func featuresIn(credit: String, known: Set<String>?) -> [String] {
        guard let range = credit.range(of: featuringPattern, options: [.regularExpression, .caseInsensitive]) else { return [] }
        return split(String(credit[range.upperBound...]), known: known)
    }

    /// A feature list: commas always separate names ("B, C"). "&", "and" and "x" separate only when
    /// every part is an artist known on its own, so "Quavo & Future" is two and "Simon & Garfunkel" one.
    private static func split(_ text: String, known: Set<String>?) -> [String] {
        let parts = text
            .replacingOccurrences(of: featuringPattern, with: ", ", options: [.regularExpression, .caseInsensitive])
            .components(separatedBy: CharacterSet(charactersIn: ",;/"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let known else { return parts }
        return parts.flatMap { part -> [String] in
            let pieces = part
                .replacingOccurrences(of: #"\s+(&|and|x)\s+"#, with: "\u{1F}", options: [.regularExpression, .caseInsensitive])
                .components(separatedBy: "\u{1F}")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let allKnown = pieces.count > 1 && pieces.allSatisfy { known.contains(ArtistNames.key($0)) }
            return allKnown ? pieces : [part]
        }
    }
}

private struct CreditsSnapshot: Codable, Sendable {
    let featured: [String: Credits.Entry]
    let artists: [BaseItem]
}
