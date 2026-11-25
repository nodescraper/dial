import Foundation

/// An internet radio station from the Radio Browser directory (radio-browser.info),
/// a free, community-maintained list of stations that broadcast online.
struct Station: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let streamURL: String
    let favicon: String?
    let tags: String?
    let country: String?
    let codec: String?
    let bitrate: Int?
    let hls: Int?

    enum CodingKeys: String, CodingKey {
        case id = "stationuuid"
        case name
        case streamURL = "url_resolved"
        case url
        case favicon, tags, country, codec, bitrate, hls
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try c.decodeIfPresent(String.self, forKey: .name) ?? "Unnamed station")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = try c.decodeIfPresent(String.self, forKey: .streamURL) ?? ""
        let original = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        streamURL = resolved.isEmpty ? original : resolved
        favicon = try c.decodeIfPresent(String.self, forKey: .favicon)
        tags = try c.decodeIfPresent(String.self, forKey: .tags)
        country = try c.decodeIfPresent(String.self, forKey: .country)
        codec = try c.decodeIfPresent(String.self, forKey: .codec)
        bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate)
        hls = try c.decodeIfPresent(Int.self, forKey: .hls)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(streamURL, forKey: .streamURL)
        try c.encodeIfPresent(favicon, forKey: .favicon)
        try c.encodeIfPresent(tags, forKey: .tags)
        try c.encodeIfPresent(country, forKey: .country)
        try c.encodeIfPresent(codec, forKey: .codec)
        try c.encodeIfPresent(bitrate, forKey: .bitrate)
        try c.encodeIfPresent(hls, forKey: .hls)
    }

    var tagList: [String] {
        (tags ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "#"))) }
            .filter { !$0.isEmpty }
    }

    var subtitle: String {
        var parts: [String] = []
        let topTags = tagList.prefix(2).map { $0.capitalized }
        if !topTags.isEmpty { parts.append(topTags.joined(separator: ", ")) }
        if let country, !country.isEmpty { parts.append(country) }
        return parts.isEmpty ? "Live radio" : parts.joined(separator: " · ")
    }

    var faviconURL: URL? {
        guard let favicon, favicon.hasPrefix("http") else { return nil }
        return URL(string: favicon)
    }

    /// iPhone plays MP3, AAC and HLS streams; skip formats it can't.
    var isPlayable: Bool {
        guard !streamURL.isEmpty else { return false }
        let format = (codec ?? "").uppercased()
        return hls == 1 || format.contains("MP3") || format.contains("AAC") || format.isEmpty || format == "UNKNOWN"
    }
}

struct RadioBrowser: Sendable {
    static let shared = RadioBrowser()

    /// Public mirrors of the same directory; if one is down, the next is tried.
    private static let hosts = [
        "https://de1.api.radio-browser.info",
        "https://de2.api.radio-browser.info",
        "https://nl1.api.radio-browser.info",
        "https://at1.api.radio-browser.info",
    ]

    func stations(tag: String, limit: Int = 60) async throws -> [Station] {
        let encoded = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag
        return try await stations(path: "json/stations/bytag/\(encoded)", query: [
            "limit": String(limit), "hidebroken": "true", "order": "clickcount", "reverse": "true",
        ])
    }

    /// Stations for several tags at once, merged, de-duplicated and ranked by how many tags they match.
    func stations(tags: [String], limit: Int = 40) async throws -> [Station] {
        if tags.count == 1 { return try await stations(tag: tags[0], limit: limit) }
        var lists: [[Station]] = []
        var firstError: Error?
        await withTaskGroup(of: Result<[Station], Error>.self) { group in
            for tag in tags {
                group.addTask { await Result { try await self.stations(tag: tag, limit: limit) } }
            }
            for await result in group {
                switch result {
                case .success(let list): lists.append(list)
                case .failure(let error): firstError = firstError ?? error
                }
            }
        }
        if lists.isEmpty, let firstError { throw firstError }
        var hits: [String: Int] = [:]
        var ordered: [Station] = []
        for list in lists { for s in list {
            if hits[s.id] == nil { ordered.append(s) }
            hits[s.id, default: 0] += 1
        } }
        // Tags overlap a lot ("christmas" and "xmas"); the same station name only once.
        var seen = Set<String>()
        return ordered.enumerated()
            .sorted { (hits[$0.element.id] ?? 0, -$0.offset) > (hits[$1.element.id] ?? 0, -$1.offset) }
            .map(\.element)
            .filter { seen.insert($0.name.lowercased()).inserted }
    }

    func search(_ name: String) async throws -> [Station] {
        try await stations(path: "json/stations/search", query: [
            "name": name, "limit": "60", "hidebroken": "true", "order": "clickcount", "reverse": "true",
        ])
    }

    /// Tells the directory a station was played, which keeps its popularity ranking useful.
    func registerClick(_ stationId: String) async {
        _ = try? await fetch(path: "json/url/\(stationId)", query: [:])
    }

    private func stations(path: String, query: [String: String]) async throws -> [Station] {
        let data = try await fetch(path: path, query: query)
        let all = try JSONDecoder().decode([Station].self, from: data)
        // The directory often lists the same station more than once.
        var seen = Set<String>()
        return all.filter { station in
            guard station.isPlayable else { return false }
            return seen.insert(station.name.lowercased()).inserted
        }
    }

    private func fetch(path: String, query: [String: String]) async throws -> Data {
        var lastError: Error = URLError(.cannotConnectToHost)
        for host in Self.hosts {
            guard var components = URLComponents(string: "\(host)/\(path)") else { continue }
            if !query.isEmpty {
                components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            }
            guard let url = components.url else { continue }
            var request = URLRequest(url: url, timeoutInterval: 8)
            request.setValue("Dial/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    lastError = JellyfinError.http(http.statusCode)
                    continue
                }
                return data
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}
