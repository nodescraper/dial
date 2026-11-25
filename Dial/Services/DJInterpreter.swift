import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What the listener asked the DJ for, limited to things that exist in their library.
struct DJMood: Sendable, Equatable {
    enum Energy: String, Sendable, Codable {
        case any, low, medium, high
    }

    var genres: [String] = []
    var artists: [String] = []
    /// Only these artists ("play Kanye") rather than music like them ("something like Kanye").
    var onlyArtists = false
    /// Artists they don't want ("no more Drake").
    var excludedArtists: [String] = []
    /// Familiar songs, new ones, or a mix ("play stuff I haven't heard").
    var discovery: DJSteering.Discovery?
    /// Adjusts what's playing ("more upbeat", "add some Bad Bunny") instead of asking for something new.
    var isFollowUp = false
    var excludedGenres: [String] = []
    var earliestYear: Int?
    var latestYear: Int?
    var energy: Energy = .any
    /// A short reply written by the on-device model, if one was available.
    var reply: String?
    /// The request in the listener's words, for finding songs by sound (AudioMuse).
    var description: String?

    var years: [Int] {
        guard earliestYear != nil || latestYear != nil else { return [] }
        let thisYear = Calendar.current.component(.year, from: .now)
        let first = max(earliestYear ?? 1950, 1900)
        let last = min(latestYear ?? thisYear, thisYear)
        return first <= last ? Array(first...last) : []
    }

    var isEmpty: Bool {
        genres.isEmpty && artists.isEmpty && excludedGenres.isEmpty && years.isEmpty && energy == .any
    }

    /// Whether a song fits the request's year range and avoids excluded genres.
    func allows(_ track: BaseItem) -> Bool {
        if let year = track.productionYear {
            if let earliestYear, year < earliestYear { return false }
            if let latestYear, year > latestYear { return false }
        }
        if !excludedGenres.isEmpty, let genres = track.genres {
            let lower = Set(genres.map { $0.lowercased() })
            if excludedGenres.contains(where: { lower.contains($0.lowercased()) }) { return false }
        }
        return true
    }
}

/// Understands requests using Apple's on-device model when the iPhone supports it,
/// and simple keyword matching otherwise. Either way, nothing leaves the phone.
enum DJInterpreter {
    static var usesOnDeviceModel: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    static func interpret(_ request: String, libraryGenres: [String], libraryArtists: [String]) async -> DJMood {
        var mood = keywordMood(request, libraryGenres: libraryGenres, libraryArtists: libraryArtists)
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), usesOnDeviceModel,
           let generated = try? await OnDeviceInterpreter.interpret(request, genres: libraryGenres) {
            // Keep only genres and artists that really exist; the model can't invent library content.
            let genres = match(generated.genres, in: libraryGenres)
            let excluded = match(generated.excludedGenres, in: libraryGenres)
            let artists = matchArtists(said: request, suggested: generated.artists, library: libraryArtists)
            if !genres.isEmpty { mood.genres = genres }
            if !excluded.isEmpty { mood.excludedGenres = excluded }
            if !artists.isEmpty {
                mood.artists = artists
                mood.onlyArtists = !wantsSimilar(request)
            }
            if generated.earliestYear > 0 { mood.earliestYear = generated.earliestYear }
            if generated.latestYear > 0 { mood.latestYear = generated.latestYear }
            if let energy = DJMood.Energy(rawValue: generated.energy.lowercased()), energy != .any { mood.energy = energy }
            let reply = generated.reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reply.isEmpty { mood.reply = reply }
        }
        #endif
        return mood
    }

    // MARK: Keyword matching (works on every iPhone)

    private static let lowEnergyWords = ["chill", "calm", "relax", "sleep", "study", "focus", "mellow", "soft", "quiet",
                                         "late night", "rainy", "slow", "cozy", "lofi", "lo-fi"]
    private static let highEnergyWords = ["party", "hype", "workout", "gym", "run", "energy", "upbeat", "dance",
                                          "loud", "pump", "fast", "banger"]
    private static let lowEnergyGenres = ["chill", "ambient", "lo-fi", "lofi", "jazz", "acoustic", "soul", "r&b",
                                          "downtempo", "classical", "folk", "trip-hop"]
    private static let highEnergyGenres = ["dance", "electronic", "edm", "house", "techno", "hip hop", "hip-hop",
                                           "rap", "rock", "metal", "pop", "drum", "trap"]

    static func keywordMood(_ request: String, libraryGenres: [String], libraryArtists: [String], soundSearch: Bool = true) -> DJMood {
        let text = request.lowercased()
        var mood = DJMood()

        // "no rap", "without metal", "not jazz"
        for genre in libraryGenres {
            let name = genre.lowercased()
            guard text.contains(name) else { continue }
            let negated = ["no \(name)", "not \(name)", "without \(name)", "except \(name)", "skip \(name)"]
                .contains { text.contains($0) }
            if negated { mood.excludedGenres.append(genre) } else { mood.genres.append(genre) }
        }
        let named = matchArtists(said: text, suggested: [], library: libraryArtists)
        // "no more Drake", "skip Drake", "without Drake"
        mood.excludedArtists = named.filter { name in
            let key = ArtistNames.key(name)
            return ["no more \(key)", "no \(key)", "skip \(key)", "without \(key)", "less \(key)", "not \(key)"]
                .contains { text.contains($0) }
        }
        mood.artists = named.filter { !mood.excludedArtists.contains($0) }
        mood.onlyArtists = !mood.artists.isEmpty && (text.contains("only") || text.contains("just ") || !isFollowUpText(text)) && !wantsSimilar(text)
        mood.isFollowUp = isFollowUpText(text)
        if ["never heard", "haven't heard", "havent heard", "new to me", "something new", "discover", "deep cuts"].contains(where: { text.contains($0) }) {
            mood.discovery = .new
        } else if ["favorites", "favourites", "classics", "my top", "familiar", "the hits"].contains(where: { text.contains($0) }) {
            mood.discovery = .familiar
        }

        if lowEnergyWords.contains(where: { text.contains($0) }) { mood.energy = .low }
        if highEnergyWords.contains(where: { text.contains($0) }) { mood.energy = .high }

        // Years: "2010s", "2010's", "90s", "nineties", "early 2000s", "after 2018", "before 2000"
        if let range = MoodVocabulary.yearRange(in: request) {
            mood.earliestYear = range.from
            mood.latestYear = range.to
        }

        // A feeling or activity ("I feel sad", "cooking dinner"): its sound, and on libraries without
        // sound search the genres that usually fit.
        if mood.genres.isEmpty, mood.artists.isEmpty, let feel = MoodVocabulary.match(request) {
            mood.description = feel.sound
            if mood.energy == .any, let energy = DJMood.Energy(rawValue: feel.energy) { mood.energy = energy }
            if !soundSearch { mood.genres = MoodVocabulary.genres(for: feel, in: libraryGenres).filter { !mood.excludedGenres.contains($0) } }
        }

        // No genre named: lean on energy to pick matching genres from the library.
        if mood.genres.isEmpty && mood.energy != .any && (mood.description == nil || !soundSearch) {
            let hints = mood.energy == .low ? lowEnergyGenres : highEnergyGenres
            mood.genres = libraryGenres.filter { genre in
                let name = genre.lowercased()
                return hints.contains { name.contains($0) } && !mood.excludedGenres.contains(genre)
            }
        }
        return mood
    }

    /// Words that adjust the current music rather than replace it.
    static func isFollowUpText(_ text: String) -> Bool {
        let lower = " " + text.lowercased() + " "
        return [" more ", " less ", " add ", " also ", " too ", "no more", "a bit", "keep ", "slower", "faster",
                "calmer", "louder", "softer", "mix in", "throw in", "without "].contains { lower.contains($0) }
    }

    /// Words that mean "music like this artist", not "only this artist".
    static func wantsSimilar(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["like ", "similar", "sounds like", "vibe", "style of", "in the style", "inspired", "mixed with", "and others"]
            .contains { lower.contains($0) }
    }

    /// Library artists the listener meant, the way people actually say names:
    /// "kanye" finds "Kanye West", "weeknd" finds "The Weeknd", "ye" finds "Ye".
    static func matchArtists(said text: String, suggested: [String], library: [String]) -> [String] {
        let fold: (String) -> String = { ArtistNames.key($0) }
        let spoken = " " + fold(text).replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression) + " "
        let common: Set<String> = ["the", "and", "band", "boys", "girls", "music", "with", "feat", "play", "some", "more", "songs",
                                   "song", "just", "only", "like", "want", "need", "give", "from", "kid", "big", "young", "lil", "dj", "mc"]
        // How many library artists share each word, so only distinctive words count on their own.
        var wordCount: [String: Int] = [:]
        for name in library {
            for word in Set(fold(name).split(separator: " ").map(String.init)) { wordCount[word, default: 0] += 1 }
        }
        var found: [String] = []
        func add(_ name: String) { if !found.contains(name) { found.append(name) } }

        for name in library {
            let key = fold(name)
            guard !key.isEmpty else { continue }
            if spoken.contains(" \(key) ") { add(name); continue } // the full name
            let words = key.split(separator: " ").map(String.init).filter { $0.count >= 4 && !common.contains($0) }
            if words.contains(where: { wordCount[$0] == 1 && spoken.contains(" \($0) ") }) { add(name) }
        }
        for suggestion in suggested {
            let key = fold(suggestion)
            guard !key.isEmpty else { continue }
            if let exact = library.first(where: { fold($0) == key }) { add(exact); continue }
            if let close = library.first(where: { fold($0).contains(key) || key.contains(fold($0)) && fold($0).count >= 3 }) { add(close) }
        }
        return found
    }

    /// Case-insensitive match of suggested names against what's in the library.
    private static func match(_ names: [String], in library: [String]) -> [String] {
        names.compactMap { name in
            library.first { $0.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame }
        }
    }
}

// MARK: - Conversation

/// What Marlo knows when it answers: your library and what's playing.
struct DJContext: Sendable {
    let djName: String
    let libraryGenres: [String]
    let libraryArtists: [String]
    let nowPlaying: String?
    let isOnAir: Bool
    /// Whether songs can be found by how they sound (then moods go to AudioMuse, otherwise to genres).
    var canSearchBySound = true
    /// Lets the model check what the library holds before it answers.
    var probe: DJLibraryProbe?
}

/// Marlo's answer to one message: what to say, and whether (and how) to change the music.
struct DJTurnResult: Sendable {
    var reply: String?
    var changeMusic: Bool
    var mood: DJMood
    /// Whether the reply was written by the on-device model (then it's said as is).
    var isNatural = false
}

extension DJInterpreter {
    /// Talks with the listener. With Apple's on-device model, Marlo writes its own replies,
    /// remembers the conversation and only changes the music when you ask for something different.
    /// Without it, every message is treated as a music request.
    static func converse(_ request: String, context: DJContext, conversation: inout AnyObject?) async -> DJTurnResult {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), usesOnDeviceModel {
            if let result = await DJConversation.respond(to: request, context: context, holder: &conversation) {
                return result
            }
        }
        #endif
        let mood = keywordMood(request, libraryGenres: context.libraryGenres, libraryArtists: context.libraryArtists,
                               soundSearch: context.canSearchBySound)
        return DJTurnResult(reply: nil, changeMusic: true, mood: mood)
    }
}

// MARK: - Apple's on-device model (iOS 26, iPhones with Apple Intelligence)

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct GeneratedMood {
    @Guide(description: "Genres from the provided list that fit the request. Empty if none fit.")
    var genres: [String]

    @Guide(description: "Artist names the listener explicitly mentioned. Empty if none.")
    var artists: [String]

    @Guide(description: "Genres from the provided list that the listener wants to avoid. Empty if none.")
    var excludedGenres: [String]

    @Guide(description: "Earliest release year the listener wants, or 0 if they didn't say.")
    var earliestYear: Int

    @Guide(description: "Latest release year the listener wants, or 0 if they didn't say.")
    var latestYear: Int

    @Guide(description: "Energy level wanted: low, medium, high, or any.")
    var energy: String

    @Guide(description: "A short, warm reply from a radio DJ acknowledging the request, under 12 words. Never name an artist or a song.")
    var reply: String
}

@available(iOS 26.0, *)
enum OnDeviceInterpreter {
    static func interpret(_ request: String, genres: [String]) async throws -> GeneratedMood {
        let session = LanguageModelSession(instructions: """
            You help a music app's radio DJ understand what the listener wants to hear.
            Only choose genres from this list: \(genres.prefix(80).joined(separator: ", ")).
            Never invent artists, songs or facts. Interpret the request; don't recommend music.
            """)
        let response = try await session.respond(to: request, generating: GeneratedMood.self)
        return response.content
    }
}
#endif

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct GeneratedTurn {
    @Guide(description: "What the DJ says back: natural, warm and short, one or two sentences. Answer questions using only facts given in this conversation.")
    var reply: String

    @Guide(description: "true if the listener wants different music now; false if they're chatting, asking something, or happy with what's playing")
    var changeMusic: Bool

    @Guide(description: "Artists the listener asked to hear, written the way they said them. Empty if none.")
    var artists: [String]

    @Guide(description: "true if they want only those artists; false if they want music like them or mixed with others")
    var onlyTheseArtists: Bool

    @Guide(description: "Genres from the provided list that fit what they want. Empty if none.")
    var genres: [String]

    @Guide(description: "Genres from the provided list they want to avoid. Empty if none.")
    var excludedGenres: [String]

    @Guide(description: "Earliest release year they want, or 0")
    var earliestYear: Int

    @Guide(description: "Latest release year they want, or 0")
    var latestYear: Int

    @Guide(description: "Energy wanted: low, medium, high, or any")
    var energy: String

    @Guide(description: "A few words describing the sound they want, like 'calm piano' or 'summer party'. Empty if they only named artists.")
    var soundDescription: String

    @Guide(description: "true if this adjusts what's already playing (more upbeat, add an artist, no more of something); false if it asks for something different")
    var isFollowUp: Bool

    @Guide(description: "Artists the listener wants to stop hearing. Empty if none.")
    var excludedArtists: [String]

    @Guide(description: "familiar if they want songs they know, new if they want songs they haven't heard, otherwise mix")
    var discovery: String
}

/// One ongoing chat with the on-device model. It keeps the conversation, and starts fresh
/// when it gets long (the model can only remember so much).
@available(iOS 26.0, *)
final class DJConversation {
    private var session: LanguageModelSession
    private var turns = 0
    private let context: DJContext

    private init(context: DJContext) {
        self.context = context
        session = Self.makeSession(context)
    }

    private static func makeSession(_ context: DJContext) -> LanguageModelSession {
        LanguageModelSession(tools: context.probe.map { [FindTagsTool(probe: $0), CheckLibraryTool(probe: $0)] } ?? [], instructions: """
            You are \(context.djName), a friendly radio DJ inside a music app. You chat with the listener in short, natural sentences, like a real DJ would.
            You can only play music from the listener's own library.
            Genres in the library: \(context.libraryGenres.prefix(60).joined(separator: ", ")).
            Some artists in the library: \(context.libraryArtists.prefix(120).joined(separator: ", ")).
            When the listener asks for music, set changeMusic to true and describe what they want. Requests like "more upbeat", "add some Bad Bunny" or "no more rap" are follow-ups: they adjust what's playing. When they're just talking, asking a question or reacting, set changeMusic to false and answer.
            To answer a request for a mood, feeling, activity, era or genre: first call findTags with their words, then call checkLibrary with the genres, years and sound words you plan to use. If fewer than 10 songs fit, loosen one thing (widen the years or drop the genre, keep the sound words) and check again. Sound search is the main way to find music, and it understands audio, not names or years: write the sound words as a short description of how the music sounds (mood, tempo, instruments, genre, vocals), like "slow melancholic piano ballad" or "upbeat sunny acoustic pop", never artists, years or the listener's story. Check them with checkLibrary; if the sound fit is weak, try one different wording and keep the one that fits better. Put the sound words you settled on in soundDescription.
            You may say how many songs you found, but only a number that checkLibrary returned. Never promise songs a tool didn't confirm.
            Only state facts you were given, like what's playing now. Don't make up facts about artists, songs or albums, and don't promise artists that aren't in the library.
            """)
    }

    static func respond(to request: String, context: DJContext, holder: inout AnyObject?) async -> DJTurnResult? {
        let conversation: DJConversation
        if let existing = holder as? DJConversation, existing.turns < 8 {
            conversation = existing
        } else {
            conversation = DJConversation(context: context)
            holder = conversation
        }
        conversation.turns += 1
        let prompt = [context.nowPlaying.map { "[Now playing: \($0)]" }, "Listener: \(request)"]
            .compactMap { $0 }.joined(separator: "\n")
        guard let generated = try? await conversation.session.respond(to: prompt, generating: GeneratedTurn.self).content else {
            holder = nil // start over next time (for example after the conversation got too long)
            return nil
        }
        var mood = DJMood()
        let library = context.libraryArtists
        mood.artists = DJInterpreter.matchArtists(said: request, suggested: generated.artists, library: library)
        mood.onlyArtists = !mood.artists.isEmpty && (generated.onlyTheseArtists || !DJInterpreter.wantsSimilar(request))
        mood.genres = context.libraryGenres.filter { genre in generated.genres.contains { $0.caseInsensitiveCompare(genre) == .orderedSame } }
        mood.excludedGenres = context.libraryGenres.filter { genre in generated.excludedGenres.contains { $0.caseInsensitiveCompare(genre) == .orderedSame } }
        if generated.earliestYear > 0 { mood.earliestYear = generated.earliestYear }
        if generated.latestYear > 0 { mood.latestYear = generated.latestYear }
        // Years written out ("2010's", "the nineties") are read exactly; the model only guesses.
        if let range = MoodVocabulary.yearRange(in: request) {
            mood.earliestYear = range.from
            mood.latestYear = range.to
        }
        if let energy = DJMood.Energy(rawValue: generated.energy.lowercased()) { mood.energy = energy }
        let sound = generated.soundDescription.trimmingCharacters(in: .whitespaces)
        if !sound.isEmpty { mood.description = sound }
        // A mood the model left without a sound still gets one from the vocabulary.
        if mood.description == nil, mood.artists.isEmpty, let feel = MoodVocabulary.match(request) {
            mood.description = feel.sound
            if mood.energy == .any, let energy = DJMood.Energy(rawValue: feel.energy) { mood.energy = energy }
        }
        if !context.canSearchBySound, mood.genres.isEmpty, mood.artists.isEmpty, let feel = MoodVocabulary.match(request) {
            mood.genres = MoodVocabulary.genres(for: feel, in: context.libraryGenres)
        }
        mood.isFollowUp = generated.isFollowUp
        mood.excludedArtists = DJInterpreter.matchArtists(said: "", suggested: generated.excludedArtists, library: library)
        mood.artists.removeAll { mood.excludedArtists.contains($0) }
        mood.discovery = DJSteering.Discovery(rawValue: generated.discovery.lowercased())

        var reply = generated.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        // They asked for artists Dial can't find: say so instead of pretending.
        if generated.changeMusic, !generated.artists.isEmpty, mood.artists.isEmpty {
            reply = "I couldn\u{2019}t find \(generated.artists.joined(separator: " or ")) in your library. Want me to try something close?"
            return DJTurnResult(reply: reply, changeMusic: false, mood: mood, isNatural: true)
        }
        return DJTurnResult(reply: reply.isEmpty ? nil : reply, changeMusic: generated.changeMusic, mood: mood, isNatural: true)
    }
}
#endif
