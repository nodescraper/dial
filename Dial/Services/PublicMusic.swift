import CryptoKit
import Foundation

/// Free, public music data (no account or key needed):
/// - MusicBrainz: every artist's full discography (albums, EPs, singles, compilations).
/// - Cover Art Archive: the covers for those releases.
/// - ListenBrainz: which artists people listen to together ("similar artists").
///
/// Jellyfin already knows each artist's MusicBrainz id, which links everything together.
/// Answers are saved on the phone for a week, so each artist is looked up rarely.
enum PublicMusic {
    // MARK: Discography

    struct Release: Codable, Sendable, Identifiable, Hashable {
        enum Kind: String, Codable, Sendable { case album, ep, single, compilation, live, other }
        let id: String // MusicBrainz release group id
        let title: String
        let year: Int?
        let kind: Kind
        /// A direct link to the cover file, when one is known (from ListenBrainz).
        var coverFile: URL? = nil
        /// The first release date, "2026-10-31" (or less exact: "2026-10", "2026"), for telling what is new.
        var date: String? = nil

        /// The cover, as one link used everywhere (tiles and album pages), so it's downloaded once and reused.
        /// The 500-pixel size: small enough for tiles, sharp on album pages, and generated even for new releases.
        var coverURL: URL? { coverFile ?? URL(string: "https://coverartarchive.org/release-group/\(id)/front-500") }
        var largeCoverURL: URL? { coverURL }
    }

    /// Forgets the saved discographies (they are looked up again, one a second, next time they are needed).
    static func clearDiscographies() { Snapshots.remove(prefix: "mb-discography-") }

    /// A saved discography whatever its age, and how old it is (nil if this artist has never been looked up).
    static func savedDiscography(artistMBID: String) async -> (releases: [Release], age: TimeInterval)? {
        guard let stamped = await Snapshots.load(Stamped<[Release]>.self, "mb-discography-v2-\(artistMBID)") else { return nil }
        return (stamped.value, Date().timeIntervalSince(stamped.saved))
    }

    static func discography(artistMBID: String, maxAge: TimeInterval = 7 * 24 * 3600) async -> [Release] {
        let key = "mb-discography-v2-\(artistMBID)"
        if let cached = await cachedValue([Release].self, key, maxAge: maxAge) { return cached }
        // If MusicBrainz cannot be reached, the old copy is better than nothing.
        let old = await Snapshots.load(Stamped<[Release]>.self, key)?.value
        var releases: [Release] = []
        var offset = 0
        // Up to 300 releases, 100 per request.
        while offset < 300 {
            guard let url = URL(string: "https://musicbrainz.org/ws/2/release-group?artist=\(artistMBID)&limit=100&offset=\(offset)&fmt=json"),
                  let page: ReleaseGroupPage = await MusicBrainzGate.shared.fetch(url) else { break }
            releases += page.groups.compactMap(\.release)
            offset += 100
            if offset >= page.count { break }
        }
        let sorted = releases.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        if !sorted.isEmpty { save(sorted, key) }
        return sorted.isEmpty ? (old ?? []) : sorted
    }

    private struct ReleaseGroupPage: Decodable {
        let count: Int
        let groups: [ReleaseGroup]
        enum CodingKeys: String, CodingKey {
            case count = "release-group-count"
            case groups = "release-groups"
        }
    }

    private struct ReleaseGroup: Decodable {
        let id: String
        let title: String
        let primaryType: String?
        let secondaryTypes: [String]?
        let firstReleaseDate: String?
        enum CodingKeys: String, CodingKey {
            case id, title
            case primaryType = "primary-type"
            case secondaryTypes = "secondary-types"
            case firstReleaseDate = "first-release-date"
        }

        var release: Release? {
            let secondary = Set((secondaryTypes ?? []).map { $0.lowercased() })
            // Leave out things that clutter a discography: interviews, DJ mixes, mixtapes of others, etc.
            if !secondary.isDisjoint(with: ["interview", "audiobook", "spokenword", "dj-mix", "demo"]) { return nil }
            let kind: Release.Kind
            if secondary.contains("compilation") { kind = .compilation }
            else if secondary.contains("live") { kind = .live }
            else {
                switch primaryType?.lowercased() {
                case "album": kind = .album
                case "ep": kind = .ep
                case "single": kind = .single
                default: kind = .other
                }
            }
            let year = firstReleaseDate.flatMap { Int($0.prefix(4)) }
            return Release(id: id, title: title, year: year, kind: kind, date: firstReleaseDate)
        }
    }

    // MARK: Tracklists

    struct Track: Codable, Sendable, Hashable, Identifiable {
        let disc: Int
        let number: Int
        let title: String
        let lengthMs: Int?
        var id: String { "\(disc)-\(number)" }
    }

    /// The songs on a release (from its main official edition), for albums you don't have.
    static func tracklist(releaseGroupId: String) async -> [Track] {
        await tracklistChecked(releaseGroupId: releaseGroupId).tracks
    }

    /// The same, and whether it is empty because the lookup failed (try again) or because MusicBrainz has no songs for it.
    static func tracklistChecked(releaseGroupId: String) async -> (tracks: [Track], failed: Bool) {
        // Albums found on Deezer or iTunes (not on MusicBrainz) get their songs from there.
        if DeezerSearch.isSourceId(releaseGroupId) {
            let tracks = await DeezerSearch.tracklist(sourceId: releaseGroupId)
            return (tracks ?? [], tracks == nil)
        }
        let key = "mb-tracks-\(releaseGroupId)"
        if let cached = await cachedValue([Track].self, key) { return (cached, false) }
        var failed = false
        // The official editions first; if there are none (promos, unlabelled releases), any edition with songs.
        for filter in ["&status=official", ""] {
            guard let url = URL(string: "https://musicbrainz.org/ws/2/release?release-group=\(releaseGroupId)&inc=recordings\(filter)&limit=25&fmt=json") else { continue }
            let (page, didFail): (ReleasePage?, Bool) = await MusicBrainzGate.shared.checked(url)
            if didFail { failed = true }
            guard let page else { continue }
            // The earliest edition as the album first came out (not a deluxe reissue), among those with songs.
            let release = page.releases
                .filter { !($0.media ?? []).isEmpty }
                .sorted { ($0.date ?? "9999") < ($1.date ?? "9999") }
                .first
            let tracks = (release?.media ?? []).enumerated().flatMap { disc, medium in
                (medium.tracks ?? []).enumerated().map { index, track in
                    Track(disc: medium.position ?? disc + 1, number: Int(track.number ?? "") ?? index + 1,
                          title: track.title, lengthMs: track.length)
                }
            }
            if !tracks.isEmpty {
                save(tracks, key)
                return (tracks, false)
            }
        }
        // Nothing is saved for a miss, so the next visit asks again.
        return ([], failed)
    }

    /// Songs on the album that you don't have: the official edition closest to what you own, minus every song whose
    /// title matches one of yours. Empty when the album can't be found or you have the whole thing.
    struct Gaps: Sendable {
        var missing: [Track] = []
        /// Where each song you own sits on the chosen edition (disc, track), by its id.
        var positions: [String: [Int]] = [:]
    }

    static func missingTracks(album: BaseItem, owned: [BaseItem]) async -> Gaps {
        guard !owned.isEmpty else { return Gaps() }
        let artist = ArtistNames.primary(album.albumArtistLine)
        var groupId = album.providerIds?["MusicBrainzReleaseGroup"] ?? album.providerIds?["MusicBrainzReleaseGroupId"]
        if groupId == nil {
            let key = "mb-group-\(normalized(artist))-\(normalized(album.name))"
            if let cached = await cachedValue(String.self, key, maxAge: 30 * 24 * 3600) { groupId = cached }
            else {
                let text = "releasegroup:\"\(album.name)\" AND artist:\"\(artist)\" AND primarytype:album"
                let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
                if let url = URL(string: "https://musicbrainz.org/ws/2/release-group?query=\(query)&limit=1&fmt=json"),
                   let found: AlbumSearch = await MusicBrainzGate.shared.fetch(url),
                   let top = found.groups.first, (top.score ?? 100) >= 90,
                   normalized(top.title) == normalized(album.name) {
                    groupId = top.id
                    save(top.id, key)
                }
            }
        }
        guard let groupId else { return Gaps() }
        let editions = await editionTracks(groupId)
        // The edition nearest the number of songs you have, preferring one that has them all.
        let have = owned.count
        guard let edition = editions.min(by: { lhs, rhs in
            func cost(_ e: [Track]) -> Int { e.count >= have ? e.count - have : (have - e.count) * 3 + 1000 }
            return cost(lhs) < cost(rhs)
        }) else { return Gaps() }
        func same(_ a: String, _ b: String) -> Bool { a == b || (a.count > 5 && b.count > 5 && (a.hasPrefix(b) || b.hasPrefix(a))) }
        var gaps = Gaps()
        var free = owned.map { (song: $0, title: normalized($0.name)) }
        for track in edition {
            let title = normalized(track.title)
            if !title.isEmpty, let at = free.firstIndex(where: { same($0.title, title) }) {
                gaps.positions[free[at].song.id] = [track.disc, track.number]
                free.remove(at: at)
            } else { gaps.missing.append(track) }
        }
        return gaps
    }

    /// A title with the extras removed ("(Remastered 2011)", "feat. X", punctuation, case), for comparing songs.
    static func normalized(_ title: String) -> String {
        var text = title.lowercased()
        for pair in [("(", ")"), ("[", "]")] {
            while let open = text.range(of: pair.0), let close = text.range(of: pair.1, range: open.upperBound..<text.endIndex) {
                text.removeSubrange(open.lowerBound..<close.upperBound)
            }
        }
        for marker in [" feat.", " feat ", " ft.", " - remaster", " - live"] {
            if let range = text.range(of: marker) { text = String(text[..<range.lowerBound]) }
        }
        return text.filter { $0.isLetter || $0.isNumber }
    }

    private static func editionTracks(_ groupId: String) async -> [[Track]] {
        let key = "mb-editions-\(groupId)"
        if let cached = await cachedValue([[Track]].self, key) { return cached }
        guard let url = URL(string: "https://musicbrainz.org/ws/2/release?release-group=\(groupId)&inc=recordings&status=official&limit=25&fmt=json"),
              let page: ReleasePage = await MusicBrainzGate.shared.fetch(url) else { return [] }
        let editions = page.releases.compactMap { release -> [Track]? in
            let tracks = (release.media ?? []).enumerated().flatMap { disc, medium in
                (medium.tracks ?? []).enumerated().map { index, track in
                    Track(disc: medium.position ?? disc + 1, number: Int(track.number ?? "") ?? index + 1, title: track.title, lengthMs: track.length)
                }
            }
            return tracks.isEmpty ? nil : tracks
        }
        if !editions.isEmpty { save(editions, key) }
        return editions
    }

    private struct ReleasePage: Decodable {
        struct Release: Decodable {
            let date: String?
            let media: [Medium]?
        }
        struct Medium: Decodable {
            let position: Int?
            let tracks: [MBTrack]?
        }
        struct MBTrack: Decodable {
            let number: String?
            let title: String
            let length: Int?
        }
        let releases: [Release]
    }

    // MARK: Similar artists

    struct SimilarArtist: Codable, Sendable, Hashable, Identifiable {
        let mbid: String
        let name: String
        let score: Double
        var id: String { mbid }
    }

    /// Artists that people who listen to this artist also listen to, most similar first.
    static func similarArtists(artistMBID: String) async -> [SimilarArtist] {
        let key = "lb-similar-\(artistMBID)"
        if let cached = await cachedValue([SimilarArtist].self, key) { return cached }
        let algorithm = "session_based_days_7500_session_300_contribution_5_threshold_10_limit_100_filter_True_skip_30"
        guard let url = URL(string: "https://labs.api.listenbrainz.org/similar-artists/json?artist_mbids=\(artistMBID)&algorithm=\(algorithm)"),
              let rows: [ListenBrainzArtist] = await fetch(url) else { return [] }
        let similar = rows
            .filter { $0.artistMBID != artistMBID }
            .map { SimilarArtist(mbid: $0.artistMBID, name: $0.name, score: $0.score ?? 0) }
            .sorted { $0.score > $1.score }
        if !similar.isEmpty { save(similar, key) }
        return similar
    }

    private struct ListenBrainzArtist: Decodable {
        let artistMBID: String
        let name: String
        let score: Double?
        enum CodingKeys: String, CodingKey {
            case artistMBID = "artist_mbid"
            case name, score
        }
    }

    /// The cover file ListenBrainz points to ("caa_release_mbid" and "caa_id"), sized for tiles.
    fileprivate static func coverFile(_ row: [String: Any]) -> URL? {
        guard let release = row["caa_release_mbid"] as? String, !release.isEmpty else { return nil }
        let id: String
        if let number = row["caa_id"] as? NSNumber { id = number.stringValue }
        else if let text = row["caa_id"] as? String { id = text } else { return nil }
        return URL(string: "https://coverartarchive.org/release/\(release)/\(id)-500.jpg")
    }

    /// Fills in photos for a list of artist picks with one request.
    static func withPhotos(_ picks: [Pick]) async -> [Pick] {
        let images = await artistImages(mbids: picks.filter { $0.kind == .artist }.map(\.mbid))
        return picks.map { pick in
            var copy = pick
            if pick.kind == .artist { copy.image = images[pick.mbid] }
            return copy
        }
    }

    /// Similar artists split into the ones in your library (playable) and the rest (to discover).
    static func similar(to artist: BaseItem, library: [BaseItem]) async -> (inLibrary: [BaseItem], elsewhere: [SimilarArtist]) {
        guard let mbid = artist.musicBrainzId else { return ([], []) }
        let similar = await similarArtists(artistMBID: mbid)
        var byMBID: [String: BaseItem] = [:]
        var byName: [String: BaseItem] = [:]
        for item in library {
            if let id = item.musicBrainzId { byMBID[id] = item }
            byName[ArtistNames.key(item.name)] = item
        }
        var inLibrary: [BaseItem] = []
        var elsewhere: [SimilarArtist] = []
        for candidate in similar.prefix(40) {
            if let match = byMBID[candidate.mbid] ?? byName[ArtistNames.key(candidate.name)] {
                if match.id != artist.id, !inLibrary.contains(where: { $0.id == match.id }) { inLibrary.append(match) }
            } else {
                elsewhere.append(candidate)
            }
        }
        return (inLibrary, elsewhere)
    }

    // MARK: Charts and new releases (ListenBrainz)

    /// Something to discover: an artist or an album, with its MusicBrainz id.
    struct Pick: Codable, Sendable, Hashable, Identifiable {
        enum Kind: String, Codable, Sendable { case artist, album }
        let kind: Kind
        let mbid: String
        let title: String
        /// The artist, for albums.
        let artist: String?
        let artistMbid: String?
        let year: Int?
        let tags: [String]
        /// The artist's photo, filled in for the whole page at once.
        var image: URL? = nil
        /// "2026-10-31", for fresh releases.
        var releaseDate: String? = nil
        /// A direct link to the cover file, when ListenBrainz knows it (faster and more reliable than a lookup).
        var coverFile: URL? = nil
        /// The Deezer or iTunes id, for results found there (they have no MusicBrainz id until one is looked up by name).
        var sourceId: String? = nil
        var id: String { "\(kind.rawValue)-\(mbid)-\(sourceId ?? "")" }
        var cover: URL? { kind == .album ? release.coverURL : nil }
        /// Found on Deezer or iTunes, it has no MusicBrainz id: its page opens by that source's id instead.
        var release: Release { Release(id: mbid.isEmpty ? (sourceId ?? "") : mbid, title: title, year: year, kind: .album, coverFile: coverFile) }
    }

    /// The most listened-to artists on ListenBrainz this week.
    static func popularArtists() async -> [Pick] {
        let key = "lb-top-artists-v2"
        if let cached = await cachedValue([Pick].self, key, maxAge: 12 * 3600) { return cached }
        guard let url = URL(string: "https://api.listenbrainz.org/1/stats/sitewide/artists?range=week&count=40"),
              let data = await fetchData(url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["payload"] as? [String: Any],
              let artists = payload["artists"] as? [[String: Any]] else { return [] }
        var seenArtists = Set<String>()
        let picks = artists.compactMap { row -> Pick? in
            let mbid = (row["artist_mbid"] as? String) ?? (row["artist_mbids"] as? [String])?.first
            guard let mbid, seenArtists.insert(mbid).inserted, let name = row["artist_name"] as? String else { return nil }
            return Pick(kind: .artist, mbid: mbid, title: name, artist: nil, artistMbid: nil, year: nil, tags: [])
        }
        if !picks.isEmpty { save(picks, key) }
        return picks
    }

    /// The most listened-to albums on ListenBrainz this week.
    static func popularAlbums() async -> [Pick] {
        let key = "lb-top-albums-v3"
        if let cached = await cachedValue([Pick].self, key, maxAge: 12 * 3600) { return cached }
        guard let url = URL(string: "https://api.listenbrainz.org/1/stats/sitewide/release-groups?range=week&count=40"),
              let data = await fetchData(url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["payload"] as? [String: Any],
              let groups = payload["release_groups"] as? [[String: Any]] else { return [] }
        var seenGroups = Set<String>()
        let picks = groups.compactMap { row -> Pick? in
            guard let mbid = row["release_group_mbid"] as? String, seenGroups.insert(mbid).inserted,
                  let name = row["release_group_name"] as? String,
                  let file = coverFile(row) else { return nil } // only albums with a cover
            var pick = Pick(kind: .album, mbid: mbid, title: name, artist: row["artist_name"] as? String,
                            artistMbid: (row["artist_mbids"] as? [String])?.first, year: nil, tags: [])
            pick.coverFile = file
            return pick
        }
        if !picks.isEmpty { save(picks, key) }
        return picks
    }

    /// Albums released in the last weeks, newest first, with their genre tags.
    static func freshReleases() async -> [Pick] {
        let key = "lb-fresh-v4"
        if let cached = await cachedValue([Pick].self, key, maxAge: 12 * 3600) { return cached }
        guard let url = URL(string: "https://api.listenbrainz.org/1/explore/fresh-releases/?days=21&sort=release_date&past=true&future=false"),
              let data = await fetchData(url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["payload"] as? [String: Any],
              let releases = payload["releases"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        let picks = releases.compactMap { row -> Pick? in
            guard let mbid = row["release_group_mbid"] as? String, seen.insert(mbid).inserted,
                  let name = row["release_name"] as? String else { return nil }
            let type = (row["release_group_primary_type"] as? String)?.lowercased()
            guard type == nil || type == "album" || type == "ep" else { return nil } // leave out singles
            let tags = ((row["release_tags"] as? [String]) ?? []).map { $0.lowercased() }
            var pick = Pick(kind: .album, mbid: mbid, title: name, artist: row["artist_credit_name"] as? String,
                            artistMbid: (row["artist_mbids"] as? [String])?.first,
                            year: (row["release_date"] as? String).flatMap { Int($0.prefix(4)) }, tags: tags)
            pick.releaseDate = row["release_date"] as? String
            pick.coverFile = coverFile(row)
            return pick
        }.reversed()
        let list = Array(picks)
        if !list.isEmpty { save(list, key) }
        return list
    }

    /// Artists MusicBrainz tags with a genre ("hip hop", "jazz").
    static func artists(taggedWith genre: String) async -> [Pick] {
        let key = "mb-genre-\(genre.replacingOccurrences(of: " ", with: "-"))"
        if let cached = await cachedValue([Pick].self, key, maxAge: 7 * 24 * 3600) { return cached }
        let query = "tag:\"\(genre)\"".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? genre
        guard let url = URL(string: "https://musicbrainz.org/ws/2/artist?query=\(query)&limit=40&fmt=json"),
              let page: ArtistSearch = await MusicBrainzGate.shared.fetch(url) else { return [] }
        let picks = page.artists.map { Pick(kind: .artist, mbid: $0.id, title: $0.name, artist: nil, artistMbid: nil, year: nil, tags: [genre]) }
        if !picks.isEmpty { save(picks, key) }
        return picks
    }

    /// Genres the MusicBrainz community gave an artist ("latin", "reggaeton"), looked up by name and saved for 90 days.
    /// With `fetch` off, only what is already saved is returned (nil when unknown), so big libraries fill in gradually.
    static func artistGenres(name: String, fetch: Bool = true) async -> [String]? {
        let key = "mb-artist-genres-" + ArtistNames.key(name).replacingOccurrences(of: " ", with: "-")
        if let cached = await cachedValue([String].self, key, maxAge: 90 * 24 * 3600) { return cached }
        guard fetch else { return nil }
        let query = "artist:\"\(name)\"".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        guard let url = URL(string: "https://musicbrainz.org/ws/2/artist?query=\(query)&limit=1&fmt=json"),
              let page: ArtistTagSearch = await MusicBrainzGate.shared.fetch(url) else { return nil }
        guard let top = page.artists.first, (top.score ?? 0) >= 90 else { save([String](), key); return [] }
        let tags = ((top.genres ?? []) + (top.tags ?? [])).sorted { ($0.count ?? 0) > ($1.count ?? 0) }.prefix(6).map(\.name)
        save(Array(tags), key)
        return Array(tags)
    }

    private struct ArtistTagSearch: Decodable {
        struct Tag: Decodable { let name: String; let count: Int? }
        struct Artist: Decodable { let score: Int?; let genres: [Tag]?; let tags: [Tag]? }
        let artists: [Artist]
    }

    // MARK: Search beyond your library (MusicBrainz)

    /// Artists and albums beyond your library (Deezer, with iTunes when Deezer cannot be reached).
    static func search(_ term: String) async -> [Pick] {
        await DeezerSearch.artistsAndAlbums(term)
    }

    /// A song you may not have, with the album it is on (when known).
    struct SongPick: Identifiable, Hashable, Sendable, Codable {
        let id: String
        let title: String
        let artist: String
        let artistMbid: String?
        let album: String?
        let year: Int?
        /// The album's Deezer or iTunes id ("dz-…", "it-…"), so it opens without a lookup.
        var albumSourceId: String? = nil
        var albumCover: URL? = nil
    }

    /// Songs beyond your library, for the Songs filter of search (Deezer, with iTunes when Deezer cannot be reached).
    static func searchSongs(_ term: String) async -> [SongPick] {
        await DeezerSearch.songs(term)
    }

    /// An artist's MusicBrainz id, found by name (nil when MusicBrainz has no clear match or cannot be reached).
    static func artistMBID(name: String) async -> String? {
        let key = "mbid-for-" + ArtistNames.key(name).replacingOccurrences(of: " ", with: "-")
        if let cached = await cachedValue(String.self, key, maxAge: 30 * 24 * 3600) { return cached.isEmpty ? nil : cached }
        let query = "artist:\"\(name)\"".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        guard let url = URL(string: "https://musicbrainz.org/ws/2/artist?query=\(query)&limit=1&fmt=json"),
              let page: ArtistSearch = await MusicBrainzGate.shared.fetch(url) else { return nil }
        let mbid = page.artists.first { ArtistNames.key($0.name) == ArtistNames.key(name) }?.id ?? ""
        save(mbid, key)
        return mbid.isEmpty ? nil : mbid
    }

    /// An album's MusicBrainz release group id, found by its artist and title (nil when there is no clear match).
    static func releaseGroupId(artist: String, title: String) async -> String? {
        let key = "mb-rg-for-" + ArtistNames.key(artist).replacingOccurrences(of: " ", with: "-") + "-"
            + ArtistNames.key(title).replacingOccurrences(of: " ", with: "-")
        if let cached = await cachedValue(String.self, key, maxAge: 30 * 24 * 3600) { return cached.isEmpty ? nil : cached }
        let clean = { (text: String) in text.replacingOccurrences(of: "\"", with: "") }
        let query = "releasegroup:\"\(clean(title))\" AND artist:\"\(clean(artist))\""
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        guard let url = URL(string: "https://musicbrainz.org/ws/2/release-group?query=\(query)&limit=5&fmt=json"),
              let page: AlbumSearch = await MusicBrainzGate.shared.fetch(url) else { return nil }
        let id = page.groups.first { ($0.score ?? 0) >= 90 && ArtistNames.key($0.title) == ArtistNames.key(title) }?.id ?? ""
        save(id, key)
        return id.isEmpty ? nil : id
    }

    private struct ArtistSearch: Decodable {
        struct Artist: Decodable { let id: String; let name: String; let score: Int? }
        let artists: [Artist]
    }

    private struct AlbumSearch: Decodable {
        struct Credit: Decodable {
            struct Who: Decodable { let id: String }
            let name: String?
            let artist: Who?
        }
        struct Group: Decodable {
            let id: String
            let title: String
            let score: Int?
            let date: String?
            let credit: [Credit]?
            enum CodingKeys: String, CodingKey {
                case id, title, score
                case date = "first-release-date"
                case credit = "artist-credit"
            }
        }
        let groups: [Group]
        enum CodingKeys: String, CodingKey { case groups = "release-groups" }
    }

    // MARK: Artist photos (Wikidata and Wikimedia Commons)

    /// Photos for many artists in one request: Wikidata links MusicBrainz ids to photos on Wikimedia Commons.
    /// No MusicBrainz request is needed, so photos never hold up anything else. Saved for a month.
    static func artistImages(mbids: [String]) async -> [String: URL] {
        var found: [String: URL] = [:]
        var missing: [String] = []
        for mbid in Set(mbids) {
            if let cached = await cachedValue(String.self, "photo3-\(mbid)", maxAge: 30 * 24 * 3600) {
                if let url = URL(string: cached), !cached.isEmpty { found[mbid] = url }
            } else {
                missing.append(mbid)
            }
        }
        for chunk in stride(from: 0, to: missing.count, by: 60).map({ Array(missing[$0..<min($0 + 60, missing.count)]) }) {
            let values = chunk.map { "\"\($0)\"" }.joined(separator: " ")
            let query = "SELECT ?mbid ?image WHERE { VALUES ?mbid { \(values) } ?item wdt:P434 ?mbid . ?item wdt:P18 ?image . }"
            guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://query.wikidata.org/sparql?format=json&query=\(encoded)"),
                  let data = await fetchData(url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = root["results"] as? [String: Any],
                  let bindings = results["bindings"] as? [[String: Any]] else { continue }
            var answered = Set<String>()
            for row in bindings {
                guard let mbid = (row["mbid"] as? [String: Any])?["value"] as? String, !answered.contains(mbid),
                      let image = (row["image"] as? [String: Any])?["value"] as? String,
                      let thumb = commonsThumbnail(image) else { continue }
                answered.insert(mbid)
                found[mbid] = thumb
                save(thumb.absoluteString, "photo3-\(mbid)")
            }
            for mbid in chunk where !answered.contains(mbid) { save("", "photo3-\(mbid)") } // none; don't ask again for a month
        }
        return found
    }

    static func artistImageURL(mbid: String) async -> URL? {
        await artistImages(mbids: [mbid])[mbid]
    }

    /// A small version of a Commons photo. Wikimedia's FilePath link resizes on the fly and also works when the
    /// original is smaller than asked for.
    private static func commonsThumbnail(_ filePath: String) -> URL? {
        guard let last = filePath.split(separator: "/").last,
              let name = String(last).removingPercentEncoding?.replacingOccurrences(of: " ", with: "_"),
              let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://commons.wikimedia.org/wiki/Special:FilePath/\(encoded)?width=320")
    }

    /// An artist's photo by name (for featured artists): finds the artist on MusicBrainz first.
    static func artistImageURL(name: String) async -> URL? {
        guard let mbid = await artistMBID(name: name) else { return nil }
        return await artistImageURL(mbid: mbid)
    }


    // MARK: What the world plays (ListenBrainz)

    /// One of an artist's most played songs worldwide.
    struct TopTrack: Codable, Sendable, Hashable, Identifiable {
        let id: String        // recording id
        let title: String
        let album: String?
        let listens: Int
        let lengthMs: Int?
    }

    /// An artist's most listened songs across everyone on ListenBrainz, most played first (repeats of a title folded together).
    /// Saved for three days.
    static func topTracks(artistMBID: String) async -> [TopTrack] {
        let key = "lb-top-tracks-\(artistMBID)"
        if let cached = await cachedValue([TopTrack].self, key, maxAge: 3 * 24 * 3600) { return cached }
        guard let url = URL(string: "https://api.listenbrainz.org/1/popularity/top-recordings-for-artist/\(artistMBID)"),
              let data = await request(url).data,
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        var tracks: [TopTrack] = []
        for row in rows {
            guard let title = row["recording_name"] as? String, let id = row["recording_mbid"] as? String else { continue }
            guard seen.insert(normalized(title)).inserted else { continue }
            tracks.append(TopTrack(id: id, title: title, album: row["release_name"] as? String,
                                   listens: row["total_listen_count"] as? Int ?? 0, lengthMs: row["length"] as? Int))
            if tracks.count >= 15 { break }
        }
        if !tracks.isEmpty { save(tracks, key) }
        return tracks
    }

    // MARK: Links

    /// The album's page on Spotify when MusicBrainz has the link (many releases do not); nil otherwise. Saved for a month.
    static func spotifyAlbumURL(releaseGroupId: String) async -> URL? {
        let key = "spotify-link-\(releaseGroupId)"
        if let stamped = await Snapshots.load(Stamped<String>.self, key) {
            let age = Date().timeIntervalSince(stamped.saved)
            if stamped.value.isEmpty ? age < 3 * 24 * 3600 : age < 30 * 24 * 3600 { return URL(string: stamped.value) }
        }
        struct Page: Decodable {
            struct Relation: Decodable { struct Link: Decodable { let resource: String }; let url: Link? }
            let relations: [Relation]?
        }
        guard let url = URL(string: "https://musicbrainz.org/ws/2/release-group/\(releaseGroupId)?inc=url-rels&fmt=json") else { return nil }
        let (page, failed): (Page?, Bool) = await MusicBrainzGate.shared.checked(url)
        let link = page?.relations?.compactMap { $0.url?.resource }.first { $0.contains("open.spotify.com/album") }
        if !failed { save(link ?? "", key) }
        return link.flatMap(URL.init(string:))
    }

    // MARK: Covers that the Cover Art Archive does not have

    /// Where else a release group's cover can come from: iTunes' public search, matched by artist and title. Saved for a
    /// month (and a miss for two days), so each cover is looked for once.
    static func alternativeCover(releaseGroupId: String) async -> URL? {
        let key = "cover-alt-\(releaseGroupId)"
        if let stamped = await Snapshots.load(Stamped<String>.self, key) {
            let age = Date().timeIntervalSince(stamped.saved)
            if stamped.value.isEmpty { if age < 2 * 24 * 3600 { return nil } }
            else if age < 30 * 24 * 3600 { return URL(string: stamped.value) }
        }
        struct Lookup: Decodable {
            struct Credit: Decodable { let name: String? }
            let title: String
            let credit: [Credit]?
            enum CodingKeys: String, CodingKey { case title, credit = "artist-credit" }
        }
        guard let lookupURL = URL(string: "https://musicbrainz.org/ws/2/release-group/\(releaseGroupId)?inc=artists&fmt=json"),
              let group: Lookup = await MusicBrainzGate.shared.fetch(lookupURL) else { return nil }
        let artist = group.credit?.first?.name ?? ""
        let term = "\(artist) \(group.title)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        struct Found: Decodable {
            struct Album: Decodable { let collectionName: String?; let artistName: String?; let artworkUrl100: String? }
            let results: [Album]
        }
        var url: String?
        if let searchURL = URL(string: "https://itunes.apple.com/search?term=\(term)&entity=album&limit=8"),
           let data = await request(searchURL).data, let found = try? JSONDecoder().decode(Found.self, from: data) {
            let wantedTitle = normalized(group.title), wantedArtist = normalized(artist)
            let match = found.results.first { normalized($0.collectionName ?? "") == wantedTitle && normalized($0.artistName ?? "").contains(wantedArtist.prefix(6)) }
                ?? found.results.first { normalized($0.collectionName ?? "").hasPrefix(wantedTitle) && normalized($0.artistName ?? "") == wantedArtist }
            url = match?.artworkUrl100?.replacingOccurrences(of: "100x100bb", with: "600x600bb")
        }
        save(url ?? "", key)
        return url.flatMap(URL.init(string:))
    }

    // MARK: Plumbing

    static let userAgent = "Dial/\(JellyfinClient.version) ( https://github.com/ )"

    /// One request that tries again when the answer is a hiccup (rate limit, server busy, timeout, no connection) and stops at
    /// once when the answer is final (404: it isn't there). `status` is the last HTTP status, 0 when nothing answered.
    private final class StatusBox: @unchecked Sendable { var status = 0 }

    static func request(_ url: URL, json: Bool = true, attempts: Int = 3) async -> (data: Data?, status: Int) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if json { request.setValue("application/json", forHTTPHeaderField: "Accept") }
        let shared = request
        let box = StatusBox()
        let data = await RequestSharing.shared.data(for: url.absoluteString) {
            for attempt in 0..<attempts {
                var wait = 1.5 * Double(attempt + 1)
                if let (data, response) = try? await Network.session.data(for: shared), let http = response as? HTTPURLResponse {
                    box.status = http.statusCode
                    if http.statusCode == 200 { return data }
                    // Final answers: the thing isn't there, or we may not ask.
                    if [400, 401, 403, 404, 410].contains(http.statusCode) { return nil }
                    if let after = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) { wait = min(max(after, 1), 8) }
                } else {
                    box.status = 0
                }
                if attempt < attempts - 1 { try? await Task.sleep(for: .seconds(wait)) }
            }
            return nil
        }
        return (data, box.status)
    }

    fileprivate static func fetch<T: Decodable>(_ url: URL) async -> T? {
        await request(url).data.flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private struct Stamped<T: Codable & Sendable>: Codable, Sendable {
        let saved: Date
        let value: T
    }

    static func cachedValue<T: Codable & Sendable>(_ type: T.Type, _ key: String,
                                                           maxAge: TimeInterval = 7 * 24 * 3600) async -> T? {
        guard let stamped = await Snapshots.load(Stamped<T>.self, key),
              Date().timeIntervalSince(stamped.saved) < maxAge else { return nil }
        return stamped.value
    }

    static func fetchData(_ url: URL) async -> Data? {
        await request(url, json: false).data
    }

    static func save<T: Codable & Sendable>(_ value: T, _ key: String) {
        Snapshots.save(Stamped(saved: Date(), value: value), key)
    }
}

/// MusicBrainz allows about one request per second per app; this keeps Dial within that.
actor MusicBrainzGate {
    static let shared = MusicBrainzGate()
    private var last = Date.distantPast

    private var waiting: [URL: Task<(data: Data?, status: Int), Never>] = [:]

    func fetch<T: Decodable>(_ url: URL) async -> T? {
        await checked(url).value
    }

    /// The answer, and whether the lookup itself failed (a hiccup that is worth asking about again) rather than MusicBrainz
    /// saying it does not have it.
    func checked<T: Decodable>(_ url: URL) async -> (value: T?, failed: Bool) {
        if let task = waiting[url] {
            let result = await task.value
            return (result.data.flatMap { try? JSONDecoder().decode(T.self, from: $0) }, result.data == nil && result.status != 404)
        }
        let task = Task<(data: Data?, status: Int), Never> {
            let wait = 1.1 - Date().timeIntervalSince(last)
            last = Date().addingTimeInterval(max(wait, 0))
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            return await PublicMusic.request(url)
        }
        waiting[url] = task
        let result = await task.value
        waiting[url] = nil
        return (result.data.flatMap { try? JSONDecoder().decode(T.self, from: $0) }, result.data == nil && result.status != 404)
    }
}

extension BaseItem {
    /// The MusicBrainz id Jellyfin stored for this artist or album.
    var musicBrainzId: String? {
        providerIds?["MusicBrainzArtist"] ?? providerIds?["MusicBrainzReleaseGroup"]
    }

    var musicBrainzReleaseGroupId: String? { providerIds?["MusicBrainzReleaseGroup"] }
}

/// Remembers when something was last fetched, so screens don't download the same thing every time they open.
enum Freshness {
    static func isFresh(_ key: String, maxAge: TimeInterval) -> Bool {
        let last = UserDefaults.standard.double(forKey: "fresh." + key)
        return last > 0 && Date().timeIntervalSince1970 - last < maxAge
    }

    static func clear(_ key: String) {
        UserDefaults.standard.removeObject(forKey: "fresh." + key)
    }

    static func mark(_ key: String) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "fresh." + key)
    }
}
