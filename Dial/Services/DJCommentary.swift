import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What Marlo says before a block: why these songs, in a sentence or two, using only true facts
/// (your listening, your library, artist bios). The on-device model writes it when the device has
/// one; otherwise it comes from hand-written lines filled with the same facts.
enum DJCommentary {
    static func line(for block: DJBlock, djName: String, opening: Bool, reply: String? = nil, timeout: Double = 5) async -> String {
        let first = block.tracks.first
        let song = first.map { DJScript.speakable($0.name) } ?? ""
        let artist = first.map { DJScript.speakable(ArtistNames.primary($0.albumArtist ?? $0.artistLine)) } ?? ""

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), DJInterpreter.usesOnDeviceModel,
           let written = await written(block: block, djName: djName, opening: opening, reply: reply, song: song, artist: artist, timeout: timeout) {
            return written
        }
        #endif
        let intro = opening ? openingLine(djName) + " " : ""
        let replyPart = reply.map { $0 + " " } ?? ""
        if opening && block.kind == .vibe {
            return replyPart + intro + ["Let's settle in. \(artist), \(song).", "Starting easy. \(song) by \(artist)."].randomElement()!
        }
        // Now and then a true, personal thing about the song or you, as a radio host would slip in.
        let stat = block.stats.randomElement().flatMap { Double.random(in: 0..<1) < 0.7 ? " " + $0 : nil } ?? ""
        return replyPart + intro + template(block, song: song, artist: artist) + stat
    }

    // MARK: Hand-written lines

    private static func openingLine(_ name: String) -> String {
        let hour = Calendar.current.component(.hour, from: .now)
        let part = hour < 12 ? "this morning" : hour < 18 ? "this afternoon" : hour < 22 ? "tonight" : "this late"
        return ["\(name) here, with you \(part).", "It's \(name). Let's get into it.", "Hey, \(name) here."].randomElement()!
    }

    private static func template(_ block: DJBlock, song: String, artist: String) -> String {
        let options: [String]
        switch block.kind {
        case .onRepeat:
            options = ["You've had these on repeat lately, so let's not stop now. Here's \(song) by \(artist).",
                       "Your recent rotation, starting with \(artist) and \(song)."]
        case .favorites:
            options = ["Some songs you love. First up, \(song) by \(artist).",
                       "Back to your favorites with \(artist), \(song)."]
        case .throwback:
            options = ["Going back a bit. You haven't played this one in a while: \(song) by \(artist).",
                       "A throwback for you, \(artist) with \(song)."]
        case .deepCuts:
            options = ["Some deep cuts from \(artist) you haven't played yet, starting with \(song).",
                       "Let's dig into \(artist). Here's \(song), one you've never played."]
        case .newArrivals:
            options = ["Fresh in your library: \(song) by \(artist).",
                       "Something you just added. Here's \(artist), \(song)."]
        case .spotlight:
            options = ["Spotlight on \(artist) for a few songs, starting with \(song).",
                       "A few from \(artist). Here's \(song)."]
        case .discovery:
            options = ["Something you don't play much, but I think you'll like it: \(song) by \(artist).",
                       "Trying something new for you. This is \(artist), \(song)."]
        case .mood:
            options = ["Setting the mood. Here's \(song) by \(artist).", "For right now: \(artist), \(song)."]
        case .vibe:
            options = ["Shifting it a little. \(artist), \(song).", "Same neighbourhood, different street. \(artist), \(song).",
                       "\(artist) coming in. \(song).", "Easing it over. \(song) by \(artist)."]
        case .seasonal:
            options = ["It\u{2019}s that time of year. \(artist), \(song).", "Some seasonal music. Here\u{2019}s \(song) by \(artist).", "In the spirit of the season: \(artist), \(song)."]
        case .request:
            options = ["As requested. Here's \(song) by \(artist).", "You got it. \(artist), \(song)."]
        }
        return options.randomElement()!
    }

    // MARK: Written by the on-device model

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func written(block: DJBlock, djName: String, opening: Bool, reply: String?,
                                song: String, artist: String, timeout: Double) async -> String? {
        let session = LanguageModelSession(instructions: block.kind == .vibe ? """
            You are \(djName), a DJ with taste. The music is shifting a little: still close, a bit different. \
            Say ONE short line, under 14 words, casual and dry, like a friend at the decks. \
            Never cheesy radio-host talk, no "folks", no "let's dive in", no exclamation marks, no emojis. \
            Use only the facts you're given. The song starting now is the one you are told about: name only that artist, never any other. Do not describe the genre or mood.
            """ : """
            You are \(djName), a friendly radio DJ. Write exactly what you say on air before the next songs: \
            one or two short spoken sentences, natural and warm, no emojis, no lists. \
            Use only the facts you're given; never add facts of your own. When a fact is about the listener ("You've played this one 14 times"), use one of them naturally. \
            End by introducing the first song and its artist. Name no other artist than that one.
            """)
        var prompt = "Theme: \(block.title).\n"
        prompt += (block.facts + block.stats.shuffled().prefix(2)).map { "Fact: \($0)" }.joined(separator: "\n")
        prompt += "\nFirst song: \(song) by \(artist)."
        if opening { prompt += "\nThis is the start of the show: greet the listener briefly." }
        if let reply { prompt += "\nThe listener just asked for this; begin by acknowledging it (you replied: \(reply))." }
        // Don't keep the music waiting: if the model is slow, use a hand-written line.
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                guard let text = try? await session.respond(to: prompt).content else { return nil }
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
                guard !clean.isEmpty, clean.count <= 320 else { return nil }
                // The line has to be about the song that is actually starting: it names that artist, or it is not used.
                let key = artist.split(separator: " ").first.map { String($0).lowercased() } ?? ""
                if key.count >= 3, !clean.lowercased().contains(key) { return nil }
                return clean
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
    #endif
}
