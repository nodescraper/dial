import Foundation
import Observation

/// AudioMuse-AI's sound analysis, reached through its Jellyfin plugin (so it uses your normal
/// sign-in and works wherever Jellyfin does). Every feature checks the plugin's list of
/// endpoints first; anything your version doesn't offer is simply hidden in the app.
///
/// AudioMuse identifies songs by the same ids Jellyfin uses, so its answers turn straight
/// into songs from your library.
@MainActor
@Observable
final class AudioMuse {
    private(set) var version: String?
    private(set) var endpoints: Set<String> = []
    private(set) var hasChecked = false

    @ObservationIgnored var client: JellyfinClient? {
        didSet {
            version = nil
            endpoints = []
            hasChecked = false
            Task { await check() }
        }
    }

    var isConnected: Bool { version != nil }
    /// Find songs by describing them ("dreamy indie pop", "calm piano").
    var canSearchBySound: Bool { endpoints.contains("POST /AudioMuseAI/clap/search") }
    /// A path of songs from one song to another; Marlo uses it to glide between directions.
    var canFindPaths: Bool { endpoints.contains("GET /AudioMuseAI/find_path") }
    /// Songs that match the sound of what you listen to most.
    var canMakeYourSound: Bool { endpoints.contains("GET /AudioMuseAI/sonic_fingerprint/generate") }
    var canFindSimilarArtists: Bool { endpoints.contains("GET /AudioMuseAI/similar_artists") }

    /// The features your AudioMuse version offers, for Settings.
    var featureNames: [String] {
        [canSearchBySound ? "Moods and sound search" : nil, canFindPaths ? "Smooth DJ transitions" : nil,
         canMakeYourSound ? "Your Sound" : nil, canFindSimilarArtists ? "Similar artists" : nil].compactMap { $0 }
    }

    /// Asks the server what AudioMuse offers. If it can't be reached right now (the app was just opened, the network was not up
    /// yet) it tries again a few times, so features like Your Sound don't stay hidden on one device until the next launch.
    func check() async {
        defer { hasChecked = true }
        for wait in [0, 2, 6] as [UInt64] {
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let client else { return }
            if let data = try? await client.request("GET", "AudioMuseAI/info"),
               let info = try? JSONDecoder().decode(Info.self, from: data) {
                version = info.version ?? "unknown"
                endpoints = Set(info.availableEndpoints ?? [])
                return
            }
            if Task.isCancelled { return }
        }
    }

    // MARK: Features

    /// Songs that sound like a description. The first search can take a few seconds
    /// while AudioMuse loads its text model.
    func songs(matching description: String, limit: Int = 50) async throws -> [BaseItem] {
        try await scoredSongs(matching: description, limit: limit).map(\.item)
    }

    /// The same search with how well each song fits (higher is closer), best first. The score is
    /// nil if this AudioMuse version doesn't send one.
    func scoredSongs(matching description: String, limit: Int = 50) async throws -> [(item: BaseItem, similarity: Double?)] {
        let body = try JSONSerialization.data(withJSONObject: ["query": description, "limit": limit])
        let response: SearchResponse = try await call("POST", "AudioMuseAI/clap/search", body: body)
        let matches = response.results ?? []
        let scores = Dictionary(matches.compactMap { match in match.similarity.map { (match.itemId, $0) } }, uniquingKeysWith: { first, _ in first })
        return try await resolve(matches.map(\.itemId)).map { ($0, scores[$0.id]) }
    }

    /// A smooth path of songs from one song to another, including both.
    func path(from start: String, to end: String, steps: Int = 25) async throws -> [BaseItem] {
        let response: PathResponse = try await call("GET", "AudioMuseAI/find_path", query: [
            "start_song_id": start, "end_song_id": end, "max_steps": String(steps),
        ])
        return try await resolve(response.path?.map(\.itemId) ?? [])
    }

    /// Songs that match the sound of your listening history.
    func yourSound(count: Int = 60) async throws -> [BaseItem] {
        guard let client else { return [] }
        let matches: [Match] = try await call("GET", "AudioMuseAI/sonic_fingerprint/generate", query: [
            "jellyfin_user_identifier": client.userId, "jellyfin_token": client.token, "n": String(count),
        ])
        return try await resolve(matches.map(\.itemId))
    }

    /// Artists that sound like this one, closest first.
    func similarArtists(to artistId: String, count: Int = 12) async throws -> [BaseItem] {
        let artists: [ArtistMatch] = try await call("GET", "AudioMuseAI/similar_artists", query: [
            "artist_id": artistId, "n": String(count),
        ])
        return try await resolve(artists.compactMap(\.artistId))
    }

    // MARK: Plumbing

    private func call<T: Decodable>(_ method: String, _ path: String, query: [String: String] = [:],
                                    body: Data? = nil) async throws -> T {
        guard let client else { throw AudioMuseError.notConnected }
        let data = try await client.request(method, path, query: query, body: body)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// AudioMuse's ids as songs (or artists) from your library, in AudioMuse's order.
    private func resolve(_ ids: [String]) async throws -> [BaseItem] {
        guard let client, !ids.isEmpty else { return [] }
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        var items: [BaseItem] = []
        // Keep each request to a reasonable size.
        for start in stride(from: 0, to: unique.count, by: 100) {
            items += try await client.items(ids: Array(unique[start..<min(start + 100, unique.count)]))
        }
        return items
    }

    private struct Info: Decodable {
        let version: String?
        let availableEndpoints: [String]?
        enum CodingKeys: String, CodingKey {
            case version = "Version"
            case availableEndpoints = "AvailableEndpoints"
        }
    }

    private struct Match: Decodable {
        let itemId: String
        enum CodingKeys: String, CodingKey { case itemId = "item_id" }
    }

    private struct ClapMatch: Decodable {
        let itemId: String
        let similarity: Double?
        enum CodingKeys: String, CodingKey { case itemId = "item_id", similarity }
    }

    private struct SearchResponse: Decodable { let results: [ClapMatch]? }
    private struct PathResponse: Decodable { let path: [Match]? }

    private struct ArtistMatch: Decodable {
        let artistId: String?
        enum CodingKeys: String, CodingKey { case artistId = "artist_id" }
    }
}

enum AudioMuseError: LocalizedError {
    case notConnected
    var errorDescription: String? { "AudioMuse isn't reachable through your Jellyfin server." }
}

/// Moods for mood stations, each described the way AudioMuse's sound search understands.
struct SoundMood: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let symbol: String
    let description: String
    let colors: [Double] // two RGB colors, flattened

    static let all: [SoundMood] = [
        SoundMood(id: "chill", title: "Chill", symbol: "leaf.fill",
                  description: "relaxed chill laid back mellow", colors: [0.13, 0.47, 0.47, 0.56, 0.8, 0.62]),
        SoundMood(id: "focus", title: "Focus", symbol: "brain.head.profile",
                  description: "calm instrumental ambient focus", colors: [0.16, 0.24, 0.45, 0.42, 0.55, 0.8]),
        SoundMood(id: "energy", title: "Energy", symbol: "bolt.fill",
                  description: "energetic upbeat powerful fast", colors: [0.75, 0.2, 0.2, 0.95, 0.6, 0.2]),
        SoundMood(id: "feelgood", title: "Feel Good", symbol: "sun.max.fill",
                  description: "happy cheerful sunny feel good", colors: [0.95, 0.55, 0.2, 0.95, 0.8, 0.35]),
        SoundMood(id: "party", title: "Party", symbol: "party.popper.fill",
                  description: "danceable party groove club", colors: [0.55, 0.15, 0.5, 0.25, 0.55, 0.9]),
        SoundMood(id: "melancholy", title: "Melancholy", symbol: "cloud.rain.fill",
                  description: "sad melancholic emotional slow", colors: [0.2, 0.22, 0.35, 0.45, 0.5, 0.65]),
        SoundMood(id: "romantic", title: "Romantic", symbol: "heart.fill",
                  description: "romantic tender soulful love", colors: [0.6, 0.15, 0.3, 0.9, 0.45, 0.5]),
        SoundMood(id: "latenight", title: "Late Night", symbol: "moon.stars.fill",
                  description: "late night dark smooth atmospheric", colors: [0.1, 0.1, 0.25, 0.4, 0.3, 0.6]),
    ]
}
