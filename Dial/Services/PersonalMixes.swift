import Foundation

/// What Dial knows about how you listen, gathered once for the day's mixtapes.
struct Listening: Sendable {
    var favoriteIds: Set<String> = []
    var plays: [String: Int] = [:]
    var lastPlayed: [String: Date] = [:]
    /// Played in the last three days, and in the last thirty (from Playback Reporting, when it is installed).
    var recent3: Set<String> = []
    var recent30: Set<String> = []
    /// Your most played songs, with their play counts and dates.
    var played: [BaseItem] = []
    var favorites: [BaseItem] = []

    func isKnown(_ id: String) -> Bool { favoriteIds.contains(id) || (plays[id] ?? 0) > 0 }

    /// Whether you played it within the last `days` days.
    func heard(_ id: String, within days: Int) -> Bool {
        if days <= 3, recent3.contains(id) { return true }
        if days <= 30, recent30.contains(id) { return true }
        if let last = lastPlayed[id], last > Date().addingTimeInterval(-Double(days) * 86400) { return true }
        return false
    }

    /// How much a song means to you: how much you play it, and whether you marked it.
    func weight(_ id: String) -> Double {
        min(Double(plays[id] ?? 0), 30) / 30 + (favoriteIds.contains(id) ? 0.5 : 0)
    }

    @MainActor
    static func load(client: JellyfinClient, history: ListeningHistory?) async -> Listening {
        var result = Listening()
        result.played = ((try? await client.songs(sortedBy: "PlayCount", limit: 600)) ?? []).filter { $0.plays > 0 }
        result.favorites = (try? await client.favoriteSongs()) ?? []
        result.favoriteIds = Set(result.favorites.map(\.id))
        for song in result.played {
            result.plays[song.id] = song.plays
            if let last = song.userData?.lastPlayed { result.lastPlayed[song.id] = last }
        }
        // Playback Reporting knows more recent plays than the server's own counters.
        for entry in await history?.topSongs(days: 90, limit: 300) ?? [] { result.plays[entry.id] = max(result.plays[entry.id] ?? 0, entry.plays) }
        result.recent3 = await history?.recentlyPlayed(hours: 72) ?? []
        result.recent30 = await history?.recentlyPlayed(hours: 24 * 30) ?? []
        return result
    }
}

/// Mixtapes made from your own listening. Your library is music you chose, so there is nothing to discover: these bring
/// back what you have not heard in a while, next to what you play now. Each is a fixed set for the day, the same on every
/// device, and different tomorrow.
/// How the plugin's made-for-you mixtapes look. The apps no longer make these themselves: the Dial plugin on the server does.
enum PersonalMixes {
    static let palettes: [String: [String]] = [
        "Daily Mix 1": ["#A8401A", "#E8742C"], "Daily Mix 2": ["#1F4D73", "#59BFD9"], "Daily Mix 3": ["#99401A", "#F2B24D"],
        "Daily Mix 4": ["#26665A", "#99D98C"], "On Repeat": ["#C2412D", "#2B1A1A"], "Rewind": ["#8C3380", "#F28066"],
        "Deep Cuts": ["#333366", "#8C73D9"], "Time Capsule": ["#80592A", "#D9BF80"],
    ]

    static func id(forTitle title: String) -> String {
        "mix-" + String(title.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

}
