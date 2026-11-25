import Foundation
import SwiftUI

/// What a mix should sound like. Mixtapes are recipes with a name; the dial makes one from where you put it.
struct MixRecipe: Codable, Sendable, Hashable {
    /// 0 calm … 1 energetic.
    var energy: Double = 0.5
    /// 0 dark … 1 bright.
    var mood: Double = 0.5
    /// 0 your favorites and what's on repeat … 1 songs you rarely or never play.
    var newness: Double = 0.3
    /// Decades to include (1990 for the 90s); empty means any.
    var decades: [Int] = []
    var genres: [String] = []
    /// Artists whose albums count as these genres, so a whole album lands in it even when only some songs are tagged.
    var artistIds: [String]? = nil
    /// A sound to describe to AudioMuse, overriding the words made from energy and mood.
    var sound: String? = nil
    /// Only songs you haven't played since then (for "forgotten favorites").
    var notPlayedSinceMonths: Int? = nil
    /// For a genre mixtape: the genre as you'd say it. A song belongs to it only if its first (main) genre tag is that genre.
    var family: String? = nil
    /// The most songs to include: a mixtape holds everything that fits, shuffled.
    var length = 500

    /// Words for AudioMuse's sound search, from the feel.
    var soundWords: String {
        if let sound { return sound }
        let energyWords = energy < 0.34 ? "calm relaxed mellow soft" : energy < 0.67 ? "groovy mid-tempo steady" : "energetic upbeat powerful driving"
        let moodWords = mood < 0.34 ? "dark moody melancholic" : mood < 0.67 ? "warm" : "happy bright uplifting"
        return "\(moodWords) \(energyWords)"
    }

    /// A plain description of the selection ("Calm, bright, mostly songs you love, from the 2000s").
    var summary: String {
        var parts: [String] = []
        parts.append(energy < 0.34 ? "Calm" : energy < 0.67 ? "Steady" : "Energetic")
        parts.append(mood < 0.34 ? "dark" : mood < 0.67 ? "warm" : "bright")
        parts.append(newness < 0.34 ? "songs you love" : newness < 0.67 ? "a mix of favorites and new" : "songs new to you")
        if !genres.isEmpty { parts.append(genres.prefix(3).joined(separator: ", ")) }
        if !decades.isEmpty { parts.append("from the " + decades.sorted().map(DecadeView.name).joined(separator: " and ")) }
        return parts.joined(separator: ", ")
    }
}

/// A named, ready-made mix, with the songs found for it today.
struct Mixtape: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let recipe: MixRecipe
    /// Colors for the cover, from the feel.
    let palette: [String]
    var tracks: [BaseItem] = []

    /// Album covers for the collage (from your library), when known before the songs are picked.
    var covers: [String] = []

    var colors: [Color] { palette.compactMap(Color.init(hex:)) }
    /// Four covers for the collage.
    var coverIds: [String] {
        if !covers.isEmpty { return covers }
        var seen = Set<String>()
        return tracks.map(\.imageItemId).filter { seen.insert($0).inserted }.prefix(4).map { $0 }
    }
}

enum MixEngine {
    // MARK: Building a mix

    /// Finds songs for a recipe in your library. Moods (a sound) ask AudioMuse; decades and genres ask your library
    /// directly, so they include every song that fits, not just the few that also matched a sound.
    /// Hidden songs are left out and the same artist never plays twice in a row.
    @MainActor
    static func build(_ recipe: MixRecipe, client: JellyfinClient, audioMuse: AudioMuse?, isHidden: (String) -> Bool) async -> [BaseItem] {
        let years = recipe.decades.flatMap { Array($0...($0 + 9)) }
        var pool: [BaseItem] = []
        // How closely each song fits the sound asked for (from AudioMuse), scaled 0 to 1.
        var fit: [String: Double] = [:]
        if let sound = recipe.sound, let audioMuse, audioMuse.canSearchBySound {
            let scored = (try? await audioMuse.scoredSongs(matching: sound, limit: 300)) ?? []
            pool = scored.map(\.item)
            let values = scored.compactMap(\.similarity)
            if let low = values.min(), let high = values.max(), high > low {
                for entry in scored { if let value = entry.similarity { fit[entry.item.id] = (value - low) / (high - low) } }
            }
        } else if recipe.sound != nil || (recipe.genres.isEmpty && years.isEmpty) {
            // A mood without AudioMuse: genres that fit the feel.
            let genres = (try? await client.genres()) ?? []
            let wanted = feelGenres(recipe)
            let names = genres.filter { genre in wanted.contains { genre.name.localizedCaseInsensitiveContains($0) } }.map(\.name)
            pool = (try? await client.songs(genres: names, years: years, limit: 1000)) ?? []
        } else {
            // A decade or genre: every song in your library that fits.
            if recipe.genres.isEmpty, !years.isEmpty {
                // A decade: every song from its albums, not only the few songs that carry the year themselves.
                pool = (try? await client.songsFromYears(years, limit: 1500)) ?? []
            } else {
                pool = (try? await client.songs(genres: recipe.genres, years: years, limit: recipe.family == nil ? 600 : 1200)) ?? []
            }
            // A song tagged with several genres is in the first one only, so "Rock" is rock, not everything that mentions it.
            if let family = recipe.family {
                pool = pool.filter { song in (song.genres?.first).map { GenreNames.canonical($0).contains(family) } ?? false }
            }
            if let artistIds = recipe.artistIds, !artistIds.isEmpty {
                pool += (try? await client.songs(albumArtistIds: artistIds, years: years, limit: 400)) ?? []
            }
        }

        // Play counts and last-played dates, which sound search results don't carry (only needed for "forgotten").
        if recipe.notPlayedSinceMonths != nil, pool.contains(where: { $0.userData == nil }),
           let detailed = try? await client.items(ids: Array(Set(pool.map(\.id)).prefix(500))) {
            let byId = Dictionary(detailed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            pool = pool.map { byId[$0.id] ?? $0 }
        }

        var seen = Set<String>()
        var songs = pool.filter { song in
            guard seen.insert(song.id).inserted, !isHidden(song.id) else { return false }
            if let months = recipe.notPlayedSinceMonths {
                let cutoff = Calendar.current.date(byAdding: .month, value: -months, to: .now) ?? .now
                guard song.plays >= 2, let last = song.userData?.lastPlayed, last < cutoff else { return false }
            }
            return true
        }
        // Familiar or new first, with some chance so every time is different; then spread artists apart.
        songs.sort { score($0, recipe, fit: fit[$0.id]) > score($1, recipe, fit: fit[$1.id]) }
        // A mood is its closest songs, not everything the search could dig up.
        let count = fit.isEmpty ? recipe.length : min(recipe.length, 150)
        return spaced(Array(songs.prefix(count)).shuffled())
    }

    /// Genre words that fit a feel, for moods on a server without AudioMuse's sound search.
    private static func feelGenres(_ recipe: MixRecipe) -> [String] {
        switch (recipe.energy, recipe.mood) {
        case (..<0.4, ..<0.4): return ["ambient", "blues", "folk", "classical", "singer-songwriter", "soul", "downtempo"]
        case (..<0.4, _): return ["acoustic", "jazz", "chill", "lo-fi", "soul", "folk", "bossa", "easy listening"]
        case (0.7..., ..<0.4): return ["metal", "industrial", "punk", "hardcore", "rock", "drum", "trap"]
        case (0.7..., _): return ["dance", "pop", "electronic", "funk", "disco", "hip hop", "house", "latin"]
        default: return ["pop", "rock", "indie", "r&b", "soul", "alternative", "singer-songwriter"]
        }
    }

    private static func score(_ song: BaseItem, _ recipe: MixRecipe, fit: Double? = nil) -> Double {
        let familiar = min(Double(song.plays), 30) / 30 + (song.userData?.isFavorite == true ? 0.5 : 0)
        let wanted = 1 - recipe.newness
        let preference = wanted * familiar + (1 - wanted) * (1 - familiar)
        // For a sound, how well it fits matters as much as whether you know it.
        guard let fit else { return preference + Double.random(in: 0..<0.35) }
        return 0.55 * fit + 0.45 * preference + Double.random(in: 0..<0.2)
    }

    /// Reorders so the same artist doesn't play twice in a row.
    static func spaced(_ songs: [BaseItem]) -> [BaseItem] {
        var remaining = songs
        var result: [BaseItem] = []
        while !remaining.isEmpty {
            let last = result.last.map { ArtistNames.key(ArtistNames.primary($0.albumArtist ?? $0.artistLine)) }
            let index = remaining.firstIndex { ArtistNames.key(ArtistNames.primary($0.albumArtist ?? $0.artistLine)) != last } ?? 0
            result.append(remaining.remove(at: index))
        }
        return result
    }
}

/// The moods behind the daily mixes: a name, the feel in words for AudioMuse's sound search, and colors.
enum MixCatalog {
    struct Mood { let id: String; let title: String; let subtitle: String; let sound: String; let palette: [String] }

    /// Moods by how songs sound (AudioMuse).
    static let moods: [Mood] = [
        Mood(id: "chill", title: "Chill", subtitle: "Relaxed and laid back", sound: "relaxed chill laid back mellow", palette: ["#21787A", "#8FCC9E"]),
        Mood(id: "feelgood", title: "Feel Good", subtitle: "Happy and sunny", sound: "happy cheerful sunny feel good", palette: ["#F28C33", "#F2CC59"]),
        Mood(id: "energy", title: "Energy", subtitle: "Upbeat and powerful", sound: "energetic upbeat powerful fast", palette: ["#BF3333", "#F29933"]),
        Mood(id: "party", title: "Party", subtitle: "Danceable, all night", sound: "danceable party groove club", palette: ["#8C2680", "#4073E6"]),
        Mood(id: "latenight", title: "Late Night", subtitle: "Dark and smooth", sound: "late night dark smooth atmospheric", palette: ["#1A1A40", "#664D99"]),
        Mood(id: "focus", title: "Focus", subtitle: "Calm, few words", sound: "calm instrumental ambient focus", palette: ["#293D73", "#6B8CCC"]),
        Mood(id: "romantic", title: "Romantic", subtitle: "Tender and soulful", sound: "romantic tender soulful love", palette: ["#99264D", "#E6737F"]),
        Mood(id: "heartbreak", title: "Heartbreak", subtitle: "Sad and emotional", sound: "sad melancholic emotional heartbreak ballad", palette: ["#333859", "#737FA6"]),
        Mood(id: "workout", title: "Workout", subtitle: "Hard and fast", sound: "intense aggressive hard fast workout", palette: ["#2B1A1A", "#C2412D"]),
        Mood(id: "roadtrip", title: "Road Trip", subtitle: "Driving and anthemic", sound: "driving anthemic upbeat road trip", palette: ["#E3683F", "#3C6E9E"]),
        Mood(id: "summer", title: "Summer", subtitle: "Bright and tropical", sound: "summer tropical sunny bright", palette: ["#F4C95D", "#2E9E8F"]),
        Mood(id: "rainy", title: "Rainy Day", subtitle: "Mellow and grey", sound: "rainy mellow acoustic soft melancholic", palette: ["#4A5568", "#9AA7B8"]),
        Mood(id: "groove", title: "Groove", subtitle: "Funky, with bass", sound: "funky groovy bass rhythm", palette: ["#7A4FB5", "#F2A83B"]),
        Mood(id: "dinner", title: "Dinner Party", subtitle: "Smooth and warm", sound: "smooth jazzy warm sophisticated", palette: ["#5C3A21", "#D9A066"]),
        Mood(id: "sleep", title: "Sleep", subtitle: "Soft and quiet", sound: "ambient soft quiet sleep peaceful", palette: ["#0F1A2E", "#3A4F7A"]),
    ]

    /// Two colors per genre, always the same for the same one.
    static let palettes: [[String]] = [
        ["#8C3380", "#F28066"], ["#264D99", "#59BFD9"], ["#99401A", "#F2B24D"], ["#26665A", "#99D98C"],
        ["#592633", "#D95966"], ["#333366", "#8C73D9"], ["#80592A", "#D9BF80"], ["#1F4D73", "#F2A83B"],
    ]
}

/// The mixtapes, like Spotify's daily mixes: the moods your library fits best, each a fixed set of songs for the day.
/// Built once a day (about fifteen sound searches on the server) and saved, so opening Radio costs nothing,
/// and the same on every device: the picks use the date, not luck.
enum DailyMixes {
    struct Day: Codable, Sendable, Equatable {
        var day: String
        var mixes: [Mixtape]
    }

    private static let key = "daily-mixes-v3"
    static let mixCount = 8
    static let songsPerMix = 40

    /// Today as "2026-11-05", in the phone's own calendar.
    static var today: String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        // The "v3" marks the mixtape kinds and picking in use; mixtapes saved with an older tag are replaced.
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0) + "-v3"
    }

    /// The saved mixes, whichever day they are from (so the shelf is never empty while today's are being made).
    static func saved() -> [Mixtape] { Snapshots.peek(Day.self, key)?.mixes ?? [] }

    // MARK: Shared through the server

    /// Each mixtape is saved on the server as a playlist named "Dial Mixtape 11 · Chill · Relaxed and laid back · 2026-11-05-v3"
    /// (rank, title, line under it, day), so the first device to make today's mixtapes does the work and every other
    /// device, and any other Jellyfin app, just reads them. Mixes made from your listening take ranks 1 to 9, moods start at 11.
    /// Yesterday's are removed when new ones are made. Dial keeps them out of its own playlist lists.
    static let playlistPrefix = "Dial Mixtape "

    /// Playlists that are not yours: Dial's shared mixtapes, and the ones AudioMuse's clustering makes on its own
    /// (it ends their names with "_automatic"). They stay on the server but out of Dial's playlist lists.
    static func isGenerated(_ name: String) -> Bool {
        name.hasPrefix(playlistPrefix) || name.lowercased().contains("_automatic")
    }
    private static let separator = " \u{00B7} "
    private static let moodRankStart = 11

    private static func parse(_ name: String) -> (rank: Int, title: String, subtitle: String, day: String)? {
        guard name.hasPrefix(playlistPrefix) else { return nil }
        let parts = name.dropFirst(playlistPrefix.count).components(separatedBy: separator)
        guard let rank = parts.first.flatMap({ Int($0) }) else { return nil }
        // The first version of the name had no line under the title.
        if parts.count == 4 { return (rank, parts[1], parts[2], parts[3]) }
        if parts.count == 3 { return (rank, parts[1], "", parts[2]) }
        return nil
    }

    /// Today's mixtapes as the server has them (empty if no device has made them yet), and older ones to clean up.
    private static func fromServer(client: JellyfinClient, isHidden: (String) -> Bool) async -> (mixes: [Mixtape], stale: [String]) {
        guard let all = try? await client.playlists(fresh: true) else { return ([], []) }
        let mine = all.compactMap { item in parse(item.name).map { (item: item, rank: $0.rank, title: $0.title, subtitle: $0.subtitle, day: $0.day) } }
        let current = mine.filter { $0.day == today }.sorted { $0.rank < $1.rank }
        let stale = mine.filter { $0.day != today }.map(\.item.id)
        var loaded: [(rank: Int, mixtape: Mixtape)] = []
        await withTaskGroup(of: (Int, Mixtape)?.self) { group in
            for entry in current {
                group.addTask {
                    guard let songs = try? await client.playlistItems(entry.item.id), songs.count >= 12 else { return nil }
                    let mood = MixCatalog.moods.first { $0.title == entry.title }
                    let id = mood.map { "daily-\($0.id)" } ?? PersonalMixes.id(forTitle: entry.title)
                    let hashed = MixCatalog.palettes[abs(entry.title.unicodeScalars.reduce(0) { $0 + Int($1.value) }) % MixCatalog.palettes.count]
                    var seen = Set<String>()
                    let covers = songs.map(\.imageItemId).filter { seen.insert($0).inserted }.prefix(4)
                    return (entry.rank, Mixtape(id: id, title: entry.title, subtitle: entry.subtitle.isEmpty ? (mood?.subtitle ?? "") : entry.subtitle,
                                                recipe: mood.map { MixRecipe(newness: 0.45, sound: $0.sound) } ?? MixRecipe(newness: 0.45),
                                                palette: mood?.palette ?? PersonalMixes.palettes[entry.title] ?? hashed,
                                                tracks: songs, covers: Array(covers)))
                }
            }
            for await result in group { if let result { loaded.append((result.0, result.1)) } }
        }
        let sorted = loaded.sorted { $0.rank < $1.rank }.map(\.mixtape)
        return (sorted.map { mix in
            var copy = mix
            copy.tracks = mix.tracks.filter { !isHidden($0.id) }
            return copy
        }, stale)
    }

    /// The songs that were in these playlists (yesterday's mixtapes), so today's can rest them.
    private static func songIds(ofPlaylists ids: [String], client: JellyfinClient) async -> Set<String> {
        var found = Set<String>()
        await withTaskGroup(of: [String].self) { group in
            for id in ids.prefix(24) { group.addTask { ((try? await client.playlistItems(id)) ?? []).map(\.id) } }
            for await songs in group { found.formUnion(songs) }
        }
        return found
    }

    /// Saves mixtapes as playlists: the ones made from your listening first, then the moods.
    private static func publish(personal: [Mixtape], moods: [Mixtape], client: JellyfinClient) async {
        func save(_ mix: Mixtape, rank: Int) async {
            let subtitle = mix.subtitle.replacingOccurrences(of: separator, with: ", ")
            let name = "\(playlistPrefix)\(rank)\(separator)\(mix.title)\(separator)\(subtitle)\(separator)\(today)"
            _ = try? await client.createPlaylist(named: name, with: mix.tracks.map(\.id))
        }
        for (index, mix) in personal.enumerated() { await save(mix, rank: index + 1) }
        for (index, mix) in moods.enumerated() { await save(mix, rank: moodRankStart + index) }
    }

    /// The work being done right now (reading or making today's mixtapes), so Home and Radio asking at once share it.
    @MainActor private static var running: Task<[Mixtape], Never>?

    @MainActor
    static func load(client: JellyfinClient, audioMuse: AudioMuse?, history: ListeningHistory?,
                     isHidden: @escaping (String) -> Bool, onUpdate: ([Mixtape]) -> Void) async {
        // The saved shelf shows at once; the check for the plugin comes after.
        let saved = await Snapshots.load(Day.self, key)
        if let saved, !saved.mixes.isEmpty {
            onUpdate(saved.mixes)
            // Today is only done once it has the plugin's made-for-you mixes (a day saved without them is asked for again).
            if saved.day == today, saved.mixes.contains(where: { !$0.id.hasPrefix("daily-") }) { return }
        }
        // Mixtapes come with the Dial plugin: without it there are none.
        let pluginThere = await client.hasDialPlugin()
        guard pluginThere else {
            if saved != nil { Snapshots.remove(key); onUpdate([]) }
            return
        }
        let task = running ?? Task { () -> [Mixtape] in
            // Another device may have made today's already, or some of them.
            var shared = await fromServer(client: client, isHidden: isHidden)
            // Made-for-you mixtapes come only from the Dial plugin; the apps never make them. Only the moods may be made here.
            shared.mixes = shared.mixes.filter { $0.id.hasPrefix("daily-") }
            // The plugin makes them on the first ask (it answers "not yet" meanwhile): ask again every few seconds for a minute.
            var madeByPlugin = await client.dialMixtapes()
            var attempts = 0
            while madeByPlugin == nil, attempts < 6, !Task.isCancelled {
                attempts += 1
                try? await Task.sleep(for: .seconds(10))
                madeByPlugin = await client.dialMixtapes()
            }
            if let made = madeByPlugin, !made.isEmpty {
                var fromPlugin: [Mixtape] = []
                for mix in made {
                    guard let songs = try? await client.items(ids: mix.trackIds) else { continue }
                    let tracks = songs.filter { !isHidden($0.id) }
                    guard tracks.count >= 12 else { continue }
                    fromPlugin.append(Mixtape(id: mix.id, title: mix.title, subtitle: mix.subtitle, recipe: MixRecipe(newness: 0.45),
                                              palette: mix.palette, tracks: tracks, covers: mix.coverIds))
                }
                shared.mixes = fromPlugin + shared.mixes
            }
            let hasMoods = shared.mixes.contains { $0.id.hasPrefix("daily-") }
            let canMakeMoods = audioMuse?.canSearchBySound == true
            if hasMoods || !canMakeMoods {
                for id in shared.stale { try? await client.deleteItem(id) }
                return shared.mixes
            }
            // The mood mixtapes are missing and this device can make them. Yesterday's songs rest for a day.
            let avoid = await songIds(ofPlaylists: shared.stale, client: client)
            for id in shared.stale { try? await client.deleteItem(id) }
            let listening = await Listening.load(client: client, history: history)
            var moods: [Mixtape] = []
            if let audioMuse {
                moods = await build(client: client, audioMuse: audioMuse, listening: listening, isHidden: isHidden, avoid: avoid)
            }
            guard !moods.isEmpty else { return shared.mixes }
            // Someone may have finished while this one was working: use theirs, so every device matches.
            let again = await fromServer(client: client, isHidden: isHidden)
            if again.mixes.contains(where: { $0.id.hasPrefix("daily-") }) { moods = [] }
            await publish(personal: [], moods: moods, client: client)
            return shared.mixes.filter { !$0.id.hasPrefix("daily-") } + again.mixes.filter { $0.id.hasPrefix("daily-") } + moods
        }
        running = task
        let mixes = await task.value
        running = nil
        guard !mixes.isEmpty else { return }
        onUpdate(mixes)
        // Until the plugin has made its mixtapes, today is not done: the next visit asks again.
        let hasPersonal = mixes.contains { !$0.id.hasPrefix("daily-") }
        Snapshots.save(Day(day: hasPersonal ? today : "pending", mixes: mixes), key)
    }

    /// A number from 0 to 1 that is the same for the same day and song on every device.
    static func noise(_ id: String, _ day: String, _ salt: String) -> Double {
        var hash: UInt64 = 14695981039346656037
        for byte in (salt + day + id).utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return Double(hash % 1000) / 1000
    }

    @MainActor
    static func build(client: JellyfinClient, audioMuse: AudioMuse, listening: Listening, isHidden: (String) -> Bool,
                      avoid: Set<String>) async -> [Mixtape] {
        typealias Scored = [(item: BaseItem, similarity: Double?)]
        let day = today

        // Every mood is searched; the ones this library fits best become the day's mixes.
        var searched: [(index: Int, songs: Scored)] = []
        await withTaskGroup(of: (Int, Scored).self) { group in
            for (index, mood) in MixCatalog.moods.enumerated() {
                group.addTask { @MainActor in
                    (index, (try? await audioMuse.scoredSongs(matching: mood.sound, limit: 120)) ?? [])
                }
            }
            for await result in group { searched.append((result.0, result.1)) }
        }
        func fit(_ songs: Scored) -> Double? {
            let top = songs.prefix(20).compactMap(\.similarity)
            return top.count >= 8 ? top.reduce(0, +) / Double(top.count) : nil
        }
        let usable = searched.filter { $0.songs.count >= 12 }.sorted { $0.index < $1.index }
        let fits = usable.map { fit($0.songs) }
        var ranked = usable.map(\.self)
        if !fits.isEmpty, fits.allSatisfy({ $0 != nil }) {
            ranked = zip(usable, fits).sorted { ($0.1 ?? 0) > ($1.1 ?? 0) }.map(\.0)
        }

        var taken = Set<String>()
        var mixes: [Mixtape] = []
        for entry in ranked {
            guard mixes.count < mixCount else { break }
            let mood = MixCatalog.moods[entry.index]
            let values = entry.songs.compactMap(\.similarity)
            let low = values.min() ?? 0
            let span = (values.max() ?? 0) - low
            func score(_ song: (item: BaseItem, similarity: Double?)) -> Double {
                let closeness = (song.similarity.map { span > 0 ? ($0 - low) / span : 0.5 }) ?? 0.5
                // Closeness leads; the day's chance and a rest for yesterday's songs make each day different.
                return closeness + 0.2 * noise(song.item.id, day, mood.id) - (avoid.contains(song.item.id) ? 0.25 : 0)
            }
            // The closest 80 of the 120 found, without what you played in the last days or an earlier mixtape has.
            let candidates = entry.songs.prefix(80)
                .filter { !isHidden($0.item.id) && !listening.heard($0.item.id, within: 3) && !taken.contains($0.item.id) }
                .sorted { score($0) > score($1) }
            // Your library is music you chose, so this brings back what you have not heard in a while: some songs you
            // play now, more that you loved and forgot, and some you own but never played.
            let current = candidates.filter { listening.isKnown($0.item.id) && listening.heard($0.item.id, within: 30) }
            let forgotten = candidates.filter { listening.isKnown($0.item.id) && !listening.heard($0.item.id, within: 60) }
            let unplayed = candidates.filter { !listening.isKnown($0.item.id) }
            var picks = Array(current.prefix(songsPerMix * 3 / 10)) + Array(forgotten.prefix(songsPerMix * 4 / 10)) + Array(unplayed.prefix(songsPerMix * 3 / 10))
            if picks.count < songsPerMix {
                let have = Set(picks.map(\.item.id))
                picks += candidates.filter { !have.contains($0.item.id) }.prefix(songsPerMix - picks.count)
            }
            guard picks.count >= 12 else { continue }
            let songs = MixEngine.spaced(picks.map(\.item).sorted { noise($0.id, day, "order") < noise($1.id, day, "order") })
            taken.formUnion(songs.map(\.id))
            var seen = Set<String>()
            let covers = songs.map(\.imageItemId).filter { seen.insert($0).inserted }.prefix(4)
            mixes.append(Mixtape(id: "daily-\(mood.id)", title: mood.title, subtitle: mood.subtitle,
                                 recipe: MixRecipe(newness: 0.45, sound: mood.sound), palette: mood.palette,
                                 tracks: songs, covers: Array(covers)))
        }
        return mixes
    }
}

/// The decades and genres on Radio: plain filters, there the moment Radio opens. The server lists the years and
/// genres it has (one small request each; nothing is counted or sampled) and the songs are only looked up when
/// you open one. A decade appears only if your library has music from it.
enum RadioFilters {
    struct Sections: Codable, Sendable, Equatable {
        var decades: [Mixtape] = []
        var genres: [Mixtape] = []
        var isEmpty: Bool { decades.isEmpty && genres.isEmpty }
    }

    private static let key = "radio-filters-v5"

    static func saved() -> Sections { Snapshots.peek(Sections.self, key) ?? Sections() }

    @MainActor
    static func load(client: JellyfinClient, onUpdate: (Sections) -> Void) async {
        if let saved = await Snapshots.load(Sections.self, key), !saved.isEmpty {
            onUpdate(saved)
            if Freshness.isFresh(key, maxAge: 6 * 3600) { return }
        }
        let built = await build(client: client)
        guard !built.isEmpty else { return }
        onUpdate(built)
        Snapshots.save(built, key)
        Freshness.mark(key)
    }

    static func build(client: JellyfinClient) async -> Sections {
        async let decades = buildDecades(client: client)
        async let genres = buildGenres(client: client)
        return await Sections(decades: decades, genres: genres)
    }

    /// The decades the library has music from, newest first.
    private static func buildDecades(client: JellyfinClient) async -> [Mixtape] {
        let starts = Set(((try? await client.libraryYears()) ?? []).filter { $0 >= 1900 }.map { $0 / 10 * 10 })
        // If the server cannot list its years there are no decades: none are made up.
        return starts.sorted(by: >).map { decade in
            Mixtape(id: "decade-\(decade)", title: "The \(DecadeView.name(decade))", subtitle: "\(decade) to \(decade + 9)",
                    recipe: MixRecipe(newness: 0.45, decades: [decade]), palette: [])
        }
    }

    /// The server's genres, grouped by meaning ("Hip-Hop", "hip hop" and "Rap/Hip Hop" together); the well-known ones first.
    private static func buildGenres(client: JellyfinClient) async -> [Mixtape] {
        // Only genres that really have songs: Jellyfin also lists tags that sit on artists or on songs you no longer have.
        // A song counts for the first genre on it, the same rule the genre's mix uses to pick its songs.
        let songs = (try? await client.songsWithGenres()) ?? []
        var tagsByFamily: [String: Set<String>] = [:]
        var counts: [String: Int] = [:]
        for song in songs {
            guard let tag = song.genres?.first else { continue }
            for family in GenreNames.canonical(tag) {
                tagsByFamily[family, default: []].insert(tag)
                counts[family, default: 0] += 1
            }
        }
        let known = ["pop", "hip", "rock", "r&b", "electronic", "dance", "jazz", "soul", "latin", "classical", "country", "folk",
                     "metal", "indie", "reggae", "blues", "funk", "alternative"]
        func rank(_ family: String) -> Int { known.firstIndex { family.lowercased().contains($0) } ?? known.count }
        return counts.keys.sorted { (rank($0), -(counts[$0] ?? 0), $0) < (rank($1), -(counts[$1] ?? 0), $1) }.map { family in
            Mixtape(id: "genre-\(family)", title: family, subtitle: "Genre", recipe: MixRecipe(newness: 0.45, genres: Array(tagsByFamily[family] ?? []).sorted(), family: family),
                    palette: MixCatalog.palettes[abs(family.unicodeScalars.reduce(0) { $0 + Int($1.value) }) % MixCatalog.palettes.count])
        }
    }
}

extension Color {
    /// A color from "#RRGGBB" (the palettes in mixtapes are saved that way).
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
