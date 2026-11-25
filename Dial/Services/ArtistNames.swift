import Foundation

/// Many files are tagged with the featured artists inside the artist name
/// ("Post Malone feat. 2 Chainz"), which makes Jellyfin list each combination
/// as its own artist, usually without a photo. These helpers find the main artist.
enum ArtistNames {
    /// Words that introduce guest artists. "&", "," and "and" are left alone on purpose,
    /// because they're also part of real names like "Earth, Wind & Fire".
    private static let guestMarkers = [" feat. ", " feat ", " ft. ", " ft ", " featuring ", " with ", " vs. ", " vs "]

    private static let bracketedGuests = try? NSRegularExpression(
        pattern: #"\s*[\(\[](feat|ft|featuring|with)\.?\s[^\)\]]*[\)\]]"#, options: [.caseInsensitive])

    /// "Post Malone feat. 2 Chainz" → "Post Malone". "Song (feat. X)" style suffixes are removed too.
    static func primary(_ name: String) -> String {
        var result = name
        if result.contains("(") || result.contains("["), let pattern = bracketedGuests {
            result = pattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        for marker in guestMarkers {
            if let range = result.range(of: marker, options: .caseInsensitive) {
                result = String(result[..<range.lowerBound])
            }
        }
        // Several artists in one tag, separated by ";" ("Juice Wrld; Marshmello; The Kid Laroi"): the first is the main one.
        if let semicolon = result.firstIndex(of: ";") { result = String(result[..<semicolon]) }
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? name : trimmed
    }

    /// A credit for reading: "A; B; C" → "A, B, C".
    static func display(_ credit: String) -> String {
        guard credit.contains(";") else { return credit }
        return credit.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// For comparing names: ignores case and accents.
    static func key(_ name: String) -> String {
        primary(name).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Separators between several artists credited together ("Kanye West & Ye", "A, B").
    private static let combiners = ["; ", ";", " & ", ", ", " and ", " x ", " + ", " / "]

    /// One entry per artist:
    /// - "Post Malone" and "Post Malone feat. 2 Chainz" become one ("Post Malone").
    /// - The same artist under two names (an artist who renamed themselves) becomes one, recognised
    ///   by their shared MusicBrainz id. The longer, more descriptive name is kept.
    /// - "A & B" is hidden when A and B are both in the library, since their songs show on their pages.
    ///   Real names like "Earth, Wind & Fire" stay, because their parts aren't artists of their own.
    /// The merged artists' ids are remembered, so an artist's page and radio include all their songs.
    static func distinct(_ artists: [BaseItem]) -> [BaseItem] {
        // 1. Main artist over "feat." combinations.
        var chosen: [String: (item: BaseItem, exact: Bool)] = [:]
        var order: [String] = []
        var allIds: [String: [String]] = [:]
        for artist in artists {
            let main = primary(artist.name)
            let key = main.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            let exact = main == artist.name
            allIds[key, default: []].append(artist.id)
            if let existing = chosen[key] {
                if !existing.exact && exact { chosen[key] = (artist, true) }
            } else {
                chosen[key] = (artist, exact)
                order.append(key)
            }
        }

        // 2. The same artist under two names.
        var byMusicBrainz: [String: String] = [:] // MusicBrainz id → kept key
        var mergedInto: [String: String] = [:]     // dropped key → kept key
        for key in order {
            guard let item = chosen[key]?.item,
                  let mbid = item.providerIds?["MusicBrainzArtist"], !mbid.isEmpty else { continue }
            if let keptKey = byMusicBrainz[mbid], let kept = chosen[keptKey]?.item {
                let better = descriptiveness(item.name) > descriptiveness(kept.name)
                let (winner, loser) = better ? (key, keptKey) : (keptKey, key)
                mergedInto[loser] = winner
                byMusicBrainz[mbid] = winner
                for (dropped, target) in mergedInto where target == loser { mergedInto[dropped] = winner }
            } else {
                byMusicBrainz[mbid] = key
            }
        }

        // Any name (kept or merged) → the key it shows under.
        func shownKey(_ key: String) -> String? {
            if let target = mergedInto[key] { return target }
            return chosen[key] != nil ? key : nil
        }

        // 3. "A & B" when both A and B are artists in the library.
        for key in order where mergedInto[key] == nil {
            guard let name = chosen[key]?.item.name else { continue }
            for separator in combiners where name.localizedCaseInsensitiveContains(separator) {
                let parts = name.components(separatedBy: separator).map { self.key($0) }
                let targets = parts.compactMap { part in part == key ? nil : shownKey(part) }
                if parts.count >= 2, targets.count == parts.count, let first = targets.first {
                    mergedInto[key] = first
                    break
                }
            }
        }

        // Remember which ids belong together.
        var groups: [String: [String]] = [:]
        for key in order {
            let target = shownKey(key) ?? key
            guard let shownId = chosen[target]?.item.id else { continue }
            groups[shownId, default: []].append(contentsOf: allIds[key] ?? [])
        }
        ArtistAliases.shared.update(groups)

        return order.filter { mergedInto[$0] == nil }.compactMap { chosen[$0]?.item }
    }

    /// Prefers fuller names ("Kanye West" over "Ye"): more words, then more letters.
    private static func descriptiveness(_ name: String) -> Int {
        name.split(separator: " ").count * 100 + name.count
    }
}

/// Which artist ids belong to the same artist, so their page, radio and songs include everything.
final class ArtistAliases: @unchecked Sendable {
    static let shared = ArtistAliases()
    private var groups: [String: [String]] = [:]
    private let lock = NSLock()

    func update(_ newGroups: [String: [String]]) {
        lock.lock()
        defer { lock.unlock() }
        for (id, ids) in newGroups {
            let unique = Array(Set(ids + [id])).sorted()
            groups[id] = unique
            // Any of the merged ids leads to the whole group.
            for other in unique where other != id { groups[other] = unique }
        }
    }

    /// The artist's ids joined for a Jellyfin query ("id1,id2"), or just the id.
    func query(for id: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return (groups[id] ?? [id]).joined(separator: ",")
    }
}
