import Foundation

/// What you've asked Marlo for in this session. Follow-ups adjust it ("more upbeat",
/// "add some Bad Bunny", "no more rap"); a new request replaces it.
struct DJSteering: Sendable, Equatable, Codable {
    enum Discovery: String, Sendable, Codable { case mix, familiar, new }

    /// Only these artists, until you ask for something else.
    var onlyArtists: [String] = []
    /// Mix these artists in.
    var includeArtists: [String] = []
    var excludeArtists: [String] = []
    var genres: [String] = []
    var excludeGenres: [String] = []
    var earliestYear: Int?
    var latestYear: Int?
    var energy: DJMood.Energy = .any
    /// A described sound, for AudioMuse ("rainy sunday", "summer party").
    var sound: String?
    var discovery: Discovery = .mix

    var hasRequest: Bool {
        !onlyArtists.isEmpty || !includeArtists.isEmpty || !genres.isEmpty || earliestYear != nil
            || latestYear != nil || sound != nil || energy != .any
    }

    /// Whether a song fits what you've asked for (years, and nothing you said no to).
    func allows(_ track: BaseItem) -> Bool {
        if let year = track.productionYear {
            if let earliestYear, year < earliestYear { return false }
            if let latestYear, year > latestYear { return false }
        }
        if !excludeArtists.isEmpty {
            let artist = ArtistNames.key(ArtistNames.primary(track.albumArtist ?? track.artistLine))
            if excludeArtists.contains(where: { ArtistNames.key($0) == artist }) { return false }
        }
        if !excludeGenres.isEmpty, let genres = track.genres {
            let lower = Set(genres.map { $0.lowercased() })
            if excludeGenres.contains(where: { lower.contains($0.lowercased()) }) { return false }
        }
        return true
    }

    /// Applies what the listener just said. A follow-up keeps everything else.
    mutating func apply(_ mood: DJMood) {
        if !mood.isFollowUp { self = DJSteering() }
        if !mood.artists.isEmpty {
            if mood.onlyArtists {
                onlyArtists = mood.artists
                includeArtists = []
            } else {
                onlyArtists = []
                includeArtists = Array(Set(includeArtists + mood.artists))
            }
        }
        excludeArtists = Array(Set(excludeArtists + mood.excludedArtists))
        onlyArtists.removeAll { name in excludeArtists.contains { ArtistNames.key($0) == ArtistNames.key(name) } }
        includeArtists.removeAll { name in excludeArtists.contains { ArtistNames.key($0) == ArtistNames.key(name) } }
        if !mood.genres.isEmpty { genres = mood.genres }
        if !mood.excludedGenres.isEmpty { excludeGenres = Array(Set(excludeGenres + mood.excludedGenres)) }
        if mood.earliestYear != nil || mood.latestYear != nil {
            earliestYear = mood.earliestYear
            latestYear = mood.latestYear
        }
        if mood.energy != .any { energy = mood.energy }
        if let description = mood.description, !description.isEmpty { sound = description }
        if let wanted = mood.discovery { discovery = wanted }
    }
}

extension DJSteering {
    /// Looser versions of the request, one step further each time: first without the genre, then a few
    /// years either side, then any year. Each comes with what Marlo should tell the listener.
    func relaxations() -> [(steering: DJSteering, note: String)] {
        var out: [(DJSteering, String)] = []
        var current = self
        if !current.genres.isEmpty {
            current.genres = []
            out.append((current, "any genre"))
        }
        if current.earliestYear != nil || current.latestYear != nil {
            var wider = current
            wider.earliestYear = wider.earliestYear.map { $0 - 5 }
            wider.latestYear = wider.latestYear.map { $0 + 5 }
            out.append((wider, "a few years either side"))
            current.earliestYear = nil
            current.latestYear = nil
            out.append((current, "any year"))
        }
        return out
    }
}

/// A few songs that belong together, with the reason Marlo gives for them.
struct DJBlock: Sendable, Identifiable {
    enum Kind: String, Sendable, Codable {
        case request, onRepeat, favorites, throwback, deepCuts, newArrivals, spotlight, discovery, mood, vibe, seasonal
    }

    let id = UUID()
    let kind: Kind
    /// Shown in the player ("Throwbacks", "Spotlight: The Weeknd").
    let title: String
    let tracks: [BaseItem]
    /// True things Marlo can say about this block (used to write the line).
    let facts: [String]
    /// Whether Marlo says something before it. A block that stays in the same vibe plays on without a word.
    var speaks = true
    /// Short true sentences about the listener and the first song ("You've played this one 14 times."), for Marlo to say.
    var stats: [String] = []
}

/// Plans Marlo's session the way a radio DJ would: short themed blocks from your own listening
/// (what's on repeat, old favorites, deep cuts, new arrivals, an artist spotlight, something new),
/// each mixing something familiar with something you play less, never repeating recent songs.
@MainActor
final class DJPlanner {
    private let client: JellyfinClient
    private let history: ListeningHistory?
    private let audioMuse: AudioMuse?
    private let isHidden: (String) -> Bool
    private var libraryArtists: [BaseItem] = []
    private var recentKinds: [DJBlock.Kind] = []
    private var featuredArtists: [String] = []
    /// Songs already used this session.
    private var used = Set<String>()
    /// The vibes (AudioMuse's clusters) and where the set is now: it holds one for a couple of blocks, then moves
    /// to a neighbour, close but not the same.
    private let vibes = VibeMap()
    private var currentVibe: Int?
    private var blocksInVibe = 0
    private var visitedVibes: [Int] = []
    /// What time of day and year it is, and the songs that sound like it (cached while it stays the same).
    private var flavor = DJFlavor.now()
    private var flavorSongs: (sound: String, ids: [String])?
    private var blocksSinceSeasonal = 0

    init(client: JellyfinClient, history: ListeningHistory?, audioMuse: AudioMuse?, isHidden: @escaping (String) -> Bool) {
        self.client = client
        self.history = history
        self.audioMuse = audioMuse
        self.isHidden = isHidden
    }

    func remember(_ tracks: [BaseItem]) {
        for track in tracks { used.insert(track.id) }
    }

    /// Songs already used this session, to carry the session to another device.
    var usedIds: [String] { Array(used) }

    func remember(ids: [String]) { used.formUnion(ids) }

    // MARK: Choosing the next block

    /// Loads the slow parts ahead (the vibes, the sound of the moment) so the first change of direction does not wait for them.
    func warmUp() async {
        await vibes.loadIfNeeded(client: client)
        flavor = DJFlavor.now()
        _ = await flavorMatches()
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    /// The block with true, personal things to say about its first song: how often you played it, when you last did,
    /// when you added it, and how much of the artist you play.
    func withStats(_ block: DJBlock) async -> DJBlock {
        guard let first = block.tracks.first else { return block }
        var lines: [String] = []
        if first.plays >= 3 { lines.append("You\u{2019}ve played this one \(first.plays) times.") }
        if let last = first.userData?.lastPlayed, Date().timeIntervalSince(last) > 45 * 86400 {
            lines.append("The last time you played it was \(Self.relative.localizedString(for: last, relativeTo: .now)).")
        }
        if let added = first.added, Date().timeIntervalSince(added) < 21 * 86400 {
            lines.append("You added it \(Self.relative.localizedString(for: added, relativeTo: .now)).")
        }
        if first.userData?.isFavorite == true { lines.append("It\u{2019}s one of your favorites.") }
        if let artistId = first.primaryArtist?.id, let songs = try? await client.songs(byArtist: artistId, limit: 200), !songs.isEmpty {
            let name = DJScript.speakable(ArtistNames.primary(first.albumArtist ?? first.artistLine))
            let total = songs.reduce(0) { $0 + $1.plays }
            if total >= 15 { lines.append("\(name) is one of your most played artists: \(total) plays across \(songs.count) songs.") }
            else if songs.count >= 5 { lines.append("You have \(songs.count) songs by \(name) in your library.") }
        }
        var copy = block
        copy.stats = lines
        return copy
    }

    func nextBlock(steering: DJSteering, current: BaseItem?, quick: Bool = false) async -> DJBlock? {
        if libraryArtists.isEmpty { libraryArtists = (try? await client.distinctArtists()) ?? [] }
        let recent = await history?.recentlyPlayed(hours: 6) ?? []
        used.formUnion(recent)

        // The set holds a vibe for a while, then drifts to a neighbouring one (AudioMuse's clusters).
        if let current, steering.onlyArtists.isEmpty, let block = await vibeBlock(steering: steering, current: current, quick: quick) {
            return keep(block)
        }
        flavor = DJFlavor.now()
        // In an event season (Christmas, Halloween) every few blocks are that music.
        if steering.onlyArtists.isEmpty, !steering.hasRequest, flavor.hasEvent, blocksSinceSeasonal >= 2,
           let block = await seasonalBlock(steering) {
            return keep(block)
        }
        // Just started, nothing asked: open in a random vibe, so the set holds it for a few songs and then drifts.
        if current == nil, !steering.hasRequest, steering.onlyArtists.isEmpty,
           let block = await openingVibeBlock(steering: steering) {
            return keep(block)
        }
        // You asked for something: most blocks follow it.
        if steering.hasRequest {
            if !steering.onlyArtists.isEmpty || Double.random(in: 0..<1) < 0.75 || recentKinds.last != .request {
                if let block = await requestBlock(steering) { return keep(block) }
            }
        }
        // Otherwise a mix of your own listening, without the same kind twice in a row.
        var kinds: [DJBlock.Kind] = [.onRepeat, .favorites, .throwback, .deepCuts, .newArrivals, .spotlight, .discovery]
        if audioMuse?.canSearchBySound == true { kinds += [.mood, .mood] }
        if history?.isAvailable != true { kinds.removeAll { $0 == .onRepeat } }
        switch steering.discovery {
        case .familiar: kinds.removeAll { [.deepCuts, .discovery, .newArrivals].contains($0) }
        case .new: kinds.removeAll { [.onRepeat, .favorites, .throwback].contains($0) }
        case .mix: break
        }
        let fresh = kinds.filter { !recentKinds.suffix(2).contains($0) }.shuffled()
        for kind in fresh + kinds.shuffled() {
            if let block = await build(kind, steering: steering, current: current) { return keep(block) }
        }
        return await anything(steering)
    }

    /// A block that really answers the request. If too few songs fit, the request is loosened one step
    /// at a time and `note` says how, so the listener is told instead of getting something unrelated.
    func requestBlockRelaxing(_ steering: DJSteering) async -> (block: DJBlock, steering: DJSteering, note: String?)? {
        if libraryArtists.isEmpty { libraryArtists = (try? await client.distinctArtists()) ?? [] }
        used.formUnion(await history?.recentlyPlayed(hours: 6) ?? [])
        if let block = await requestBlock(steering, strict: true) { return (keep(block), steering, nil) }
        for step in steering.relaxations() {
            if let block = await requestBlock(step.steering, strict: true) { return (keep(block), step.steering, step.note) }
        }
        return nil
    }

    private func keep(_ block: DJBlock) -> DJBlock {
        // Something other than the drift (a request, a jump): the next drift starts from wherever the music is.
        if block.kind != .vibe { currentVibe = nil; blocksInVibe = 0 }
        recentKinds.append(block.kind)
        blocksSinceSeasonal = block.kind == .seasonal ? 0 : blocksSinceSeasonal + 1
        if recentKinds.count > 6 { recentKinds.removeFirst() }
        remember(block.tracks)
        if let artist = block.tracks.first.map({ ArtistNames.primary($0.albumArtist ?? $0.artistLine) }) {
            featuredArtists.append(ArtistNames.key(artist))
            if featuredArtists.count > 8 { featuredArtists.removeFirst() }
        }
        return block
    }

    private var length: Int { Int.random(in: 3...4) }

    /// Songs that can play now: not used this session, not hidden, fitting your requests.
    private func usable(_ songs: [BaseItem], _ steering: DJSteering) -> [BaseItem] {
        var seen = Set<String>()
        return songs.filter { !used.contains($0.id) && !isHidden($0.id) && steering.allows($0) && seen.insert($0.id).inserted }
    }

    /// One song you know well first, then ones you play less.
    private func familiarFirst(_ songs: [BaseItem], count: Int) -> [BaseItem] {
        let sorted = songs.sorted { $0.plays > $1.plays }
        guard let anchor = sorted.prefix(max(sorted.count / 3, 1)).randomElement() else { return [] }
        let rest = songs.filter { $0.id != anchor.id }.shuffled()
        return [anchor] + rest.prefix(count - 1)
    }

    private func artist(named name: String) -> BaseItem? {
        libraryArtists.first { ArtistNames.key($0.name) == ArtistNames.key(name) }
    }

    // MARK: Blocks

    private func build(_ kind: DJBlock.Kind, steering: DJSteering, current: BaseItem?) async -> DJBlock? {
        switch kind {
        case .onRepeat: return await onRepeat(steering)
        case .favorites: return await favorites(steering)
        case .throwback: return await throwback(steering)
        case .deepCuts: return await deepCuts(steering)
        case .newArrivals: return await newArrivals(steering)
        case .spotlight: return await spotlight(steering)
        case .discovery: return await discovery(steering)
        case .mood: return await moodBlock(steering)
        case .seasonal: return await seasonalBlock(steering)
        case .request: return await requestBlock(steering)
        case .vibe: return nil
        }
    }

    private func onRepeat(_ steering: DJSteering) async -> DJBlock? {
        guard let history, history.isAvailable else { return nil }
        let top = await history.topSongs(days: 14, limit: 30)
        guard !top.isEmpty, let songs = try? await client.items(ids: top.map(\.id)) else { return nil }
        let plays = Dictionary(top.map { ($0.id, $0.plays) }, uniquingKeysWith: { a, _ in a })
        let picks = Array(usable(songs, steering).shuffled().prefix(length))
        guard picks.count >= 2, let first = picks.first else { return nil }
        let count = plays[first.id] ?? 0
        return DJBlock(kind: .onRepeat, title: "On repeat", tracks: picks, facts: [
            "These are songs the listener has been playing a lot in the last two weeks.",
            count > 1 ? "The first song, \(first.name) by \(first.artistLine), has been played \(count) times in two weeks." : "",
        ].filter { !$0.isEmpty })
    }

    private func favorites(_ steering: DJSteering) async -> DJBlock? {
        guard let songs = try? await client.favoriteSongs() else { return nil }
        let picks = Array(usable(songs, steering).shuffled().prefix(length))
        guard picks.count >= 2 else { return nil }
        return DJBlock(kind: .favorites, title: "Songs you love", tracks: picks, facts: [
            "These are songs the listener marked as favorites.",
        ])
    }

    private func throwback(_ steering: DJSteering) async -> DJBlock? {
        guard let songs = try? await client.songs(sortedBy: "PlayCount", limit: 400) else { return nil }
        let monthsAgo = Calendar.current.date(byAdding: .month, value: -4, to: .now) ?? .now
        let forgotten = usable(songs, steering).filter { song in
            song.plays >= 2 && (song.userData?.lastPlayed.map { $0 < monthsAgo } ?? false)
        }
        let picks = Array(forgotten.shuffled().prefix(length))
        guard picks.count >= 2, let first = picks.first else { return nil }
        let when = first.userData?.lastPlayed.map { $0.formatted(.dateTime.month(.wide).year()) }
        return DJBlock(kind: .throwback, title: "Throwbacks", tracks: picks, facts: [
            "These are songs the listener used to play but hasn't heard in months.",
            when.map { "The listener last played \(first.name) by \(first.artistLine) in \($0)." } ?? "",
            first.productionYear.map { "\(first.name) came out in \($0)." } ?? "",
        ].filter { !$0.isEmpty })
    }

    private func deepCuts(_ steering: DJSteering) async -> DJBlock? {
        // Artists you play, songs of theirs you've never played.
        let candidates = libraryArtists.filter { !featuredArtists.contains(ArtistNames.key($0.name)) }.shuffled().prefix(4)
        for artist in candidates {
            guard let songs = try? await client.songs(sortedBy: "Random", filters: "IsUnplayed", artistId: artist.id, limit: 30) else { continue }
            let picks = Array(usable(songs, steering).prefix(length))
            if picks.count >= 2 {
                let name = ArtistNames.primary(artist.name)
                return DJBlock(kind: .deepCuts, title: "Deep cuts: \(name)", tracks: picks, facts: [
                    "These are songs by \(name) from the listener's library that they have never played.",
                ])
            }
        }
        return nil
    }

    private func newArrivals(_ steering: DJSteering) async -> DJBlock? {
        guard let albums = try? await client.recentAlbums(limit: 8) else { return nil }
        for album in albums.shuffled().prefix(3) {
            guard let tracks = try? await client.tracks(inAlbum: album.id) else { continue }
            let picks = Array(usable(tracks, steering).sorted { $0.plays < $1.plays }.prefix(length).shuffled())
            if picks.count >= 2 {
                let days = album.added.map { Calendar.current.dateComponents([.day], from: $0, to: .now).day ?? 0 }
                let when: String
                switch days {
                case .some(0): when = "today"
                case .some(1): when = "yesterday"
                case .some(let d) where d < 14: when = "\(d) days ago"
                default: when = "recently"
                }
                return DJBlock(kind: .newArrivals, title: "New in your library", tracks: picks, facts: [
                    "These songs are from \(album.name) by \(album.albumArtistLine), added to the listener's library \(when).",
                    album.productionYear.map { "\(album.name) came out in \($0)." } ?? "",
                ].filter { !$0.isEmpty })
            }
        }
        return nil
    }

    private func spotlight(_ steering: DJSteering) async -> DJBlock? {
        let candidates = libraryArtists.filter { !featuredArtists.contains(ArtistNames.key($0.name)) }.shuffled().prefix(3)
        for artist in candidates {
            guard let songs = try? await client.songs(sortedBy: "PlayCount", artistId: artist.id, limit: 40) else { continue }
            let picks = familiarFirst(usable(songs, steering), count: length)
            if picks.count >= 2 {
                let name = ArtistNames.primary(artist.name)
                var facts = ["This block is a spotlight on \(name): one song the listener knows well, then some they play less."]
                if let bio = (try? await client.details(artist.id))?.overview, let first = Self.firstSentence(of: bio) {
                    facts.append("About \(name): \(first)")
                }
                return DJBlock(kind: .spotlight, title: "Spotlight: \(name)", tracks: picks, facts: facts)
            }
        }
        return nil
    }

    private func discovery(_ steering: DJSteering) async -> DJBlock? {
        // Something you rarely or never play, like something you love.
        guard let seed = ((try? await client.favoriteSongs()) ?? []).randomElement(),
              let mix = try? await client.instantMix(for: seed.id, limit: 50) else { return nil }
        let picks = Array(usable(mix, steering).filter { $0.plays <= 1 && $0.id != seed.id }.shuffled().prefix(length))
        guard picks.count >= 2 else { return nil }
        let because = ArtistNames.primary(seed.albumArtist ?? seed.artistLine)
        return DJBlock(kind: .discovery, title: "New to you", tracks: picks, facts: [
            "These are songs the listener has rarely or never played, picked because they love \(seed.name) by \(because).",
        ])
    }

    private func moodBlock(_ steering: DJSteering) async -> DJBlock? {
        guard let audioMuse, audioMuse.canSearchBySound else { return nil }
        guard let found = try? await audioMuse.songs(matching: flavor.sound, limit: 40) else { return nil }
        let picks = familiarFirst(usable(found, steering), count: length)
        guard picks.count >= 2 else { return nil }
        return DJBlock(kind: .mood, title: flavor.title, tracks: picks, facts: flavor.facts + [
            "These songs were picked by how they sound, to fit the \(flavor.title.lowercased()) mood.",
        ])
    }

    /// Songs that sound like the time of day and year (AudioMuse), asked once per change of flavor.
    private func flavorMatches() async -> [String] {
        guard let audioMuse, audioMuse.canSearchBySound else { return [] }
        if let cached = flavorSongs, cached.sound == flavor.sound { return cached.ids }
        let ids = ((try? await audioMuse.songs(matching: flavor.sound, limit: 80)) ?? []).map(\.id)
        flavorSongs = (flavor.sound, ids)
        return ids
    }

    /// Christmas or Halloween music: songs from the library's own genres for it, and ones that sound like it.
    private func seasonalBlock(_ steering: DJSteering) async -> DJBlock? {
        guard flavor.hasEvent else { return nil }
        var pool = (try? await client.songs(genres: flavor.eventGenres, years: [], limit: 60)) ?? []
        if pool.count < 8, let audioMuse, audioMuse.canSearchBySound {
            pool += (try? await audioMuse.songs(matching: flavor.eventSound, limit: 40)) ?? []
        }
        let picks = familiarFirst(usable(pool, steering), count: length)
        guard picks.count >= 2 else { return nil }
        let name = flavor.season == .christmas ? "Christmas" : "Halloween"
        return DJBlock(kind: .seasonal, title: name, tracks: picks, facts: [
            "It is \(name) season, so these are \(name) songs.", "Say it lightly, not a full festive speech.",
        ])
    }

    // MARK: Drifting between vibes

    /// Four or five songs from the current vibe; every second block the vibe moves to a neighbour that is close
    /// (it shares the most songs with what sounds like the current song), and Marlo says so in a line.
    private func vibeBlock(steering: DJSteering, current: BaseItem, quick: Bool = false) async -> DJBlock? {
        await vibes.loadIfNeeded(client: client)
        guard vibes.isReady else { return nil }
        var vibe = currentVibe ?? vibes.vibes(containing: current.id).first
        var drifted = false
        if vibe == nil || blocksInVibe >= 2 {
            // A quick change (the DJ button) skips asking the server what sounds like the song; the vibe map decides on its own.
            let similar = quick ? [] : ((try? await client.instantMix(for: current.id, limit: 60)) ?? [])
            // Close to the current song first; the time of day and year tip it toward the right feel.
            let next = vibes.neighbour(of: vibe, similar: similar.map(\.id) + (await flavorMatches()).prefix(40), avoiding: visitedVibes.suffix(3))
            drifted = vibe != nil && next != vibe
            vibe = next
            blocksInVibe = 0
        }
        guard let vibe else { return nil }
        let count = Int.random(in: 4...5)
        var picks = familiarFirst(usable(vibes.songs(in: vibe), steering), count: count)
        if picks.count < 2 {
            // This vibe has been played out: take another one.
            guard let other = vibes.neighbour(of: vibe, similar: [], avoiding: [vibe]) else { return nil }
            picks = familiarFirst(usable(vibes.songs(in: other), steering), count: count)
            guard picks.count >= 2 else { return nil }
            currentVibe = other
            drifted = true
        } else {
            currentVibe = vibe
        }
        if let now = currentVibe, visitedVibes.last != now { visitedVibes.append(now) }
        blocksInVibe += 1
        let name = vibes.name(of: currentVibe ?? vibe)
        var facts = ["The music is moving a little: close to what was playing, but a different feel. Do not name the vibe."] + flavor.facts
        return DJBlock(kind: .vibe, title: name, tracks: picks, facts: facts, speaks: drifted)
    }

    /// The first block of a set nobody steered: a few songs from a random vibe.
    private func openingVibeBlock(steering: DJSteering) async -> DJBlock? {
        await vibes.loadIfNeeded(client: client)
        guard vibes.isReady else { return nil }
        // Start in the vibe that sounds most like now (morning bright, evening mellow, December festive), picked among the best few.
        var order = vibes.shuffledIndices()
        if let best = vibes.neighbour(of: nil, similar: await flavorMatches(), avoiding: []), let at = order.firstIndex(of: best) {
            order.remove(at: at)
            order.insert(best, at: 0)
        }
        for vibe in order {
            let picks = familiarFirst(usable(vibes.songs(in: vibe), steering), count: Int.random(in: 4...5))
            guard picks.count >= 2 else { continue }
            currentVibe = vibe
            blocksInVibe = 1
            visitedVibes = [vibe]
            return DJBlock(kind: .vibe, title: vibes.name(of: vibe), tracks: picks,
                           facts: ["Opening the set in one feel. Do not name the vibe."] + flavor.facts, speaks: false)
        }
        return nil
    }

    // MARK: What you asked for

    /// Everything that could answer a request: songs that sound like it (AudioMuse) narrowed to the
    /// genres and years asked for, topped up from the library's own genre and year search when
    /// that leaves too few. "Sad songs from the 2010s" is both at once, not either one.
    func pool(for steering: DJSteering) async -> (songs: [BaseItem], usedSound: Bool, facts: [String]) {
        if libraryArtists.isEmpty { libraryArtists = (try? await client.distinctArtists()) ?? [] }
        var facts: [String] = []
        var soundSongs: [BaseItem] = []
        var usedSound = false
        let hasFilters = !steering.genres.isEmpty || steering.earliestYear != nil || steering.latestYear != nil
        if let sound = steering.sound, let audioMuse, audioMuse.canSearchBySound,
           let found = try? await audioMuse.songs(matching: sound, limit: hasFilters ? 200 : 50) {
            soundSongs = found
            usedSound = !found.isEmpty
            facts.append("The listener asked for \(sound).")
        }
        guard hasFilters else { return (soundSongs.topShuffled(), usedSound, facts) }

        let wanted = Set(steering.genres.map { $0.lowercased() })
        let narrowed = soundSongs.filter { song in
            guard steering.allows(song) else { return false }
            guard !wanted.isEmpty else { return true }
            return (song.genres ?? []).contains { wanted.contains($0.lowercased()) }
        }
        var songs = narrowed.topShuffled()
        if narrowed.count < 6 {
            var range = DJMood()
            range.earliestYear = steering.earliestYear
            range.latestYear = steering.latestYear
            songs += (try? await client.songs(genres: steering.genres, years: range.years, limit: 60)) ?? []
        }
        if !steering.genres.isEmpty { facts.append("The listener asked for \(steering.genres.joined(separator: " and ")).") }
        if let from = steering.earliestYear, let to = steering.latestYear {
            facts.append(from == to ? "The listener asked for music from \(from)." : "The listener asked for music from \(from) to \(to).")
        }
        return (songs, usedSound, facts)
    }

    private func requestBlock(_ steering: DJSteering, strict: Bool = false) async -> DJBlock? {
        // Only these artists.
        if !steering.onlyArtists.isEmpty {
            var songs: [BaseItem] = []
            for name in steering.onlyArtists {
                guard let artist = artist(named: name) else { continue }
                songs += (try? await client.songs(sortedBy: "Random", artistId: artist.id, limit: 200)) ?? []
            }
            var picks = familiarFirst(usable(songs, steering), count: length)
            if picks.count < 2 {
                // Everything by them has played: start their songs over.
                used.subtract(songs.map(\.id))
                picks = familiarFirst(usable(songs, steering), count: length)
            }
            guard picks.count >= 1 else { return nil }
            let names = steering.onlyArtists.joined(separator: " and ")
            return DJBlock(kind: .request, title: "Only \(names)", tracks: picks, facts: [
                "The listener asked to hear only \(names).",
            ])
        }

        let found = await pool(for: steering)
        var pool = found.songs
        var title = "Your request"
        var facts = found.facts
        if found.usedSound, let sound = steering.sound { title = sound.prefix(1).uppercased() + sound.dropFirst() }
        // Artists to mix in: two of theirs in every block.
        var featured: [BaseItem] = []
        for name in steering.includeArtists {
            guard let artist = artist(named: name) else { continue }
            featured += (try? await client.songs(sortedBy: "Random", artistId: artist.id, limit: 20)) ?? []
        }
        if !steering.includeArtists.isEmpty {
            facts.append("The listener asked to add \(steering.includeArtists.joined(separator: " and ")).")
        }
        if pool.isEmpty, !strict {
            var seed = usable(featured, steering).first
            if seed == nil {
                seed = usable(((try? await client.favoriteSongs()) ?? []).shuffled(), steering).first
            }
            if let seed {
                pool = (try? await client.instantMix(for: seed.id, limit: 40)) ?? []
            }
        }
        if steering.energy != .any { facts.append("The listener wants \(steering.energy.rawValue) energy.") }

        var picks = Array(usable(pool, steering).prefix(length))
        let extra = usable(featured, steering).shuffled().prefix(2)
        if !extra.isEmpty {
            picks = Array(extra) + picks.filter { song in !extra.contains { $0.id == song.id } }
            picks = Array(picks.prefix(length))
        }
        guard picks.count >= 2 else { return nil }
        if steering.sound == nil, !steering.includeArtists.isEmpty { title = "With \(steering.includeArtists.joined(separator: " and "))" }
        return DJBlock(kind: .request, title: title, tracks: picks, facts: facts)
    }

    private func anything(_ steering: DJSteering) async -> DJBlock? {
        guard let songs = try? await client.randomSongs(limit: 40) else { return nil }
        let picks = Array(usable(songs, steering).prefix(length))
        guard !picks.isEmpty else { return nil }
        return DJBlock(kind: .discovery, title: "From your library", tracks: picks, facts: [])
    }

    private static func firstSentence(of text: String) -> String? {
        let clean = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let end = clean.firstIndex(where: { ".!?".contains($0) }) else { return clean.isEmpty ? nil : String(clean.prefix(160)) }
        let sentence = String(clean[...end])
        return sentence.count > 220 ? String(sentence.prefix(200)) + "\u{2026}" : sentence
    }
}


/// The "vibes" AudioMuse finds: its clustering makes playlists named "..._automatic", each a group of songs that sound
/// alike. Marlo stays in one and moves to a neighbouring one, so the set drifts instead of jumping.
@MainActor
final class VibeMap {
    private var clusters: [(name: String, songs: [BaseItem])] = []
    private var membership: [String: [Int]] = [:]
    private var loaded = false

    var isReady: Bool { !clusters.isEmpty }

    func loadIfNeeded(client: JellyfinClient) async {
        guard !loaded else { return }
        loaded = true
        guard let all = try? await client.playlists(fresh: false) else { return }
        let automatic = all.filter { $0.name.lowercased().contains("_automatic") }.prefix(48)
        var found: [(String, [BaseItem])] = []
        await withTaskGroup(of: (String, [BaseItem])?.self) { group in
            for list in automatic {
                group.addTask {
                    guard let songs = try? await client.playlistItems(list.id), songs.count >= 8 else { return nil }
                    return (Self.clean(list.name), songs)
                }
            }
            for await result in group { if let result { found.append(result) } }
        }
        clusters = found.sorted { $0.0 < $1.0 }.map { (name: $0.0, songs: $0.1) }
        for (index, cluster) in clusters.enumerated() {
            for song in cluster.songs { membership[song.id, default: []].append(index) }
        }
    }

    nonisolated private static func clean(_ name: String) -> String {
        var text = name.replacingOccurrences(of: "_automatic", with: "", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? name : text
    }

    func vibes(containing id: String) -> [Int] { membership[id] ?? [] }
    func shuffledIndices() -> [Int] { clusters.indices.shuffled() }
    func songs(in vibe: Int) -> [BaseItem] { clusters.indices.contains(vibe) ? clusters[vibe].songs.shuffled() : [] }
    func name(of vibe: Int) -> String { clusters.indices.contains(vibe) ? clusters[vibe].name : "Vibe" }

    /// The vibe to move to from `vibe`: the one that holds the most songs that sound like the current song
    /// (picked among the best few, so it is not always the same), never one visited a moment ago.
    func neighbour(of vibe: Int?, similar: [String], avoiding: some Sequence<Int>) -> Int? {
        let blocked = Set(avoiding).union(vibe.map { [$0] } ?? [])
        var score: [Int: Int] = [:]
        for id in similar { for index in membership[id] ?? [] where !blocked.contains(index) { score[index, default: 0] += 1 } }
        let best = score.sorted { $0.value > $1.value }.prefix(3).map(\.key)
        if let pick = best.randomElement() { return pick }
        let others = clusters.indices.filter { !blocked.contains($0) }
        return others.randomElement() ?? vibe
    }
}
