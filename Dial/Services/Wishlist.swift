import Foundation
import Observation

/// Something you want but don't have yet: an album, or a song (with the album it is on).
struct WishItem: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case album, song }
    let id: String
    let kind: Kind
    let title: String
    let artist: String
    /// For songs: the album it is on.
    var album: String? = nil
    /// The album to open: a MusicBrainz release group id, or a Deezer ("dz-…") or iTunes ("it-…") id.
    var sourceId: String? = nil
    var cover: URL? = nil
    /// When it was added, "2026-11-22T13:25:00Z".
    var added: String = ISO8601DateFormatter().string(from: Date())

    /// The cover: the one saved with it, or MusicBrainz's cover for its album.
    var coverURL: URL? {
        if let cover { return cover }
        guard let sourceId, !sourceId.hasPrefix("dz-"), !sourceId.hasPrefix("it-") else { return nil }
        return PublicMusic.Release(id: sourceId, title: title, year: nil, kind: .album).coverURL
    }

    /// The same album or song always gets the same id, wherever it was found, so it is never on the list twice.
    static func id(_ kind: Kind, artist: String, title: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV-1a
        for byte in (ArtistNames.key(artist) + "|" + ArtistNames.key(title)).utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return "\(kind.rawValue)-\(String(hash, radix: 16))"
    }

    static func album(artist: String, title: String, sourceId: String? = nil, cover: URL? = nil) -> WishItem {
        WishItem(id: id(.album, artist: artist, title: title), kind: .album, title: title, artist: artist,
                 sourceId: sourceId.flatMap { $0.isEmpty ? nil : $0 }, cover: cover)
    }

    static func song(artist: String, title: String, album: String? = nil, albumSourceId: String? = nil, cover: URL? = nil) -> WishItem {
        WishItem(id: id(.song, artist: artist, title: title), kind: .song, title: title, artist: artist, album: album,
                 sourceId: albumSourceId.flatMap { $0.isEmpty ? nil : $0 }, cover: cover)
    }
}

/// Your wishlist, kept by the Dial plugin so every device shows the same one. A copy is saved on the device, so the list
/// shows at once; changes show at once too, and go back if the server says no.
@MainActor
@Observable
final class WishlistStore {
    private static let key = "dial.wishlist"
    private(set) var items: [WishItem] = UserDefaults.standard.data(forKey: WishlistStore.key)
        .flatMap { try? JSONDecoder().decode([WishItem].self, from: $0) } ?? []

    func contains(_ id: String) -> Bool { items.contains { $0.id == id } }

    func refresh(client: JellyfinClient?) async {
        guard let client, let fresh = await client.dialWishlist() else { return }
        set(fresh)
    }

    func toggle(_ item: WishItem, client: JellyfinClient?) async {
        if contains(item.id) { await remove(item.id, client: client) } else { await add(item, client: client) }
    }

    func add(_ item: WishItem, client: JellyfinClient?) async {
        guard let client, !contains(item.id) else { return }
        let before = items
        set([item] + items)
        if let fresh = await client.dialWishlistAdd(item) { set(fresh) } else { set(before) }
    }

    func remove(_ id: String, client: JellyfinClient?) async {
        guard let client else { return }
        let before = items
        set(items.filter { $0.id != id })
        if let fresh = await client.dialWishlistRemove(id) { set(fresh) } else { set(before) }
    }

    private func set(_ list: [WishItem]) {
        items = list
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: Self.key)
    }
}

extension JellyfinClient {
    /// The wishlist the plugin keeps for this user (nil when the plugin can't be reached).
    func dialWishlist() async -> [WishItem]? {
        guard let data = try? await request("GET", "Dial/Wishlist") else { return nil }
        return Self.wishItems(data)
    }

    func dialWishlistAdd(_ item: WishItem) async -> [WishItem]? {
        guard let body = try? JSONEncoder().encode(item),
              let data = try? await request("POST", "Dial/Wishlist", body: body) else { return nil }
        return Self.wishItems(data)
    }

    func dialWishlistRemove(_ id: String) async -> [WishItem]? {
        guard let data = try? await request("DELETE", "Dial/Wishlist/\(id)") else { return nil }
        return Self.wishItems(data)
    }

    /// Items another version of the app wrote in a shape this one can't read are skipped, not the whole list.
    private static func wishItems(_ data: Data) -> [WishItem]? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        return raw.compactMap { element in
            (try? JSONSerialization.data(withJSONObject: element)).flatMap { try? JSONDecoder().decode(WishItem.self, from: $0) }
        }
    }
}
