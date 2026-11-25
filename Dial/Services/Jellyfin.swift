import Foundation

// MARK: - Models

struct NameId: Codable, Hashable, Sendable {
    let id: String
    let name: String?
    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
    }
}

struct UserData: Codable, Hashable, Sendable {
    /// When you last played it, if ever.
    var lastPlayed: Date? { lastPlayedDate.flatMap(JellyfinDates.parse) }

    var isFavorite: Bool?
    var playCount: Int?
    /// 0 to 10; Dial shows it as 0 to 5 stars.
    var rating: Double?
    var lastPlayedDate: String?
    enum CodingKeys: String, CodingKey {
        case isFavorite = "IsFavorite"
        case playCount = "PlayCount"
        case rating = "Rating"
        case lastPlayedDate = "LastPlayedDate"
    }
}

/// The file behind a song: its format and quality.
struct MediaSource: Codable, Hashable, Sendable {
    let container: String?
    let bitrate: Int?
    let size: Int64?
    let mediaStreams: [MediaStream]?
    enum CodingKeys: String, CodingKey {
        case container = "Container"
        case bitrate = "Bitrate"
        case size = "Size"
        case mediaStreams = "MediaStreams"
    }
}

struct MediaStream: Codable, Hashable, Sendable {
    let type: String?
    let codec: String?
    let sampleRate: Int?
    let bitDepth: Int?
    let channels: Int?
    let bitRate: Int?
    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case codec = "Codec"
        case sampleRate = "SampleRate"
        case bitDepth = "BitDepth"
        case channels = "Channels"
        case bitRate = "BitRate"
    }
}

/// Any item from Jellyfin: a song, album, artist, playlist or genre.
struct BaseItem: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let type: String?
    let album: String?
    let albumId: String?
    let albumArtist: String?
    let artists: [String]?
    let artistItems: [NameId]?
    let albumArtists: [NameId]?
    let runTimeTicks: Int64?
    let productionYear: Int?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let imageTags: [String: String]?
    let playlistItemId: String?
    let childCount: Int?
    let userData: UserData?
    let genres: [String]?
    let backdropImageTags: [String]?
    let parentBackdropItemId: String?
    let parentBackdropImageTags: [String]?
    let parentLogoItemId: String?
    let parentThumbItemId: String?
    let overview: String?
    let communityRating: Double?
    let criticRating: Double?
    let premiereDate: String?
    let dateCreated: String?
    let studios: [NameId]?
    let mediaSources: [MediaSource]?
    /// Whether the server has lyrics for this song (embedded, or a .lrc/.txt file next to it).
    let hasLyrics: Bool?
    /// Decibels to reach Jellyfin's loudness target (-18 LUFS), measured by its audio normalization task.
    let normalizationGain: Double?
    /// Where the item lives on the server (asked for only where it matters, like playlists).
    var path: String? = nil
    /// Ids from other databases; artists use "MusicBrainzArtist" to recognise the same person under two names.
    let providerIds: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case album = "Album"
        case albumId = "AlbumId"
        case albumArtist = "AlbumArtist"
        case artists = "Artists"
        case artistItems = "ArtistItems"
        case albumArtists = "AlbumArtists"
        case runTimeTicks = "RunTimeTicks"
        case productionYear = "ProductionYear"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case imageTags = "ImageTags"
        case playlistItemId = "PlaylistItemId"
        case childCount = "ChildCount"
        case userData = "UserData"
        case genres = "Genres"
        case backdropImageTags = "BackdropImageTags"
        case parentBackdropItemId = "ParentBackdropItemId"
        case parentBackdropImageTags = "ParentBackdropImageTags"
        case parentLogoItemId = "ParentLogoItemId"
        case parentThumbItemId = "ParentThumbItemId"
        case overview = "Overview"
        case communityRating = "CommunityRating"
        case criticRating = "CriticRating"
        case premiereDate = "PremiereDate"
        case dateCreated = "DateCreated"
        case studios = "Studios"
        case mediaSources = "MediaSources"
        case hasLyrics = "HasLyrics"
        case normalizationGain = "NormalizationGain"
        case providerIds = "ProviderIds"
        case path = "Path"
    }

    var isSong: Bool { type == "Audio" }

    /// Unique within a list, even when a playlist contains the same song twice.
    var listId: String { playlistItemId ?? id }

    var artistLine: String {
        if let artists, !artists.isEmpty { return ArtistNames.display(artists.joined(separator: ", ")) }
        return albumArtist.map(ArtistNames.display) ?? "Unknown artist"
    }

    var albumArtistLine: String {
        ArtistNames.display(albumArtist ?? albumArtists?.first?.name ?? artistLine)
    }

    /// The artist page to open from this song or album.
    var primaryArtist: NameId? { albumArtists?.first ?? artistItems?.first }

    /// Jellyfin measures time in ticks: 10,000,000 per second.
    var duration: TimeInterval? { runTimeTicks.map { Double($0) / 10_000_000 } }

    /// Songs usually have no cover of their own, so fall back to the album's cover.
    var imageItemId: String {
        imageTags?["Primary"] != nil ? id : (albumId ?? id)
    }

    /// A wide (16:9) picture for hero cards: the item's own backdrop or thumb, or its
    /// artist's backdrop, which Jellyfin downloads from TheAudioDB when artist images are on.
    var wideImage: (itemId: String, type: String)? {
        if backdropImageTags?.isEmpty == false { return (id, "Backdrop/0") }
        if imageTags?["Thumb"] != nil { return (id, "Thumb") }
        if let parent = parentBackdropItemId, parentBackdropImageTags?.isEmpty == false { return (parent, "Backdrop/0") }
        if let parent = parentThumbItemId { return (parent, "Thumb") }
        if let artist = primaryArtist?.id { return (artist, "Backdrop/0") }
        return nil
    }

    // MARK: File details

    var audioStream: MediaStream? {
        mediaSources?.first?.mediaStreams?.first { $0.type == "Audio" }
    }

    /// "FLAC", "MP3", "AAC"…
    var formatLabel: String? {
        let codec = audioStream?.codec ?? mediaSources?.first?.container?.components(separatedBy: ",").first
        return codec.map { $0 == "alac" ? "ALAC" : $0.uppercased() }
    }

    /// "44.1 kHz / 16-bit" for lossless files, "320 kbps" for compressed ones.
    var qualityLabel: String? {
        if isLossless, let rate = audioStream?.sampleRate {
            let khz = Double(rate) / 1000
            let rateText = khz == khz.rounded() ? String(Int(khz)) : String(format: "%.1f", khz)
            if let depth = audioStream?.bitDepth { return "\(rateText) kHz / \(depth)-bit" }
            return "\(rateText) kHz"
        }
        let bitrate = audioStream?.bitRate ?? mediaSources?.first?.bitrate
        return bitrate.map { "\($0 / 1000) kbps" }
    }

    /// Release year, or the year from the release date.
    var year: Int? {
        productionYear ?? premiereDate.flatMap { Int($0.prefix(4)) }
    }

    /// The artist's transparent logo, if the server has one.
    var logoImage: (itemId: String, type: String)? {
        if imageTags?["Logo"] != nil { return (id, "Logo") }
        if let parent = parentLogoItemId { return (parent, "Logo") }
        if let artist = primaryArtist?.id { return (artist, "Logo") }
        return nil
    }
}

struct LyricLine: Decodable, Hashable, Sendable {
    let text: String
    let start: Int64?

    enum CodingKeys: String, CodingKey {
        case text = "Text"
        case start = "Start"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        start = try container.decodeIfPresent(Int64.self, forKey: .start)
    }

    var startSeconds: TimeInterval? { start.map { Double($0) / 10_000_000 } }

    init(text: String, start: Int64?) {
        self.text = text
        self.start = start
    }
}

enum AlbumSort: String, CaseIterable, Identifiable {
    case recentlyAdded, title, artist, year

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recentlyAdded: return "Recently Added"
        case .title: return "Title"
        case .artist: return "Artist"
        case .year: return "Year"
        }
    }

    fileprivate var query: (sortBy: String, order: String) {
        switch self {
        case .recentlyAdded: return ("DateCreated", "Descending")
        case .title: return ("SortName", "Ascending")
        case .artist: return ("AlbumArtist,SortName", "Ascending")
        case .year: return ("ProductionYear,SortName", "Descending")
        }
    }
}

enum PlaybackEvent {
    case start, progress, stopped

    fileprivate var path: String {
        switch self {
        case .start: return "Sessions/Playing"
        case .progress: return "Sessions/Playing/Progress"
        case .stopped: return "Sessions/Playing/Stopped"
        }
    }
}

private struct ItemsResponse: Decodable {
    let items: [BaseItem]
    enum CodingKeys: String, CodingKey { case items = "Items" }
}

private struct ItemsPage: Decodable {
    let items: [BaseItem]
    let total: Int
    enum CodingKeys: String, CodingKey { case items = "Items", total = "TotalRecordCount" }
}

private struct CountResponse: Decodable {
    let total: Int
    enum CodingKeys: String, CodingKey { case total = "TotalRecordCount" }
}

private struct LyricsResponse: Decodable {
    let lyrics: [LyricLine]?
    enum CodingKeys: String, CodingKey { case lyrics = "Lyrics" }
}

private struct CreatedItem: Decodable {
    let id: String
    enum CodingKeys: String, CodingKey { case id = "Id" }
}

private struct AuthResponse: Decodable {
    let accessToken: String
    let user: NameId
    enum CodingKeys: String, CodingKey {
        case accessToken = "AccessToken"
        case user = "User"
    }
}

private struct NewPlaylist: Encodable {
    let name: String
    let ids: [String]
    let userId: String
    let mediaType = "Audio"
    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case ids = "Ids"
        case userId = "UserId"
        case mediaType = "MediaType"
    }
}

/// The rest of what's playing, so apps controlling this one see the whole picture.
struct PlaybackExtras: Sendable {
    var queueIds: [String] = []
    var volume = 100
    var repeatMode = "RepeatNone"
    var shuffled = false
}

private struct PlaybackReport: Encodable {
    struct QueueItem: Encodable {
        let id: String
        let playlistItemId: String
        enum CodingKeys: String, CodingKey {
            case id = "Id"
            case playlistItemId = "PlaylistItemId"
        }
    }

    let itemId: String
    let positionTicks: Int64
    let isPaused: Bool
    let playMethod: String
    let playSessionId: String
    let canSeek = true
    let nowPlayingQueue: [QueueItem]?
    let volumeLevel: Int?
    let isMuted: Bool?
    let repeatMode: String?
    let shuffleMode: String?

    enum CodingKeys: String, CodingKey {
        case itemId = "ItemId"
        case positionTicks = "PositionTicks"
        case isPaused = "IsPaused"
        case playMethod = "PlayMethod"
        case playSessionId = "PlaySessionId"
        case canSeek = "CanSeek"
        case nowPlayingQueue = "NowPlayingQueue"
        case volumeLevel = "VolumeLevel"
        case isMuted = "IsMuted"
        case repeatMode = "RepeatMode"
        case shuffleMode = "ShuffleMode"
    }
}

enum JellyfinError: LocalizedError {
    case badURL
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "That server address isn't valid. Use something like http://192.168.1.10:8096."
        case .http(401):
            return "Wrong username or password, or your sign-in expired. Sign in again."
        case .http(let code):
            return "The server returned error \(code)."
        }
    }
}

// MARK: - Response cache

/// Keeps library responses for a few minutes so moving between screens is instant.
/// Any change (favorites, playlists) clears it, and pull-to-refresh clears it too.
actor ResponseCache {
    private var entries: [URL: (stored: Date, data: Data)] = [:]
    private let lifetime: TimeInterval = 300

    func data(for url: URL) -> Data? {
        guard let entry = entries[url], Date().timeIntervalSince(entry.stored) < lifetime else { return nil }
        return entry.data
    }

    func store(_ data: Data, for url: URL) {
        entries[url] = (Date(), data)
    }

    func clear() {
        entries.removeAll()
    }
}

// MARK: - Client

struct JellyfinClient: Sendable {
    let server: URL
    let token: String
    let userId: String

    static let cache = ResponseCache()

    static func clearCache() async {
        await cache.clear()
    }

    static let clientName = "Dial"
    static let version = "1.0"

    static let deviceId: String = {
        let key = "dial.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    /// The header Jellyfin expects on every request (and on sign-in, without a token).
    static func authHeader(token: String?) -> String {
        var header = "MediaBrowser Client=\"\(clientName)\", Device=\"\(Platform.deviceKind)\", DeviceId=\"\(deviceId)\", Version=\"\(version)\""
        if let token { header += ", Token=\"\(token)\"" }
        return header
    }

    static func login(server: URL, username: String, password: String) async throws -> JellyfinClient {
        var request = URLRequest(url: server.appending(path: "Users/AuthenticateByName"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader(token: nil), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(["Username": username, "Pw": password])
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response)
        let auth = try JSONDecoder().decode(AuthResponse.self, from: data)
        return JellyfinClient(server: server, token: auth.accessToken, userId: auth.user.id)
    }

    // MARK: Connecting (before you're signed in)

    struct ServerInfo: Decodable, Sendable {
        let serverName: String?
        let version: String?
        enum CodingKeys: String, CodingKey { case serverName = "ServerName", version = "Version" }
    }

    struct QuickConnectState: Decodable, Sendable {
        let secret: String
        let code: String
        let authenticated: Bool
        enum CodingKeys: String, CodingKey { case secret = "Secret", code = "Code", authenticated = "Authenticated" }
    }

    /// "192.168.1.5:8096" or "http://host/" → a clean server URL.
    static func normalizedServer(_ raw: String) throws -> URL {
        var address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.lowercased().hasPrefix("http") { address = "http://" + address }
        while address.hasSuffix("/") { address.removeLast() }
        guard let url = URL(string: address), url.host != nil else { throw JellyfinError.badURL }
        return url
    }

    private static func anonymous(_ url: URL, method: String = "GET", timeout: TimeInterval = 8) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(authHeader(token: nil), forHTTPHeaderField: "Authorization")
        return request
    }

    /// The server's name and version: also proves the address is a Jellyfin server.
    static func serverInfo(_ server: URL) async throws -> ServerInfo {
        let (data, response) = try await URLSession.shared.data(for: anonymous(server.appending(path: "System/Info/Public")))
        try check(response)
        return try JSONDecoder().decode(ServerInfo.self, from: data)
    }

    /// Whether the server lets you sign in with a code (Dashboard → General → Quick Connect).
    static func quickConnectEnabled(_ server: URL) async -> Bool {
        guard let (data, response) = try? await URLSession.shared.data(for: anonymous(server.appending(path: "QuickConnect/Enabled"))),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return String(decoding: data, as: UTF8.self).lowercased().contains("true")
    }

    /// Asks for a code to approve from a device that's already signed in.
    static func startQuickConnect(_ server: URL) async throws -> QuickConnectState {
        let (data, response) = try await URLSession.shared.data(for: anonymous(server.appending(path: "QuickConnect/Initiate"), method: "POST"))
        try check(response)
        return try JSONDecoder().decode(QuickConnectState.self, from: data)
    }

    static func quickConnectState(_ server: URL, secret: String) async throws -> QuickConnectState {
        var parts = URLComponents(url: server.appending(path: "QuickConnect/Connect"), resolvingAgainstBaseURL: false)
        parts?.queryItems = [URLQueryItem(name: "secret", value: secret)]
        guard let url = parts?.url else { throw JellyfinError.badURL }
        let (data, response) = try await URLSession.shared.data(for: anonymous(url))
        try check(response)
        return try JSONDecoder().decode(QuickConnectState.self, from: data)
    }

    /// Signs in with a code someone approved.
    static func login(server: URL, quickConnectSecret: String) async throws -> JellyfinClient {
        var request = anonymous(server.appending(path: "Users/AuthenticateWithQuickConnect"), method: "POST", timeout: 15)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["Secret": quickConnectSecret])
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response)
        let auth = try JSONDecoder().decode(AuthResponse.self, from: data)
        return JellyfinClient(server: server, token: auth.accessToken, userId: auth.user.id)
    }

    // MARK: Plumbing

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else { throw JellyfinError.http(http.statusCode) }
    }

    private func makeURL(_ path: String, _ query: [String: String]) throws -> URL {
        guard var components = URLComponents(url: server.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw JellyfinError.badURL
        }
        if !query.isEmpty {
            components.queryItems = query
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw JellyfinError.badURL }
        return url
    }

    /// Sends a request. GET responses are cached unless `fresh` is true; any change on the
    /// server (except playback reports) clears the cache so screens never show stale data.
    @discardableResult
    private func send(_ method: String, _ path: String, query: [String: String] = [:],
                      body: Data? = nil, fresh: Bool = false) async throws -> Data {
        let url = try makeURL(path, query)
        let cacheable = method == "GET" && !fresh
        if cacheable, let cached = await Self.cache.data(for: url) { return cached }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(Self.authHeader(token: token), forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        if method == "GET" {
            // Several screens asking for the same list at once share one request.
            let shared = request
            let result = await RequestSharing.shared.data(for: url.absoluteString) {
                guard let (data, response) = try? await Network.session.data(for: shared),
                      (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else { return nil }
                return data
            }
            guard let result else {
                // Not shared on failure: ask once more on our own, so the real error is reported.
                let (retry, response) = try await Network.session.data(for: request)
                try Self.check(response)
                return retry
            }
            data = result
        } else {
            let sent: Data
            let response: URLResponse
            do {
                (sent, response) = try await Network.session.data(for: request)
            } catch let error as URLError where path.hasPrefix("Sessions")
                && [.networkConnectionLost, .timedOut, .cannotConnectToHost].contains(error.code) {
                // After the app has been in the background, the first request often fails on a connection iOS kept
                // but the server has dropped. Commands to another device are safe to send again.
                try await Task.sleep(for: .milliseconds(400))
                (sent, response) = try await Network.session.data(for: request)
            }
            try Self.check(response)
            data = sent
        }

        if cacheable {
            await Self.cache.store(data, for: url)
        } else if method != "GET" && !path.hasPrefix("Sessions") {
            await Self.cache.clear()
        }
        return data
    }

    /// Whether the server has the Dial plugin installed.
    func hasDialPlugin() async -> Bool {
        (try? await send("GET", "Dial/Ping", fresh: true)) != nil
    }

    /// The Discovery feed the plugin made for this user. `ready` is false while the server is still making the first one.
    func dialDiscovery() async -> (feed: DiscoveryFeed, ready: Bool)? {
        guard let data = try? await send("GET", "Dial/Discovery", fresh: true) else { return nil }
        if let text = String(data: data, encoding: .utf8), text.contains("\"ready\":false") { return (DiscoveryFeed(), false) }
        guard let feed = try? JSONDecoder().decode(DiscoveryFeed.self, from: data) else { return nil }
        return (feed, true)
    }

    /// Today's made-for-you mixtapes from the plugin (nil if it is not there or has not made them yet).
    func dialMixtapes() async -> [PluginMixtape]? {
        guard let data = try? await send("GET", "Dial/Mixtapes", fresh: true),
              let set = try? JSONDecoder().decode(PluginMixtapeSet.self, from: data) else { return nil }
        return set.mixes
    }

    /// For other parts of the app that talk to less common endpoints (like remote control).
    @discardableResult
    func request(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil) async throws -> Data {
        try await send(method, path, query: query, body: body, fresh: true)
    }

    private func items(_ path: String = "Items", _ query: [String: String], fresh: Bool = false) async throws -> [BaseItem] {
        var params = query
        params["userId"] = userId
        let data = try await send("GET", path, query: params, fresh: fresh)
        return try JSONDecoder().decode(ItemsResponse.self, from: data).items
    }

    private func items(_ query: [String: String], fresh: Bool = false) async throws -> [BaseItem] {
        try await items("Items", query, fresh: fresh)
    }

    // MARK: Albums

    func item(_ id: String) async throws -> BaseItem {
        let data = try await send("GET", "Items/\(id)", query: ["userId": userId])
        return try JSONDecoder().decode(BaseItem.self, from: data)
    }

    /// An item with everything about it: description, genres, label, ratings and file details.
    func details(_ id: String) async throws -> BaseItem {
        let data = try await send("GET", "Items/\(id)", query: [
            "userId": userId, "Fields": "Overview,Genres,Studios,MediaSources,DateCreated,PremiereDate,ProviderIds",
        ])
        return try JSONDecoder().decode(BaseItem.self, from: data)
    }

    func items(ids: [String]) async throws -> [BaseItem] {
        guard !ids.isEmpty else { return [] }
        let found = try await items(["Ids": ids.joined(separator: ","), "Fields": "Genres"], fresh: true)
        // Keep the order they were asked for in.
        let byId = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byId[$0] }
    }

    func similar(to itemId: String, limit: Int = 12) async throws -> [BaseItem] {
        try await items("Items/\(itemId)/Similar", ["Limit": String(limit)])
    }

    /// Every song by an artist, whether they're on the track or only credited on the album.
    func songs(byArtist artistId: String, limit: Int = 100) async throws -> [BaseItem] {
        let query = ["IncludeItemTypes": "Audio", "Recursive": "true", "SortBy": "Random", "Limit": String(limit)]
        var byTrack = query
        byTrack["ArtistIds"] = ArtistAliases.shared.query(for: artistId)
        let songs = try await items(byTrack, fresh: true)
        if !songs.isEmpty { return songs }
        var byAlbum = query
        byAlbum["AlbumArtistIds"] = artistId
        return try await items(byAlbum, fresh: true)
    }

    /// Sets your rating, 0 to 5 stars (stored as 0 to 10 on the server).
    func setRating(_ itemId: String, stars: Int) async throws {
        let body = try JSONEncoder().encode(["Rating": Double(stars * 2)])
        try await send("POST", "UserItems/\(itemId)/UserData", query: ["userId": userId], body: body)
    }

    // MARK: Server maintenance (administrators only)

    /// Asks the server to scan all libraries for new and changed files.
    func scanLibrary() async throws {
        try await send("POST", "Library/Refresh")
    }

    /// Asks the server to look up one item's details and pictures again.
    func refreshMetadata(_ itemId: String) async throws {
        try await send("POST", "Items/\(itemId)/Refresh", query: [
            "metadataRefreshMode": "FullRefresh", "imageRefreshMode": "FullRefresh",
            "replaceAllMetadata": "false", "replaceAllImages": "false",
        ])
    }

    func recentAlbums(limit: Int = 20) async throws -> [BaseItem] {
        try await items([
            "IncludeItemTypes": "MusicAlbum", "Recursive": "true",
            "SortBy": "DateCreated", "SortOrder": "Descending", "Limit": String(limit), "Fields": "DateCreated",
        ])
    }

    func albums(sortedBy sort: AlbumSort) async throws -> [BaseItem] {
        try await items([
            "IncludeItemTypes": "MusicAlbum", "Recursive": "true",
            "SortBy": sort.query.sortBy, "SortOrder": sort.query.order, "Limit": "3000",
        ])
    }

    func favoriteAlbums() async throws -> [BaseItem] {
        try await items([
            "IncludeItemTypes": "MusicAlbum", "Recursive": "true",
            "Filters": "IsFavorite", "SortBy": "SortName", "Limit": "200",
        ])
    }

    func albums(byArtist artistId: String) async throws -> [BaseItem] {
        try await items([
            "IncludeItemTypes": "MusicAlbum", "Recursive": "true", "AlbumArtistIds": ArtistAliases.shared.query(for: artistId),
            "SortBy": "ProductionYear,SortName", "SortOrder": "Descending", "Fields": "ProviderIds",
        ])
    }

    /// A broad sample of albums with their genres and years, to build Search's categories from.
    func albumsForBrowsing(limit: Int = 600) async throws -> [BaseItem] {
        try await items([
            "IncludeItemTypes": "MusicAlbum", "Recursive": "true", "SortBy": "Random",
            "Fields": "Genres", "Limit": String(limit),
        ], fresh: true)
    }

    /// How many albums came out in a decade (counted by the server, so every album is included, not a sample),
    /// and a few of them for the cover collage. The covers are the most recently added, so every device shows the same.
    func albumsInDecade(_ decade: Int, covers: Int = 4) async throws -> (count: Int, albums: [BaseItem]) {
        let years = (decade...(decade + 9)).map(String.init).joined(separator: ",")
        let data = try await send("GET", "Items", query: [
            "userId": userId, "IncludeItemTypes": "MusicAlbum", "Recursive": "true", "Years": years,
            "SortBy": "DateCreated", "SortOrder": "Descending", "Limit": String(covers),
        ], fresh: true)
        let page = try JSONDecoder().decode(ItemsPage.self, from: data)
        return (page.total, page.items)
    }

    /// How many albums have any of these genres (counted by the server), and a few of the most recently added for covers.
    /// Genres go by name: names are separated with "|" on every Jellyfin version, while id lists changed to commas in 10.9
    /// (a "|" there is quietly ignored, which would count the whole library for every genre).
    func albumsInGenres(_ genreNames: [String], covers: Int = 4) async throws -> (count: Int, albums: [BaseItem]) {
        guard !genreNames.isEmpty else { return (0, []) }
        let data = try await send("GET", "Items", query: [
            "userId": userId, "IncludeItemTypes": "MusicAlbum", "Recursive": "true", "Genres": genreNames.joined(separator: "|"),
            "SortBy": "DateCreated", "SortOrder": "Descending", "Limit": String(covers),
        ], fresh: true)
        let page = try JSONDecoder().decode(ItemsPage.self, from: data)
        return (page.total, page.items)
    }

    /// The release years the library has, from the server's own list (one small request, no counting).
    func libraryYears() async throws -> [Int] {
        let found = try await items("Years", ["IncludeItemTypes": "MusicAlbum", "Recursive": "true", "SortBy": "SortName"])
        return found.compactMap { Int($0.name) }
    }

    /// Albums released in these years, newest first.
    func albums(years: [Int], limit: Int = 500) async throws -> [BaseItem] {
        try await items([
            "IncludeItemTypes": "MusicAlbum", "Recursive": "true", "Years": years.map(String.init).joined(separator: ","),
            "SortBy": "ProductionYear,SortName", "SortOrder": "Descending", "Limit": String(limit),
        ])
    }

    /// Every song from these years. Albums carry the year; many songs on them have no year of their own, so asking for
    /// songs by year finds only a few. This takes the songs tagged with the year, plus every song on an album from it.
    func songsFromYears(_ years: [Int], limit: Int) async throws -> [BaseItem] {
        async let tagged = songs(genres: [], years: years, limit: limit)
        let albums = (try? await albums(years: years, limit: 3000)) ?? []
        let ids = Set(albums.map(\.id))
        var all = (try? await tagged) ?? []
        let chunks = stride(from: 0, to: albums.count, by: 40).map { Array(albums[$0..<min($0 + 40, albums.count)].map(\.id)) }
        await withTaskGroup(of: [BaseItem].self) { group in
            for chunk in chunks {
                group.addTask {
                    let found = (try? await self.items([
                        "IncludeItemTypes": "Audio", "Recursive": "true", "AlbumIds": chunk.joined(separator: ","),
                        "Limit": "3000", "Fields": "Genres",
                    ])) ?? []
                    // Only songs that really are on these albums, in case the server ignored the filter.
                    return found.filter { $0.albumId.map(ids.contains) ?? false }
                }
            }
            for await found in group { all += found }
        }
        var seen = Set<String>()
        return all.filter { seen.insert($0.id).inserted }
    }

    func albums(inGenre genreId: String) async throws -> [BaseItem] {
        try await items([
            "IncludeItemTypes": "MusicAlbum", "Recursive": "true", "GenreIds": genreId,
            "SortBy": "SortName", "Limit": "500",
        ])
    }

    // MARK: Songs

    func tracks(inAlbum albumId: String) async throws -> [BaseItem] {
        try await items([
            "ParentId": albumId, "IncludeItemTypes": "Audio", "Recursive": "true",
            "SortBy": "ParentIndexNumber,IndexNumber,SortName", "Fields": "MediaSources,Genres",
        ])
    }

    /// How many songs, albums or artists your library has, without downloading them.
    func count(_ type: String) async -> Int {
        var query = ["Recursive": "true", "Limit": "0", "userId": userId]
        let path: String
        if type == "MusicArtist" { path = "Artists/AlbumArtists" } else { path = "Items"; query["IncludeItemTypes"] = type }
        guard let data = try? await send("GET", path, query: query),
              let response = try? JSONDecoder().decode(CountResponse.self, from: data) else { return 0 }
        return response.total
    }

    /// Your name on the server.
    func userName() async -> String? {
        guard let data = try? await send("GET", "Users/\(userId)"),
              let user = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return user["Name"] as? String
    }

    /// Your profile picture on the server, if you've set one.
    var userImageURL: URL? { try? makeURL("Users/\(userId)/Images/Primary", ["maxWidth": "200", "quality": "90"]) }

    func allSongs() async throws -> [BaseItem] {
        try await items([
            "IncludeItemTypes": "Audio", "Recursive": "true", "SortBy": "SortName", "Limit": "5000",
        ])
    }

    func topSongs(byArtist artistId: String, limit: Int = 50) async throws -> [BaseItem] {
        try await items([
            "IncludeItemTypes": "Audio", "Recursive": "true", "ArtistIds": ArtistAliases.shared.query(for: artistId),
            "SortBy": "PlayCount,SortName", "SortOrder": "Descending", "Limit": String(limit),
        ])
    }

    func songs(inGenre genreId: String, limit: Int = 150) async throws -> [BaseItem] {
        try await items([
            "IncludeItemTypes": "Audio", "Recursive": "true", "GenreIds": genreId,
            "SortBy": "Random", "Limit": String(limit),
        ], fresh: true)
    }

    func favoriteSongs() async throws -> [BaseItem] {
        try await items([
            "IncludeItemTypes": "Audio", "Recursive": "true", "Filters": "IsFavorite",
            "SortBy": "SortName", "Limit": "3000",
        ], fresh: true)
    }

    func recentlyPlayedSongs(limit: Int = 60) async throws -> [BaseItem] {
        try await items([
            "IncludeItemTypes": "Audio", "Recursive": "true", "Filters": "IsPlayed",
            "SortBy": "DatePlayed", "SortOrder": "Descending", "Limit": String(limit),
        ], fresh: true)
    }

    /// Songs in a chosen order, with your play counts and last-played dates, for the DJ's blocks.
    /// `filters` is Jellyfin's filter list (for example "IsUnplayed" or "IsFavorite").
    func songs(sortedBy sort: String, order: String = "Descending", filters: String? = nil,
               artistId: String? = nil, limit: Int) async throws -> [BaseItem] {
        var query = ["IncludeItemTypes": "Audio", "Recursive": "true", "SortBy": sort, "SortOrder": order,
                     "Limit": String(limit), "Fields": "Genres,DateCreated", "EnableUserData": "true"]
        if let filters { query["Filters"] = filters }
        if let artistId { query["ArtistIds"] = ArtistAliases.shared.query(for: artistId) }
        return try await items(query, fresh: true)
    }

    func randomSongs(limit: Int) async throws -> [BaseItem] {
        try await items([
            "IncludeItemTypes": "Audio", "Recursive": "true", "SortBy": "Random", "Limit": String(limit),
        ], fresh: true)
    }

    /// Songs similar to the given song, album, artist, playlist or genre. With the
    /// AudioMuse plugin installed, Jellyfin answers this with sound-based matches.
    func instantMix(for itemId: String, limit: Int) async throws -> [BaseItem] {
        try await items("Items/\(itemId)/InstantMix", ["Limit": String(limit), "Fields": "Genres"], fresh: true)
    }

    /// Random songs filtered by genres and release years, for the DJ.
    func songs(genreIds: [String], years: [Int], limit: Int) async throws -> [BaseItem] {
        var query = [
            "IncludeItemTypes": "Audio", "Recursive": "true", "SortBy": "Random",
            "Limit": String(limit), "Fields": "Genres",
        ]
        if !genreIds.isEmpty { query["GenreIds"] = genreIds.joined(separator: ",") }
        if !years.isEmpty { query["Years"] = years.map(String.init).joined(separator: ",") }
        return try await items(query, fresh: true)
    }

    /// Random songs with any of these genres (by name) in these release years.
    func songs(genres: [String], years: [Int], limit: Int) async throws -> [BaseItem] {
        var query = [
            "IncludeItemTypes": "Audio", "Recursive": "true", "SortBy": "Random",
            "Limit": String(limit), "Fields": "Genres",
        ]
        if !genres.isEmpty { query["Genres"] = genres.joined(separator: "|") }
        if !years.isEmpty { query["Years"] = years.map(String.init).joined(separator: ",") }
        return try await items(query, fresh: true)
    }

    /// Songs on albums by these artists, in chunks so the request stays short.
    func songs(albumArtistIds: [String], years: [Int], limit: Int) async throws -> [BaseItem] {
        let chunks = stride(from: 0, to: albumArtistIds.count, by: 40).map { Array(albumArtistIds[$0..<min($0 + 40, albumArtistIds.count)]) }
        var all: [BaseItem] = []
        for chunk in chunks {
            var query = [
                "IncludeItemTypes": "Audio", "Recursive": "true", "SortBy": "Random",
                "Limit": String(limit), "Fields": "Genres", "AlbumArtistIds": chunk.joined(separator: ","),
            ]
            if !years.isEmpty { query["Years"] = years.map(String.init).joined(separator: ",") }
            all += try await items(query, fresh: true)
        }
        return all
    }

    // MARK: Artists, genres, search

    func artists() async throws -> [BaseItem] {
        try await items("Artists/AlbumArtists", ["SortBy": "SortName", "Limit": "3000", "Fields": "ProviderIds"])
    }

    /// All artists, one per main artist ("Post Malone", not also "Post Malone feat. X").
    /// Runs off the main thread, since libraries can have thousands of artists.
    func distinctArtists() async throws -> [BaseItem] {
        ArtistNames.distinct(try await artists())
    }

    /// The artist with exactly this name, if the server has one.
    func artist(named name: String) async throws -> BaseItem? {
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        do {
            let data = try await send("GET", "Artists/\(encoded)", query: ["userId": userId])
            return try JSONDecoder().decode(BaseItem.self, from: data)
        } catch JellyfinError.http(404) {
            return nil
        }
    }

    /// Artists for station tiles: one per main artist, preferring the real artist over "X feat. Y".
    /// Combined names are looked up all at once rather than one after another.
    func stationArtists(limit: Int) async throws -> [BaseItem] {
        let picks = Array(try await distinctArtists().shuffled().prefix(limit))
        let resolved = await withTaskGroup(of: (Int, BaseItem).self) { group in
            for (index, candidate) in picks.enumerated() {
                group.addTask {
                    let main = ArtistNames.primary(candidate.name)
                    guard candidate.name != main, let real = try? await artist(named: main) else { return (index, candidate) }
                    return (index, real)
                }
            }
            var results: [(Int, BaseItem)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return ArtistNames.distinct(resolved)
    }

    func randomArtists(limit: Int) async throws -> [BaseItem] {
        try await items("Artists/AlbumArtists", ["SortBy": "Random", "Limit": String(limit)], fresh: true)
    }

    /// Every song with its genre tags, for working out which genres your library really has.
    func songsWithGenres() async throws -> [BaseItem] {
        try await items(["IncludeItemTypes": "Audio", "Recursive": "true", "Fields": "Genres", "Limit": "50000"], fresh: true)
    }

    func genres() async throws -> [BaseItem] {
        try await items("MusicGenres", ["SortBy": "SortName", "Limit": "300"])
    }

    /// Every song with its file (format, quality, size), genres, ids, when it was added and whether you played it: Library Stats.
    func songsForLibraryStats() async throws -> [BaseItem] {
        try await items(["IncludeItemTypes": "Audio", "Recursive": "true", "Fields": "MediaSources,Genres,DateCreated,ProviderIds",
                         "EnableUserData": "true", "Limit": "50000"], fresh: true)
    }

    /// Every album with its cover, year, genres and when it was added: Library Stats.
    func albumsForLibraryStats() async throws -> [BaseItem] {
        try await items(["IncludeItemTypes": "MusicAlbum", "Recursive": "true", "Fields": "Genres,DateCreated,ProviderIds",
                         "Limit": "20000"], fresh: true)
    }

    /// Searches your library the forgiving way: "passion fruit" finds "Passionfruit", "the weekend" finds
    /// "The Weeknd", "kanye" finds "Kanye West". Jellyfin only matches exact pieces of text, so Dial asks for a few
    /// versions of what you typed at once (as typed, without spaces, each long word) and ranks everything by how
    /// well it really matches.
    func search(_ term: String) async throws -> [BaseItem] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        var variants = [trimmed]
        let joined = trimmed.replacingOccurrences(of: " ", with: "")
        if joined != trimmed { variants.append(joined) }
        let words = trimmed.split(separator: " ").map(String.init).filter { $0.count >= 4 }.sorted { $0.count > $1.count }
        for word in words.prefix(2) where !variants.contains(word) { variants.append(word) }
        // Close spellings: drop one letter from the end of each long word ("weekend" → "weeken" finds "Weeknd" via its start).
        if let longest = words.first, longest.count >= 6 { variants.append(String(longest.prefix(longest.count - 2))) }

        let found = try await withThrowingTaskGroup(of: [BaseItem].self) { group in
            for variant in variants {
                group.addTask {
                    try await self.items([
                        "searchTerm": variant, "IncludeItemTypes": "Audio,MusicAlbum,MusicArtist,Playlist",
                        "Recursive": "true", "Limit": "60",
                    ])
                }
            }
            var all: [BaseItem] = []
            for try await batch in group { all += batch }
            return all
        }
        var seen = Set<String>()
        let unique = found.filter { seen.insert($0.id).inserted }
        // Then look through everything you have, forgivingly: spelling slips, half-typed words, words in any order.
        let local = await LibraryIndex.shared.search(trimmed, client: self)
        var best: [String: (item: BaseItem, score: Double)] = [:]
        for item in unique { best[item.id] = (item, SearchRanking.score(item, for: trimmed)) }
        for hit in local {
            let score = hit.score * 80 + (hit.item.type == "MusicArtist" ? 3 : hit.item.type == "MusicAlbum" ? 2 : 0)
            if let existing = best[hit.item.id], existing.score >= score { continue }
            best[hit.item.id] = (hit.item, score)
        }
        return best.values.filter { $0.score >= 22 }.sorted { $0.score > $1.score }.map(\.item)
    }

    /// Every song, for the search index.
    func allSongsForIndex() async throws -> [BaseItem] {
        try await items([
            "IncludeItemTypes": "Audio", "Recursive": "true", "SortBy": "SortName", "Limit": "40000",
        ])
    }

    // MARK: Deleting

    /// Whether this account may delete files (Jellyfin's "Allow media deletion" in the user's settings).
    func canDelete() async -> Bool {
        guard let data = try? await request("GET", "Users/\(userId)"),
              let user = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let policy = user["Policy"] as? [String: Any] else { return false }
        if policy["EnableContentDeletion"] as? Bool == true { return true }
        return !((policy["EnableContentDeletionFromFolders"] as? [String]) ?? []).isEmpty
    }

    /// Deletes a song or an album (with all its songs) from the server, files included.
    func delete(_ itemId: String) async throws {
        try await request("DELETE", "Items/\(itemId)")
    }

    // MARK: Favorites

    func favoriteIds() async throws -> Set<String> {
        let favorites = try await items([
            "Recursive": "true", "Filters": "IsFavorite",
            "IncludeItemTypes": "Audio,MusicAlbum,MusicArtist,Playlist", "Limit": "10000",
        ], fresh: true)
        return Set(favorites.map(\.id))
    }

    func setFavorite(_ itemId: String, _ favorite: Bool) async throws {
        try await send(favorite ? "POST" : "DELETE", "UserFavoriteItems/\(itemId)", query: ["userId": userId])
    }

    // MARK: Playlists

    func playlists(fresh: Bool = false) async throws -> [BaseItem] {
        try await items(["IncludeItemTypes": "Playlist", "Recursive": "true", "SortBy": "SortName", "Fields": "Path,ChildCount"], fresh: fresh)
    }

    func playlistItems(_ playlistId: String) async throws -> [BaseItem] {
        try await items("Playlists/\(playlistId)/Items", [:])
    }

    @discardableResult
    func createPlaylist(named name: String, with itemIds: [String]) async throws -> String {
        let body = try JSONEncoder().encode(NewPlaylist(name: name, ids: itemIds, userId: userId))
        let data = try await send("POST", "Playlists", body: body)
        return (try? JSONDecoder().decode(CreatedItem.self, from: data).id) ?? ""
    }

    func addToPlaylist(_ playlistId: String, itemIds: [String]) async throws {
        try await send("POST", "Playlists/\(playlistId)/Items", query: [
            "ids": itemIds.joined(separator: ","), "userId": userId,
        ])
    }

    func removeFromPlaylist(_ playlistId: String, entryIds: [String]) async throws {
        try await send("DELETE", "Playlists/\(playlistId)/Items", query: [
            "entryIds": entryIds.joined(separator: ","),
        ])
    }

    /// Renames a playlist (the server leaves everything else about it as it is).
    func renamePlaylist(_ playlistId: String, to name: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["Name": name])
        try await send("POST", "Playlists/\(playlistId)", body: body)
    }

    /// Moves a song (by its place in this playlist, not its song id) to a new position.
    func movePlaylistItem(_ playlistId: String, entryId: String, to index: Int) async throws {
        try await send("POST", "Playlists/\(playlistId)/Items/\(entryId)/Move/\(index)")
    }

    func deleteItem(_ itemId: String) async throws {
        try await send("DELETE", "Items/\(itemId)")
    }

    // MARK: Lyrics

    /// Lyrics stored on your server (for example .lrc files next to the songs). Empty if there are none.
    func lyrics(for itemId: String) async throws -> [LyricLine] {
        do {
            let data = try await send("GET", "Audio/\(itemId)/Lyrics", fresh: true)
            return try JSONDecoder().decode(LyricsResponse.self, from: data).lyrics ?? []
        } catch JellyfinError.http(404) {
            return []
        }
    }

    // MARK: Playback reporting (play counts, "Recently played")

    func report(_ event: PlaybackEvent, itemId: String, position: TimeInterval, isPaused: Bool,
                playMethod: String, sessionId: String, extras: PlaybackExtras? = nil) async throws {
        let ticks = Int64(max(position, 0) * 10_000_000)
        let queue = extras?.queueIds.enumerated().map { PlaybackReport.QueueItem(id: $0.element, playlistItemId: "q\($0.offset)") }
        let report = PlaybackReport(itemId: itemId, positionTicks: ticks, isPaused: isPaused,
                                    playMethod: playMethod, playSessionId: sessionId,
                                    nowPlayingQueue: queue, volumeLevel: extras?.volume,
                                    isMuted: extras.map { $0.volume == 0 },
                                    repeatMode: extras?.repeatMode,
                                    shuffleMode: extras.map { $0.shuffled ? "Shuffle" : "Sorted" })
        try await send("POST", event.path, body: try JSONEncoder().encode(report))
    }

    // MARK: URLs

    /// Any of an item's pictures (Backdrop/0, Thumb, Logo…) at a given width, keeping its shape.
    func imageURL(for itemId: String, type: String, width: Int) -> URL? {
        try? makeURL("Items/\(itemId)/Images/\(type)", ["maxWidth": String(width), "quality": "90", "format": "Webp"])
    }

    func imageURL(for itemId: String, size: Int) -> URL? {
        try? makeURL("Items/\(itemId)/Images/Primary", [
            "fillWidth": String(size), "fillHeight": String(size), "quality": "90", "format": "Webp",
        ])
    }

    /// Streams the original file when iPhone can play it and no bitrate limit is set;
    /// otherwise the server converts the song to AAC at or below `maxBitrate`.
    func streamURL(for itemId: String, maxBitrate: Int?) -> URL? {
        try? makeURL("Audio/\(itemId)/universal", [
            "UserId": userId,
            "DeviceId": Self.deviceId,
            "ApiKey": token,
            "Container": maxBitrate == nil ? "mp3,aac,m4a|aac,m4a|alac,m4b|aac,flac,alac,wav" : "mp3,aac,m4a|aac",
            // A plain MP3 stream rather than HLS: the equalizer can't process HLS audio.
            "TranscodingContainer": "mp3",
            "TranscodingProtocol": "http",
            "AudioCodec": "mp3",
            "MaxStreamingBitrate": String(maxBitrate ?? 999_999_999),
            "AudioBitRate": String(min(maxBitrate ?? 320_000, 320_000)),
        ])
    }

    /// The original file, for offline downloads.
    func downloadURL(for itemId: String) -> URL? {
        try? makeURL("Audio/\(itemId)/stream", [
            "static": "true", "DeviceId": Self.deviceId, "ApiKey": token,
        ])
    }
}

/// Jellyfin's dates ("2026-11-04T21:20:52.0000000Z"), with or without fractions of a second.
enum JellyfinDates {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

    static func parse(_ text: String) -> Date? {
        // Jellyfin writes seven digits after the dot; ISO8601DateFormatter handles at most three.
        let trimmed = text.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        return fractional.date(from: trimmed) ?? plain.date(from: trimmed)
    }
}

extension BaseItem {
    var added: Date? { dateCreated.flatMap(JellyfinDates.parse) }
    var plays: Int { userData?.playCount ?? 0 }
}

/// Orders search results by how well they match what was typed, ignoring spaces, case, accents and punctuation.
enum SearchRanking {
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    static func score(_ item: BaseItem, for term: String) -> Double {
        let wanted = normalize(term)
        guard !wanted.isEmpty else { return 0 }
        let name = normalize(item.name)
        let artist = normalize(item.albumArtist ?? item.artistLine)
        var best: Double
        if name == wanted { best = 100 }
        else if name.hasPrefix(wanted) { best = 85 }
        else if name.contains(wanted) { best = 70 }
        else if (artist + name).contains(wanted) || (name + artist).contains(wanted) { best = 60 } // "drake passionfruit"
        else {
            // Every word typed appears somewhere in the title or artist.
            let words = term.split(separator: " ").map { normalize(String($0)) }.filter { !$0.isEmpty }
            let hay = name + " " + artist
            let hits = words.filter { hay.contains($0) }.count
            best = words.isEmpty ? 0 : 50 * Double(hits) / Double(words.count)
            // A near miss in spelling ("weeknd" for "weekend").
            best = max(best, 45 * similarity(name, wanted))
        }
        // Artists and albums first when the match is equally good, then songs.
        switch item.type {
        case "MusicArtist": best += 3
        case "MusicAlbum": best += 2
        default: break
        }
        return best
    }

    static func rank(_ items: [BaseItem], for term: String) -> [BaseItem] {
        items.map { ($0, score($0, for: term)) }
            .filter { $0.1 >= 22 }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// How alike two strings are, 0 to 1 (edit distance compared with the length).
    static func similarity(_ a: String, _ b: String) -> Double {
        let a = Array(a.prefix(40)), b = Array(b.prefix(40))
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
    }
}

extension BaseItem {
    /// A playlist file that came with your music (a .m3u in an album folder, like "Play Me" or "00.Info"),
    /// rather than one made in Jellyfin. Jellyfin can't delete these; they go away when the file does.
    var isPlaylistFile: Bool {
        guard type == "Playlist", let path = path?.lowercased() else { return false }
        if path.contains("/data/playlists/") || path.contains("\\data\\playlists\\") { return false }
        return [".m3u", ".m3u8", ".pls", ".wpl", ".xspf", ".zpl"].contains { path.hasSuffix($0) }
    }
}


/// A mixtape as the Dial plugin makes it: song ids and a look, resolved to songs by the app.
struct PluginMixtape: Decodable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let palette: [String]
    let trackIds: [String]
    let coverIds: [String]
}

struct PluginMixtapeSet: Decodable, Sendable {
    let day: String
    let mixes: [PluginMixtape]
}


/// What the Dial plugin reports about everything Dial builds on (for the Server Add-ons screen).
struct DialPluginStatus: Decodable, Sendable {
    struct Row: Decodable, Sendable, Identifiable {
        let name: String
        let active: Bool
        let provides: String
        let note: String?
        var id: String { name }
    }
    struct Group: Decodable, Sendable, Identifiable {
        let title: String
        let rows: [Row]
        var id: String { title }
    }
    let groups: [Group]
}

extension JellyfinClient {
    func dialPluginStatus() async -> DialPluginStatus? {
        guard let data = try? await request("GET", "Dial/Status") else { return nil }
        return try? JSONDecoder().decode(DialPluginStatus.self, from: data)
    }
}
