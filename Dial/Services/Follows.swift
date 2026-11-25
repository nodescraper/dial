import Foundation
import Observation
import UserNotifications

/// An album you asked to be told about on its release day (the bell).
struct FollowedRelease: Codable, Identifiable, Hashable, Sendable {
    let id: String          // MusicBrainz release group id
    let title: String
    let artist: String
    let artistMbid: String?
    let date: String        // "2026-11-28"
}

/// An artist you follow: any new release of theirs is announced.
struct FollowedArtist: Codable, Identifiable, Hashable, Sendable {
    let id: String          // MusicBrainz artist id
    let name: String
}

/// The bells and followed artists behind Discovery, and the notifications that go with them. Notifications are local: each
/// is scheduled on the device for the morning of the release, and renewed whenever Discovery refreshes.
@MainActor
@Observable
final class FollowStore {
    private(set) var releases: [FollowedRelease] = FollowStore.read("dial.follow.releases")
    private(set) var artists: [FollowedArtist] = FollowStore.read("dial.follow.artists")
    /// The system said no to notifications: bells still work as a list, but nothing is delivered.
    private(set) var notificationsDenied = false
    private var announced: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "dial.follow.announced") ?? [])

    private static func read<T: Decodable>(_ key: String) -> [T] {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([T].self, from: $0) } ?? []
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(releases), forKey: "dial.follow.releases")
        UserDefaults.standard.set(try? JSONEncoder().encode(artists), forKey: "dial.follow.artists")
        UserDefaults.standard.set(Array(announced.suffix(300)), forKey: "dial.follow.announced")
    }

    func isBelled(_ id: String) -> Bool { releases.contains { $0.id == id } }
    func isFollowing(_ artistMbid: String?) -> Bool { artistMbid.map { id in artists.contains { $0.id == id } } ?? false }

    // MARK: Changing

    func toggleBell(_ pick: PublicMusic.Pick) async {
        if isBelled(pick.mbid) {
            releases.removeAll { $0.id == pick.mbid }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["rel-\(pick.mbid)"])
        } else if let date = pick.releaseDate, date.count >= 10 {
            releases.append(FollowedRelease(id: pick.mbid, title: pick.title, artist: pick.artist ?? "", artistMbid: pick.artistMbid,
                                            date: String(date.prefix(10))))
            _ = await askPermission()
            await schedule(releases.last!)
        }
        save()
    }

    func toggleFollow(artistMbid: String?, name: String) async {
        guard let artistMbid else { return }
        if isFollowing(artistMbid) {
            artists.removeAll { $0.id == artistMbid }
        } else {
            artists.append(FollowedArtist(id: artistMbid, name: name))
            _ = await askPermission()
        }
        save()
    }

    func remove(release id: String) {
        releases.removeAll { $0.id == id }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["rel-\(id)"])
        save()
    }

    func remove(artist id: String) {
        artists.removeAll { $0.id == id }
        save()
    }

    // MARK: Notifications

    private func askPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            notificationsDenied = !granted
            return granted
        }
        notificationsDenied = settings.authorizationStatus == .denied
        return settings.authorizationStatus != .denied
    }

    private static func day(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(text.prefix(10)))
    }

    /// A notification at nine in the morning on the day it comes out.
    private func schedule(id: String, artist: String, title: String, date: String) async {
        guard let day = Self.day(date) else { return }
        var parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
        parts.hour = 9
        guard let fire = Calendar.current.date(from: parts), fire > Date().addingTimeInterval(60) else { return }
        let content = UNMutableNotificationContent()
        content.title = artist.isEmpty ? "Out today" : "New from \(artist)"
        content.body = "\(title) is out today."
        content.sound = .default
        content.userInfo = ["dial": "discovery"]
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    private func schedule(_ release: FollowedRelease) async {
        await schedule(id: "rel-\(release.id)", artist: release.artist, title: release.title, date: release.date)
    }

    /// Called after Discovery refreshes: keeps every notification in step with the newest release dates (they move), schedules
    /// the upcoming releases of followed artists, and announces a followed artist's release that came out in the last two days.
    func reconcile(feed: DiscoveryFeed) async {
        guard !releases.isEmpty || !artists.isEmpty else { return }
        let followed = Set(artists.map(\.id))
        // The feed covers your top artists; anyone else you follow is looked up on their own (saved for three days).
        var upcoming = feed.upcoming
        var fresh = feed.fresh
        let covered = Set(feed.artists.map(\.mbid))
        for artist in artists where !covered.contains(artist.id) {
            for release in await PublicMusic.discography(artistMBID: artist.id, maxAge: 3 * 24 * 3600) {
                guard [.album, .ep, .single].contains(release.kind), let date = release.date, date.count >= 10,
                      let day = Self.day(date) else { continue }
                let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: day).day ?? 0
                let pick = PublicMusic.Pick(kind: .album, mbid: release.id, title: release.title, artist: artist.name, artistMbid: artist.id,
                                            year: release.year, tags: [], releaseDate: date)
                if (0...200).contains(days) { upcoming.append(pick) } else if (-2 ... -1).contains(days) { fresh.append(pick) }
            }
        }
        // A bell follows its album's date if MusicBrainz moved it.
        let dates = Dictionary((upcoming + fresh).compactMap { pick in pick.releaseDate.map { (pick.mbid, String($0.prefix(10))) } },
                               uniquingKeysWith: { first, _ in first })
        for index in releases.indices {
            if let moved = dates[releases[index].id], moved != releases[index].date, moved.count == 10 {
                let old = releases[index]
                releases[index] = FollowedRelease(id: old.id, title: old.title, artist: old.artist, artistMbid: old.artistMbid, date: moved)
            }
            await schedule(releases[index])
        }
        for pick in upcoming where pick.artistMbid.map(followed.contains) == true {
            await schedule(id: "rel-\(pick.mbid)", artist: pick.artist ?? "", title: pick.title, date: pick.releaseDate ?? "")
        }
        let center = UNUserNotificationCenter.current()
        for pick in fresh where pick.artistMbid.map(followed.contains) == true && !announced.contains(pick.mbid) {
            guard let date = pick.releaseDate.flatMap(Self.day), Date().timeIntervalSince(date) < 2 * 86400 else { continue }
            announced.insert(pick.mbid)
            let content = UNMutableNotificationContent()
            content.title = "New from \(pick.artist ?? "an artist you follow")"
            content.body = "\(pick.title) is out."
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: "new-\(pick.mbid)", content: content,
                                                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)))
        }
        save()
    }
}
