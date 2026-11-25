import AppIntents

// Siri phrases that work as soon as Dial is installed ("Hey Siri, play my favorites in Dial"), and the same actions in
// the Shortcuts app and Spotlight. They run inside Dial, in the background: the music starts without opening it.

/// "Hey Siri, play something in Dial": asks what, then plays the artist, album, song, playlist or mixtape it finds.
struct PlayInDialIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play from Your Library"
    static let description = IntentDescription("Plays an artist, album, song, playlist, mixtape or genre from your library.")

    @Parameter(title: "What", requestValueDialog: "What should I play?")
    var query: String

    @Parameter(title: "Shuffle", default: false)
    var shuffle: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$query)") { \.$shuffle }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let match = await VoiceCommands.find(query).first else {
            return .result(dialog: "I couldn\u{2019}t find \(query) in your library.")
        }
        guard await VoiceCommands.play(match, shuffle: shuffle) else {
            return .result(dialog: "I couldn\u{2019}t play \(match.title) right now.")
        }
        return .result(dialog: "Playing \(match.title).")
    }
}

/// "Hey Siri, shuffle my library in Dial."
struct ShuffleLibraryIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Shuffle Your Library"
    static let description = IntentDescription("Plays a mix of your whole library.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await VoiceCommands.play(VoiceCommands.library)
        return .result(dialog: "Shuffling your library.")
    }
}

/// "Hey Siri, play my favorites in Dial."
struct PlayFavoritesIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Your Favorites"
    static let description = IntentDescription("Plays songs you love, and more like them.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppModel.shared.play(.favoritesMix)
        return .result(dialog: "Playing your favorites, and more like them.")
    }
}

/// "Hey Siri, start Marlo in Dial."
struct StartDJIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Start Marlo"
    static let description = IntentDescription("Starts Marlo, your DJ, who picks the music and talks between songs.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppModel.shared.play(.dj)
        return .result(dialog: "Here\u{2019}s Marlo.")
    }
}

/// "Hey Siri, play Daily Mix 1 in Dial": a mixtape or one of your playlists, by name.
struct PlayMixIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play a Mix or Playlist"
    static let description = IntentDescription("Plays one of your mixtapes or playlists.")

    @Parameter(title: "Mix or Playlist")
    var mix: MixEntity

    @Parameter(title: "Shuffle", default: false)
    var shuffle: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$mix)") { \.$shuffle }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard await VoiceCommands.play(mix.match, shuffle: shuffle) else {
            return .result(dialog: "I couldn\u{2019}t play \(mix.title) right now.")
        }
        return .result(dialog: "Playing \(mix.title).")
    }
}

/// "Hey Siri, like this song in Dial": adds the song playing now to your favorites.
struct LikeSongIntent: AppIntent {
    static let title: LocalizedStringResource = "Like the Current Song"
    static let description = IntentDescription("Adds the song that\u{2019}s playing to your favorites.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = AppModel.shared
        guard let song = app.player.current else { return .result(dialog: "Nothing is playing in Dial.") }
        if !app.library.favoriteIds.contains(song.id) { app.library.toggleFavorite(song) }
        return .result(dialog: "Added \(song.name) to your favorites.")
    }
}

// MARK: - Mixes and playlists for Siri

/// A mixtape or playlist Siri can name: today's mixtapes and your playlists.
struct MixEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mix or Playlist"
    static let defaultQuery = MixQuery()

    let id: String
    let title: String
    let subtitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }

    var match: VoiceCommands.Match {
        VoiceCommands.Match(identifier: id, title: title) ?? VoiceCommands.Match(kind: .playlist, id: id, title: title)
    }
}

struct MixQuery: EntityStringQuery {
    @MainActor
    private func all() -> [MixEntity] {
        let mixes = DailyMixes.saved().filter { !$0.tracks.isEmpty }.map {
            MixEntity(id: "mixtape:\($0.id)", title: $0.title, subtitle: "Mixtape")
        }
        let playlists = AppModel.shared.library.playlists.map {
            MixEntity(id: "playlist:\($0.id)", title: $0.name, subtitle: "Playlist")
        }
        return mixes + playlists
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [MixEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [MixEntity] {
        let key = LibraryMatcher.key(string)
        return all().filter { LibraryMatcher.key($0.title).contains(key) }
    }

    @MainActor
    func suggestedEntities() async throws -> [MixEntity] { all() }
}

// MARK: - The phrases

struct DialShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayInDialIntent(), phrases: [
            "Play something in \(.applicationName)",
            "Play from my library in \(.applicationName)",
        ], shortTitle: "Play", systemImageName: "play.fill")
        AppShortcut(intent: ShuffleLibraryIntent(), phrases: [
            "Shuffle my library in \(.applicationName)",
            "Play my music in \(.applicationName)",
            "Shuffle \(.applicationName)",
        ], shortTitle: "Shuffle Library", systemImageName: "shuffle")
        AppShortcut(intent: PlayFavoritesIntent(), phrases: [
            "Play my favorites in \(.applicationName)",
            "Play my favorite songs in \(.applicationName)",
        ], shortTitle: "Favorites", systemImageName: "heart.fill")
        AppShortcut(intent: StartDJIntent(), phrases: [
            "Start Marlo in \(.applicationName)",
            "Play Marlo in \(.applicationName)",
            "Start the DJ in \(.applicationName)",
        ], shortTitle: "Start Marlo", systemImageName: "waveform")
        AppShortcut(intent: PlayMixIntent(), phrases: [
            "Play \(\.$mix) in \(.applicationName)",
            "Play my \(\.$mix) in \(.applicationName)",
        ], shortTitle: "Play a Mix", systemImageName: "music.note.list")
        AppShortcut(intent: LikeSongIntent(), phrases: [
            "Like this song in \(.applicationName)",
            "Add this song to my favorites in \(.applicationName)",
        ], shortTitle: "Like Song", systemImageName: "heart")
    }
}
