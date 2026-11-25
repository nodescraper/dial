import Foundation

/// Everything the DJ says. Lines are templates with blanks filled from the song that's
/// about to play: {dj} (the DJ's name), {artist}, {song}, {album}, {year}, {time} ("this morning", "tonight"…).
/// A line is only used if every blank it needs is known, and recent lines aren't repeated.
enum DJMoment: CaseIterable {
    case intro, lateIntro, newDirection, stay, favorite, throwback, lateNight, chatStart
}

struct DJScript {
    private var recent: [String] = []

    static let lines: [DJMoment: [String]] = [
        .intro: [
            "Hey, it's {dj}. Let's start with {artist}.",
            "{dj} here. I've been digging through your library {time}. First up, {artist}.",
            "Alright, let's get this going. First up, {song} by {artist}.",
            "I've got a set lined up for you {time}. Starting with {artist}.",
            "Here we go. {artist}, {song}.",
            "Let's ease into it with {artist}.",
            "Pulling from your library {time}. We'll open with {song}.",
            "Good to have you back. Kicking things off with {artist}.",
            "Let's warm up with a little {artist}.",
        ],
        .lateIntro: [
            "Still up? It's {dj}. Let's keep it easy with {artist}.",
            "Late one, huh. I'll start you off with {song}.",
            "Quiet hours. Here's {artist} to set the tone.",
        ],
        .newDirection: [
            "Let's switch it up. {artist} takes it from here.",
            "New direction. Here's {artist}.",
            "Time for a change of pace. This is {artist} with {song}.",
            "Going somewhere different now. {artist} is setting the vibe.",
            "Okay, let's turn a corner. {song}, from {artist}.",
            "Shaking things up a little. Here's {artist}.",
            "Let's head somewhere else for a bit, with {artist}.",
            "You've been in that lane a while, so let's move. {artist}, coming up.",
            "Different flavor now. Give this one a second: {artist}.",
            "Changing gears. {artist} is up.",
            "{dj} again. Let's go somewhere new with {artist}.",
        ],
        .stay: [
            "Staying in this lane for a bit. Here's {artist}.",
            "Keeping this mood going with {song}.",
            "More of that feeling, coming right up. {artist}.",
            "Not changing a thing. Next up, {artist}.",
            "Let's ride this one out. {song} by {artist}.",
            "Same energy, different song. This is {artist}.",
            "You seem into this, so here's more. {artist}.",
            "Holding the vibe right here, with {artist}.",
        ],
        .favorite: [
            "Here's one you keep coming back to. {song} by {artist}.",
            "A favorite of yours, coming up. {artist}.",
            "You know this one. {song}.",
            "Let's bring back a favorite: {artist}, {song}.",
            "One from your favorites, because why not. {artist}.",
        ],
        .throwback: [
            "Back to {year} for this one. {artist}, {song}.",
            "From {album}, here's {artist}.",
            "A little throwback now: {song}, from {year}.",
            "Digging into {album} for this next one.",
        ],
        .lateNight: [
            "It's getting late, so let's keep it smooth. {artist}.",
            "Late night picks, continuing with {song}.",
            "Keeping it low for the night. Here's {artist}.",
        ],
        .chatStart: [
            "Starting with {artist}.",
            "Here's {artist} to kick things off.",
            "First up, {song} by {artist}.",
            "Let's open with {song}.",
        ],
    ]

    /// A line for this moment, filled in from the song about to play.
    mutating func line(for moment: DJMoment, track: BaseItem, djName: String, now: Date = .now) -> String {
        var values = Self.values(for: track, now: now)
        values["dj"] = djName
        let usable = (Self.lines[moment] ?? []).filter { template in
            Self.blanks(in: template).allSatisfy { values[$0] != nil }
        }
        let fresh = usable.filter { !recent.contains($0) }
        guard let template = (fresh.isEmpty ? usable : fresh).randomElement() else {
            return "Here's \(values["artist"] ?? "the next song")."
        }
        recent.append(template)
        if recent.count > 8 { recent.removeFirst() }

        var text = template
        for (key, value) in values {
            text = text.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return text
    }

    // MARK: Filling the blanks

    private static func values(for track: BaseItem, now: Date) -> [String: String] {
        var values: [String: String] = ["time": timePhrase(now)]
        if let artist = track.artists?.first ?? track.albumArtist {
            values["artist"] = speakable(ArtistNames.primary(artist))
        }
        values["song"] = speakable(track.name)
        if let album = track.album, album != track.name { values["album"] = speakable(album) }
        if let year = track.productionYear { values["year"] = String(year) }
        return values
    }

    private static func blanks(in template: String) -> [String] {
        template.components(separatedBy: "{").dropFirst().compactMap { $0.components(separatedBy: "}").first }
    }

    static func isLateNight(_ date: Date = .now) -> Bool {
        let hour = Calendar.current.component(.hour, from: date)
        return hour >= 23 || hour < 5
    }

    private static func timePhrase(_ date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: return "this morning"
        case 12..<17: return "this afternoon"
        case 17..<23: return "this evening"
        default: return "tonight"
        }
    }

    /// Cleans names so the voice reads them naturally: no "(Remastered 2011)" or "[Deluxe]",
    /// and "feat." and "&" read as words.
    static func speakable(_ name: String) -> String {
        var text = name
        for pattern in [#"\s*\([^)]*\)"#, #"\s*\[[^\]]*\]"#, #"\s+-\s+.*(Remaster|Version|Edit|Mix).*$"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: " feat. ", with: " featuring ", options: .caseInsensitive)
        text = text.replacingOccurrences(of: " ft. ", with: " featuring ", options: .caseInsensitive)
        text = text.replacingOccurrences(of: " & ", with: " and ")
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? name : trimmed
    }
}
