import AVFoundation
import Combine
import MediaPlayer
import SwiftUI
import UIKit

enum RepeatMode: Sendable {
    case off, all, one
}

/// Where the music plays. Like Spotify Connect there's one listening session: it plays on
/// one device at a time, and this iPhone controls it wherever it is.
enum PlaybackOutput: Equatable {
    case thisDevice
    case remote(id: String, name: String)
}

/// What you just started, shown right away while its songs load.
struct PendingPlayback: Equatable {
    enum Artwork: Equatable {
        case item(String)
        case dj
        case symbol(String)
    }

    let title: String
    let subtitle: String
    let artwork: Artwork
}

@MainActor
@Observable
final class Player {
    // MARK: Library playback

    private(set) var queue: [BaseItem] = [] {
        didSet {
            // The song loaded ahead isn't next any more (queue edited, shuffled, cleared).
            if let prepared, !queue.indices.contains(prepared.index) || queue[prepared.index].id != prepared.trackId {
                cancelPrepared()
            }
        }
    }
    private(set) var index = 0
    private(set) var shuffleOn = false
    private(set) var repeatMode: RepeatMode = .off
    private(set) var radioOn = false
    private(set) var radioLoading = false
    private(set) var radioTrackIds: Set<String> = []
    /// What the music was started from, when it was a station, a mix or a mixtape ("Chill", "Kanye West \u{00B7} Radio"): shown small in the mini player.
    private(set) var source: String?
    @ObservationIgnored private var pendingSource: String?

    // MARK: Live radio

    private(set) var liveStation: Station?
    /// "Artist - Title" sent by many stations while they play.
    private(set) var liveTitle: String?
    private(set) var stationContext: [Station] = []

    // MARK: Shared state

    private(set) var isPlaying = false
    private(set) var isBuffering = false
    /// A song is opening or a jump is on its way: true until its audio is actually moving.
    private(set) var isLoadingAudio = false
    /// Where that audio should start: the clock isn't shown going back before it while it loads.
    @ObservationIgnored private var loadingTarget: TimeInterval = 0
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var sleepEndsAt: Date?
    private(set) var sleepAtEndOfTrack = false
    var errorMessage: String?

    var isLive: Bool { liveStation != nil }
    var current: BaseItem? {
        guard !isLive, queue.indices.contains(index) else { return nil }
        return queue[index]
    }
    private(set) var output: PlaybackOutput = .thisDevice
    /// The other device's volume, 0 to 100, while playing there.
    private(set) var remoteVolume: Int?

    var isRemote: Bool { if case .remote = output { return true } else { return false } }
    var outputName: String? { if case .remote(_, let name) = output { return name } else { return nil } }

    /// Set the moment you start something that has to load first; cleared once it plays.
    private(set) var pending: PendingPlayback?
    var isStarting: Bool { pending != nil }

    var hasContent: Bool { pending != nil || isLive || current != nil }
    var upNext: [BaseItem] { isLive ? [] : Array(queue.dropFirst(index + 1)) }
    var progress: Double { duration > 0 ? min(currentTime / duration, 1) : 0 }
    var sleepTimerOn: Bool { sleepEndsAt != nil || sleepAtEndOfTrack }

    var nowTitle: String {
        if let pending { return pending.title }
        if let station = liveStation { return liveTitle ?? station.name }
        return current?.name ?? ""
    }

    var nowSubtitle: String {
        if let pending { return pending.subtitle }
        if let station = liveStation { return liveTitle == nil ? station.subtitle : station.name }
        return current?.artistLine ?? ""
    }

    // MARK: Dependencies

    @ObservationIgnored var client: JellyfinClient?
    @ObservationIgnored weak var downloads: DownloadManager?
    @ObservationIgnored weak var settings: AppSettings?
    @ObservationIgnored var equalizerSettings: EqualizerTap.Settings?
    /// Sends commands to the device playing, when it isn't this iPhone.
    @ObservationIgnored weak var remote: RemoteControl?
    /// When playback last started on this device by choice, so the newest start across your devices can win.
    private(set) var playStartedAt = Date.distantPast
    @ObservationIgnored private var remoteClock: Task<Void, Never>?

    /// Called each time a song starts (the DJ uses this to talk between sets).
    @ObservationIgnored var onTrackStart: ((BaseItem) -> Void)?
    /// Called when something other than the DJ replaces what's playing.
    @ObservationIgnored var onTakeover: (() -> Void)?
    /// Called once, a few seconds before the current song ends.
    @ObservationIgnored var onNearEnd: ((BaseItem) -> Void)?
    /// Called when you start something new (songs, a radio or a station), so the app can open the player.
    @ObservationIgnored var onPlay: (() -> Void)?

    /// The music's own volume (the DJ lowers it while talking). The system volume is separate.
    var musicVolume: Float { baseVolume }
    /// Tells the player when the server can't be reached, so it plays only downloaded songs.
    @ObservationIgnored var isOffline: () -> Bool = { false }
    /// Songs the listener hid; never queued automatically.
    @ObservationIgnored var isHidden: (String) -> Bool = { _ in false }
    @ObservationIgnored private var nearEndSent = false

    // MARK: Internals

    /// Two players: the active one plays; the other has the next song ready for a crossfade.
    /// Each is a queue player, so with crossfade off the next song follows with no gap.
    private let players = [AVQueuePlayer(), AVQueuePlayer()]
    @ObservationIgnored private var activeSlot = 0
    private var avPlayer: AVQueuePlayer { players[activeSlot] }
    private var standby: AVQueuePlayer { players[1 - activeSlot] }

    /// The next song, loaded ahead of time.
    private struct Prepared {
        let index: Int
        let trackId: String
        let item: AVPlayerItem
        let playMethod: String
        /// true: waiting in the standby player for a crossfade. false: queued right after this song.
        let crossfade: Bool
    }
    @ObservationIgnored private var prepared: Prepared?
    /// The item of the song Dial considers playing, to tell its end apart from others.
    @ObservationIgnored private var playingItem: AVPlayerItem?
    @ObservationIgnored private var preparedStatus: AnyCancellable?
    @ObservationIgnored private var crossfadeTask: Task<Void, Never>?

    /// The DJ's volume (lowered while it talks), the loudness leveling for each player's song,
    /// and each player's crossfade level, multiplied together.
    @ObservationIgnored private var baseVolume: Float = 1
    /// Dial's own volume, set from another device controlling this one (0 to 1).
    private(set) var outputVolume: Float = 1
    @ObservationIgnored private var levels: [Float] = [1, 1]
    @ObservationIgnored private var fades: [Float] = [1, 1]
    private let metadataReader = StreamMetadataReader()
    /// Plays the YouTube live streams (Lofi Girl); the page itself sits in the window, see `YouTubeHost`.
    let youtube = YouTubeEmbed()
    var isYouTube: Bool { liveStation?.youtubeID != nil }
    @ObservationIgnored private var timeObservers: [Any] = []
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var itemStatus: AnyCancellable?
    @ObservationIgnored private var usingFallback = false
    @ObservationIgnored private var unshuffledQueue: [BaseItem]?
    @ObservationIgnored private var artwork: MPMediaItemArtwork?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    @ObservationIgnored private var reportingItemId: String?
    /// Plays that could not be reported (no connection) are kept here until the server can be told.
    @ObservationIgnored var playLog: PlayLog?
    @ObservationIgnored private var reportingStartedAt = Date()
    @ObservationIgnored private var reportingFurthest: TimeInterval = 0
    @ObservationIgnored private var reportingSession = ""
    /// How the current song reaches the iPhone: "DirectPlay" (downloaded), "DirectStream" (the file as stored)
    /// or "Transcode" (converted by the server).
    @ObservationIgnored private(set) var playMethod = "DirectStream"
    @ObservationIgnored private var lastProgressReport = Date.distantPast
    @ObservationIgnored private var fadeTask: Task<Void, Never>?
    /// For artist and genre radio: songs from that artist or genre to keep mixing in.
    @ObservationIgnored private var radioPool: [BaseItem] = []

    init() {
        for player in players {
            player.automaticallyWaitsToMinimizeStalling = false
            player.actionAtItemEnd = .advance
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        // Activating the audio session can block for a moment, so it happens once, off the main thread.
        Task.detached(priority: .userInitiated) {
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        configureRemoteCommands()
        youtube.onError = { [weak self] code in
            guard let self, self.isYouTube else { return }
            self.isPlaying = false
            self.isBuffering = false
            self.errorMessage = "YouTube wouldn't play this stream (error \(code))."
        }
        youtube.onState = { [weak self] playing, buffering in
            guard let self, self.isYouTube else { return }
            self.isPlaying = playing
            self.isBuffering = buffering
            self.updateNowPlaying()
        }

        metadataReader.onTitle = { [weak self] title in
            guard let self, self.isLive else { return }
            self.liveTitle = title
            self.updateNowPlaying()
        }

        for (slot, player) in players.enumerated() {
            timeObservers.append(player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                queue: .main
            ) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self, self.activeSlot == slot else { return }
                    self.tick(time)
                }
            })
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let item = notification.object as? AVPlayerItem
            MainActor.assumeIsolated { self?.itemEnded(item) }
        }

        for (slot, player) in players.enumerated() {
            player.publisher(for: \.timeControlStatus)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] status in
                    MainActor.assumeIsolated {
                        guard let self, !self.isRemote, !self.isYouTube, self.activeSlot == slot else { return }
                        let wasPlaying = self.isPlaying
                        self.isPlaying = status != .paused
                        // Paused by you: nothing is loading any more (a jump waiting for the copy pauses on purpose).
                        if status == .paused, self.copySeek == nil { self.isLoadingAudio = false }
                        let wasBuffering = self.isBuffering
                        self.isBuffering = status == .waitingToPlayAtSpecifiedRate
                        self.updateNowPlaying()
                        if wasPlaying != self.isPlaying || wasBuffering != self.isBuffering { self.reportProgress() }
                    }
                }
                .store(in: &cancellables)
        }
    }

    @ObservationIgnored private var lastSave = Date.distantPast

    private func tick(_ time: CMTime) {
        guard !isRemote else { return }
        let seconds = time.seconds.isFinite ? time.seconds : 0
        if isLoadingAudio {
            // Hold the clock on the new position until the audio there is playing.
            guard isPlaying, copySeek == nil, seconds > loadingTarget + 0.25 else { return }
            isLoadingAudio = false
        }
        currentTime = seconds
        // The lock screen counts on its own from the last position it was told. If the song jumped (a stream opened again after a
        // pause, a seek that finished late), it would show the old place: tell it again when the two drift apart.
        if !isLive, let anchor = nowPlayingAnchor {
            let expected = anchor.time + (isPlaying ? Date().timeIntervalSince(anchor.wall) : 0)
            if abs(expected - seconds) > 1.5 { updateNowPlaying() }
        }
        // Copy the song once it plays, so the copy doesn't slow down its start.
        if isPlaying, currentTime > 1, let track = current, songCopy?.id != track.id { startCopy(of: track) }
        if Date().timeIntervalSince(lastSave) > 15 {
            lastSave = Date()
            saveSession()
        }
        if !isLive, let d = avPlayer.currentItem?.duration.seconds, d.isFinite, d > 0, abs(d - duration) > 0.5 {
            duration = d
            updateNowPlaying()
        }
        if isPlaying, Date().timeIntervalSince(lastProgressReport) > 10 {
            reportProgress()
        }
        if !isLive, !nearEndSent, duration > 8, duration - currentTime < 4, let track = current {
            nearEndSent = true
            onNearEnd?(track)
        }
        guard !isLive, duration > 0, isPlaying else { return }
        let remaining = duration - currentTime
        if prepared == nil, remaining < crossfadeLength + 20 { prepareNext() }
        if let prepared, prepared.crossfade, crossfadeTask == nil, remaining <= crossfadeLength {
            startCrossfade(into: prepared)
        }
    }

    // MARK: Gapless and crossfade


    /// Which song plays after this one, without changing anything.
    private func upcomingIndex() -> Int? {
        if sleepAtEndOfTrack || (repeatMode == .one && !radioOn) { return nil }
        var candidate = index + 1
        if candidate >= queue.count {
            guard repeatMode == .all, !radioOn, queue.count > 1 else { return nil }
            candidate = 0
        }
        // Offline: only downloaded songs can play.
        if isOffline() {
            let order = Array(candidate..<queue.count) + (repeatMode == .all ? Array(0..<candidate) : [])
            return order.first { downloads?.isDownloaded(queue[$0].id) == true && $0 != index }
        }
        return candidate
    }

    /// Loads the next song ahead of time: queued right behind this one (gapless), or in the
    /// other player for a crossfade. Consecutive songs from the same album never crossfade,
    /// so albums made to flow from track to track play exactly as recorded.
    private func prepareNext() {
        guard let next = upcomingIndex(), let track = current, let made = makeItem(for: queue[next]) else { return }
        let upcoming = queue[next]
        let sameAlbum = upcoming.albumId != nil && upcoming.albumId == track.albumId
            && (upcoming.indexNumber ?? 0) == (track.indexNumber ?? 0) + 1
        let crossfade = crossfadeLength > 0 && !sameAlbum
        attachEqualizer(to: made.item)
        if crossfade {
            standby.removeAllItems()
            standby.insert(made.item, after: nil)
            fades[1 - activeSlot] = 0
            applyVolume()
        } else {
            avPlayer.insert(made.item, after: avPlayer.currentItem)
        }
        prepared = Prepared(index: next, trackId: upcoming.id, item: made.item, playMethod: made.playMethod, crossfade: crossfade)
        preparedStatus = made.item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard status == .failed else { return }
                MainActor.assumeIsolated { self?.cancelPrepared() } // it'll load the normal way instead
            }
    }

    private func cancelPrepared() {
        guard let old = prepared else { return }
        prepared = nil
        preparedStatus = nil
        if old.crossfade {
            if crossfadeTask == nil { standby.removeAllItems() }
        } else {
            avPlayer.remove(old.item)
        }
    }

    /// Both songs play at once while one fades out and the other fades in.
    private func startCrossfade(into next: Prepared) {
        let outgoing = activeSlot
        let incoming = 1 - activeSlot
        let length = max(crossfadeLength, 0.5)
        activeSlot = incoming
        fades[incoming] = 0
        applyVolume()
        players[incoming].play()
        commit(next)
        crossfadeTask = Task { [weak self] in
            let steps = 30
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(Int(length * 1000) / steps))
                guard let self, !Task.isCancelled else { return }
                let progress = Float(step) / Float(steps)
                self.fades[incoming] = progress
                self.fades[outgoing] = 1 - progress
                self.applyVolume()
            }
            guard let self else { return }
            self.finishCrossfade(outgoing: outgoing)
        }
    }

    private func finishCrossfade(outgoing: Int) {
        crossfadeTask = nil
        players[outgoing].pause()
        players[outgoing].removeAllItems()
        fades = [1, 1]
        applyVolume()
    }

    /// Stops any crossfade straight away (you skipped, or started something else).
    private func abortCrossfade() {
        guard let task = crossfadeTask else { return }
        task.cancel()
        finishCrossfade(outgoing: 1 - activeSlot)
    }

    /// The song loaded ahead is now the one playing: update everything that follows the current song.
    private func commit(_ next: Prepared) {
        playingItem = next.item
        prepared = nil
        preparedStatus = nil
        reportStopped()
        index = next.index
        guard let track = current else { return }
        playMethod = next.playMethod
        usingFallback = false
        currentTime = 0
        duration = track.duration ?? 0
        nearEndSent = false
        levels[activeSlot] = level(for: track)
        applyVolume()
        observeFailure(of: next.item) { [weak self] in
            guard let self, self.current?.id == track.id else { return }
            self.loadCurrent(fallback: true)
        }
        loadArtwork(from: client?.imageURL(for: track.imageItemId, size: 600))
        updateNowPlaying()
        reportStart(track)
        if let albumId = track.albumId {
        }
        onTrackStart?(track)
        prefetchNextArtwork()
        saveSession()
        Task { await extendRadioIfNeeded() }
    }

    /// Volume leveling: quieter for loud masters, so songs play at a similar loudness.
    /// Jellyfin measures each song; Dial aims for -14 LUFS (like most streaming services)
    /// and never boosts, so quiet songs play at their normal volume.
    /// The volume leveling applied to a song, in decibels (0 when off or not needed).
    func levelingDecibels(for track: BaseItem) -> Double {
        let linear = Double(level(for: track))
        return linear > 0 ? 20 * log10(linear) : 0
    }

    /// The streaming quality setting, for the signal path view.
    var qualityLimit: Int? { settings?.quality.maxBitrate }
    var crossfadeLength: Double { settings?.crossfadeSeconds ?? 0 }

    private func level(for track: BaseItem) -> Float {
        guard settings?.volumeLeveling ?? true else { return 1 }
        let gain = track.normalizationGain.map { $0 + 4 } ?? -4 // unmeasured songs: a typical level
        return Float(pow(10, min(gain, 0) / 20))
    }

    private func applyVolume() {
        for slot in players.indices {
            players[slot].volume = baseVolume * levels[slot] * fades[slot] * outputVolume
        }
    }

    /// Another device turned Dial's volume up or down.
    func setOutputVolume(_ volume: Float) {
        outputVolume = min(max(volume, 0), 1)
        applyVolume()
        reportProgress()
    }

    /// Another device changed repeat.
    func setRepeat(_ mode: RepeatMode) {
        while repeatMode != mode { cycleRepeat() }
        reportProgress()
    }

    /// Another device turned shuffle on or off.
    func setShuffle(_ on: Bool) {
        if shuffleOn != on { toggleShuffle() }
        reportProgress()
    }

    /// What controlling apps need besides the song: the queue around it, volume and modes.
    private func playbackExtras() -> PlaybackExtras {
        let start = max(index - 20, 0)
        let window = queue.isEmpty ? [] : Array(queue[start..<min(start + 100, queue.count)])
        let mode: String
        switch repeatMode {
        case .off: mode = "RepeatNone"
        case .all: mode = "RepeatAll"
        case .one: mode = "RepeatOne"
        }
        return PlaybackExtras(queueIds: window.map(\.id), volume: Int(outputVolume * 100),
                              repeatMode: mode, shuffled: shuffleOn)
    }

    /// Another Dial is playing a live station that this one sent it: show it here.
    func showRemoteStation(_ station: Station, in list: [Station], playing: Bool = true, announce: Bool = true) {
        guard isRemote else { return }
        pending = nil
        liveStation = station
        liveTitle = nil
        stationContext = list.isEmpty ? [station] : list
        currentTime = 0
        duration = 0
        isPlaying = playing
        loadArtwork(from: station.faviconURL)
        updateNowPlaying()
        if announce { onPlay?() }
    }

    /// The other Dial switched to the next or previous station: follow along here.
    private func stepRemoteStation(by step: Int) {
        guard let station = liveStation, stationContext.count > 1,
              let position = stationContext.firstIndex(where: { $0.id == station.id }) else { return }
        let next = stationContext[(position + step + stationContext.count) % stationContext.count]
        liveStation = next
        liveTitle = nil
        loadArtwork(from: next.faviconURL)
        updateNowPlaying()
    }

    /// The other device is no longer playing a station (it started songs, or stopped).
    func endRemoteStation() {
        guard isRemote, liveStation != nil else { return }
        endLive()
    }

    /// The leveling setting changed: apply it to what's playing.
    func refreshLeveling() {
        if let track = current { levels[activeSlot] = level(for: track) }
        applyVolume()
    }

    // MARK: Starting playback

    /// Plays a list of songs. `shuffle: true` turns shuffle on and starts from a random song.
    func play(_ tracks: [BaseItem], startAt requestedStart: Int = 0, radio: Bool = false, shuffle: Bool = false,
              fromDJ: Bool = false, source named: String? = nil) {
        // Leave out hidden songs, except the one you tapped yourself.
        let picked = tracks.indices.contains(requestedStart) ? tracks[requestedStart].listId : nil
        let tracks = tracks.filter { $0.listId == picked || !isHidden($0.id) }
        let start = tracks.firstIndex { $0.listId == picked } ?? 0
        guard !tracks.isEmpty else { return }
        pending = nil
        source = fromDJ ? nil : (named ?? pendingSource)
        pendingSource = nil
        playStartedAt = .now
        if !fromDJ { remote?.takeOverIfFollowing() }
        if fromDJ && isRemote {
            useThisDevice() // the DJ's voice comes from this iPhone
        }
        if fromDJ {
            shuffleOn = false // the DJ's order matters: it talks before the first song of each set
        } else {
            onTakeover?()
        }
        setVolume(1)
        endLive()
        if shuffle { shuffleOn = true }
        radioOn = radio
        radioTrackIds = []
        radioPool = []

        let first = shuffle ? Int.random(in: 0..<tracks.count) : min(max(start, 0), tracks.count - 1)
        if shuffleOn {
            unshuffledQueue = tracks
            var rest = tracks
            let startItem = rest.remove(at: first)
            queue = [startItem] + rest.shuffled()
            index = 0
        } else {
            unshuffledQueue = nil
            queue = tracks
            index = first
        }
        if isRemote {
            showRemote(position: 0, playing: true)
            remote?.play(queue, from: index, at: 0)
        } else {
            loadCurrent()
        }
        onPlay?()
    }

    /// Opens the player right away for something that still has to load.
    func prepare(_ pending: PendingPlayback) {
        self.pending = pending
        pendingSource = pending.subtitle.localizedCaseInsensitiveContains("radio") ? "\(pending.title) \u{00B7} Radio" : pending.title
        onPlay?()
    }

    func cancelPending(error: String? = nil) {
        pending = nil
        pendingSource = nil
        if let error { errorMessage = error }
    }

    /// Endless radio from a song, album, artist, playlist or genre. Artist and genre radio
    /// open with that artist or genre and keep coming back to it between similar songs.
    func startRadio(from item: BaseItem) {
        switch item.type {
        case nil, "Audio":
            play([item], radio: true)
        case "MusicArtist":
            startArtistRadio(id: item.id, name: ArtistNames.primary(item.name))
        case "MusicGenre":
            startGenreRadio(id: item.id, name: item.name)
        default:
            startPoolRadio(PendingPlayback(title: item.name, subtitle: "Radio", artwork: .item(item.id)),
                           mixSeedId: item.id) { _ in [] }
        }
    }

    func startArtistRadio(id: String, name: String) {
        startPoolRadio(PendingPlayback(title: name, subtitle: "Artist radio", artwork: .item(id)), mixSeedId: id) {
            try await $0.songs(byArtist: id)
        }
    }

    func startGenreRadio(id: String, name: String) {
        startPoolRadio(PendingPlayback(title: name, subtitle: "Genre radio", artwork: .symbol("guitars")), mixSeedId: id) {
            try await $0.songs(inGenre: id)
        }
    }

    /// A radio around a set of songs found by sound (a mood, your sound, a blend): it starts
    /// with them, keeps coming back to them, and fills in with similar songs.
    func startSoundRadio(_ placeholder: PendingPlayback, pool: @escaping () async throws -> [BaseItem]) {
        startPoolRadio(placeholder, mixSeedId: nil, shuffle: false) { _ in try await pool() }
    }

    /// Opens the player immediately, then fetches the songs: some from the pool to start
    /// (and keep coming back to), or a mix of similar songs if the pool is empty.
    private func startPoolRadio(_ placeholder: PendingPlayback, mixSeedId: String?, shuffle: Bool = true,
                                pool: @escaping (JellyfinClient) async throws -> [BaseItem]) {
        guard let client else { return }
        prepare(placeholder)
        Task {
            do {
                var songs = try await pool(client)
                guard pending == placeholder else { return } // something else was started meanwhile
                if !songs.isEmpty {
                    if shuffle { songs.shuffle() }
                    play(Array(songs.prefix(2)), radio: true)
                    radioPool = Array(songs.dropFirst(2))
                    return
                }
                guard let mixSeedId else {
                    cancelPending(error: "Nothing in your library matched \(placeholder.title) yet. AudioMuse may still be analyzing.")
                    return
                }
                let mix = try await client.instantMix(for: mixSeedId, limit: 40)
                guard pending == placeholder else { return }
                guard !mix.isEmpty else {
                    cancelPending(error: "There aren't enough songs yet to make a radio from \(placeholder.title).")
                    return
                }
                play(mix, radio: true)
            } catch {
                cancelPending(error: "Couldn't start the radio: \(error.localizedDescription)")
            }
        }
    }

    /// Opens the player immediately and plays the songs once they've loaded.
    func play(_ placeholder: PendingPlayback, loading: @escaping () async throws -> [BaseItem], shuffle: Bool = false) {
        prepare(placeholder)
        Task {
            do {
                let songs = try await loading()
                guard pending == placeholder else { return }
                guard !songs.isEmpty else {
                    cancelPending(error: "There's nothing to play in \(placeholder.title) yet.")
                    return
                }
                play(songs, shuffle: shuffle)
            } catch {
                cancelPending(error: "Couldn't play \(placeholder.title): \(error.localizedDescription)")
            }
        }
    }

    /// A single song tapped outside an album: it plays first, then the songs AudioMuse finds closest to it,
    /// in a random order that still tends to put the closest first. Radio keeps it going.
    func playLike(_ track: BaseItem, source named: String? = nil) {
        guard let client else { play([track], radio: true, source: named); return }
        let placeholder = PendingPlayback(title: track.name, subtitle: track.artistLine, artwork: .item(track.imageItemId))
        prepare(placeholder)
        Task {
            let closest = ((try? await client.instantMix(for: track.id, limit: 40)) ?? []).filter { $0.id != track.id }
            guard pending == placeholder else { return } // something else was started meanwhile
            pendingSource = named // the list's name, not the song's own title (set by prepare)
            play([track] + Self.closestFirstShuffled(closest), radio: true, source: named)
        }
    }

    /// A random order that tends to keep the closest songs first: each song gets a random key that grows with its rank.
    private static func closestFirstShuffled(_ songs: [BaseItem]) -> [BaseItem] {
        songs.enumerated()
            .map { rank, song in (song, Double.random(in: 0..<1) * Double(rank + 6)) }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// Prefetches the next song's cover so it appears instantly when the song changes.
    private func prefetchNextArtwork() {
        guard let next = upNext.first, let url = client?.imageURL(for: next.imageItemId, size: Theme.Pixels.hero) else { return }
        Task { _ = await ImagePipeline.shared.image(for: url) }
    }

    func playStation(_ station: Station, in list: [Station] = []) {
        guard let url = URL(string: station.streamURL) else {
            errorMessage = "This station has no valid stream address."
            return
        }
        pending = nil
        remote?.takeOverIfFollowing()
        if let id = station.youtubeID {
            startYouTube(station, id: id, in: list)
            return
        }
        youtube.stop()
        if isRemote {
            if remote?.targetIsDial == true {
                // Another Dial can play internet radio itself: send the station there.
                let list = list.isEmpty ? (stationContext.contains(station) ? stationContext : [station]) : list
                remote?.handOff(.station(station, list))
                endLive()
                showRemoteStation(station, in: list)
                return
            }
            useThisDevice()
        }
        onTakeover?()
        setVolume(1)
        reportStopped()
        radioOn = false
        playStartedAt = .now
        liveStation = station
        liveTitle = nil
        if !list.isEmpty {
            stationContext = list
        } else if !stationContext.contains(where: { $0.id == station.id }) {
            stationContext = [station]
        }

        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemMetadataOutput(identifiers: nil)
        output.setDelegate(metadataReader, queue: .main)
        item.add(output)
        observeFailure(of: item) { [weak self] in
            self?.errorMessage = "“\(station.name)” isn't responding right now. Try another station."
        }
        attachEqualizer(to: item)

        clearPlayers()
        levels[activeSlot] = 1
        applyVolume()
        avPlayer.insert(item, after: nil)
        playingItem = item
        currentTime = 0
        duration = 0
        resume()
        loadArtwork(from: station.faviconURL)
        updateNowPlaying()
        onPlay?()
        recordStation(station)
        remote?.stationChanged()
        Task { await RadioBrowser.shared.registerClick(station.id) }
    }

    /// Whatever plays here (a station, or the album of the song) is what the Home Screen widget shows.
    private func recordForWidget() {
        if let station = liveStation { recordStation(station); return }
        guard let track = current else { return }
        WidgetFeed.record(DialWidgetItem(kind: .song, id: track.id, albumId: track.albumId, album: track.album, title: track.name,
                                         subtitle: ArtistNames.primary(track.albumArtist ?? track.artistLine), station: nil),
                          artworkURL: client?.imageURL(for: track.albumId ?? track.imageItemId, size: 400))
    }

    private func recordStation(_ station: Station) {
        WidgetFeed.record(DialWidgetItem(kind: .station, id: station.id, albumId: nil, album: nil, title: station.name, subtitle: station.subtitle,
                                         station: try? JSONEncoder().encode(station)), artworkURL: station.faviconURL)
    }

    /// A live stream that plays in YouTube's embedded player.
    private func startYouTube(_ station: Station, id: String, in list: [Station]) {
        playStartedAt = .now
        youtubeLog.notice("start \(id, privacy: .public), remote: \(self.isRemote)")
        if isRemote { useThisDevice() }
        onTakeover?()
        setVolume(1)
        reportStopped()
        radioOn = false
        clearPlayers()
        liveStation = station
        liveTitle = nil
        stationContext = list.isEmpty ? (stationContext.contains(where: { $0.id == station.id }) ? stationContext : [station]) : list
        currentTime = 0
        duration = 0
        isPlaying = true
        isBuffering = true
        youtube.load(id)
        recordStation(station)
        remote?.stationChanged()
        // If YouTube's player says nothing within a few seconds, say where it got stuck.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.isYouTube, self.liveStation?.id == station.id, self.isBuffering else { return }
            self.errorMessage = "YouTube didn\u{2019}t start. " + (self.youtube.trail.suffix(6).joined(separator: ", "))
        }
        loadArtwork(from: station.faviconURL)
        updateNowPlaying()
        onPlay?()
    }

    // MARK: Queue

    func playNext(_ tracks: [BaseItem]) {
        guard !tracks.isEmpty else { return }
        guard current != nil else { play(tracks); return }
        if isRemote { remote?.enqueue(tracks, next: true) }
        queue.insert(contentsOf: tracks, at: index + 1)
        if var original = unshuffledQueue, let id = current?.id,
           let position = original.firstIndex(where: { $0.id == id }) {
            original.insert(contentsOf: tracks, at: position + 1)
            unshuffledQueue = original
        }
    }

    func addToQueue(_ tracks: [BaseItem]) {
        guard !tracks.isEmpty else { return }
        guard current != nil else { play(tracks); return }
        if isRemote { remote?.enqueue(tracks, next: false) }
        queue.append(contentsOf: tracks)
        unshuffledQueue?.append(contentsOf: tracks)
    }

    func jump(to position: Int) {
        guard queue.indices.contains(position) else { return }
        index = position
        if isRemote {
            showRemote(position: 0, playing: true)
            remote?.play(queue, from: index, at: 0)
        } else {
            loadCurrent()
        }
    }

    /// Positions here are relative to Up Next (0 = the song after the current one).
    func moveUpNext(from source: IndexSet, to destination: Int) {
        var upcoming = upNext
        upcoming.move(fromOffsets: source, toOffset: destination)
        queue = Array(queue.prefix(index + 1)) + upcoming
        unshuffledQueue = nil
    }

    func removeUpNext(at offsets: IndexSet) {
        var upcoming = upNext
        upcoming.remove(atOffsets: offsets)
        queue = Array(queue.prefix(index + 1)) + upcoming
        unshuffledQueue = nil
    }

    func clearUpNext() {
        queue = Array(queue.prefix(index + 1))
        unshuffledQueue = nil
        radioOn = false
    }

    /// Adds the DJ's next set after everything already queued.
    func appendFromDJ(_ tracks: [BaseItem]) {
        queue.append(contentsOf: tracks.filter { !isHidden($0.id) })
    }

    /// Replaces everything after the current song (the DJ's "change direction").
    func replaceUpNext(with tracks: [BaseItem]) {
        queue = Array(queue.prefix(index + 1)) + tracks.filter { !isHidden($0.id) }
        unshuffledQueue = nil
    }

    // MARK: Volume (for talking over the music)

    func setVolume(_ volume: Float) {
        fadeTask?.cancel()
        baseVolume = volume
        applyVolume()
    }

    func fadeVolume(to target: Float, over duration: TimeInterval) async {
        fadeTask?.cancel()
        let start = baseVolume
        let steps = 20
        let pause = max(Int(duration * 1000) / steps, 1)
        let task = Task {
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(pause))
                if Task.isCancelled { return }
                baseVolume = start + (target - start) * Float(step) / Float(steps)
                applyVolume()
            }
        }
        fadeTask = task
        await task.value
    }

    // MARK: Controls

    /// When it was paused (by you), to tell a long wait from a short one.
    @ObservationIgnored private var pausedAt: Date?
    @ObservationIgnored private var stallWatch: Task<Void, Never>?
    @ObservationIgnored private var lastStallReopen = Date.distantPast

    /// Opens the song again at this position: a stream left paused for a while loses its connection, and then pressing play does nothing.
    private func reopenCurrent(at seconds: TimeInterval) {
        guard let track = current, !isLive, !isYouTube else { return }
        pausedAt = nil
        lastStallReopen = Date()
        if needsExactJumps(track), seconds >= 1 { exactTiming.insert(track.id) }
        seekAfterLoad = seconds >= 1 ? seconds : nil
        loadCurrent(fallback: usingFallback)
    }

    /// After pressing play following a pause, checks that the song really moves: if not, the connection died, so it is opened again.
    private func watchForStall() {
        stallWatch?.cancel()
        guard !isLive, !isYouTube else { return }
        let before = avPlayer.currentTime().seconds
        stallWatch = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, self.isPlaying, !self.isRemote, !self.isLive, !self.isLoadingAudio,
                  Date().timeIntervalSince(self.lastStallReopen) > 20 else { return }
            if abs(self.avPlayer.currentTime().seconds - before) < 0.3 { self.reopenCurrent(at: before) }
        }
    }

    func resume() {
        if isYouTube {
            youtube.play()
            isPlaying = true
            updateNowPlaying()
            remote?.stationChanged()
            return
        }
        if isRemote {
            // The device we follow was turned off or closed: nothing would happen there, so play it here, from the same spot.
            if remote?.targetLooksGone == true, let remote {
                Task { await remote.selectThisDevice(startPlaying: true) }
                return
            }
            isPlaying = true
            remote?.command("Unpause")
            return
        }
        // Back from following another device the song is known but nothing is loaded in this player yet: open it where it was.
        if current != nil, !isLive, avPlayer.currentItem == nil {
            seekAfterLoad = currentTime >= 1 ? currentTime : nil
            loadCurrent()
            return
        }
        let wasPausedAt = pausedAt
        pausedAt = nil
        // Left paused for a while (and streaming): the connection is gone, so open the song again where it was.
        if let wasPausedAt, Date().timeIntervalSince(wasPausedAt) > 90, !isLive,
           (avPlayer.currentItem?.asset as? AVURLAsset)?.url.isFileURL != true {
            reopenCurrent(at: currentTime)
            return
        }
        avPlayer.play()
        if wasPausedAt != nil { watchForStall() }
        // A song restored from last time was never reported to the server, so your other devices couldn't see it
        // playing: tell the server now.
        if reportingItemId == nil, !isLive, let track = current {
            reportStart(track)
            reportProgress()
        }
    }

    func pause() {
        if isYouTube {
            youtube.pause()
            isPlaying = false
            updateNowPlaying()
            remote?.stationChanged()
            return
        }
        if isRemote {
            isPlaying = false
            remote?.command("Pause")
            return
        }
        abortCrossfade() // the song fading out stops too
        pausedAt = Date()
        avPlayer.pause()
        saveSession()
    }

    func togglePlayPause() { isPlaying ? pause() : resume() }

    func next() {
        if isRemote {
            remote?.command("NextTrack")
            if isLive { stepRemoteStation(by: 1) }
            return
        }
        if isLive { stepStation(by: 1) } else { advance() }
    }

    func previous() {
        if isRemote {
            remote?.command("PreviousTrack")
            if isLive { stepRemoteStation(by: -1) }
            return
        }
        if isLive { stepStation(by: -1); return }
        if currentTime > 3 || index == 0 {
            seek(to: 0)
        } else {
            index -= 1
            loadCurrent()
        }
    }

    func seek(to seconds: TimeInterval) {
        guard !isLive else { return }
        if isRemote {
            currentTime = seconds
            remote?.seek(to: seconds)
            return
        }
        abortCrossfade()
        // Apple's player ignores a streamed FLAC's seek table and guesses where to jump, landing in the wrong place.
        // Jumps go to the copy of the song kept on this device instead, opened with exact timing (quick on a local file).
        // Jumping back to the start always lands right, so it needs none of this (Previous restarts songs this way).
        if seconds >= 1, let track = current, needsExactJumps(track),
           (playingItem?.asset as? AVURLAsset)?.url.isFileURL != true, !exactTiming.contains(track.id) {
            startCopy(of: track)
            if let copy = songCopy, copy.id == track.id, copy.file == nil, !copy.failed {
                // Still copying: wait at the new position, and jump there once the copy is in.
                copySeek = seconds
                startLoading(at: seconds)
                avPlayer.pause()
                updateNowPlaying()
                return
            }
            if songCopy?.id != track.id || songCopy?.file == nil {
                // No copy could be made: reopen the stream with exact timing (slow, but lands right).
                exactTiming.insert(track.id)
            }
            seekAfterLoad = seconds
            loadCurrent()
            return
        }
        avPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        if isPlaying { startLoading(at: seconds) } else { currentTime = seconds }
        updateNowPlaying()
    }

    private func startLoading(at seconds: TimeInterval) {
        isLoadingAudio = true
        loadingTarget = seconds
        currentTime = seconds
    }

    func toggleShuffle() {
        guard !isLive else { return }
        if shuffleOn {
            shuffleOn = false
            if let original = unshuffledQueue, let id = current?.id,
               let position = original.firstIndex(where: { $0.id == id }) {
                queue = original
                index = position
            }
            unshuffledQueue = nil
        } else {
            shuffleOn = true
            unshuffledQueue = queue
            queue = Array(queue.prefix(index + 1)) + queue.dropFirst(index + 1).shuffled()
        }
        if isRemote {
            // Another Dial shuffles its own queue; other apps get the shuffled queue resent.
            if remote?.targetIsDial == true { remote?.setShuffle(shuffleOn) } else { remote?.play(queue, from: index, at: currentTime) }
        } else {
            reportProgress()
        }
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        cancelPrepared()
        if isRemote { remote?.setRepeat(repeatMode) }
    }

    func toggleRadio() {
        guard !isLive else { return }
        radioOn.toggle()
        if radioOn {
            Task { await extendRadioIfNeeded() }
        } else {
            // Remove the songs radio added that haven't played yet.
            let head = Array(queue.prefix(index + 1))
            let tail = queue.dropFirst(index + 1).filter { !radioTrackIds.contains($0.id) }
            queue = head + tail
        }
    }

    /// Closes the player: stops, empties the queue, and forgets the last session so the next launch starts clean.
    /// Following another device only stops following it (that device keeps playing).
    func close() {
        if isRemote { remote?.stopFollowing() }
        stop()
        Snapshots.save(SavedSession(queue: [], index: 0, position: 0, shuffle: false, radio: false), "last-session")
    }

    func stop() {
        pending = nil
        pendingSource = nil
        source = nil
        if isRemote {
            remote?.command("Stop")
            useThisDevice()
        }
        onTakeover?()
        setVolume(1)
        reportStopped()
        pause()
        clearPlayers()
        endLive()
        queue = []
        index = 0
        radioOn = false
        radioTrackIds = []
        unshuffledQueue = nil
        currentTime = 0
        duration = 0
        cancelSleepTimer()
        updateNowPlaying()
    }

    // MARK: Playing on another device

    /// This iPhone becomes the remote for another device. Local playback stops.
    func useRemote(id: String, name: String) {
        if !isRemote {
            reportStopped()
            clearPlayers()
            endLive()
        }
        output = .remote(id: id, name: name)
        startRemoteClock()
        updateNowPlaying()
    }

    /// Playback comes back to this iPhone's own speaker (the other device is told to stop by the caller).
    func useThisDevice() {
        guard isRemote else { return }
        output = .thisDevice
        remoteVolume = nil
        remoteClock?.cancel()
        isPlaying = false
    }

    /// The other device's latest state, from the server.
    func applyRemote(queue newQueue: [BaseItem], index newIndex: Int, position: TimeInterval,
                     duration newDuration: TimeInterval, playing: Bool, volume: Int?,
                     repeatMode newRepeat: RepeatMode? = nil, shuffled: Bool? = nil) {
        guard isRemote, newQueue.indices.contains(newIndex) else { return }
        // Shuffle and repeat show what the other device is actually doing.
        if let newRepeat { repeatMode = newRepeat }
        if let shuffled, shuffled != shuffleOn {
            shuffleOn = shuffled
            unshuffledQueue = nil
        }
        if liveStation != nil { endLive() }
        let songChanged = current?.id != newQueue[newIndex].id
        queue = newQueue
        index = newIndex
        currentTime = position
        duration = newDuration
        isPlaying = playing
        remoteVolume = volume
        if songChanged {
            loadArtwork(from: client?.imageURL(for: newQueue[newIndex].imageItemId, size: 600))
            prefetchNextArtwork()
            Task { await extendRadioIfNeeded() }
        }
        updateNowPlaying()
    }

    func setRemoteVolume(_ volume: Int) {
        remoteVolume = volume
        remote?.setVolume(volume)
    }

    private func showRemote(position: TimeInterval, playing: Bool) {
        currentTime = position
        duration = current?.duration ?? 0
        isPlaying = playing
        if let track = current {
            loadArtwork(from: client?.imageURL(for: track.imageItemId, size: 600))
        }
        updateNowPlaying()
    }

    /// Moves the progress bar along between updates from the server.
    private func startRemoteClock() {
        remoteClock?.cancel()
        remoteClock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.isRemote, self.isPlaying else { continue }
                self.currentTime = min(self.currentTime + 0.5, max(self.duration, self.currentTime))
            }
        }
    }

    // MARK: Sleep timer

    func setSleepTimer(minutes: Int) {
        cancelSleepTimer()
        sleepEndsAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled else { return }
            self?.pause()
            self?.sleepEndsAt = nil
        }
    }

    func sleepAtEndOfCurrentTrack() {
        cancelSleepTimer()
        sleepAtEndOfTrack = true
        cancelPrepared()
    }

    func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepEndsAt = nil
        sleepAtEndOfTrack = false
    }

    // MARK: Loading songs

    /// A playable item for a song: the downloaded file if there is one, otherwise a stream.
    private func makeItem(for track: BaseItem, fallback: Bool = false) -> (item: AVPlayerItem, playMethod: String)? {
        if let local = downloads?.localURL(for: track.id) {
            return (AVPlayerItem(asset: AVURLAsset(url: local, options: assetOptions(for: track))), "DirectPlay")
        }
        guard let client, !isOffline() else { return nil }
        // The fallback asks the server to convert the song, for files iPhone can't play directly.
        let limit = fallback ? 320_000 : settings?.quality.maxBitrate
        if limit == nil, let copy = songCopy, copy.id == track.id, let file = copy.file {
            return (AVPlayerItem(asset: AVURLAsset(url: file, options: assetOptions(for: track))), "DirectStream")
        }
        guard let url = client.streamURL(for: track.id, maxBitrate: limit) else { return nil }
        // Exact timing only for the original file: a stream the server converts on the fly can't be scanned ahead of time,
        // and asking for it there made songs never start.
        var options = limit == nil && exactTiming.contains(track.id) ? assetOptions(for: track) : [:]
        options["AVURLAssetHTTPHeaderFieldsKey"] = ["Authorization": JellyfinClient.authHeader(token: client.token)]
        let asset = AVURLAsset(url: url, options: options)
        return (AVPlayerItem(asset: asset), limit == nil ? "DirectStream" : "Transcode")
    }

    /// Apple's player seeks FLAC files to the wrong place unless it is told to work out the file's timing exactly: it plays
    /// audio from minutes earlier than the position it reports, and then never notices the song has ended. With the exact
    /// timing the seek lands on the right sample, for the cost of a fraction of a second at the start. Other formats don't
    /// need it (it would make some MP3s slow to start), so it is only used for FLAC, and when the format isn't known.
    /// Songs streamed from the server start at once; reading a whole FLAC ahead of time to get exact timing took ~10 seconds
    /// on a phone. A song only gets it once you jump around in it (see `seek`), which is when it matters.
    private var exactTiming: Set<String> = []

    /// A copy of the streamed FLAC that's playing, saved on this device in one download so jumps in it land right
    /// at once (see `seek`). Only the current song's copy is kept.
    private struct SongCopy {
        let id: String
        var file: URL?
        var failed = false
        let task: Task<Void, Never>
    }
    @ObservationIgnored private var songCopy: SongCopy?
    /// A jump made while the copy was still downloading.
    @ObservationIgnored private var copySeek: TimeInterval?
    nonisolated private static let copiesFolder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "song-copies")

    /// Streamed in the original format and possibly FLAC: the songs Apple's player jumps around in wrongly.
    private func needsExactJumps(_ track: BaseItem) -> Bool {
        downloads?.localURL(for: track.id) == nil && !isOffline() && !usingFallback
            && settings?.quality.maxBitrate == nil && (track.formatLabel == nil || track.formatLabel == "FLAC")
    }

    private func startCopy(of track: BaseItem) {
        guard songCopy?.id != track.id else { return }
        songCopy?.task.cancel()
        songCopy = nil
        copySeek = nil
        guard needsExactJumps(track), let url = client?.downloadURL(for: track.id) else { return }
        let id = track.id
        let task = Task { [weak self] in
            let file = await Self.download(url, id: id)
            guard let self, !Task.isCancelled, self.songCopy?.id == id else { return }
            self.songCopy?.file = file
            self.songCopy?.failed = file == nil
            if let at = self.copySeek {
                self.copySeek = nil
                guard self.current?.id == id else { return }
                if file == nil { self.exactTiming.insert(id) }
                self.seekAfterLoad = at
                self.loadCurrent()
            }
        }
        songCopy = SongCopy(id: id, task: task)
    }

    nonisolated private static func download(_ url: URL, id: String) async -> URL? {
        let manager = FileManager.default
        let folder = copiesFolder
        try? manager.removeItem(at: folder)
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let (temporary, response) = try? await Network.session.download(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        // The player tells the format from the file name.
        let suffix = (response.suggestedFilename as NSString?)?.pathExtension ?? ""
        let file = folder.appending(path: id + "." + (suffix.isEmpty ? "flac" : suffix))
        do { try manager.moveItem(at: temporary, to: file) } catch { return nil }
        return file
    }
    private var seekAfterLoad: TimeInterval?

    private func assetOptions(for track: BaseItem) -> [String: Any] {
        let format = track.formatLabel
        guard format == nil || format == "FLAC" else { return [:] }
        return [AVURLAssetPreferPreciseDurationAndTimingKey: true]
    }

    private func clearPlayers() {
        crossfadeTask?.cancel()
        crossfadeTask = nil
        prepared = nil
        preparedStatus = nil
        for player in players {
            player.pause()
            player.removeAllItems()
        }
        fades = [1, 1]
    }

    // MARK: Picking up where you left off

    /// What was playing, saved on the phone so Dial opens with it after being closed.
    struct SavedSession: Codable, Sendable {
        let queue: [BaseItem]
        let index: Int
        let position: TimeInterval
        let shuffle: Bool
        let radio: Bool
    }

    /// Loads the last session without playing it: the player shows the song, paused at the same spot.
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var restorePosition: TimeInterval?

    func restoreLastSession() async {
        guard current == nil, !isLive, !isRemote, pending == nil,
              let saved = await Snapshots.load(SavedSession.self, "last-session"),
              saved.queue.indices.contains(saved.index) else { return }
        queue = saved.queue
        index = saved.index
        shuffleOn = saved.shuffle
        radioOn = saved.radio
        restoring = true
        restorePosition = saved.position
        loadCurrent()
    }

    /// Saves the session now and then (and when you pause), so a closed app can pick it up.
    func saveSession() {
        guard !isRemote, !isLive, queue.indices.contains(index) else { return }
        let start = max(index - 20, 0)
        let window = Array(queue[start..<min(start + 150, queue.count)])
        Snapshots.save(SavedSession(queue: window, index: index - start, position: currentTime, shuffle: shuffleOn, radio: radioOn),
                       "last-session")
    }

    private func loadCurrent(fallback: Bool = false) {
        guard current != nil, client != nil else { return }
        // Offline: skip ahead to the next downloaded song.
        if isOffline(), let track = current, downloads?.isDownloaded(track.id) != true {
            if let next = queue.indices.dropFirst(index).first(where: { downloads?.isDownloaded(queue[$0].id) == true }) {
                index = next
            } else {
                clearPlayers()
                isPlaying = false
                errorMessage = "You're offline, and none of these songs are downloaded. Download music to play it without a connection."
                return
            }
        }
        guard let track = current else { return }
        reportStopped()
        abortCrossfade()
        clearPlayers()

        guard let made = makeItem(for: track, fallback: fallback) else { return }
        let item = made.item
        playMethod = made.playMethod
        usingFallback = fallback
        levels[activeSlot] = level(for: track)
        applyVolume()

        observeFailure(of: item) { [weak self] in
            guard let self else { return }
            if !self.usingFallback, self.downloads?.localURL(for: track.id) == nil {
                self.loadCurrent(fallback: true)
            } else {
                self.errorMessage = "Couldn't play “\(track.name)”. Check that your server is reachable."
            }
        }

        attachEqualizer(to: item)
        avPlayer.insert(item, after: nil)
        playingItem = item
        currentTime = 0
        duration = track.duration ?? 0
        nearEndSent = false
        if let at = seekAfterLoad {
            seekAfterLoad = nil
            avPlayer.seek(to: CMTime(seconds: at, preferredTimescale: 600))
            currentTime = at
        }
        if restoring {
            // Back where you left off, paused: press play to continue.
            restoring = false
            if let position = restorePosition, position > 1 {
                avPlayer.seek(to: CMTime(seconds: position, preferredTimescale: 600))
                currentTime = position
            }
            restorePosition = nil
            isPlaying = false
            loadArtwork(from: client?.imageURL(for: track.imageItemId, size: 600))
            updateNowPlaying()
            return
        }
        startLoading(at: currentTime)
        // Reported before resume(): resume() reports a song nobody has reported yet, so the server was told twice
        // (two plays counted, and an empty play in the history every time).
        reportStart(track)
        resume()
            loadArtwork(from: client?.imageURL(for: track.imageItemId, size: 600))
        updateNowPlaying()
        onTrackStart?(track)
        prefetchNextArtwork()
        Task { await extendRadioIfNeeded() }
    }

    /// The equalizer hooks into a song's audio only while it is on: an audio tap on every song, even with the equalizer off,
    /// made the player's clock run past the end of songs.
    private func attachEqualizer(to item: AVPlayerItem) {
        guard let equalizerSettings, equalizerSettings.snapshot.enabled, item.audioMix == nil else { return }
        Task { await EqualizerTap.attach(to: item, settings: equalizerSettings) }
    }

    /// The equalizer was switched on or changed: hook it into the song that is playing and the one queued behind it.
    func equalizerChanged() {
        if let playingItem { attachEqualizer(to: playingItem) }
        if let prepared { attachEqualizer(to: prepared.item) }
    }

    private func observeFailure(of item: AVPlayerItem, onFailure: @escaping () -> Void) {
        itemStatus = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { status in
                guard status == .failed else { return }
                MainActor.assumeIsolated { onFailure() }
            }
    }

    private func itemEnded(_ item: AVPlayerItem?) {
        // Only the song that's playing matters (not the one fading out in a crossfade).
        guard let item, item === playingItem else { return }
        if let next = prepared, !next.crossfade {
            commit(next) // already playing, with no gap
            return
        }
        trackEnded()
    }

    private func trackEnded() {
        guard !isLive else { return }
        currentTime = duration
        if sleepAtEndOfTrack {
            sleepAtEndOfTrack = false
            reportStopped()
            pause()
            seek(to: 0)
            return
        }
        if repeatMode == .one && !radioOn {
            loadCurrent()
            return
        }
        advance()
    }

    private func advance() {
        if index + 1 < queue.count {
            index += 1
            loadCurrent()
        } else if radioOn {
            Task {
                while radioLoading { try? await Task.sleep(for: .milliseconds(200)) }
                await extendRadioIfNeeded(force: true)
                if index + 1 < queue.count {
                    index += 1
                    loadCurrent()
                }
            }
        } else if repeatMode == .all && !queue.isEmpty {
            index = 0
            loadCurrent()
        } else {
            reportStopped()
            pause()
            seek(to: 0)
        }
    }

    private func endLive() {
        youtube.stop()
        liveStation = nil
        liveTitle = nil
    }

    private func stepStation(by step: Int) {
        guard let station = liveStation, stationContext.count > 1,
              let position = stationContext.firstIndex(where: { $0.id == station.id }) else { return }
        let next = (position + step + stationContext.count) % stationContext.count
        playStation(stationContext[next])
    }

    // MARK: Radio

    /// When radio is on and fewer than 3 songs are left, ask Jellyfin for songs similar
    /// to the one playing now. Seeding from the current song lets the radio drift
    /// gradually from one style to the next, like a DJ.
    private func extendRadioIfNeeded(force: Bool = false) async {
        guard radioOn, !radioLoading, let client, let now = current else { return }
        let remaining = queue.count - index - 1
        guard force || remaining < 3 else { return }

        radioLoading = true
        defer { radioLoading = false }
        do {
            let existing = Set(queue.map(\.id))
            // Half the time the radio grows from a song you heard a moment ago, so it wanders instead of always
            // returning to the same neighbours of the song playing now.
            let seed = Bool.random() ? (queue.prefix(index + 1).suffix(8).randomElement() ?? now) : now
            let heardLately = Date().addingTimeInterval(-3 * 86_400)
            var fresh = try await client.instantMix(for: seed.id, limit: 80)
                .filter { song in
                    !existing.contains(song.id) && !(song.userData?.lastPlayed.map { $0 > heardLately } ?? false)
                }
            if fresh.isEmpty {
                // Small library: everything similar has played, so fall back to
                // random songs and allow repeats of anything not played recently.
                let recent = Set(queue.suffix(5).map(\.id))
                fresh = try await client.randomSongs(limit: 20)
                    .filter { !recent.contains($0.id) }
            }
            guard radioOn else { return } // radio was switched off while loading
            // Any of the closest 40, in random order: the same top neighbours no longer come back in the same order.
            var batch = Array(fresh.filter { !isHidden($0.id) }.prefix(40).shuffled().prefix(radioPool.isEmpty ? 10 : 4))
            // Artist or genre radio: put two of its own songs back into every batch.
            let own = radioPool.filter { !existing.contains($0.id) }.prefix(2)
            radioPool.removeAll { song in own.contains { $0.id == song.id } }
            for (offset, song) in own.enumerated() {
                batch.insert(song, at: min(offset * 3, batch.count))
            }
            radioTrackIds.formUnion(batch.map(\.id))
            queue.append(contentsOf: batch)
            unshuffledQueue?.append(contentsOf: batch)
            if isRemote { remote?.enqueue(batch, next: false) }
        } catch {
            errorMessage = "Radio couldn't load more songs: \(error.localizedDescription)"
        }
    }

    // MARK: Playback reporting

    private func reportStart(_ track: BaseItem) {
        guard let client else { return }
        reportingItemId = track.id
        reportingSession = UUID().uuidString
        reportingStartedAt = Date()
        reportingFurthest = 0
        lastProgressReport = Date()
        let id = track.id, session = reportingSession, method = playMethod, extras = playbackExtras()
        Task {
            try? await client.report(.start, itemId: id, position: 0, isPaused: true,
                                     playMethod: method, sessionId: session, extras: extras)
        }
    }

    private func reportProgress() {
        guard let client, let id = reportingItemId else { return }
        lastProgressReport = Date()
        reportingFurthest = max(reportingFurthest, currentTime)
        if isOffline() { return } // nobody to tell; the play is kept when the song stops
        let session = reportingSession, method = playMethod, position = currentTime, paused = !isPlaying || isBuffering
        let extras = playbackExtras()
        Task {
            try? await client.report(.progress, itemId: id, position: position, isPaused: paused,
                                     playMethod: method, sessionId: session, extras: extras)
        }
    }

    private func reportStopped() {
        guard let client, let id = reportingItemId else { return }
        reportingItemId = nil
        let session = reportingSession, method = playMethod, position = currentTime
        let started = reportingStartedAt, heard = max(reportingFurthest, position), length = duration, offline = isOffline()
        // Without a connection (or if the report fails) the play is kept and sent later, with the date it really happened.
        if offline {
            playLog?.record(itemId: id, at: started, seconds: heard, duration: length)
            return
        }
        Task { [weak self] in
            do {
                try await client.report(.stopped, itemId: id, position: position, isPaused: false,
                                        playMethod: method, sessionId: session)
            } catch {
                if (error as? URLError) != nil { self?.playLog?.record(itemId: id, at: started, seconds: heard, duration: length) }
            }
        }
    }

    // MARK: Lock screen and Control Center

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            MainActor.assumeIsolated { self?.seek(to: position) }
            return .success
        }
    }

    /// The position the lock screen was last told, and when.
    @ObservationIgnored private var nowPlayingAnchor: (time: TimeInterval, wall: Date)?

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard hasContent else {
            center.nowPlayingInfo = nil
            return
        }
        // Only what plays on this device counts as playing: saying "playing" while another device does makes the
        // Mac and iPhone fight over your earbuds.
        if !isRemote { center.playbackState = isPlaying ? .playing : .paused }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowTitle,
            MPMediaItemPropertyArtist: nowSubtitle,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if isLive {
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
        } else {
            info[MPMediaItemPropertyAlbumTitle] = current?.album ?? ""
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
            nowPlayingAnchor = (currentTime, Date())
        }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled = !isLive
        // The widget shows what plays now: here, or on the device this one follows.
        recordForWidget()
        WidgetFeed.setPlaying(isPlaying)
    }

    private func loadArtwork(from url: URL?) {
        artwork = nil
        artworkTask?.cancel()
        guard let url else { return }
        artworkTask = Task {
            // The same cover the screens show: from the image cache, not downloaded again.
            guard let image = await ImagePipeline.shared.image(for: url), !Task.isCancelled else { return }
            artwork = Player.makeArtwork(image)
            updateNowPlaying()
        }
    }

    /// Built outside the main actor because iOS may ask for the image on a background thread.
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}

/// Reads the song titles that many internet radio stations send along with the audio.
final class StreamMetadataReader: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    var onTitle: (@MainActor (String) -> Void)?

    func metadataOutput(_ output: AVPlayerItemMetadataOutput,
                        didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                        from track: AVPlayerItemTrack?) {
        guard let item = groups.first?.items.first,
              let raw = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return }
        let handler = onTitle
        Task { @MainActor in handler?(raw) }
    }
}
