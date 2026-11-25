import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What Marlo can look up in your library while it works out a request. It asks the same planner
/// that picks the songs, so what the model is told is exactly what would play.
@MainActor
final class DJLibraryProbe {
    private let planner: DJPlanner
    private let isHidden: (String) -> Bool
    private let genreNames: () -> [String]
    private weak var audioMuse: AudioMuse?
    /// The best fit seen for any wording this session, so a second try can be compared.
    private var bestFit: Double?

    init(planner: DJPlanner, audioMuse: AudioMuse? = nil, isHidden: @escaping (String) -> Bool, genreNames: @escaping () -> [String]) {
        self.planner = planner
        self.audioMuse = audioMuse
        self.isHidden = isHidden
        self.genreNames = genreNames
    }

    /// How closely the library's best songs match these sound words, and whether it beats the last wording tried.
    private func soundFit(_ sound: String?) async -> String? {
        guard let sound, let audioMuse, audioMuse.canSearchBySound,
              let scored = try? await audioMuse.scoredSongs(matching: sound, limit: 20) else { return nil }
        let values = scored.compactMap(\.similarity)
        guard values.count >= 5 else { return nil }
        let fit = values.prefix(10).reduce(0, +) / Double(min(values.count, 10))
        defer { bestFit = max(bestFit ?? fit, fit) }
        let label = String(format: "%.2f", fit)
        guard let best = bestFit else { return "Sound fit \(label) (higher is better)." }
        return fit > best ? "Sound fit \(label): better than your last wording." : "Sound fit \(label): not better than your best so far (\(String(format: "%.2f", best)))."
    }

    /// How a mood, feeling, activity or era is described in this library.
    func lookup(_ query: String) -> String {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return "Say a mood, feeling, activity, genre or era to look up." }
        let genres = genreNames()
        var lines: [String] = []
        if let mood = MoodVocabulary.match(text) {
            lines.append("Mood \"\(mood.name)\": sound words \"\(mood.sound)\", energy \(mood.energy).")
            let fitting = MoodVocabulary.genres(for: mood, in: genres)
            lines.append(fitting.isEmpty ? "No library genre clearly fits; rely on the sound words."
                                         : "Library genres that fit: \(fitting.prefix(8).joined(separator: ", ")).")
        }
        let named = genres.filter { text.contains($0.lowercased()) || $0.lowercased().contains(text) }
        if !named.isEmpty { lines.append("Library genres with that name: \(named.prefix(6).joined(separator: ", ")).") }
        if let range = MoodVocabulary.yearRange(in: text) {
            lines.append("Years: \(range.from.map(String.init) ?? "any") to \(range.to.map(String.init) ?? "now").")
        }
        return lines.isEmpty ? "Nothing in the library is tagged like that. Use it as sound words." : lines.joined(separator: "\n")
    }

    /// How many songs in the library fit these filters, with a few examples.
    func check(genres: [String], from: Int?, to: Int?, sound: String?) async -> String {
        let library = genreNames()
        var steering = DJSteering()
        var unknown: [String] = []
        for genre in genres {
            if let real = library.first(where: { $0.caseInsensitiveCompare(genre.trimmingCharacters(in: .whitespaces)) == .orderedSame }) {
                steering.genres.append(real)
            } else {
                unknown.append(genre)
            }
        }
        steering.earliestYear = from.flatMap { $0 > 0 ? $0 : nil }
        steering.latestYear = to.flatMap { $0 > 0 ? $0 : nil }
        let words = sound?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        steering.sound = words.isEmpty ? nil : words
        guard steering.hasRequest else { return "Give at least a genre, a year range or sound words to check." }

        let found = await planner.pool(for: steering)
        var seen = Set<String>()
        let fits = found.songs.filter { steering.allows($0) && !isHidden($0.id) && seen.insert($0.id).inserted }

        var notes: [String] = []
        if !unknown.isEmpty { notes.append("These genres don't exist in the library and were ignored: \(unknown.joined(separator: ", ")).") }
        if steering.sound != nil, !found.usedSound { notes.append("Sound search found nothing or isn't available, so only genres and years were used.") }
        if fits.isEmpty { return (["No songs fit. Loosen the years or drop the genre."] + notes).joined(separator: " ") }
        let examples = fits.prefix(5).map { song in
            "\(song.name) by \(song.artistLine)" + (song.productionYear.map { " (\($0))" } ?? "")
        }
        let count = fits.count >= 60 ? "Plenty (60 or more) songs fit." : "\(fits.count) songs fit."
        if let fit = await soundFit(steering.sound) { notes.append(fit) }
        return ([count, "For example: " + examples.joined(separator: "; ") + "."] + notes).joined(separator: " ")
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, *)
struct FindTagsTool: Tool {
    let probe: DJLibraryProbe
    let name = "findTags"
    let description = "Looks up how a mood, feeling, activity or era is described in the listener's library: the sound words and the genres that fit. Use it first for moods like sad, happy, focus or dinner."

    @Generable
    struct Arguments {
        @Guide(description: "The mood, feeling, activity, genre or era, in the listener's words")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        await probe.lookup(arguments.query)
    }
}

@available(iOS 26.0, macOS 26.0, *)
struct CheckLibraryTool: Tool {
    let probe: DJLibraryProbe
    let name = "checkLibrary"
    let description = "Counts how many songs in the listener's library fit a plan, and gives examples. Use it before changing the music, with the genres, years and sound words you intend to use."

    @Generable
    struct Arguments {
        @Guide(description: "Genres from the library that fit. Empty if none.")
        var genres: [String]
        @Guide(description: "Earliest release year, or 0 for any")
        var earliestYear: Int
        @Guide(description: "Latest release year, or 0 for any")
        var latestYear: Int
        @Guide(description: "Sound words describing the feel, like 'sad melancholic emotional'. Empty if none.")
        var sound: String
    }

    func call(arguments: Arguments) async throws -> String {
        await probe.check(genres: arguments.genres, from: arguments.earliestYear, to: arguments.latestYear, sound: arguments.sound)
    }
}
#endif
