import Foundation

/// An upcoming concert by an artist in your library.
struct Concert: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let artist: String
    let name: String
    /// "2026-12-04"
    let date: String
    let venue: String
    let city: String
    let url: URL
    let image: URL?
}

/// An artist you play, with the MusicBrainz id Discovery looks them up by.
struct DiscoveryArtist: Codable, Sendable, Hashable {
    let name: String
    let mbid: String
}

/// Everything on the Discovery page, saved so it opens instantly and refreshed a part at a time.
///
/// Reading a saved copy never fails because the shape changed: every field is optional on the way in, so an update that
/// adds a field keeps what was saved (a plain Codable struct throws away the whole copy when one new field is missing).
struct DiscoveryFeed: Codable, Sendable {
    /// Recent albums and EPs by artists in your library.
    var fresh: [PublicMusic.Pick] = []
    /// Albums, EPs and singles by those artists with a release date still ahead, soonest first.
    var upcoming: [PublicMusic.Pick] = []
    /// Who the fans of the artists you play most also play.
    var fans: [DiscoverData.FanGroup] = []
    var concerts: [Concert] = []
    /// True while each part is being looked up, so its row can show it is working (never kept between launches).
    var releasesLoading = false
    var fansLoading = false
    var concertsLoading = false
    /// The artists you play most. Kept, so the server is not asked for them every time: renewed once a day.
    var artists: [DiscoveryArtist] = []
    /// Whether the server's plugin has concerts switched on (so the row shows a loader while it works).
    var concertsEnabled = true

    init() {}

    enum CodingKeys: String, CodingKey { case fresh, upcoming, fans, concerts, releasesLoading, fansLoading, concertsLoading, artists, concertsEnabled }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fresh = (try? c.decode([PublicMusic.Pick].self, forKey: .fresh)) ?? []
        upcoming = (try? c.decode([PublicMusic.Pick].self, forKey: .upcoming)) ?? []
        fans = (try? c.decode([DiscoverData.FanGroup].self, forKey: .fans)) ?? []
        concerts = (try? c.decode([Concert].self, forKey: .concerts)) ?? []
        artists = (try? c.decode([DiscoveryArtist].self, forKey: .artists)) ?? []
        concertsEnabled = (try? c.decode(Bool.self, forKey: .concertsEnabled)) ?? true
        // The loading flags are only for the moment: a copy read back from disk is never in the middle of looking.
        releasesLoading = false
        fansLoading = false
        concertsLoading = false
    }

    var isEmpty: Bool { fresh.isEmpty && fans.isEmpty && concerts.isEmpty }
}

/// Builds the Discovery page from your library and the open music databases. It is for people who chose their own
/// music: nothing global or random, only what concerns the artists you own.
///
/// Caching: the page always shows what was saved last, at once, and the refresh happens quietly in the background,
/// starting soon after the app opens (see `prefetch`), not when the tab is opened. Every part has its own schedule:
/// concerts every twelve hours, your artist list and the rest once a day. MusicBrainz allows one request
/// a second, so each artist's discography is saved and renewed every three days, and no more than a dozen are
/// renewed in one go (all of them the very first time), the page filling in as it goes.
enum DiscoveryEngine {
    static let snapshotKey = "discovery-v1"
    private static let coreKey = "discovery-core"
    private static let coreRunKey = "discovery-core-run"
    private static let artistsKey = "discovery-artists"
    private static let fansKey = "discovery-fans"
    /// "v2": concerts found by exact act match; results saved before that (which could include tribute shows) are not used.
    static let concertsKey = "discovery-concerts-v2"

    static let coreMaxAge: TimeInterval = 24 * 3600
    static let concertsMaxAge: TimeInterval = 12 * 3600
    /// A saved discography is shown whatever its age, and renewed in the background once it is this old.
    static let discographyMaxAge: TimeInterval = 3 * 24 * 3600
    private static let batchSize = 12

    /// How many of your artists are looked through (the ones you play most).
    private static let artistLimit = 40

    // MARK: Settings for concerts

    static let ticketmasterKeyDefaults = "dial.ticketmasterKey"
    static let cityDefaults = "dial.concertCity"
    static let countryDefaults = "dial.concertCountry"

    static var concertsEnabled: Bool {
        !(UserDefaults.standard.string(forKey: ticketmasterKeyDefaults) ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: Saved copy

    static func saved() -> DiscoveryFeed { Snapshots.peek(DiscoveryFeed.self, snapshotKey) ?? DiscoveryFeed() }

    /// Forgets everything Discovery saved (the page is rebuilt next time it opens).
    @MainActor static func clearCache() {
        Snapshots.remove(snapshotKey)
        for key in [coreKey, coreRunKey, artistsKey, fansKey, concertsKey] { Freshness.clear(key) }
        PublicMusic.clearDiscographies()
    }

    /// Which rows have been looked up (or found fresh) since the app opened: an empty row that is finished is not shown,
    /// and one that is not finished yet shows its loading skeleton. "releases", "fans", "concerts".
    @MainActor private(set) static var finished = Set<String>()

    @MainActor private static var running: Task<Void, Never>?
    /// Whoever asked last gets the updates, so leaving the page and coming back while it is working picks it up again.
    @MainActor private static var listener: (@MainActor (DiscoveryFeed) -> Void)?

    /// Brings Discovery up to date in the background, without a page asking for it: called soon after the app opens
    /// and when it comes back, so the page is already fresh when you get to it. Cheap when nothing is out of date.
    @MainActor
    static func prefetch(client: JellyfinClient) async {
        let owned = await OwnershipIndex.load(client: client)
        await refresh(client: client, owned: owned, force: false, onUpdate: nil)
    }

    /// Refreshes whatever is out of date (or everything, when `force` is set), calling `onUpdate` as parts arrive.
    @MainActor
    static func refresh(client: JellyfinClient, owned: OwnershipIndex, force: Bool,
                        onUpdate: (@MainActor (DiscoveryFeed) -> Void)?) async {
        if let onUpdate { listener = onUpdate }
        if let running { await running.value; return }
        let task = Task { @MainActor in
            // The server's plugin makes the feed; the app only fetches it.
            if await client.hasDialPlugin() {
                var waited = 0
                while let result = await client.dialDiscovery() {
                    if result.ready {
                        Snapshots.save(result.feed, snapshotKey)
                        listener?(result.feed)
                        break
                    }
                    waited += 1
                    if waited > 18 { break } // the server is still making the first one: try again later
                    try? await Task.sleep(for: .seconds(10))
                }
                for row in ["releases", "fans", "concerts"] { finished.insert(row) }
                return
            }
            var feed = saved()
            if feed.isEmpty, let disk = await Snapshots.load(DiscoveryFeed.self, snapshotKey) { feed = disk }
            @MainActor func publish() {
                Snapshots.save(feed, snapshotKey)
                listener?(feed)
            }
            let concertsDue = concertsEnabled && (force || feed.concerts.isEmpty || !Freshness.isFresh(concertsKey, maxAge: concertsMaxAge))
            // A pass over the discographies is not started again within ten minutes, even if it is not finished.
            // An empty list of new releases is a result too (nothing came out), not a reason to look again.
            // A saved page with nothing in it is never "fresh": the timestamps can outlive a wiped page.
            let hollow = feed.fresh.isEmpty && feed.fans.isEmpty
            let coreDue = (force || hollow || !Freshness.isFresh(coreKey, maxAge: coreMaxAge))
                && (force || !Freshness.isFresh(coreRunKey, maxAge: 600))
            // The people recommendations alone, when the rest is fresh but they were never worked out.
            let fansDue = !coreDue && !feed.artists.isEmpty && (force || !Freshness.isFresh(fansKey, maxAge: coreMaxAge))
            if !concertsEnabled, !feed.concerts.isEmpty { feed.concerts = []; publish() }
            // A row that is not due is as up to date as it will be: nothing to wait for.
            if !concertsEnabled || !concertsDue { finished.insert("concerts") }
            if !coreDue { finished.insert("releases") }
            if !coreDue && !fansDue { finished.insert("fans") }
            guard concertsDue || coreDue || fansDue else { return }

            // Your artists: kept from last time, renewed once a day.
            if force || feed.artists.isEmpty || !Freshness.isFresh(artistsKey, maxAge: coreMaxAge) {
                let found = await topArtists(client: client)
                if !found.isEmpty {
                    feed.artists = found.map { DiscoveryArtist(name: $0.name, mbid: $0.mbid) }
                    Freshness.mark(artistsKey)
                    publish()
                }
            }
            // The artists you follow are watched too, whether or not they are in your library.
            var artists = feed.artists.map { LibraryArtist(name: $0.name, mbid: $0.mbid, weight: 0) }
            let known = Set(artists.map(\.mbid))
            artists += AppModel.shared.follows.artists.filter { !known.contains($0.id) }.map { LibraryArtist(name: $0.name, mbid: $0.id, weight: 0) }

            // Concerts do not wait for the slow part.
            if concertsDue {
                feed.concertsLoading = true
                publish()
                feed.concerts = await ConcertEngine.fetch(artists: artists.prefix(25).map(\.name))
                feed.concertsLoading = false
                finished.insert("concerts")
                Freshness.mark(concertsKey)
                publish()
            }

            if fansDue {
                feed.fansLoading = true
                publish()
                feed.fans = await fans(artists: artists)
                feed.fansLoading = false
                Freshness.mark(fansKey)
                finished.insert("fans")
                publish()
            }
            guard coreDue, !artists.isEmpty else {
                finished.insert("releases")
                if !fansDue { finished.insert("fans") }
                publish()
                return
            }
            Freshness.mark(coreRunKey)
            feed.releasesLoading = true
            feed.fansLoading = true
            publish()
            // 1. Everything already known is shown at once, whatever its age.
            var byArtist: [String: [PublicMusic.Pick]] = [:]
            var upcomingByArtist: [String: [PublicMusic.Pick]] = [:]
            var needs: [LibraryArtist] = []
            for artist in artists {
                if let saved = await PublicMusic.savedDiscography(artistMBID: artist.mbid) {
                    byArtist[artist.mbid] = newReleases(saved.releases, of: artist, owned: owned)
                    upcomingByArtist[artist.mbid] = upcomingReleases(saved.releases, of: artist, owned: owned)
                    if saved.age > discographyMaxAge { needs.append(artist) }
                } else {
                    needs.append(artist)
                }
            }
            func rebuild() {
                feed.fresh = sortedFresh(byArtist.values.flatMap { $0 })
                feed.upcoming = upcomingByArtist.values.flatMap { $0 }.sorted { ($0.releaseDate ?? "") < ($1.releaseDate ?? "") }
            }
            rebuild()
            // 2. The ones not looked at for a while are renewed, a dozen at a time (all of them the very first time).
            let batch = Array(needs.prefix(byArtist.isEmpty ? artists.count : batchSize))
            publish()
            for (index, artist) in batch.enumerated() {
                guard !Task.isCancelled else { return }
                let releases = await PublicMusic.discography(artistMBID: artist.mbid, maxAge: discographyMaxAge)
                byArtist[artist.mbid] = newReleases(releases, of: artist, owned: owned)
                upcomingByArtist[artist.mbid] = upcomingReleases(releases, of: artist, owned: owned)
                // The page fills in as it goes.
                if index % 3 == 2 || index == batch.count - 1 { rebuild(); publish() }
            }
            rebuild()
            feed.releasesLoading = false
            finished.insert("releases")
            publish()
            feed.fans = await fans(artists: artists)
            feed.fansLoading = false
            Freshness.mark(fansKey)
            finished.insert("fans")
            // Everything renewed: done for the day. Otherwise the next pass takes the next dozen.
            if needs.count <= batch.count { Freshness.mark(coreKey) }
            publish()
        }
        running = task
        await task.value
        running = nil
        if let saved = await Snapshots.load(DiscoveryFeed.self, snapshotKey) { await AppModel.shared.follows.reconcile(feed: saved) }
    }

    // MARK: Your artists

    struct LibraryArtist: Sendable {
        let name: String
        let mbid: String
        let weight: Double
    }

    /// The artists you play most that Jellyfin knows a MusicBrainz id for, most played first.
    private static func topArtists(client: JellyfinClient) async -> [LibraryArtist] {
        async let songs = client.songs(sortedBy: "PlayCount", limit: 600)
        async let library = client.distinctArtists()
        let played = ((try? await songs) ?? []).filter { $0.plays > 0 }
        let artists = (try? await library) ?? []
        var mbidByKey: [String: String] = [:]
        for artist in artists { if let mbid = artist.musicBrainzId { mbidByKey[ArtistNames.key(artist.name)] = mbid } }
        var weight: [String: (name: String, value: Double)] = [:]
        for song in played {
            let name = ArtistNames.primary(song.albumArtist ?? song.artistLine)
            let key = ArtistNames.key(name)
            weight[key, default: (name, 0)].value += Double(min(song.plays, 30))
        }
        let ranked = weight.sorted { $0.value.value > $1.value.value }.compactMap { key, entry -> LibraryArtist? in
            mbidByKey[key].map { LibraryArtist(name: entry.name, mbid: $0, weight: entry.value) }
        }
        if ranked.count >= 10 { return Array(ranked.prefix(artistLimit)) }
        // Not much listening yet: the artists with the most albums fill in.
        var seen = Set(ranked.map(\.mbid))
        var result = ranked
        for artist in artists where result.count < artistLimit {
            if let mbid = artist.musicBrainzId, seen.insert(mbid).inserted {
                result.append(LibraryArtist(name: ArtistNames.primary(artist.name), mbid: mbid, weight: 0))
            }
        }
        return result
    }

    // MARK: New releases

    /// What is new in an artist's discography that you don't have yet: recent albums and EPs, and singles while they are fresh.
    @MainActor
    private static func newReleases(_ releases: [PublicMusic.Release], of artist: LibraryArtist, owned: OwnershipIndex) -> [PublicMusic.Pick] {
        let now = Date()
        var fresh: [PublicMusic.Pick] = []
        for release in releases {
            let item = PublicMusic.Pick(kind: .album, mbid: release.id, title: release.title, artist: artist.name, artistMbid: artist.mbid,
                                        year: release.year, tags: [], releaseDate: release.date)
            guard owned.album(item) == nil, let age = ageInDays(release, now: now), age >= 0 else { continue }
            switch release.kind {
            case .album, .ep: if age <= 150 { fresh.append(item) }
            case .single: if age <= 60 { fresh.append(item) }
            default: break
            }
        }
        return fresh
    }

    /// Releases with an exact date still ahead (within about six months): what the calendar and "coming soon" show.
    @MainActor
    private static func upcomingReleases(_ releases: [PublicMusic.Release], of artist: LibraryArtist, owned: OwnershipIndex) -> [PublicMusic.Pick] {
        let now = Date()
        var result: [PublicMusic.Pick] = []
        for release in releases {
            guard release.kind == .album || release.kind == .ep || release.kind == .single,
                  let date = release.date, date.count >= 10, let age = ageInDays(release, now: now), age < 0, age >= -200 else { continue }
            let item = PublicMusic.Pick(kind: .album, mbid: release.id, title: release.title, artist: artist.name, artistMbid: artist.mbid,
                                        year: release.year, tags: [], releaseDate: date)
            if owned.album(item) == nil { result.append(item) }
        }
        return result
    }

    private static func ageInDays(_ release: PublicMusic.Release, now: Date) -> Int? {
        guard let date = release.date, date.count >= 7 else { return release.year.map { $0 >= Calendar.current.component(.year, from: now) ? 0 : 10_000 } }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = date.count >= 10 ? "yyyy-MM-dd" : "yyyy-MM"
        guard let parsed = formatter.date(from: String(date.prefix(date.count >= 10 ? 10 : 7))) else { return nil }
        return Calendar.current.dateComponents([.day], from: parsed, to: now).day
    }

    private static func sortedFresh(_ picks: [PublicMusic.Pick]) -> [PublicMusic.Pick] {
        picks.sorted { ($0.releaseDate ?? "\($0.year ?? 0)") > ($1.releaseDate ?? "\($1.year ?? 0)") }
    }

    // MARK: Who else

    /// For the three artists you play most: who their fans also listen to (ListenBrainz), not counting what you own.
    private static func fans(artists: [LibraryArtist]) async -> [DiscoverData.FanGroup] {
        let seeds = Array(artists.prefix(3))
        let lists = await withTaskGroup(of: (Int, [PublicMusic.SimilarArtist]).self) { group in
            for (index, seed) in seeds.enumerated() {
                group.addTask { (index, await PublicMusic.similarArtists(artistMBID: seed.mbid)) }
            }
            var all: [(Int, [PublicMusic.SimilarArtist])] = []
            for await result in group { all.append(result) }
            return all.sorted { $0.0 < $1.0 }.map(\.1)
        }
        var used = Set(artists.map(\.mbid))
        var groups: [DiscoverData.FanGroup] = []
        var picks: [[PublicMusic.Pick]] = []
        for similar in lists {
            picks.append(similar.filter { used.insert($0.mbid).inserted }.prefix(12).map {
                PublicMusic.Pick(kind: .artist, mbid: $0.mbid, title: $0.name, artist: nil, artistMbid: nil, year: nil, tags: [])
            })
        }
        let photos = await PublicMusic.artistImages(mbids: picks.flatMap { $0.map(\.mbid) })
        for (seed, list) in zip(seeds, picks) where !list.isEmpty {
            groups.append(.init(seedName: seed.name, picks: list.map { pick in var copy = pick; copy.image = photos[pick.mbid]; return copy }))
        }
        return groups
    }
}

// MARK: - Concerts

/// Upcoming concerts from Ticketmaster's Discovery API. It needs a free key (Settings) and a city; the artists you
/// own are sent to Ticketmaster to look them up, so nothing happens until you add the key.
///
/// It is exact on purpose: a search for "Queen" also finds tribute and symphonic shows. So each artist is first looked up
/// as an act on Ticketmaster (the name must match exactly; tribute acts are separate acts with other names), and only
/// that act's own events are asked for. The act ids are remembered, so later refreshes need one request per artist.
enum ConcertEngine {
    private static let idsKey = "dial.tmAttractions"
    private static let idsStampKey = "dial.tmAttractionsAt"

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func json(_ url: URL?) async -> [String: Any]? {
        guard let url, let (data, _) = try? await Network.session.data(from: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The act's Ticketmaster id, remembered ("" = no act of that exact name, remembered for a month).
    private static func attractionId(for name: String, key: String, ids: inout [String: String]) async -> String? {
        let remembered = normalize(name)
        if let known = ids[remembered] { return known.isEmpty ? nil : known }
        var components = URLComponents(string: "https://app.ticketmaster.com/discovery/v2/attractions.json")!
        components.queryItems = [URLQueryItem(name: "apikey", value: key), URLQueryItem(name: "keyword", value: name),
                                 URLQueryItem(name: "classificationName", value: "music"), URLQueryItem(name: "size", value: "8")]
        guard let root = await json(components.url) else { return nil } // not answered: try again next time
        let found = ((root["_embedded"] as? [String: Any])?["attractions"] as? [[String: Any]] ?? [])
            .first { normalize($0["name"] as? String ?? "") == remembered }
        let id = found?["id"] as? String ?? ""
        ids[remembered] = id
        return id.isEmpty ? nil : id
    }

    static func fetch(artists: [String]) async -> [Concert] {
        let defaults = UserDefaults.standard
        let key = (defaults.string(forKey: DiscoveryEngine.ticketmasterKeyDefaults) ?? "").trimmingCharacters(in: .whitespaces)
        let city = (defaults.string(forKey: DiscoveryEngine.cityDefaults) ?? "").trimmingCharacters(in: .whitespaces)
        let country = (defaults.string(forKey: DiscoveryEngine.countryDefaults) ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        guard !key.isEmpty else { return [] }
        // The remembered ids are renewed once a month.
        if Date().timeIntervalSince(defaults.object(forKey: idsStampKey) as? Date ?? .distantPast) > 30 * 86400 {
            defaults.removeObject(forKey: idsKey)
            defaults.set(Date(), forKey: idsStampKey)
        }
        var ids = defaults.dictionary(forKey: idsKey) as? [String: String] ?? [:]
        var concerts: [Concert] = []
        // Ticketmaster allows a few requests a second; one at a time with a short pause stays well under.
        for name in artists {
            guard !Task.isCancelled else { break }
            guard let attraction = await attractionId(for: name, key: key, ids: &ids) else {
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            var components = URLComponents(string: "https://app.ticketmaster.com/discovery/v2/events.json")!
            var items = [URLQueryItem(name: "apikey", value: key), URLQueryItem(name: "attractionId", value: attraction),
                         URLQueryItem(name: "size", value: "5"), URLQueryItem(name: "sort", value: "date,asc")]
            if !city.isEmpty { items.append(URLQueryItem(name: "city", value: city)) }
            if country.count == 2 { items.append(URLQueryItem(name: "countryCode", value: country)) }
            components.queryItems = items
            if let root = await json(components.url),
               let events = (root["_embedded"] as? [String: Any])?["events"] as? [[String: Any]] {
                for event in events {
                    guard let id = event["id"] as? String, let title = event["name"] as? String,
                          let link = (event["url"] as? String).flatMap(URL.init(string:)),
                          let dates = event["dates"] as? [String: Any], let start = dates["start"] as? [String: Any],
                          let day = start["localDate"] as? String else { continue }
                    let venue = ((event["_embedded"] as? [String: Any])?["venues"] as? [[String: Any]])?.first
                    // The best picture for a card: a wide one, around 640 pixels.
                    let pictures = (event["images"] as? [[String: Any]] ?? []).compactMap { picture -> (url: URL, width: Int, wide: Bool)? in
                        guard let text = picture["url"] as? String, let url = URL(string: text) else { return nil }
                        return (url, picture["width"] as? Int ?? 0, (picture["ratio"] as? String) == "16_9")
                    }
                    let best = pictures.filter(\.wide).min { abs($0.width - 640) < abs($1.width - 640) } ?? pictures.first
                    let image = best?.url
                    concerts.append(Concert(id: id, artist: name, name: title, date: day, venue: venue?["name"] as? String ?? "",
                                            city: (venue?["city"] as? [String: Any])?["name"] as? String ?? "", url: link, image: image))
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        defaults.set(ids, forKey: idsKey)
        var seen = Set<String>()
        return concerts.filter { seen.insert($0.id).inserted }.sorted { $0.date < $1.date }
    }
}
