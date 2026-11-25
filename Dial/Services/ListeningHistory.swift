import Foundation
import Observation

/// Your listening history from Jellyfin's Playback Reporting plugin: every play with its date.
/// It lets the DJ know what you've had on repeat this week, not just what you've played most ever.
/// Without the plugin, the DJ estimates from Jellyfin's play counts and last-played dates.
@MainActor
@Observable
final class ListeningHistory {
    private(set) var isAvailable = false
    private(set) var hasChecked = false
    /// Plays recorded for you, shown in Settings.
    private(set) var totalPlays = 0

    @ObservationIgnored var client: JellyfinClient? {
        didSet {
            isAvailable = false
            hasChecked = false
            Task { await check() }
        }
    }

    func check() async {
        defer { hasChecked = true }
        guard let rows = await query("SELECT COUNT(*) FROM PlaybackActivity WHERE \(userClause)") else {
            isAvailable = false
            return
        }
        isAvailable = true
        totalPlays = Int(rows.first?.first ?? "") ?? 0
    }

    /// Your most played songs over the last days, most played first.
    func topSongs(days: Int, limit: Int = 40) async -> [(id: String, plays: Int)] {
        guard isAvailable else { return [] }
        let sql = """
            SELECT ItemId, COUNT(*) AS Plays FROM PlaybackActivity
            WHERE \(userClause) AND ItemType = 'Audio' AND DateCreated >= DATETIME('now', 'localtime', '-\(days) days')
            GROUP BY ItemId ORDER BY Plays DESC LIMIT \(limit)
            """
        return (await query(sql) ?? []).compactMap { row in
            guard row.count >= 2, let plays = Int(row[1]) else { return nil }
            return (Self.plainId(row[0]), plays)
        }
    }

    /// Songs played in the last hours, so the DJ doesn't repeat them.
    func recentlyPlayed(hours: Int) async -> Set<String> {
        guard isAvailable else { return [] }
        let sql = """
            SELECT DISTINCT ItemId FROM PlaybackActivity
            WHERE \(userClause) AND ItemType = 'Audio' AND DateCreated >= DATETIME('now', 'localtime', '-\(hours) hours')
            """
        return Set((await query(sql) ?? []).compactMap { $0.first.map(Self.plainId) })
    }

    /// Any read-only question about your plays. Write `{user}` where your plays should be selected, for example
    /// `SELECT COUNT(*) FROM PlaybackActivity WHERE {user} AND ItemType = 'Audio'`.
    func rows(_ sql: String) async -> [[String]] {
        guard isAvailable else { return [] }
        return await query(sql.replacingOccurrences(of: "{user}", with: userClause)) ?? []
    }

    // MARK: Plumbing

    private var userClause: String {
        let id = (client?.userId ?? "").lowercased().replacingOccurrences(of: "-", with: "").filter(\.isHexDigit)
        return "LOWER(REPLACE(UserId, '-', '')) = '\(id)'"
    }

    private static func plainId(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private struct Response: Decodable {
        let results: [[String]]?
    }

    /// Runs a read-only query on the plugin's database. Values come back as text.
    private func query(_ sql: String) async -> [[String]]? {
        guard let client,
              let body = try? JSONSerialization.data(withJSONObject: ["CustomQueryString": sql, "ReplaceUserId": false]),
              let data = try? await client.request("POST", "user_usage_stats/submit_custom_query", body: body) else { return nil }
        // Numbers may come back as numbers or text; read both.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["results"] as? [[Any]] else { return nil }
        return rows.map { $0.map { "\($0)" } }
    }
}
