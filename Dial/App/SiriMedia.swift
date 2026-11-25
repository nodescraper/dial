#if os(iOS) && !targetEnvironment(macCatalyst)
import Intents

/// "Hey Siri, play Ariana Grande on Dial": Siri's own media requests, like with Apple Music. Siri works out what was
/// said (an artist, album, song, playlist, genre or mood), Dial finds it in your library and plays it. Handled inside
/// the app (no extension), which Siri starts in the background when needed.
enum SiriMedia {
    /// Asks once for permission to use Siri, and tells Siri what's in your library: how much there is, and the names of
    /// your artists and playlists, so unusual names are heard right.
    @MainActor
    static func setUp(client: JellyfinClient, app: AppModel) async {
        if INPreferences.siriAuthorizationStatus() == .notDetermined {
            _ = await withCheckedContinuation { continuation in
                INPreferences.requestSiriAuthorization { continuation.resume(returning: $0) }
            }
        }
        let context = INMediaUserContext()
        context.numberOfLibraryItems = await client.count("Audio")
        context.subscriptionStatus = .subscribed
        context.becomeCurrent()

        let artists = ((try? await client.artists()) ?? []).map { ArtistNames.display($0.name) }
        let playlists = DailyMixes.saved().map(\.title) + app.library.playlists.map(\.name)
        let vocabulary = INVocabulary.shared()
        vocabulary.setVocabularyStrings(NSOrderedSet(array: Array(artists.prefix(1000))), of: .mediaMusicArtistName)
        vocabulary.setVocabularyStrings(NSOrderedSet(array: Array(playlists.prefix(200))), of: .mediaPlaylistTitle)
    }
}

/// Finds and plays what Siri heard.
final class PlayMediaHandler: NSObject, INPlayMediaIntentHandling {
    func resolveMediaItems(for intent: INPlayMediaIntent) async -> [INPlayMediaMediaItemResolutionResult] {
        let matches = await Self.matches(for: intent.mediaSearch)
        guard !matches.isEmpty else { return [.unsupported()] }
        let items = matches.map { match in
            INMediaItem(identifier: match.identifier, title: match.title, type: Self.type(of: match.kind), artwork: nil,
                        artist: match.subtitle)
        }
        return INPlayMediaMediaItemResolutionResult.successes(with: Array(items.prefix(1)))
    }

    func handle(intent: INPlayMediaIntent) async -> INPlayMediaIntentResponse {
        guard let item = intent.mediaItems?.first, let identifier = item.identifier,
              let match = VoiceCommands.Match(identifier: identifier, title: item.title) else {
            return INPlayMediaIntentResponse(code: .failure, userActivity: nil)
        }
        let started: Bool
        if match.kind == .song, match.id == "current" {
            started = await MainActor.run { VoiceCommands.moreLikeThis() }
        } else {
            started = await VoiceCommands.play(match, shuffle: intent.playShuffled ?? false)
        }
        return INPlayMediaIntentResponse(code: started ? .success : .failure, userActivity: nil)
    }

    /// What Siri heard, as Dial's matches.
    private static func matches(for search: INMediaSearch?) async -> [VoiceCommands.Match] {
        guard let search else { return [VoiceCommands.library] }
        if search.reference == .currentlyPlaying {
            return [VoiceCommands.Match(kind: .song, id: "current", title: "More like this")]
        }
        if let genre = search.genreNames?.first, search.mediaName == nil, search.artistName == nil, search.albumName == nil {
            return await VoiceCommands.find(genre, kind: .genre)
        }
        if let mood = search.moodNames?.first, search.mediaName == nil, search.artistName == nil {
            let found = await VoiceCommands.find(mood, kind: .mood)
            if !found.isEmpty { return found }
        }
        switch search.mediaType {
        case .artist:
            return await VoiceCommands.find(search.mediaName ?? search.artistName ?? "", kind: .artist)
        case .album:
            return await VoiceCommands.find(search.mediaName ?? search.albumName ?? "", kind: .album, artist: search.artistName)
        case .song:
            return await VoiceCommands.find(search.mediaName ?? "", kind: .song, artist: search.artistName)
        case .playlist:
            return await VoiceCommands.find(search.mediaName ?? "", kind: .playlist)
        case .genre:
            return await VoiceCommands.find(search.mediaName ?? search.genreNames?.first ?? "", kind: .genre)
        default:
            if let name = search.mediaName {
                return await VoiceCommands.find(name, artist: search.artistName)
            }
            if let album = search.albumName {
                return await VoiceCommands.find(album, kind: .album, artist: search.artistName)
            }
            if let artist = search.artistName {
                return await VoiceCommands.find(artist, kind: .artist)
            }
            return [VoiceCommands.library]
        }
    }

    private static func type(of kind: VoiceCommands.Kind) -> INMediaItemType {
        switch kind {
        case .artist: .artist
        case .album: .album
        case .song: .song
        case .playlist, .mixtape: .playlist
        case .genre: .genre
        case .mood, .library: .music
        }
    }
}
#endif
