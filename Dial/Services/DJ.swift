import AVFoundation
import Observation
import SwiftUI

struct DJMessage: Identifiable, Equatable {
    enum Sender: String, Codable { case listener, dj }
    let id = UUID()
    let sender: Sender
    let text: String
}

/// A Marlo session, as one Dial hands it to another: what you asked for, the chat,
/// the songs already played and the block that's on.
struct DJSessionSnapshot: Codable, Sendable {
    struct Message: Codable, Sendable {
        let sender: DJMessage.Sender
        let text: String
    }

    var steering: DJSteering
    var messages: [Message]
    var usedIds: [String]
    var blockTitle: String?
    var blockKind: DJBlock.Kind?
}

/// What the Dial running Marlo tells your other Dials, so they show the same session.
struct DJSharedState: Codable, Sendable {
    var active: Bool
    var onAir: Bool
    var caption: String?
    var session: DJSessionSnapshot
}

/// Things another Dial can ask the Marlo running here to do.
enum DJRemoteCommand: String, Codable, Sendable {
    case somethingDifferent, skipBreak, stop, stopQuietly
    /// "Tell me what you're doing": sent when a Dial starts following this one.
    case shareState
}

/// What Marlo is doing while a set is being put together, so the screen can say it: understanding the request, choosing songs,
/// writing the intro, cueing the first song, and what has been decided so far.
struct DJPrep: Equatable {
    enum Step: Int, CaseIterable, Identifiable {
        case understanding, choosing, writing, cueing
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .understanding: return "Understanding what you asked"
            case .choosing: return "Choosing songs from your library"
            case .writing: return "Writing the intro"
            case .cueing: return "Cueing up the first song"
            }
        }
    }

    var steps: [Step]
    var step: Step
    /// What was asked for, when something was.
    var request: String?
    /// Filled in as it is decided.
    var blockTitle: String?
    var songs: [String] = []
    var why: [String] = []
    var line: String?
}

/// A radio DJ for your own library, working like Spotify's DJ:
/// - The music comes in short themed blocks built from your listening: what's on repeat,
///   songs you love, throwbacks you haven't heard in months, deep cuts, new arrivals,
///   an artist spotlight, something new to you, a mood for the time of day.
/// - Between blocks the music dips and the DJ says why these songs, using real facts.
/// - Tap the DJ button to change it up; hold it (or type) to ask for something. Follow-ups
///   steer the session ("more upbeat", "add some Bad Bunny", "only Kanye", "no more rap").
/// - Ask about what's playing and it answers without stopping the music.
@MainActor
@Observable
final class DJ {
    private(set) var isActive = false {
        didSet { stateChanged() }
    }
    private(set) var isPreparing = false
    /// What is going on while it prepares (nil when it is not preparing).
    private(set) var prep: DJPrep?
    /// True during a break: the player shows the DJ instead of the song.
    private(set) var isOnAir = false {
        didSet { stateChanged() }
    }
    /// What the DJ is saying (shown as a caption during a break).
    private(set) var caption: String? {
        didSet { stateChanged() }
    }
    /// When the DJ last started a word; the on-air ring pulses from this.
    private(set) var lastWordAt: Date = .distantPast
    private(set) var messages: [DJMessage] = [] {
        didSet { stateChanged() }
    }
    /// The block playing now ("Throwbacks", "Spotlight: The Weeknd").
    private(set) var currentBlock: DJBlock? {
        didSet { stateChanged() }
    }
    /// What the session is steered toward right now.
    private(set) var steering = DJSteering()

    var name: String { settings?.displayDJName ?? AppSettings.defaultDJName }
    var isSpeaking: Bool { isOnAir && caption != nil }

    @ObservationIgnored var client: JellyfinClient?
    @ObservationIgnored weak var settings: AppSettings?
    @ObservationIgnored weak var audioMuse: AudioMuse?
    @ObservationIgnored weak var history: ListeningHistory?
    @ObservationIgnored var isHidden: (String) -> Bool = { _ in false }
    @ObservationIgnored weak var player: Player? {
        didSet {
            player?.onTrackStart = { [weak self] track in self?.trackStarted(track) }
            player?.onNearEnd = { [weak self] track in self?.trackNearEnd(track) }
            player?.onTakeover = { [weak self] in self?.stop(silently: true) }
        }
    }

    /// True while this device shows the Marlo running on another Dial (and its chat).
    private(set) var isMirroring = false
    /// Called whenever something others should see changes (block, on air, chat).
    @ObservationIgnored var onStateChange: (() -> Void)?
    /// Sends a command to the Marlo on the other device, while mirroring it.
    @ObservationIgnored var sendCommand: ((DJRemoteCommand) -> Void)?

    private func stateChanged() {
        guard !isMirroring else { return }
        onStateChange?()
    }

    /// The session as it stands, to share with or hand to another Dial.
    func snapshot() -> DJSessionSnapshot {
        DJSessionSnapshot(steering: steering,
                          messages: messages.suffix(20).map { .init(sender: $0.sender, text: String($0.text.prefix(400))) },
                          usedIds: Array((planner?.usedIds ?? []).suffix(150)),
                          blockTitle: currentBlock?.title,
                          blockKind: currentBlock?.kind)
    }

    var sharedState: DJSharedState {
        DJSharedState(active: isActive, onAir: isOnAir, caption: caption, session: snapshot())
    }

    /// Shows the Marlo running on another Dial: its block, on-air captions and chat.
    func mirror(_ state: DJSharedState?) {
        guard let state, state.active else {
            if isMirroring {
                // Clear while still mirroring, so nothing is shared from here.
                isActive = false
                isOnAir = false
                caption = nil
                currentBlock = nil
                isMirroring = false
            }
            return
        }
        isMirroring = true
        isActive = true
        steering = state.session.steering
        if currentBlock?.title != state.session.blockTitle {
            currentBlock = state.session.blockTitle.map {
                DJBlock(kind: state.session.blockKind ?? .request, title: $0, tracks: [], facts: [])
            }
        }
        if isOnAir != state.onAir { withAnimation(.easeInOut(duration: 0.4)) { isOnAir = state.onAir } }
        caption = state.caption
        if state.caption != nil { lastWordAt = .now }
        let shared = state.session.messages.map { DJMessage(sender: $0.sender, text: $0.text) }
        if shared.map(\.text) != messages.map(\.text) { messages = shared }
    }

    /// Continues a session handed over from another Dial: same requests, same chat,
    /// no repeats, picking up the music where it was.
    func resume(_ session: DJSessionSnapshot, queue: [BaseItem], index: Int, position: TimeInterval) {
        guard let player, let planner = makePlanner(), queue.indices.contains(index) else { return }
        mirror(nil)
        self.planner = planner
        planner.remember(ids: session.usedIds)
        planner.remember(queue)
        steering = session.steering
        messages = session.messages.map { DJMessage(sender: $0.sender, text: $0.text) }
        currentBlock = session.blockTitle.map { DJBlock(kind: session.blockKind ?? .request, title: $0, tracks: [], facts: []) }
        announcements = [:]
        blocksByFirstSong = [:]
        isActive = true
        player.setVolume(1)
        player.play(queue, startAt: index, fromDJ: true)
        if position > 1 { player.seek(to: position) }
        if queue.count - index <= 2 {
            Task { await queueNextBlock(after: queue[index]) }
        }
    }

    /// A command from the Dial that's controlling this one.
    func perform(_ command: DJRemoteCommand) async {
        switch command {
        case .somethingDifferent: await changeDirection()
        case .skipBreak: skipBreak()
        case .stop: stop()
        case .stopQuietly: stop(silently: true)
        case .shareState: if isActive { onStateChange?() }
        }
    }

    /// The last thing the listener asked for, so the DJ can move to another device with it.
    private(set) var lastRequest: String?
    /// When the music is playing on another Dial, the DJ runs there instead. Returns true if it did.
    @ObservationIgnored var runElsewhere: ((String?) -> Bool)?

    @ObservationIgnored private let speaker = Speaker()
    @ObservationIgnored private var planner: DJPlanner?
    /// Lines waiting for a particular song to start, keyed by song id.
    @ObservationIgnored private var announcements: [String: String] = [:]
    /// Blocks waiting to start, keyed by their first song.
    @ObservationIgnored private var blocksByFirstSong: [String: DJBlock] = [:]
    @ObservationIgnored private var conversation: AnyObject?
    @ObservationIgnored private var breakTask: Task<Void, Never>?
    @ObservationIgnored private var libraryGenres: [BaseItem] = []
    @ObservationIgnored private var libraryArtists: [BaseItem] = []

    init() {
        speaker.onWord = { [weak self] in self?.lastWordAt = .now }
    }

    // MARK: Starting, steering and stopping

    func start() async {
        if runElsewhere?(nil) == true { return }
        lastRequest = nil
        steering = DJSteering()
        await begin(reply: nil)
    }

    /// Something the listener typed or said.
    func handle(request text: String) async {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        messages.append(DJMessage(sender: .listener, text: request))
        lastRequest = request
        if runElsewhere?(request) == true {
            if !isMirroring { messages.append(DJMessage(sender: .dj, text: "On it. Playing it where your music is.")) }
            return
        }
        isPreparing = true
        prep = DJPrep(steps: DJPrep.Step.allCases, step: .understanding, request: request)
        defer { isPreparing = false; prep = nil }

        await loadLibraryNames()
        var currentConversation = conversation
        let turn = await DJInterpreter.converse(request, context: context(), conversation: &currentConversation)
        conversation = currentConversation

        // Just talking: answer and keep the music as it is.
        if !turn.changeMusic && isActive {
            messages.append(DJMessage(sender: .dj, text: turn.reply ?? "I\u{2019}m here. Tell me what you\u{2019}d like to hear."))
            return
        }
        var mood = turn.mood
        if mood.artists.isEmpty && mood.description == nil && !mood.isFollowUp && mood.genres.isEmpty {
            mood.description = request // a described sound, for AudioMuse
        }
        steering.apply(mood)
        let reply = turn.reply ?? (mood.isFollowUp ? "You got it." : "Coming up.")
        if isActive {
            await changeNow(reply: reply)
        } else {
            await begin(reply: reply)
        }
    }

    /// A vibe picked with a tap: no need to have the request interpreted, so it goes straight to choosing songs.
    func play(sound: String, title: String) async {
        messages.append(DJMessage(sender: .listener, text: title))
        lastRequest = title
        if runElsewhere?(title) == true {
            if !isMirroring { messages.append(DJMessage(sender: .dj, text: "On it. Playing it where your music is.")) }
            return
        }
        var mood = DJMood()
        mood.description = sound
        steering.apply(mood)
        prep = DJPrep(steps: [.choosing, .writing, .cueing], step: .choosing, request: title)
        if isActive { await changeNow(reply: "You got it.") } else { await begin(reply: "Coming up.") }
    }

    /// Tap the DJ button: a new block right away, like Spotify's "change it up".
    func changeDirection() async {
        if isMirroring { sendCommand?(.somethingDifferent); return }
        guard isActive else { return }
        await changeNow(reply: nil)
    }

    /// Ends a break early and goes straight to the music.
    func skipBreak() {
        if isMirroring { sendCommand?(.skipBreak); return }
        guard isOnAir else { return }
        breakTask?.cancel()
        speaker.stop()
        endBreak()
        if player?.isPlaying == false { player?.resume() }
        Task { await player?.fadeVolume(to: 1, over: 0.4) }
    }

    func stop(silently: Bool = false) {
        if isMirroring {
            // The other device stops its own Marlo when its music is replaced; a stop you tap goes there.
            if !silently { sendCommand?(.stop) }
            return
        }
        guard isActive else { return }
        isActive = false
        currentBlock = nil
        announcements.removeAll()
        blocksByFirstSong.removeAll()
        breakTask?.cancel()
        speaker.stop()
        endBreak()
        player?.setVolume(1)
        if !silently {
            messages.append(DJMessage(sender: .dj, text: "That's \(name) signing off. Play the DJ station whenever you want me back."))
        }
    }

    private func makePlanner() -> DJPlanner? {
        guard let client else { return nil }
        return DJPlanner(client: client, history: history, audioMuse: audioMuse, isHidden: isHidden)
    }

    private func begin(reply: String?) async {
        guard let player, let planner = makePlanner() else { return }
        self.planner = planner
        isPreparing = true
        if prep == nil { prep = DJPrep(steps: [.choosing, .writing, .cueing], step: .choosing, request: nil) } else { prep?.step = .choosing }
        defer { isPreparing = false; prep = nil }
        player.prepare(PendingPlayback(title: name, subtitle: "Choosing songs\u{2026}", artwork: .dj))
        guard let found = await firstBlock(planner, current: nil) else {
            player.cancelPending()
            messages.append(DJMessage(sender: .dj, text: "I couldn\u{2019}t find songs for that in your library. Try something broader?"))
            return
        }
        let block = await planner.withStats(found.block)
        note(block)
        Task { await planner.warmUp() } // the slow parts load while the first song plays
        let line = await DJCommentary.line(for: block, djName: name, opening: reply == nil, reply: reply, timeout: 2.5)
        prep?.line = line
        prep?.step = .cueing
        try? await Task.sleep(for: .milliseconds(900)) // long enough to read what was decided
        messages.append(DJMessage(sender: .dj, text: line))
        noteLoosened(found.note)
        announcements = [block.tracks[0].id: line]
        blocksByFirstSong = [block.tracks[0].id: block]
        currentBlock = block
        isActive = true
        player.setVolume(Self.isLong(line) ? 0 : Self.breakVolume) // the first song starts quietly under a short intro, silently under a long one
        player.play(block.tracks, fromDJ: true)
    }

    /// Replaces what's coming with a new block now, and talks over its first song.
    private func changeNow(reply: String?) async {
        guard let player, let planner else { return }
        isPreparing = true
        if prep == nil { prep = DJPrep(steps: [.choosing, .writing, .cueing], step: .choosing, request: nil) } else { prep?.step = .choosing }
        defer { isPreparing = false; prep = nil }
        guard let found = await firstBlock(planner, current: player.current, quick: reply == nil) else {
            messages.append(DJMessage(sender: .dj, text: "I couldn\u{2019}t find anything for that in your library."))
            return
        }
        let block = await planner.withStats(found.block)
        note(block)
        let line = await DJCommentary.line(for: block, djName: name, opening: false, reply: reply, timeout: 2)
        prep?.line = line
        prep?.step = .cueing
        messages.append(DJMessage(sender: .dj, text: line))
        noteLoosened(found.note)
        announcements = [block.tracks[0].id: line]
        blocksByFirstSong = [block.tracks[0].id: block]
        player.replaceUpNext(with: block.tracks)
        Task { await player.fadeVolume(to: Self.breakVolume, over: 0.3) }
        try? await Task.sleep(for: .milliseconds(250))
        player.next()
    }

    /// The block for what was just asked: one that answers the request (loosened if the library is thin
    /// on it) when there is a request, otherwise the usual mix.
    private func firstBlock(_ planner: DJPlanner, current: BaseItem?, quick: Bool = false) async -> (block: DJBlock, note: String?)? {
        if steering.hasRequest, let hit = await planner.requestBlockRelaxing(steering) {
            steering = hit.steering
            return (hit.block, hit.note)
        }
        guard let block = await planner.nextBlock(steering: steering, current: current, quick: quick) else { return nil }
        return (block, nil)
    }

    /// Records what was chosen, for the screen that says what Marlo is doing.
    private func note(_ block: DJBlock) {
        prep?.blockTitle = block.title
        prep?.songs = block.tracks.prefix(3).map(\.name)
        prep?.why = Array(block.facts.prefix(2))
        prep?.step = .writing
    }

    private func noteLoosened(_ note: String?) {
        guard let note else { return }
        messages.append(DJMessage(sender: .dj, text: "Not many songs matched exactly, so I went with \(note)."))
    }

    private func context() -> DJContext {
        let nowPlaying = player?.current.map { track -> String in
            var parts = ["\"\(track.name)\" by \(track.artistLine)"]
            if let album = track.album { parts.append("from the album \(album)") }
            if let year = track.productionYear { parts.append("released \(year)") }
            if let genres = track.genres, !genres.isEmpty { parts.append("genre \(genres.prefix(2).joined(separator: ", "))") }
            parts.append("the listener has played it \(track.plays) times")
            if let block = currentBlock { parts.append("part of the block \"\(block.title)\"") }
            return parts.joined(separator: ", ")
        }
        return DJContext(djName: name,
                         libraryGenres: libraryGenres.map(\.name),
                         libraryArtists: libraryArtists.map { ArtistNames.primary($0.name) },
                         nowPlaying: nowPlaying,
                         isOnAir: isActive,
                         canSearchBySound: audioMuse?.canSearchBySound == true,
                         probe: makePlanner().map { planner in
                             DJLibraryProbe(planner: planner, audioMuse: audioMuse, isHidden: isHidden, genreNames: { [weak self] in self?.libraryGenres.map(\.name) ?? [] })
                         })
    }

    // MARK: Breaks

    /// Music volume while the DJ talks.
    private static let breakVolume: Float = 0.1

    private func trackNearEnd(_ track: BaseItem) {
        // A break is coming: fade the song out instead of cutting it.
        guard isActive, let next = player?.upNext.first, announcements[next.id] != nil else { return }
        Task { await player?.fadeVolume(to: Self.breakVolume, over: 3.5) }
    }

    private func trackStarted(_ track: BaseItem) {
        guard isActive, let player else { return }
        if let block = blocksByFirstSong.removeValue(forKey: track.id) {
            withAnimation { currentBlock = block }
        }
        if let line = announcements.removeValue(forKey: track.id) {
            breakTask?.cancel()
            breakTask = Task { await onAir(line) }
        } else if isOnAir {
            skipBreak() // skipped to another song in the middle of a break
        } else if player.musicVolume < 1 {
            Task { await player.fadeVolume(to: 1, over: 0.6) } // never leave the music quiet
        }
        // When the block is about to run out, line up the next one.
        if player.upNext.count <= 1, !isPreparing {
            Task { await queueNextBlock(after: track) }
        }
    }

    /// The break itself. A short line goes over the quiet start of the song. A long one is heard alone: the song is held, and
    /// comes in only for the last few seconds of the line, so it never sits under ten seconds of talking. Then a short breath
    /// and the music swells back up.
    private static let leadIn: Double = 4

    /// A line long enough that the song should wait for it (about six seconds or more of speech).
    private static func isLong(_ line: String) -> Bool { Double(line.split(separator: " ").count) / 2.6 > leadIn + 1.5 }

    private func onAir(_ line: String) async {
        guard let player else { return }
        let longLine = Self.isLong(line)
        player.setVolume(longLine ? 0 : Self.breakVolume)
        if longLine { player.pause() }
        withAnimation(.easeInOut(duration: 0.4)) { isOnAir = true }
        try? await Task.sleep(for: .milliseconds(700))
        guard !Task.isCancelled else { return }
        caption = line
        var songStarted = !longLine
        speaker.onRemaining = { [weak self] seconds in
            guard let self, !songStarted, seconds <= Self.leadIn else { return }
            songStarted = true
            player.setVolume(0.02)
            player.resume()
            Task { await player.fadeVolume(to: Self.breakVolume, over: 1.5) }
        }
        await speaker.say(line, voiceId: settings?.djVoiceId)
        speaker.onRemaining = nil
        guard !Task.isCancelled, isActive else { return }
        if !songStarted { player.resume() } // the voice ended before the estimate said it would
        try? await Task.sleep(for: .milliseconds(1200))
        guard !Task.isCancelled else { return }
        endBreak()
        await player.fadeVolume(to: 1, over: 2.5)
    }

    private func endBreak() {
        caption = nil
        withAnimation(.easeInOut(duration: 0.5)) { isOnAir = false }
    }

    private func queueNextBlock(after track: BaseItem) async {
        guard let planner else { return }
        isPreparing = true
        defer { isPreparing = false }
        guard isActive, let plain = await planner.nextBlock(steering: steering, current: track) else { return }
        let block = await planner.withStats(plain)
        // Glide into a different sound over a couple of songs; the DJ talks when the block arrives.
        let lead = await bridge(from: track, to: block.tracks[0])
        planner.remember(lead)
        let line = block.speaks ? await DJCommentary.line(for: block, djName: name, opening: false) : nil
        player?.appendFromDJ(lead + block.tracks)
        if let line { announcements[block.tracks[0].id] = line }
        blocksByFirstSong[block.tracks[0].id] = block
    }

    /// A couple of songs between two sounds (AudioMuse), so a change doesn't feel abrupt.
    /// Never used while you've asked for particular artists.
    private func bridge(from track: BaseItem, to seed: BaseItem) async -> [BaseItem] {
        guard steering.onlyArtists.isEmpty, let audioMuse, audioMuse.canFindPaths, track.id != seed.id,
              let path = try? await audioMuse.path(from: track.id, to: seed.id, steps: 6) else { return [] }
        let played = Set(player?.queue.map(\.id) ?? [])
        return Array(path.dropFirst().dropLast().filter { !played.contains($0.id) && !isHidden($0.id) && steering.allows($0) }.prefix(2))
    }

    private func loadLibraryNames() async {
        guard let client else { return }
        if libraryGenres.isEmpty { libraryGenres = (try? await client.genres()) ?? [] }
        if libraryArtists.isEmpty { libraryArtists = (try? await client.distinctArtists()) ?? [] }
    }
}

// MARK: - Voice

/// Speaks with one of the iPhone's built-in voices. Works offline and in the background.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var finished: CheckedContinuation<Void, Never>?
    /// Called as each word starts, so visuals can move with the voice.
    var onWord: (() -> Void)?
    /// Called with the seconds the line still has to run (estimated from how fast it is being spoken).
    var onRemaining: ((Double) -> Void)?
    private var spokenText = ""
    private var startedAt = Date()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// English voices installed on this iPhone, best quality first. Novelty voices are left out.
    static var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }

    static func voice(for identifier: String?) -> AVSpeechSynthesisVoice? {
        if let identifier, let chosen = AVSpeechSynthesisVoice(identifier: identifier) { return chosen }
        return availableVoices.first ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    func say(_ text: String, voiceId: String?) async {
        stop()
        spokenText = text
        startedAt = Date()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(for: voiceId)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02
        utterance.postUtteranceDelay = 0.2
        await withCheckedContinuation { continuation in
            finished = continuation
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        resume()
    }

    private func resume() {
        finished?.resume()
        finished = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.onWord?()
            guard let onRemaining = self.onRemaining else { return }
            let text = self.spokenText as NSString
            let location = min(characterRange.location, text.length)
            let total = max(self.spokenText.split(separator: " ").count, 1)
            let left = text.substring(from: location).split(separator: " ").count
            let spoken = total - left
            let elapsed = Date().timeIntervalSince(self.startedAt)
            let rate = spoken >= 3 && elapsed > 0.5 ? Double(spoken) / elapsed : 2.6
            onRemaining(Double(left) / rate)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resume() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resume() }
    }
}
