import Foundation
import Observation

/// Songs you played without a connection to your server, kept until it can be told. Without this they would be lost: Jellyfin never
/// heard of them, so play counts, "last played" and everything built on them (On Repeat, the daily mixes) would miss them.
/// Back online, each one is sent as played, with the date it was really played.
@MainActor
@Observable
final class PlayLog {
    struct Entry: Codable, Hashable {
        let itemId: String
        let at: Date
        let seconds: Double
        let duration: Double
    }

    private(set) var entries: [Entry]
    @ObservationIgnored private var flushing = false
    private static let key = "dial.playlog.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        } else {
            entries = []
        }
    }

    var pending: Int { entries.count }

    /// A play counts when most of the song was heard (half of it, or at least 30 seconds); skips do not.
    static func counts(seconds: Double, duration: Double) -> Bool {
        seconds >= 30 || (duration > 0 && seconds / duration >= 0.5)
    }

    func record(itemId: String, at: Date, seconds: Double, duration: Double) {
        guard Self.counts(seconds: seconds, duration: duration) else { return }
        entries.append(Entry(itemId: itemId, at: at, seconds: seconds, duration: duration))
        save()
    }

    /// Tells the server about every saved play, oldest first; what could not be sent stays for next time.
    func flush(client: JellyfinClient) async {
        guard !flushing, !entries.isEmpty else { return }
        flushing = true
        defer { flushing = false }
        let formatter = ISO8601DateFormatter()
        for entry in entries.sorted(by: { $0.at < $1.at }) {
            do {
                _ = try await client.request("POST", "UserPlayedItems/\(entry.itemId)",
                                             query: ["userId": client.userId, "datePlayed": formatter.string(from: entry.at)])
            } catch {
                // The server is gone again (stop and retry later), or the song no longer exists (drop it).
                if (error as? URLError) != nil { break }
            }
            entries.removeAll { $0 == entry }
            save()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
