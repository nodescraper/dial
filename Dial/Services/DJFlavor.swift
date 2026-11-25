import Foundation

/// What time it is and what time of year: Marlo leans its choices on both. Mornings are bright and energizing, the
/// afternoon steady and upbeat, evenings warm and relaxed, late nights calm. December is Christmas, late October is
/// spooky, summer is sunny; the other seasons only tint the sound a little.
struct DJFlavor: Equatable, Sendable {
    enum Part: String, Sendable { case morning, midday, afternoon, evening, night }
    enum Season: String, Sendable { case christmas, halloween, summer, winter, spring, autumn }

    let part: Part
    let season: Season

    static func now(_ date: Date = .now) -> DJFlavor {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        let part: Part = switch hour {
        case 5..<9: .morning
        case 9..<12: .midday
        case 12..<17: .afternoon
        case 17..<22: .evening
        default: .night
        }
        let season: Season = switch (month, day) {
        case (12, 1...26): .christmas
        case (10, 24...31): .halloween
        case (12, _), (1, _), (2, _): .winter
        case (3...5, _): .spring
        case (6...8, _): .summer
        default: .autumn
        }
        return DJFlavor(part: part, season: season)
    }

    /// A season with its own music, worth whole blocks of it.
    var hasEvent: Bool { season == .christmas || season == .halloween }

    var title: String {
        switch part {
        case .morning: "Morning"
        case .midday: "Daytime"
        case .afternoon: "Afternoon"
        case .evening: "Evening"
        case .night: "Late night"
        }
    }

    /// How the music should sound now, for AudioMuse's search by sound.
    var sound: String {
        let base: String = switch part {
        case .morning: "energizing bright upbeat fresh morning"
        case .midday: "upbeat positive focused"
        case .afternoon: "feel good groovy steady upbeat"
        case .evening: "warm relaxed mellow smooth evening"
        case .night: "calm slow soft quiet late night"
        }
        let tint: String = switch season {
        case .christmas: "festive warm"
        case .halloween: "dark moody"
        case .summer: "sunny summer"
        case .winter: "cozy"
        case .spring: "fresh light"
        case .autumn: "mellow cozy"
        }
        return base + " " + tint
    }

    /// Sound for the event's own music.
    var eventSound: String {
        season == .christmas ? "christmas holiday festive songs" : "spooky dark halloween"
    }

    /// Library genres that hold the event's music.
    var eventGenres: [String] {
        season == .christmas ? ["Christmas", "Holiday", "Xmas", "Christmas Music", "Holiday Music"] : ["Halloween", "Spooky"]
    }

    /// For Marlo's line: what's true right now.
    var facts: [String] {
        var out = ["It is \(part == .night ? "late at night" : "the \(part.rawValue)"), so the music leans \(leaning)."]
        switch season {
        case .christmas: out.append("It is the Christmas season.")
        case .halloween: out.append("It is almost Halloween.")
        case .summer: out.append("It is summer.")
        default: break
        }
        return out
    }

    private var leaning: String {
        switch part {
        case .morning: "energizing"
        case .midday, .afternoon: "upbeat"
        case .evening: "relaxed"
        case .night: "calm"
        }
    }
}
