import AppIntents
import Foundation

/// What the Home Screen widget shows: the last album or station you played here.
struct DialWidgetItem: Codable, Equatable {
    enum Kind: String, Codable { case album, song, station }
    var kind: Kind
    /// The song, album or station this is (changes with every new song).
    var id: String
    /// For a song: its album, so the widget can open it and play from this song.
    var albumId: String?
    var album: String?
    var title: String
    var subtitle: String
    /// The station itself (JSON), so the widget's play button can start it.
    var station: Data?
}

/// Shared between Dial and its widget through an app group: the last played item and its cover.
enum DialWidgetStore {
    static let group = "group.com.nodescraper.dial"
    static let kind = "DialLastPlayed"

    private static var folder: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) }

    static func save(_ item: DialWidgetItem, artwork: Data?) {
        guard let folder, let json = try? JSONEncoder().encode(item) else { return }
        try? json.write(to: folder.appendingPathComponent("last.json"), options: .atomic)
        let cover = folder.appendingPathComponent("cover.jpg")
        if let artwork { try? artwork.write(to: cover, options: .atomic) } else { try? FileManager.default.removeItem(at: cover) }
    }

    /// Whether the music is playing on this device right now, for the button of the widget.
    static func savePlaying(_ playing: Bool) {
        guard let folder else { return }
        try? Data((playing ? "1" : "0").utf8).write(to: folder.appendingPathComponent("playing.txt"), options: .atomic)
    }

    static func load() -> (item: DialWidgetItem, artwork: Data?, playing: Bool)? {
        guard let folder, let json = try? Data(contentsOf: folder.appendingPathComponent("last.json")),
              let item = try? JSONDecoder().decode(DialWidgetItem.self, from: json) else { return nil }
        let playing = (try? String(contentsOf: folder.appendingPathComponent("playing.txt"), encoding: .utf8)) == "1"
        return (item, try? Data(contentsOf: folder.appendingPathComponent("cover.jpg")), playing)
    }
}

/// What the app does when the widget's button is pressed. The app sets this; the button runs in the app.
enum DialIntentHooks {
    @MainActor static var handler: ((_ command: String) -> Void)?
}

/// The widget's play button: starts the last played item without opening Dial.
struct DialPlayLastIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or pause"

    func perform() async throws -> some IntentResult {
        await MainActor.run { DialIntentHooks.handler?("playLast") }
        return .result()
    }
}
