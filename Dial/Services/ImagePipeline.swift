import CryptoKit
import SwiftUI
import UIKit

/// Loads cover art once, keeps it in memory, and retries if a load fails.
///
/// SwiftUI's AsyncImage cancels its download when a view scrolls in and out of a lazy
/// stack (like the Home carousel) and then shows nothing. Here loads keep running even
/// if the view that asked goes away, so the next view that needs the image gets it instantly.
@MainActor
final class ImagePipeline {
    static let shared = ImagePipeline()

    private let memory = NSCache<NSURL, UIImage>()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]
    /// When the server can't be reached, only covers saved on the phone are shown.
    var isOffline = false

    /// Covers are also kept on disk (up to about 400 MB), so they show instantly after a
    /// relaunch and offline.
    private static let folder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folder = caches.appending(path: "Artwork", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    private init() {
        // About 150 MB of decoded images at most; older ones are dropped first.
        memory.totalCostLimit = 150 * 1024 * 1024
        Task.detached(priority: .background) { Self.trimDisk(to: 400 * 1024 * 1024) }
    }

    nonisolated private static func file(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appending(path: digest)
    }

    /// Removes the least recently saved covers when the disk cache grows too big.
    nonisolated private static func trimDisk(to limit: Int) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { file -> (URL, Int, Date)? in
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > limit else { return }
        entries.sort { $0.2 < $1.2 }
        for entry in entries where total > limit * 3 / 4 {
            try? FileManager.default.removeItem(at: entry.0)
            total -= entry.1
        }
    }

    /// How much the saved covers take on disk, for Settings.
    nonisolated static func diskBytes() async -> Int64 {
        await Task.detached(priority: .utility) {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }.value
    }

    /// Removes the saved covers (they download again as needed).
    func clearDisk() {
        memory.removeAllObjects()
        largest = [:]
        try? FileManager.default.removeItem(at: Self.folder)
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
    }

    func cached(_ url: URL) -> UIImage? {
        if let image = memory.object(forKey: url as NSURL) { return image }
        // A bigger copy of the same picture already in memory does just as well.
        if let bigger = largerCopy(of: url) { return memory.object(forKey: bigger as NSURL) }
        return nil
    }

    // MARK: One picture, many sizes

    /// The biggest copy saved of each picture (the same cover asked for at 160 and 400 pixels is one picture).
    private var largest: [String: (width: Int, url: URL)] = ImagePipeline.loadFamilies()
    private var savingFamilies: Task<Void, Never>?

    /// "This cover, without its size", and the size asked for. Only for Jellyfin's resizable images.
    nonisolated private static func family(of url: URL) -> (key: String, width: Int)? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = parts.queryItems else { return nil }
        let sizeNames: Set<String> = ["fillWidth", "fillHeight", "maxWidth", "maxHeight", "width", "height"]
        guard let width = items.first(where: { ["fillWidth", "maxWidth", "width"].contains($0.name) })?.value.flatMap(Int.init) else { return nil }
        let cropped = items.contains { $0.name == "fillWidth" } // square crops and full pictures aren't interchangeable
        parts.queryItems = items.filter { !sizeNames.contains($0.name) }.sorted { $0.name < $1.name }
        return ((parts.url?.absoluteString ?? url.absoluteString) + (cropped ? "#fill" : "#max"), width)
    }

    private func largerCopy(of url: URL) -> URL? {
        guard let family = Self.family(of: url), let best = largest[family.key], best.width >= family.width, best.url != url else { return nil }
        return best.url
    }

    private func remember(_ url: URL) {
        guard let family = Self.family(of: url) else { return }
        if let best = largest[family.key], best.width >= family.width { return }
        largest[family.key] = (family.width, url)
        savingFamilies?.cancel()
        let snapshot = largest.mapValues { [String($0.width), $0.url.absoluteString] }
        savingFamilies = Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: Self.familiesFile, options: .atomic)
        }
    }

    nonisolated private static var familiesFile: URL { folder.appending(path: "sizes.json") }

    nonisolated private static func loadFamilies() -> [String: (width: Int, url: URL)] {
        guard let data = try? Data(contentsOf: familiesFile),
              let saved = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return saved.compactMapValues { pair in
            guard pair.count == 2, let width = Int(pair[0]), let url = URL(string: pair[1]) else { return nil }
            return (width, url)
        }
    }

    /// The cover, and when it is a Cover Art Archive link that has no picture, the same album's cover from another source.
    func image(for requested: URL) async -> UIImage? {
        if let image = await primary(requested) { return image }
        guard requested.host == "coverartarchive.org", !isOffline,
              let id = Self.releaseGroupID(in: requested),
              let alternative = await PublicMusic.alternativeCover(releaseGroupId: id),
              let image = await primary(alternative) else { return nil }
        // Remembered under the original link too, so the next ask is instant.
        memory.setObject(image, forKey: requested as NSURL, cost: image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0)
        return image
    }

    /// "release-group/<id>/front-500" gives the id.
    nonisolated private static func releaseGroupID(in url: URL) -> String? {
        let parts = url.pathComponents
        guard let index = parts.firstIndex(of: "release-group"), parts.count > index + 1 else { return nil }
        return parts[index + 1]
    }

    private func primary(_ requested: URL) async -> UIImage? {
        if let image = cached(requested) { return image }
        // Already have this picture at the same size or bigger (in memory or on disk): use that one.
        let url = largerCopy(of: requested) ?? requested
        if let running = inFlight[url] { return await running.value }

        let offline = isOffline
        let task = Task<UIImage?, Never> {
            let saved = Self.file(for: url)
            // From disk first.
            if let data = await Task.detached(priority: .userInitiated, operation: { try? Data(contentsOf: saved) }).value,
               let image = UIImage(data: data) {
                return await image.byPreparingForDisplay() ?? image
            }
            guard !offline else { return nil }
            for attempt in 0..<3 {
                if let result = try? await Network.session.data(from: url) {
                    let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 200
                    // The server doesn't have this picture (common for artist backdrops): don't retry.
                    if (400..<500).contains(status) { return nil }
                    if (200..<300).contains(status), let image = UIImage(data: result.0) {
                        let data = result.0
                        Task.detached(priority: .utility) { try? data.write(to: saved, options: .atomic) }
                        // Decode now rather than while scrolling.
                        return await image.byPreparingForDisplay() ?? image
                    }
                }
                try? await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
            }
            return nil
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image {
            let bytes = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            memory.setObject(image, forKey: url as NSURL, cost: bytes)
            remember(url)
        } else if url != requested {
            // The bigger copy wasn't there after all (trimmed from disk): fetch what was asked for.
            largest[Self.family(of: requested)?.key ?? ""] = nil
            return await self.primary(requested)
        }
        return image
    }
}

/// An image from a URL, with any placeholder while it loads (or if it can't).
struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    let placeholder: Placeholder
    @State private var image: UIImage?
    @State private var loading = false

    init(url: URL?, contentMode: ContentMode = .fill, @ViewBuilder placeholder: () -> Placeholder) {
        self.url = url
        self.contentMode = contentMode
        self.placeholder = placeholder()
        // Show a cached image immediately instead of flashing the placeholder.
        _image = State(initialValue: url.flatMap { ImagePipeline.shared.cached($0) })
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder.shimmering(loading)
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            if let cached = ImagePipeline.shared.cached(url) {
                image = cached
                return
            }
            loading = true
            let loaded = await ImagePipeline.shared.image(for: url)
            loading = false
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
        .accessibilityHidden(true)
    }
}
