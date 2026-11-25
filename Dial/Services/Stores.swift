import Foundation
import Observation

// MARK: - Favorites and playlists

@MainActor
@Observable
final class LibraryStore {
    private(set) var favoriteIds: Set<String> = []
    /// Bumped on every favorite change, so screens listing favorites can refresh.
    private(set) var favoritesVersion = 0
    /// Whether favorites have been loaded from the server at least once.
    private(set) var hasLoadedFavorites = false
    /// Songs you chose not to hear. They're skipped everywhere except when you tap them yourself.
    private(set) var hiddenSongs: [String: BaseItem] = LibraryStore.loadHidden()
    private(set) var playlists: [BaseItem] = []
    /// Ratings changed in this session, shown right away while the server catches up.
    private(set) var ratings: [String: Int] = [:]
    var errorMessage: String?
    @ObservationIgnored var client: JellyfinClient?

    func refresh() async {
        guard let client else { return }
        Task { await checkDeletePermission() }
        if let ids = try? await client.favoriteIds() {
            favoriteIds = ids
            hasLoadedFavorites = true
            favoritesVersion += 1
        }
        await refreshPlaylists()
    }

    func refreshPlaylists() async {
        try? await loadPlaylists()
    }

    /// Like `refreshPlaylists`, but reports failures so a screen can show them.
    func loadPlaylists() async throws {
        guard let client else { return }
        // Playlists Dial and AudioMuse generate (shared mixtapes, clustering) are not playlists of yours.
        let all = try await client.playlists().filter { !DailyMixes.isGenerated($0.name) }
        playlistFiles = all.filter(\.isPlaylistFile)
        // Playlist files from your music folders stay out of the way unless you ask for them (Settings).
        playlists = UserDefaults.standard.bool(forKey: "dial.showPlaylistFiles") ? all : all.filter { !$0.isPlaylistFile }
    }

    /// Playlists that are files in your music folders (shown in Settings, hidden from lists by default).
    private(set) var playlistFiles: [BaseItem] = []

    func reset() {
        favoriteIds = []
        playlists = []
    }

    func isFavorite(_ id: String) -> Bool { favoriteIds.contains(id) }

    func isHidden(_ id: String) -> Bool { hiddenSongs[id] != nil }

    /// Whether this account may delete files from the server (checked once after sign-in).
    private(set) var canDelete = false
    /// Items deleted in this session, so lists drop them right away.
    private(set) var deletedIds: Set<String> = []

    func checkDeletePermission() async {
        canDelete = await client?.canDelete() ?? false
    }

    /// Deletes a song or a whole album from your server, files and all. There's no undo.
    func deleteFromServer(_ item: BaseItem) async -> Bool {
        guard let client else { return false }
        do {
            try await client.delete(item.id)
            deletedIds.insert(item.id)
            favoriteIds.remove(item.id)
            hiddenSongs[item.id] = nil
            return true
        } catch {
            errorMessage = "Couldn\u{2019}t delete \u{201C}\(item.name)\u{201D}: \(error.localizedDescription)"
            return false
        }
    }

    func setHidden(_ track: BaseItem, _ hidden: Bool) {
        if hidden { hiddenSongs[track.id] = track } else { hiddenSongs[track.id] = nil }
        saveHidden()
    }

    func unhideAll() {
        hiddenSongs = [:]
        saveHidden()
    }

    private static let hiddenKey = "dial.hiddenSongs"

    private static func loadHidden() -> [String: BaseItem] {
        guard let data = UserDefaults.standard.data(forKey: hiddenKey),
              let songs = try? JSONDecoder().decode([String: BaseItem].self, from: data) else { return [:] }
        return songs
    }

    private func saveHidden() {
        if let data = try? JSONEncoder().encode(hiddenSongs) { UserDefaults.standard.set(data, forKey: Self.hiddenKey) }
    }

    /// A favorite or rating changed on another device (the server tells every open Dial).
    func applyChange(itemId: String, isFavorite: Bool?, rating: Double?) {
        if let isFavorite, isFavorite != favoriteIds.contains(itemId) {
            if isFavorite { favoriteIds.insert(itemId) } else { favoriteIds.remove(itemId) }
            favoritesVersion += 1
        }
        if let rating { ratings[itemId] = Int((rating / 2).rounded()) }
    }

    /// Your rating for an item, 0 to 5 stars.
    func rating(for item: BaseItem) -> Int {
        ratings[item.id] ?? Int(((item.userData?.rating ?? 0) / 2).rounded())
    }

    func setRating(_ stars: Int, for item: BaseItem) {
        guard let client else { return }
        let previous = rating(for: item)
        ratings[item.id] = stars
        Task {
            do {
                try await client.setRating(item.id, stars: stars)
            } catch {
                ratings[item.id] = previous
                errorMessage = "Couldn't save the rating: \(error.localizedDescription)"
            }
        }
    }

    /// Updates the heart right away, then tells the server; undoes it if the server says no.
    func toggleFavorite(_ item: BaseItem) {
        guard let client else { return }
        let makeFavorite = !favoriteIds.contains(item.id)
        if makeFavorite { favoriteIds.insert(item.id) } else { favoriteIds.remove(item.id) }
        favoritesVersion += 1
        Task {
            do {
                try await client.setFavorite(item.id, makeFavorite)
            } catch {
                if makeFavorite { favoriteIds.remove(item.id) } else { favoriteIds.insert(item.id) }
                errorMessage = "Couldn't update favorites: \(error.localizedDescription)"
            }
        }
    }

    func createPlaylist(named name: String, with tracks: [BaseItem]) async throws {
        guard let client else { return }
        try await client.createPlaylist(named: name, with: tracks.map(\.id))
        await refreshPlaylists()
    }

    func add(_ tracks: [BaseItem], to playlist: BaseItem) async throws {
        guard let client else { return }
        try await client.addToPlaylist(playlist.id, itemIds: tracks.map(\.id))
    }

    func remove(_ track: BaseItem, from playlistId: String) async throws {
        guard let client, let entryId = track.playlistItemId else { return }
        try await client.removeFromPlaylist(playlistId, entryIds: [entryId])
    }

    func renamePlaylist(_ id: String, to name: String) async throws {
        guard let client else { return }
        try await client.renamePlaylist(id, to: name)
        await JellyfinClient.clearCache()
        await refreshPlaylists()
    }

    func move(entryId: String, inPlaylist playlistId: String, to index: Int) async throws {
        guard let client else { return }
        try await client.movePlaylistItem(playlistId, entryId: entryId, to: index)
    }

    func deletePlaylist(_ playlist: BaseItem) async throws {
        guard let client else { return }
        if playlist.isPlaylistFile { throw PlaylistFileError() }
        try await client.deleteItem(playlist.id)
        playlists.removeAll { $0.id == playlist.id }
    }

    struct PlaylistFileError: LocalizedError {
        var errorDescription: String? {
            "This playlist is a file in your music folder (a .m3u that came with an album), so Jellyfin can\u{2019}t delete it. Delete the file on your server, or hide playlist files in Settings."
        }
    }
}

// MARK: - Offline downloads

/// Downloads songs for offline listening. Downloads run in a background session, so they keep
/// going when you leave Dial or lock the phone, and finish even if iOS closes the app meanwhile.
@MainActor
@Observable
final class DownloadManager {
    struct Record: Codable, Sendable {
        let item: BaseItem
        let fileName: String
        let bytes: Int64
    }

    private(set) var records: [String: Record] = [:]
    /// Songs waiting for or in the middle of downloading, in the order they were added.
    private(set) var pending: [BaseItem] = []
    /// How far each download in progress has got, 0 to 1.
    private(set) var progress: [String: Double] = [:]
    var errorMessage: String?
    @ObservationIgnored var client: JellyfinClient? {
        didSet { resumeWaiting() }
    }

    static let sessionIdentifier = "dial.downloads"
    /// Set by the app delegate when iOS wakes Dial to finish downloads in the background.
    @ObservationIgnored var backgroundCompletion: (() -> Void)?
    @ObservationIgnored private let delegate = DownloadSessionDelegate()
    @ObservationIgnored private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }()

    static let folder: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appending(path: "Downloads", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    private static var indexFile: URL { folder.appending(path: "index.json") }
    private static var pendingFile: URL { folder.appending(path: "pending.json") }

    init() {
        if let data = try? Data(contentsOf: Self.indexFile),
           let saved = try? JSONDecoder().decode([String: Record].self, from: data) {
            // Forget any records whose file has gone missing.
            records = saved.filter { FileManager.default.fileExists(atPath: Self.folder.appending(path: $0.value.fileName).path) }
        }
        if let data = try? Data(contentsOf: Self.pendingFile),
           let waiting = try? JSONDecoder().decode([BaseItem].self, from: data) {
            pending = waiting.filter { records[$0.id] == nil }
        }
        delegate.manager = self
        _ = session // reconnects to downloads that continued while Dial was closed
    }

    var isWorking: Bool { !pending.isEmpty }
    var totalBytes: Int64 { records.values.reduce(0) { $0 + $1.bytes } }

    /// Downloaded songs, grouped the way they appear on their albums.
    var downloadedSongs: [BaseItem] {
        records.values.map(\.item).sorted {
            let a = ($0.albumArtistLine, $0.album ?? "", $0.parentIndexNumber ?? 0, $0.indexNumber ?? 0)
            let b = ($1.albumArtistLine, $1.album ?? "", $1.parentIndexNumber ?? 0, $1.indexNumber ?? 0)
            return a < b
        }
    }

    func isDownloaded(_ id: String) -> Bool { records[id] != nil }

    func isDownloading(_ id: String) -> Bool { pending.contains { $0.id == id } }

    func localURL(for id: String) -> URL? {
        guard let record = records[id] else { return nil }
        return Self.folder.appending(path: record.fileName)
    }

    func download(_ tracks: [BaseItem]) {
        let new = tracks.filter { $0.isSong && !isDownloaded($0.id) && !isDownloading($0.id) }
        guard !new.isEmpty else { return }
        pending.append(contentsOf: new)
        savePending()
        for track in new { start(track) }
    }

    func delete(_ id: String) {
        if let index = pending.firstIndex(where: { $0.id == id }) {
            pending.remove(at: index)
            cancelTask(for: id)
            savePending()
        }
        guard let record = records.removeValue(forKey: id) else { return }
        try? FileManager.default.removeItem(at: Self.folder.appending(path: record.fileName))
        saveIndex()
    }

    func delete(_ tracks: [BaseItem]) {
        for track in tracks { delete(track.id) }
    }

    func deleteAll() {
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        pending.removeAll()
        progress.removeAll()
        savePending()
        for id in Array(records.keys) { delete(id) }
    }

    // MARK: Background session

    private func start(_ track: BaseItem) {
        guard let client, let url = client.downloadURL(for: track.id) else { return }
        var request = URLRequest(url: url)
        request.setValue(JellyfinClient.authHeader(token: client.token), forHTTPHeaderField: "Authorization")
        let task = session.downloadTask(with: request)
        task.taskDescription = track.id
        task.resume()
        warmArtwork(for: track)
    }

    /// After a relaunch: restart any waiting song that has no download running.
    private func resumeWaiting() {
        guard client != nil, !pending.isEmpty else { return }
        session.getAllTasks { [weak self] tasks in
            let running = Set(tasks.compactMap(\.taskDescription))
            Task { @MainActor in
                guard let self else { return }
                for track in self.pending where !running.contains(track.id) { self.start(track) }
            }
        }
    }

    private func cancelTask(for id: String) {
        session.getAllTasks { tasks in tasks.filter { $0.taskDescription == id }.forEach { $0.cancel() } }
    }

    /// Saves the cover in the image cache too, so downloaded music shows its artwork offline.
    private func warmArtwork(for track: BaseItem) {
        guard let client else { return }
        // The large size into Dial's own image cache; smaller sizes are made from it, so one download covers all.
        guard let url = client.imageURL(for: track.imageItemId, size: Theme.Pixels.hero) else { return }
        Task { _ = await ImagePipeline.shared.image(for: url) }
    }

    fileprivate func finished(id: String, fileName: String?, bytes: Int64, error: String?) {
        progress[id] = nil
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let track = pending.remove(at: index)
        savePending()
        if let fileName {
            records[id] = Record(item: track, fileName: fileName, bytes: bytes)
            saveIndex()
        } else if let error {
            errorMessage = "Couldn't download \u{201C}\(track.name)\u{201D}: \(error)"
        }
    }

    fileprivate func updateProgress(id: String, fraction: Double) {
        progress[id] = fraction
    }

    fileprivate func allEventsDelivered() {
        backgroundCompletion?()
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: Self.indexFile, options: .atomic)
    }

    private func savePending() {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? data.write(to: Self.pendingFile, options: .atomic)
    }

    nonisolated static func fileExtension(for mimeType: String?) -> String? {
        switch (mimeType ?? "").lowercased() {
        case "audio/flac", "audio/x-flac": return "flac"
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/x-m4a", "audio/m4a": return "m4a"
        case "audio/aac", "audio/aacp": return "aac"
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        case "audio/aiff", "audio/x-aiff": return "aiff"
        default: return nil
        }
    }
}

/// Receives the background session's callbacks. The file has to be moved before the
/// callback returns (iOS deletes it right after), so that part happens here, off the main thread.
private final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var manager: DownloadManager?

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            report(id: id, fileName: nil, bytes: 0, error: "the server returned error \(status).")
            return
        }
        guard let ext = DownloadManager.fileExtension(for: downloadTask.response?.mimeType) else {
            report(id: id, fileName: nil, bytes: 0, error: "it's in a format that can't play offline.")
            return
        }
        let fileName = "\(id).\(ext)"
        let destination = DownloadManager.folder.appending(path: fileName)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? NSNumber)?.int64Value ?? 0
            report(id: id, fileName: fileName, bytes: bytes, error: nil)
        } catch {
            report(id: id, fileName: nil, bytes: 0, error: error.localizedDescription)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        if (error as? URLError)?.code == .cancelled { return }
        report(id: id, fileName: nil, bytes: 0, error: error.localizedDescription)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor [weak manager] in manager?.updateProgress(id: id, fraction: fraction) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak manager] in manager?.allEventsDelivered() }
    }

    private func report(id: String, fileName: String?, bytes: Int64, error: String?) {
        Task { @MainActor [weak manager] in manager?.finished(id: id, fileName: fileName, bytes: bytes, error: error) }
    }
}

// MARK: - Saved and recently played stations

/// Anything that plays like a station: the DJ, a live internet station, or a radio from your library.
enum RecentStation: Codable, Hashable, Identifiable, Sendable {
    case dj
    case live(Station)
    case yourMix
    case favoritesMix
    case artist(id: String, name: String)
    case genre(id: String, name: String)
    /// A mood station found by sound (AudioMuse).
    case mood(id: String)
    /// Songs that match the sound of what you play most (AudioMuse).
    case yourSound

    var id: String {
        switch self {
        case .dj: return "dj"
        case .live(let station): return "live-\(station.id)"
        case .yourMix: return "mix"
        case .favoritesMix: return "favorites-mix"
        case .artist(let id, _): return "artist-\(id)"
        case .genre(let id, _): return "genre-\(id)"
        case .mood(let id): return "mood-\(id)"
        case .yourSound: return "your-sound"
        }
    }
}

@MainActor
@Observable
final class StationStore {
    private(set) var saved: [Station] = []
    /// Most recent first. The DJ is always listed first on Home, played or not.
    private(set) var recent: [RecentStation] = []

    init() {
        saved = Self.load([Station].self, "dial.savedStations") ?? []
        recent = Self.load([RecentStation].self, "dial.recentStations.v2")
            ?? (Self.load([Station].self, "dial.recentStations") ?? []).map { .live($0) }
    }

    var recentLive: [Station] {
        recent.compactMap { if case .live(let station) = $0 { return station } else { return nil } }
    }

    func isSaved(_ station: Station) -> Bool { saved.contains { $0.id == station.id } }

    func toggleSaved(_ station: Station) {
        if isSaved(station) {
            saved.removeAll { $0.id == station.id }
        } else {
            saved.insert(station, at: 0)
        }
        Self.store(saved, "dial.savedStations")
    }

    func markPlayed(_ station: Station) {
        markPlayed(.live(station))
    }

    func markPlayed(_ station: RecentStation) {
        recent.removeAll { $0.id == station.id }
        recent.insert(station, at: 0)
        recent = Array(recent.prefix(16))
        Self.store(recent, "dial.recentStations.v2")
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func store<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
