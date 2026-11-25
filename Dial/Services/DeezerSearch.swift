import Foundation

/// Search beyond your library, the way music apps do it: Deezer answers artists, albums and songs in a few requests,
/// with photos and covers and no key. When Deezer cannot be reached, iTunes answers albums and songs instead.
/// Each search is saved for a day, so typing the same words again is instant.
enum DeezerSearch {
    private struct Page<T: Decodable>: Decodable { let data: [T]? }
    private struct Named: Decodable { let id: Int; let name: String }
    private struct Artist: Decodable { let id: Int; let name: String; let pictureBig: String? }
    private struct Album: Decodable { let id: Int; let title: String; let coverBig: String?; let artist: Named? }
    private struct Track: Decodable { let id: Int; let title: String; let artist: Named?; let album: Album? }

    private struct ITunesPage: Decodable { let results: [ITunesItem] }
    private struct ITunesItem: Decodable {
        let collectionId: Int?
        let trackId: Int?
        let collectionName: String?
        let trackName: String?
        let artistName: String?
        let artworkUrl100: String?
    }

    private static let maxAge: TimeInterval = 24 * 3600
    private static let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=#"))

    // MARK: Artists and albums

    static func artistsAndAlbums(_ term: String) async -> [PublicMusic.Pick] {
        let key = "deezer-artists-albums-v1-" + term.lowercased()
        if let cached = await PublicMusic.cachedValue([PublicMusic.Pick].self, key, maxAge: maxAge) { return cached }

        async let artists = items(Artist.self, "artist", term, limit: 8)
        async let albums = items(Album.self, "album", term, limit: 10)
        let foundArtists = await artists
        let foundAlbums = await albums

        var picks: [PublicMusic.Pick] = []
        if foundArtists != nil || foundAlbums != nil {
            picks += (foundArtists ?? []).map {
                PublicMusic.Pick(kind: .artist, mbid: "", title: $0.name, artist: nil, artistMbid: nil, year: nil, tags: [],
                                 image: $0.pictureBig.flatMap(URL.init(string:)), sourceId: "dz-\($0.id)")
            }
            picks += (foundAlbums ?? []).map {
                PublicMusic.Pick(kind: .album, mbid: "", title: $0.title, artist: $0.artist?.name, artistMbid: nil, year: nil, tags: [],
                                 coverFile: $0.coverBig.flatMap(URL.init(string:)), sourceId: "dz-\($0.id)")
            }
        } else {
            picks = await iTunesAlbums(term)
        }
        if !picks.isEmpty { PublicMusic.save(picks, key) }
        return picks
    }

    // MARK: Songs

    static func songs(_ term: String) async -> [PublicMusic.SongPick] {
        let key = "deezer-songs-v2-" + term.lowercased()
        if let cached = await PublicMusic.cachedValue([PublicMusic.SongPick].self, key, maxAge: maxAge) { return cached }

        var picks: [PublicMusic.SongPick]
        if let tracks = await items(Track.self, "track", term, limit: 25) {
            picks = tracks.map {
                PublicMusic.SongPick(id: "dz-\($0.id)", title: $0.title, artist: $0.artist?.name ?? "", artistMbid: nil,
                                     album: $0.album?.title, year: nil,
                                     albumSourceId: $0.album.map { "dz-\($0.id)" },
                                     albumCover: $0.album?.coverBig.flatMap(URL.init(string:)))
            }
        } else {
            picks = await iTunesSongs(term)
        }

        // The same song from several albums is shown once.
        var seen = Set<String>()
        picks = picks.filter { seen.insert(ArtistNames.key($0.title) + "|" + ArtistNames.key($0.artist)).inserted }
        picks = Array(picks.prefix(25))
        if !picks.isEmpty { PublicMusic.save(picks, key) }
        return picks
    }

    // MARK: Albums that aren't on MusicBrainz

    /// Whether an album id came from Deezer or iTunes (rather than being a MusicBrainz release group).
    static func isSourceId(_ id: String) -> Bool { id.hasPrefix("dz-") || id.hasPrefix("it-") }

    private struct AlbumTrack: Decodable { let title: String; let duration: Int?; let trackPosition: Int?; let diskNumber: Int? }
    private struct ITunesTrack: Decodable {
        let wrapperType: String?
        let trackName: String?
        let trackNumber: Int?
        let discNumber: Int?
        let trackTimeMillis: Int?
    }
    private struct ITunesTracks: Decodable { let results: [ITunesTrack] }

    /// The songs on a Deezer or iTunes album; nil when the lookup failed (try again), empty when it has none.
    static func tracklist(sourceId: String) async -> [PublicMusic.Track]? {
        let key = "source-tracks-v1-" + sourceId
        if let cached = await PublicMusic.cachedValue([PublicMusic.Track].self, key, maxAge: 30 * 24 * 3600) { return cached }
        let id = String(sourceId.dropFirst(3))
        var tracks: [PublicMusic.Track]?
        if sourceId.hasPrefix("dz-") {
            if let url = URL(string: "https://api.deezer.com/album/\(id)/tracks?limit=200"),
               let data = await PublicMusic.request(url).data,
               let page = decode(Page<AlbumTrack>.self, from: data) {
                tracks = (page.data ?? []).enumerated().map { index, track in
                    PublicMusic.Track(disc: track.diskNumber ?? 1, number: track.trackPosition ?? index + 1,
                                      title: track.title, lengthMs: track.duration.map { $0 * 1000 })
                }
            }
        } else if let url = URL(string: "https://itunes.apple.com/lookup?id=\(id)&entity=song&limit=200"),
                  let data = await PublicMusic.request(url).data,
                  let page = try? JSONDecoder().decode(ITunesTracks.self, from: data) {
            tracks = page.results.filter { $0.wrapperType == "track" }.enumerated().compactMap { index, track in
                track.trackName.map {
                    PublicMusic.Track(disc: track.discNumber ?? 1, number: track.trackNumber ?? index + 1,
                                      title: $0, lengthMs: track.trackTimeMillis)
                }
            }
        }
        if let tracks, !tracks.isEmpty { PublicMusic.save(tracks, key) }
        return tracks
    }

    /// An album's Deezer id ("dz-…"), found by its artist and title, for albums MusicBrainz doesn't know.
    static func albumSourceId(artist: String, title: String) async -> String? {
        guard let albums = await items(Album.self, "album", "\(artist) \(title)", limit: 10) else { return nil }
        let wanted = ArtistNames.key(title), wantedArtist = ArtistNames.key(artist)
        let match = albums.first { ArtistNames.key($0.title) == wanted && ArtistNames.key($0.artist?.name ?? "") == wantedArtist }
            ?? albums.first { ArtistNames.key($0.title) == wanted }
        return match.map { "dz-\($0.id)" }
    }

    // MARK: Deezer

    /// The results of one Deezer search; nil when Deezer could not answer (an error or no connection), empty when it found nothing.
    private static func items<T: Decodable>(_ type: T.Type, _ kind: String, _ term: String, limit: Int) async -> [T]? {
        let query = term.addingPercentEncoding(withAllowedCharacters: allowed) ?? term
        guard let url = URL(string: "https://api.deezer.com/search/\(kind)?q=\(query)&limit=\(limit)"),
              let data = await PublicMusic.request(url).data,
              let page = decode(Page<T>.self, from: data) else { return nil }
        return page.data
    }

    // MARK: iTunes (fallback)

    private static func iTunesAlbums(_ term: String) async -> [PublicMusic.Pick] {
        guard let items = await iTunes("album", term, limit: 10) else { return [] }
        return items.compactMap { item in
            guard let id = item.collectionId, let title = item.collectionName else { return nil }
            return PublicMusic.Pick(kind: .album, mbid: "", title: title, artist: item.artistName, artistMbid: nil, year: nil, tags: [],
                                    coverFile: item.artworkUrl100.flatMap { URL(string: $0.replacingOccurrences(of: "100x100bb", with: "600x600bb")) },
                                    sourceId: "it-\(id)")
        }
    }

    private static func iTunesSongs(_ term: String) async -> [PublicMusic.SongPick] {
        guard let items = await iTunes("song", term, limit: 25) else { return [] }
        return items.compactMap { item in
            guard let id = item.trackId, let title = item.trackName else { return nil }
            return PublicMusic.SongPick(id: "it-\(id)", title: title, artist: item.artistName ?? "", artistMbid: nil,
                                        album: item.collectionName, year: nil,
                                        albumSourceId: item.collectionId.map { "it-\($0)" },
                                        albumCover: item.artworkUrl100.flatMap { URL(string: $0.replacingOccurrences(of: "100x100bb", with: "600x600bb")) })
        }
    }

    private static func iTunes(_ entity: String, _ term: String, limit: Int) async -> [ITunesItem]? {
        let query = term.addingPercentEncoding(withAllowedCharacters: allowed) ?? term
        guard let url = URL(string: "https://itunes.apple.com/search?term=\(query)&entity=\(entity)&limit=\(limit)"),
              let data = await PublicMusic.request(url).data,
              let page = decode(ITunesPage.self, from: data) else { return nil }
        return page.results
    }

    // MARK: Plumbing

    /// Deezer writes its keys in snake_case ("picture_big"); the properties above are camelCase.
    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(type, from: data)
    }
}
