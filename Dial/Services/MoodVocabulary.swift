import Foundation
import NaturalLanguage

/// Turns how someone says they feel or what they're doing ("I'm sad", "cooking dinner", "gloomy day")
/// into a sound AudioMuse can search and genres the library can filter on. Works on every device:
/// a hand-written table of everyday words first, then on-device word embeddings for the words the
/// table doesn't know ("gloomy" is close enough to "sad").
struct MoodMatch: Sendable, Equatable {
    let name: String
    /// A description for sound search ("sad melancholic emotional ballad").
    let sound: String
    /// low, medium, high or any.
    let energy: String
    /// Genre names that usually fit, matched against what the library really has.
    let genreHints: [String]
}

enum MoodVocabulary {
    fileprivate struct Entry {
        let name: String
        let words: [String]
        let sound: String
        let energy: String
        let genres: [String]
    }

    private static let entries: [Entry] = [
        Entry(name: "sad", words: ["sad", "blue", "down", "crying", "cry", "heartbroken", "heartbreak", "lonely", "depressed", "melancholy",
                                   "melancholic", "gloomy", "tearful", "miserable", "grief", "sorrow", "breakup", "broken", "hurt", "upset", "tears", "devastated", "gutted", "crushed", "numb", "hopeless", "grieving", "weepy", "sorrowful", "blue"],
              sound: "sad melancholic emotional heartbreak ballad", energy: "low",
              genres: ["blues", "soul", "singer-songwriter", "folk", "indie", "ballad", "r&b", "acoustic"]),
        Entry(name: "happy", words: ["happy", "joyful", "cheerful", "sunny", "uplifting", "feelgood", "smile", "positive", "bright", "good mood", "joy", "euphoric", "ecstatic", "elated", "excited", "thrilled", "upbeat", "lively", "cheery", "glad"],
              sound: "happy cheerful sunny feel good uplifting", energy: "medium",
              genres: ["pop", "funk", "disco", "soul", "reggae", "dance"]),
        Entry(name: "energetic", words: ["hype", "hyped", "energetic", "energy", "pump", "pumped", "workout", "gym", "run", "running", "intense", "banger", "bangers"],
              sound: "energetic intense powerful fast workout", energy: "high",
              genres: ["rock", "electronic", "hip hop", "metal", "dance", "drum and bass", "trap"]),
        Entry(name: "party", words: ["party", "dance", "dancing", "club", "celebrate", "celebration", "pregame", "night out"],
              sound: "danceable party groove club upbeat", energy: "high",
              genres: ["dance", "pop", "electronic", "hip hop", "house", "disco", "latin"]),
        Entry(name: "calm", words: ["calm", "relax", "relaxed", "relaxing", "chill", "mellow", "peaceful", "soothing", "unwind", "gentle", "easy", "laid back", "lazy", "anxious", "stressed", "overwhelmed", "nervous", "coffee", "breakfast", "sunday", "morning"],
              sound: "relaxed calm mellow gentle peaceful", energy: "low",
              genres: ["chill", "ambient", "jazz", "acoustic", "lo-fi", "downtempo", "classical"]),
        Entry(name: "focus", words: ["focus", "study", "studying", "concentrate", "concentration", "work", "working", "reading", "homework", "coding", "productive"],
              sound: "calm instrumental ambient focus no vocals", energy: "low",
              genres: ["ambient", "classical", "lo-fi", "instrumental", "electronic", "jazz"]),
        Entry(name: "sleep", words: ["sleep", "sleeping", "bedtime", "lullaby", "drift", "insomnia", "rest", "tired", "exhausted", "sleepy", "drowsy", "nap"],
              sound: "ambient soft quiet sleep peaceful", energy: "low",
              genres: ["ambient", "classical", "new age", "piano"]),
        Entry(name: "romantic", words: ["romantic", "romance", "love", "date", "dinner for two", "sexy", "intimate", "tender", "valentine", "slow dance"],
              sound: "romantic tender soulful love smooth", energy: "low",
              genres: ["r&b", "soul", "jazz", "pop", "latin", "ballad"]),
        Entry(name: "angry", words: ["angry", "mad", "furious", "rage", "aggressive", "frustrated", "pissed", "annoyed", "vent"],
              sound: "aggressive angry intense heavy hard", energy: "high",
              genres: ["metal", "punk", "rock", "hip hop", "hardcore", "rap"]),
        Entry(name: "nostalgic", words: ["nostalgic", "nostalgia", "throwback", "memories", "remember", "old school", "oldies", "childhood", "miss"],
              sound: "nostalgic warm retro classic", energy: "medium",
              genres: ["oldies", "classic rock", "pop", "soul", "disco"]),
        Entry(name: "dreamy", words: ["dreamy", "dream", "floating", "ethereal", "hazy", "spacey", "atmospheric", "cinematic", "airy"],
              sound: "dreamy ethereal atmospheric hazy", energy: "low",
              genres: ["ambient", "dream pop", "shoegaze", "electronic", "indie", "chill"]),
        Entry(name: "dark", words: ["dark", "moody", "brooding", "late night", "night", "midnight", "noir", "edgy", "creepy", "spooky"],
              sound: "dark moody atmospheric late night smooth", energy: "low",
              genres: ["trip-hop", "electronic", "industrial", "ambient", "r&b", "hip hop"]),
        Entry(name: "rainy", words: ["rainy", "rain", "stormy", "grey", "gray", "autumn", "cloudy", "cozy", "cosy", "fireplace", "winter"],
              sound: "rainy mellow acoustic soft cozy", energy: "low",
              genres: ["acoustic", "folk", "jazz", "indie", "singer-songwriter"]),
        Entry(name: "road trip", words: ["driving", "drive", "roadtrip", "road trip", "commute", "highway", "car", "cruising"],
              sound: "driving anthemic upbeat road trip", energy: "medium",
              genres: ["rock", "pop", "indie", "country", "electronic"]),
        Entry(name: "dinner", words: ["dinner", "cooking", "cook", "brunch", "hosting", "dinner party", "wine", "cocktail", "lounge"],
              sound: "smooth jazzy warm sophisticated dinner", energy: "low",
              genres: ["jazz", "bossa nova", "soul", "lounge", "latin", "acoustic"]),
        Entry(name: "summer", words: ["summer", "beach", "pool", "holiday", "vacation", "tropical", "barbecue", "bbq", "poolside"],
              sound: "summer tropical sunny bright beach", energy: "medium",
              genres: ["reggae", "latin", "pop", "dance", "tropical", "surf"]),
        Entry(name: "groove", words: ["groove", "groovy", "funky", "funk", "bass", "swing"],
              sound: "funky groovy bass rhythm", energy: "medium",
              genres: ["funk", "soul", "disco", "r&b", "jazz", "hip hop"]),
    ]

    // MARK: Matching

    /// The mood a request describes, if any. "not sad" and "no sad songs" count as nothing.
    static func match(_ request: String) -> MoodMatch? {
        let text = " " + request.lowercased().replacingOccurrences(of: #"[^\p{L}\p{N}']+"#, with: " ", options: .regularExpression) + " "
        var best: (entry: Entry, score: Int)?
        for entry in entries {
            var score = 0
            for word in entry.words {
                guard let range = text.range(of: " \(word) ") ?? text.range(of: " \(word)s ") ?? text.range(of: " \(word)ing ") else { continue }
                // "not sad", "no sad", "without sad", "don't want sad"
                let before = String(text[text.startIndex..<range.lowerBound]).split(separator: " ").suffix(2)
                if before.contains(where: { ["no", "not", "without", "never", "dont", "don't", "except", "skip", "less"].contains(String($0)) }) { continue }
                score += word.contains(" ") ? 2 : 1
            }
            if score > 0, score > (best?.score ?? 0) { best = (entry, score) }
        }
        if let best { return best.entry.asMatch }
        return embeddingMatch(text)
    }

    /// Words close in meaning to a mood word we know ("gloomy" to "sad"), by Apple's on-device word embedding.
    private static func embeddingMatch(_ text: String) -> MoodMatch? {
        guard let embedding = NLEmbedding.wordEmbedding(for: .english) else { return nil }
        let skip: Set<String> = ["want", "something", "some", "play", "give", "songs", "song", "music", "feel", "feeling", "need", "like", "the", "and",
                                 "for", "with", "that", "this", "from", "but", "not", "have", "has", "can", "you", "please", "mood", "tracks"]
        let words = text.split(separator: " ").map(String.init)
            .filter { $0.count >= 4 && !skip.contains($0) && !$0.contains("'") && Int($0) == nil }
        var best: (entry: Entry, distance: Double)?
        for word in words {
            guard embedding.contains(word) else { continue }
            for entry in entries {
                for key in [entry.name] + entry.words.prefix(3) where !key.contains(" ") {
                    let distance = embedding.distance(between: word, and: key)
                    if distance < embeddingThreshold, distance < (best?.distance ?? .infinity) { best = (entry, distance) }
                }
            }
        }
        return best?.entry.asMatch
    }

    static let embeddingThreshold: Double = 0.92

    /// Library genres that fit a mood (the hints matched against names the library really has).
    static func genres(for mood: MoodMatch, in library: [String]) -> [String] {
        library.filter { genre in
            let name = genre.lowercased()
            return mood.genreHints.contains { hint in name == hint || name.contains(hint) }
        }
    }

    // MARK: Decades and eras

    /// Years in a request: "2010s", "2010's", "the 90s", "'80s", "nineties", "early 2000s", "from 2015", "between 2005 and 2010".
    static func yearRange(in request: String) -> (from: Int?, to: Int?)? {
        let text = request.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let thisYear = Calendar.current.component(.year, from: .now)

        func decade(_ start: Int) -> (Int?, Int?) {
            if text.contains("early \(start)") || text.contains("early \(start % 100)") { return (start, start + 3) }
            if text.contains("late \(start)") || text.contains("late \(start % 100)") { return (start + 6, min(start + 9, thisYear)) }
            if text.contains("mid \(start)") || text.contains("mid-\(start)") { return (start + 3, start + 6) }
            return (start, min(start + 9, thisYear))
        }

        // 2010s, 2010's, 1990s
        if let m = text.firstMatch(of: #/\b((?:19|20)\d0)'?s\b/#), let start = Int(m.output.1) { return decade(start) }
        // 90s, '90s, 00s
        if let m = text.firstMatch(of: #/(?:^|[^\d])'?(\d0)'?s\b/#), let two = Int(m.output.1) {
            let start = two >= 30 ? 1900 + two : 2000 + two
            return decade(start)
        }
        let words: [(String, Int)] = [("fifties", 1950), ("sixties", 1960), ("seventies", 1970), ("eighties", 1980), ("nineties", 1990),
                                      ("noughties", 2000), ("aughts", 2000), ("twenty tens", 2010), ("twenty-tens", 2010)]
        if let (_, start) = words.first(where: { text.contains($0.0) }) { return decade(start) }

        let years = text.matches(of: #/\b(?:19|20)\d{2}\b/#).compactMap { Int($0.output) }.filter { $0 <= thisYear + 1 }
        guard let first = years.first else { return nil }
        if years.count >= 2, let low = years.min(), let high = years.max() { return (low, high) }
        if ["nothing older than", "no older than", "not older than"].contains(where: { text.contains($0) }) { return (first, nil) }
        if ["before", "older than", "until", "up to", "earlier than"].contains(where: { text.contains($0) }) { return (nil, first) }
        if ["after", "since", "newer than", "from", "later than"].contains(where: { text.contains($0) }) { return (first, nil) }
        return (first, first)
    }
}

private extension MoodVocabulary.Entry {
    var asMatch: MoodMatch { MoodMatch(name: name, sound: sound, energy: energy, genreHints: genres) }
}
