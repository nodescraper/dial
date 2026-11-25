import Foundation

/// The last version of each screen's content, saved on the phone. Screens show it instantly
/// on the next launch and refresh it in the background, so nothing starts out empty.
enum Snapshots {
    private static let folder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folder = caches.appending(path: "Snapshots", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    private static func file(_ key: String) -> URL {
        folder.appending(path: key.replacingOccurrences(of: "/", with: "-") + ".json")
    }

    /// Values already read or saved, so the same snapshot is never read and decoded twice.
    private actor Memory {
        private var values: [String: any Sendable] = [:]
        func value(_ key: String) -> (any Sendable)? { values[key] }
        func set(_ value: any Sendable, _ key: String) {
            if values.count > 400 { values.removeAll() } // a simple cap; everything is on disk anyway
            values[key] = value
        }
        func clear() { values.removeAll() }
    }
    private static let memory = Memory()

    /// The same values, readable at once (no await), so a screen can start out with what it showed last time
    /// instead of drawing empty and then jumping when the saved copy arrives.
    private final class Mirror: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: any Sendable] = [:]
        func get(_ key: String) -> (any Sendable)? { lock.lock(); defer { lock.unlock() }; return values[key] }
        func set(_ value: any Sendable, _ key: String) {
            lock.lock(); defer { lock.unlock() }
            if values.count > 400 { values.removeAll() }
            values[key] = value
        }
        func clear() { lock.lock(); defer { lock.unlock() }; values.removeAll() }
    }
    private static let mirror = Mirror()

    /// A snapshot that is already in memory (nil if it hasn't been read or saved since launch).
    static func peek<T: Sendable>(_ type: T.Type, _ key: String) -> T? { mirror.get(key) as? T }

    /// Reads a saved snapshot: from memory when it's been read before, otherwise from disk off the main thread.
    static func load<T: Decodable & Sendable>(_ type: T.Type, _ key: String) async -> T? {
        if let value = mirror.get(key) as? T { return value }
        if let value = await memory.value(key) as? T { return value }
        let url = file(key)
        let value = await Task.detached(priority: .userInitiated) { () -> T? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }.value
        if let value { mirror.set(value, key); await memory.set(value, key) }
        return value
    }

    /// Saves a snapshot (in memory right away, on disk off the main thread).
    static func save<T: Encodable & Sendable>(_ value: T, _ key: String) {
        let url = file(key)
        mirror.set(value, key)
        Task.detached(priority: .utility) {
            await memory.set(value, key)
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Forgets one snapshot, or every snapshot whose key starts with `prefix`.
    static func remove(_ key: String) { remove(prefix: key, exact: true) }

    static func remove(prefix: String, exact: Bool = false) {
        mirror.clear()
        Task { await memory.clear() }
        let name = prefix.replacingOccurrences(of: "/", with: "-")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in files {
            let base = url.deletingPathExtension().lastPathComponent
            if exact ? base == name : base.hasPrefix(name) { try? FileManager.default.removeItem(at: url) }
        }
    }

    static func clear() {
        mirror.clear()
        Task { await memory.clear() }
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
}
