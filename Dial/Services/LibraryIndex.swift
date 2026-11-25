import Foundation

/// Every song, album, artist and playlist you have, kept in memory (and refreshed now and then) so search can be forgiving:
/// "end of begg" finds "End of Beginning", "kendric lamar" finds "Kendrick Lamar". Jellyfin's own search only matches
/// exact pieces of text, so Dial also looks through everything itself.
actor LibraryIndex {
    static let shared = LibraryIndex()

    private struct Entry {
        let item: BaseItem
        let name: [String]
        let other: [String]
    }

    private var entries: [Entry] = []
    private var builtAt = Date.distantPast
    private var building: Task<Void, Never>?
    private var builtFor: String?

    /// Items that match the typed words (all of them, allowing small spelling slips), best first, with a score from 0 to 1.
    func search(_ term: String, client: JellyfinClient, limit: Int = 60) async -> [(item: BaseItem, score: Double)] {
        await ensure(client)
        let words = Self.tokens(term)
        guard !words.isEmpty else { return [] }
        var scored: [(BaseItem, Double)] = []
        for entry in entries {
            if let score = Self.score(words, entry.name, entry.other) { scored.append((entry.item, score)) }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map { (item: $0.0, score: $0.1) }
    }

    private func ensure(_ client: JellyfinClient) async {
        let key = client.server.absoluteString
        if builtFor == key, !entries.isEmpty {
            // Stale: rebuild behind the scenes, answer with what there is.
            if Date().timeIntervalSince(builtAt) > 600, building == nil { start(client) }
            return
        }
        if building == nil { start(client) }
        await building?.value
    }

    private func start(_ client: JellyfinClient) {
        building = Task { [weak self] in
            async let songs = (try? await client.allSongsForIndex()) ?? []
            async let albums = (try? await client.albums(sortedBy: .title)) ?? []
            async let artists = (try? await client.artists()) ?? []
            async let playlists = (try? await client.playlists()) ?? []
            let all = await songs + albums + artists + playlists
            let built = all.map { Entry(item: $0, name: Self.tokens($0.name), other: Self.tokens(([$0.artistLine, $0.albumArtist, $0.album].compactMap { $0 }).joined(separator: " "))) }
            await self?.finish(built, key: client.server.absoluteString)
        }
    }

    private func finish(_ built: [Entry], key: String) {
        if !built.isEmpty { entries = built; builtFor = key; builtAt = Date() }
        building = nil
    }

    // MARK: Matching

    static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// nil when a typed word matches nothing; otherwise how well they all match (title words count more than artist or album).
    private static func score(_ words: [String], _ name: [String], _ other: [String]) -> Double? {
        var total = 0.0
        for word in words {
            var best = 0.0
            for token in name { best = max(best, match(word, token)) }
            if best < 1 { for token in other { best = max(best, match(word, token) * 0.85) } }
            if best == 0 { return nil }
            total += best
        }
        // Shorter titles that are all matched rank above long ones that merely contain the words.
        let coverage = Double(min(words.count, name.count)) / Double(max(name.count, 1))
        return total / Double(words.count) * 0.85 + coverage * 0.15
    }

    /// 1 for the same word, a little less for the start of a longer one, and for a small spelling slip.
    private static func match(_ word: String, _ token: String) -> Double {
        if word == token { return 1 }
        if token.hasPrefix(word) { return 0.9 }
        if word.count >= 3, token.contains(word) { return 0.7 }
        guard word.count >= 3 else { return 0 }
        let allowed = word.count >= 7 ? 2 : word.count >= 4 ? 1 : 0
        guard allowed > 0 else { return 0 }
        // A slip in the typed word compared with the same length of the start of the token ("begg" ~ "begi"nning), or the whole token.
        let start = String(token.prefix(word.count))
        let d = min(distance(word, start), distance(word, token))
        return d <= allowed ? 0.6 - 0.1 * Double(d) : 0
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
