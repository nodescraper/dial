import SwiftUI

/// The three parts of Discovery.
enum DiscoveryTab: String, CaseIterable, Identifiable {
    case forYou = "For You", calendar = "Calendar", following = "Following"
    var id: String { rawValue }
}

// MARK: - Dates

enum ReleaseDates {
    static func date(_ pick: PublicMusic.Pick) -> Date? {
        guard let text = pick.releaseDate, text.count >= 10 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(text.prefix(10)))
    }

    /// "Fri 14 Nov"
    static func chip(_ date: Date) -> String { date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) }

    static func days(from date: Date) -> Int {
        Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: Calendar.current.startOfDay(for: date)).day ?? 0
    }

    /// "Out today", "Out 3 days ago", "Tomorrow", "In 12 days"
    static func relative(_ date: Date) -> String {
        let d = days(from: date)
        switch d {
        case 0: return "Out today"
        case 1: return "Tomorrow"
        case 2...: return "In \(d) days"
        case -1: return "Out yesterday"
        case -13 ... -2: return "Out \(-d) days ago"
        default: return "Out " + date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}

// MARK: - Spotify

enum SpotifyLink {
    /// The album's own Spotify page when MusicBrainz knows it, else a Spotify search for it (which always works).
    static func url(for pick: PublicMusic.Pick) async -> URL {
        if let known = await PublicMusic.spotifyAlbumURL(releaseGroupId: pick.mbid) { return known }
        let term = "\(pick.artist ?? "") \(pick.title)".trimmingCharacters(in: .whitespaces)
        let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? term
        return URL(string: "https://open.spotify.com/search/\(encoded)")!
    }
}

// MARK: - Small components

/// "Fri 14 Nov" on a frosted chip, for covers.
struct DateChip: View {
    let text: String
    var tint: Color? = nil

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(tint?.opacity(0.9) ?? Color.black.opacity(0.55), in: Capsule())
            .foregroundStyle(.white)
    }
}

/// The bell on a release: tell me when it is out.
struct BellButton: View {
    let pick: PublicMusic.Pick
    @Environment(AppModel.self) private var app

    var body: some View {
        let on = app.follows.isBelled(pick.mbid)
        Button {
            Task { await app.follows.toggleBell(pick) }
        } label: {
            Image(systemName: on ? "bell.fill" : "bell")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(on ? Color.dial : .white)
                .frame(width: 28, height: 28)
                .background(.black.opacity(0.45), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "Stop telling me when \(pick.title) is out" : "Tell me when \(pick.title) is out")
    }
}

/// The menu every release shares: Spotify, the bell and following the artist.
struct ReleaseMenu: View {
    let pick: PublicMusic.Pick
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            Task { openURL(await SpotifyLink.url(for: pick)) }
        } label: { Label("Open in Spotify", systemImage: "arrow.up.right.square") }
        WishlistButton(item: .album(artist: pick.artist ?? "", title: pick.title, sourceId: pick.release.id, cover: pick.cover))
        if let date = ReleaseDates.date(pick), ReleaseDates.days(from: date) >= 0 {
            Button {
                Task { await app.follows.toggleBell(pick) }
            } label: {
                Label(app.follows.isBelled(pick.mbid) ? "Remove Reminder" : "Remind Me on Release Day",
                      systemImage: app.follows.isBelled(pick.mbid) ? "bell.slash" : "bell")
            }
        }
        if pick.artistMbid != nil {
            Button {
                Task { await app.follows.toggleFollow(artistMbid: pick.artistMbid, name: pick.artist ?? "") }
            } label: {
                Label(app.follows.isFollowing(pick.artistMbid) ? "Unfollow \(pick.artist ?? "Artist")" : "Follow \(pick.artist ?? "Artist")",
                      systemImage: app.follows.isFollowing(pick.artistMbid) ? "person.badge.minus" : "person.badge.plus")
            }
        }
    }
}

/// A release as a tile, like Recently Added on Home: the cover with its date and, when it is not out yet, a bell. Press and hold
/// (right-click on Mac) for Spotify, a release-day reminder and following the artist.
struct DiscoveryReleaseTile: View {
    let pick: PublicMusic.Pick
    let ownedArtist: OwnershipIndex.Ref?
    var width: CGFloat = Theme.Size.shelfTile
    @Environment(AppModel.self) private var app

    private var date: Date? { ReleaseDates.date(pick) }
    private var upcoming: Bool { date.map { ReleaseDates.days(from: $0) > 0 } ?? false }

    var body: some View {
        NavigationLink(value: Route.publicAlbum(pick.release, artist: pick.artist ?? "", artistId: ownedArtist?.id)) {
            MediaTile(title: pick.title, subtitle: pick.artist, width: width) {
                RemoteImage(url: pick.cover) { ArtworkPlaceholder(symbol: "music.note") }
                    .overlay(alignment: .bottomLeading) {
                        if let date { DateChip(text: ReleaseDates.chip(date), tint: upcoming ? Color.dial : nil).padding(6) }
                    }
            }
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if upcoming { BellButton(pick: pick).padding(6) }
        }
        .contextMenu { ReleaseMenu(pick: pick) }
    }
}

// MARK: - Tab bar

/// The three tabs as big titles, like Apple Music's page headings: the open one dark, the others grey. Plain buttons, always clickable.
struct DiscoveryTabBar: View {
    @Binding var tab: DiscoveryTab
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.l) {
            ForEach(DiscoveryTab.allCases) { item in
                Button { tab = item } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(item.rawValue)
                            .font(.headline)
                            .foregroundStyle(tab == item ? Color.primary : Color.secondary.opacity(0.7))
                        if item == .following, app.follows.releases.count + app.follows.artists.count > 0 {
                            Text("\(app.follows.releases.count + app.follows.artists.count)")
                                .font(.caption2.weight(.bold)).foregroundStyle(Color.dial)
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == item ? [.isSelected, .isButton] : .isButton)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.l)
    }
}

// MARK: - Calendar

/// A month of releases: a dot under each day that has one, and the day's releases below.
struct ReleaseCalendar: View {
    let picks: [PublicMusic.Pick]
    let owned: OwnershipIndex
    @State private var month = Calendar.current.startOfDay(for: .now)
    @State private var selected = Calendar.current.startOfDay(for: .now)
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL

    private var calendar: Calendar { Calendar.current }

    private var byDay: [Date: [PublicMusic.Pick]] {
        Dictionary(grouping: picks.compactMap { pick in ReleaseDates.date(pick).map { (calendar.startOfDay(for: $0), pick) } }, by: \.0)
            .mapValues { $0.map(\.1) }
    }

    private var days: [Date?] {
        guard let start = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
              let range = calendar.range(of: .day, in: .month, for: start) else { return [] }
        let lead = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: lead) + range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: start) }
    }

    private var weekdayLetters: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year())).font(.title3.weight(.semibold))
                Spacer()
                Button { shift(-1) } label: { Image(systemName: "chevron.left").padding(8) }.buttonStyle(.plain)
                Button { month = .now; selected = calendar.startOfDay(for: .now) } label: { Text("Today").font(.subheadline.weight(.semibold)) }.buttonStyle(.plain)
                Button { shift(1) } label: { Image(systemName: "chevron.right").padding(8) }.buttonStyle(.plain)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 6) {
                ForEach(Array(weekdayLetters.enumerated()), id: \.offset) { _, letter in
                    Text(letter).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day { cell(day) } else { Color.clear.frame(height: 40) }
                }
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text(selected.formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.headline)
                let items = byDay[selected] ?? []
                if items.isEmpty {
                    Text("No releases from your artists this day.").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, Theme.Spacing.s)
                }
                ForEach(items) { pick in row(pick) }
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
    }

    private func shift(_ delta: Int) {
        month = calendar.date(byAdding: .month, value: delta, to: month) ?? month
    }

    private func cell(_ day: Date) -> some View {
        let count = byDay[day]?.count ?? 0
        let isSelected = calendar.isDate(day, inSameDayAs: selected)
        let isToday = calendar.isDateInToday(day)
        let upcoming = day > calendar.startOfDay(for: .now)
        return Button { selected = day } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.subheadline.weight(isToday ? .bold : .regular))
                    .foregroundStyle(isSelected ? Color.white : isToday ? Color.dial : Color.primary)
                Circle().fill(count == 0 ? Color.clear : (isSelected ? Color.white : (upcoming ? Color.dial : Color.green))).frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity).frame(height: 40)
            .background(isSelected ? Color.dial : Color.clear, in: .rect(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(.dateTime.day().month(.wide)) + (count > 0 ? ", \(count) releases" : ""))
    }

    private func row(_ pick: PublicMusic.Pick) -> some View {
        let upcoming = ReleaseDates.date(pick).map { ReleaseDates.days(from: $0) > 0 } ?? false
        return HStack(spacing: Theme.Spacing.m) {
            NavigationLink(value: Route.publicAlbum(pick.release, artist: pick.artist ?? "", artistId: owned.artist(of: pick)?.id)) {
                HStack(spacing: Theme.Spacing.m) {
                    RemoteImage(url: pick.cover) { ArtworkPlaceholder(symbol: "music.note") }
                    .artworkFrame(size: Theme.Size.rowArtwork)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pick.title).lineLimit(1)
                        Text(pick.artist ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { Task { openURL(await SpotifyLink.url(for: pick)) } } label: {
                Image(systemName: "arrow.up.right.square").padding(8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(pick.title) in Spotify")
            if upcoming {
                Button { Task { await app.follows.toggleBell(pick) } } label: {
                    Image(systemName: app.follows.isBelled(pick.mbid) ? "bell.fill" : "bell")
                        .foregroundStyle(app.follows.isBelled(pick.mbid) ? Color.dial : Color.primary).padding(8)
                }
                .buttonStyle(.plain)
            }
        }
        .contextMenu { ReleaseMenu(pick: pick) }
    }
}

// MARK: - Following

/// What you asked to hear about: albums waiting for their day, and the artists you follow.
struct FollowingTab: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL

    var body: some View {
        let follows = app.follows
        let waiting = follows.releases.filter { ReleaseDates.date(forText: $0.date).map { ReleaseDates.days(from: $0) >= 0 } ?? true }
            .sorted { $0.date < $1.date }
        let out = follows.releases.filter { r in !waiting.contains(r) }.sorted { $0.date > $1.date }
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            if follows.notificationsDenied {
                Label("Notifications are off for Dial. Turn them on in Settings to be told when something comes out.", systemImage: "bell.slash")
                    .font(.subheadline).foregroundStyle(.orange).padding(.horizontal, Theme.Spacing.l)
            }
            if waiting.isEmpty && out.isEmpty && follows.artists.isEmpty {
                ContentUnavailableView("Nothing followed yet", systemImage: "bell",
                                       description: Text("Tap the bell on an album that is coming soon to be told on its release day, or follow an artist (press and hold a release) to hear about everything they put out."))
                    .padding(.top, Theme.Spacing.xl)
            }
            if !waiting.isEmpty {
                section("Waiting for release") {
                    ForEach(waiting) { release in releaseRow(release, waiting: true) }
                }
            }
            if !follows.artists.isEmpty {
                section("Followed artists") {
                    ForEach(follows.artists) { artist in
                        HStack(spacing: Theme.Spacing.m) {
                            PublicArtistPhoto(name: artist.name, mbid: artist.id).artworkFrame(size: Theme.Size.rowArtwork, .circle)
                            Text(artist.name)
                            Spacer()
                            Button("Unfollow") { follows.remove(artist: artist.id) }
                                .font(.subheadline).buttonStyle(.plain).foregroundStyle(Color.dial)
                        }
                    }
                }
            }
            if !out.isEmpty {
                section("Released") {
                    ForEach(out) { release in releaseRow(release, waiting: false) }
                }
            }
        }
        .padding(.vertical, Theme.Spacing.m)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text(title).font(.title3.weight(.semibold))
            content()
        }
        .padding(.horizontal, Theme.Spacing.l)
    }

    private func releaseRow(_ release: FollowedRelease, waiting: Bool) -> some View {
        let date = ReleaseDates.date(forText: release.date)
        let pick = PublicMusic.Pick(kind: .album, mbid: release.id, title: release.title, artist: release.artist, artistMbid: release.artistMbid,
                                    year: nil, tags: [], releaseDate: release.date)
        return HStack(spacing: Theme.Spacing.m) {
            NavigationLink(value: Route.publicAlbum(pick.release, artist: release.artist, artistId: nil)) {
                HStack(spacing: Theme.Spacing.m) {
                    RemoteImage(url: pick.cover) { ArtworkPlaceholder(symbol: "music.note") }
                    .artworkFrame(size: Theme.Size.rowArtwork)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(release.title).lineLimit(1)
                        Text(release.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let date {
                        Text(waiting ? ReleaseDates.relative(date) : ReleaseDates.chip(date))
                            .font(.caption.weight(.semibold)).foregroundStyle(waiting ? Color.dial : .secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { Task { openURL(await SpotifyLink.url(for: pick)) } } label: { Image(systemName: "arrow.up.right.square").padding(8) }
                .buttonStyle(.plain)
        }
        .swipeActions { Button(role: .destructive) { app.follows.remove(release: release.id) } label: { Label("Remove", systemImage: "trash") } }
        .contextMenu { Button(role: .destructive) { app.follows.remove(release: release.id) } label: { Label("Remove", systemImage: "bell.slash") } }
    }
}

extension ReleaseDates {
    static func date(forText text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(text.prefix(10)))
    }
}

// MARK: - Discovery's big cards

/// The biggest news first: what Discovery leads with, chosen from the releases of the artists you play most. Out in the last
/// three weeks, or coming in the next month; the nearer a date and the more you play the artist, the higher it goes. One card
/// per artist, five at most.
enum DiscoveryHighlights {
    @MainActor
    static func make(feed: DiscoveryFeed, owned: OwnershipIndex) -> [Highlight] {
        let rank = Dictionary(feed.artists.enumerated().map { ($1.mbid, $0) }, uniquingKeysWith: { a, _ in a })
        var scored: [(pick: PublicMusic.Pick, days: Int, score: Double)] = []
        for pick in feed.fresh + feed.upcoming {
            guard let date = ReleaseDates.date(pick) else { continue }
            let days = ReleaseDates.days(from: date)
            let base: Double
            switch days {
            case ...(-22): continue
            case -21 ... -15: base = 40
            case -14 ... -8: base = 55
            case -7 ... -4: base = 75
            case -3 ... -2: base = 90
            case -1 ... 0: base = 100
            case 1 ... 2: base = 95
            case 3 ... 7: base = 80
            case 8 ... 14: base = 60
            case 15 ... 30: base = 40
            default: continue
            }
            let bonus = Double(max(0, 25 - (pick.artistMbid.flatMap { rank[$0] } ?? 25)))
            scored.append((pick, days, base + bonus))
        }
        var seenArtists = Set<String>()
        var result: [Highlight] = []
        for entry in scored.sorted(by: { $0.score > $1.score }) {
            let artist = entry.pick.artistMbid ?? entry.pick.artist ?? entry.pick.mbid
            guard seenArtists.insert(artist).inserted else { continue }
            let date = ReleaseDates.date(entry.pick)!
            let owner = owned.artist(of: entry.pick)
            result.append(Highlight(kind: .newRelease, label: ReleaseDates.relative(date), title: entry.pick.title,
                                    subtitle: entry.pick.artist ?? "", detail: "", coverURL: entry.pick.cover, artistId: owner?.id,
                                    action: .publicAlbum(entry.pick.release, artist: entry.pick.artist ?? "", artistId: owner?.id)))
            if result.count == 5 { break }
        }
        return result
    }
}


// MARK: - Skeletons in the shape of the page

/// The hero while it loads: the wide picture and the three lines of text under it, as the real card is laid out.
struct DiscoveryHeroSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SkeletonBlock(height: nil, radius: Theme.Radius.hero).aspectRatio(16 / 9, contentMode: .fit)
            SkeletonBlock(width: 70, height: 10)
            SkeletonBlock(width: 190, height: 18)
            SkeletonBlock(width: 120, height: 12)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .shimmering()
        .accessibilityHidden(true)
    }
}
