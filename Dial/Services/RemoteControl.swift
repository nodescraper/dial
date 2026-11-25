import Foundation
import Observation

/// One listening session across your devices, like Spotify Connect: you pick where the music
/// plays (this iPhone, a TV, the web player, another phone), the music moves there from the same
/// spot, and Dial becomes the remote: play, pause, skip, seek, queue and volume all control that device.
///
/// It also lets other Jellyfin apps control Dial when Dial is the one playing.
@MainActor
@Observable
final class RemoteControl {
    struct Device: Identifiable, Hashable {
        let id: String
        let deviceId: String
        let name: String
        let app: String
        let canBeControlled: Bool
        let nowPlaying: BaseItem?
        let isPaused: Bool
        let userId: String?
        /// When the device last reported where it is in the song. Playing devices do this every few seconds.
        let lastCheckIn: Date?
        /// When the server last heard anything from the device at all.
        var lastActive: Date? = nil

        var isDial: Bool { app == JellyfinClient.clientName }
        /// A device whose last report is old is not playing, whatever the server still lists: the app was closed or reinstalled
        /// mid-song, or it only follows another device. Following a stale one is how the devices ended up chasing each other.
        var isStale: Bool { lastCheckIn.map { Date().timeIntervalSince($0) > 45 } ?? false }
        var isPlaying: Bool { nowPlaying != nil && !isPaused && !isStale }
    }

    private(set) var devices: [Device] = []
    private(set) var isLoading = false
    /// Whether the live connection to the server is up (needed for other devices to control this one).
    private(set) var isLinked = false
    /// Why the server may not know Dial can be controlled, if telling it failed.
    private(set) var capabilitiesProblem: String?
    /// Other sessions on your account that can't be controlled, for troubleshooting.
    private(set) var uncontrollable: [String] = []
    /// Set while switching devices, so the picker can show progress.
    private(set) var switchingTo: String?
    var errorMessage: String?

    @ObservationIgnored weak var player: Player?
    /// For starting Marlo on this device when another Dial hands it over.
    @ObservationIgnored weak var dj: DJ?
    /// Favorites and ratings changed on your other devices are applied here.
    @ObservationIgnored weak var library: LibraryStore?
    @ObservationIgnored var client: JellyfinClient? {
        didSet { connect() }
    }

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var keepAliveTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// While the app is in the background, the periodic sharing and polling loops are paused (the socket stays open).
    @ObservationIgnored private var inBackground = false
    @ObservationIgnored private var pollingPausedForBackground = false
    @ObservationIgnored private var targetDeviceId: String?
    @ObservationIgnored private var lastSeenTarget = Date()
    @ObservationIgnored private var lastSessionsUpdate = Date.distantPast
    @ObservationIgnored private var songs: [String: BaseItem] = [:]

    /// Devices that can play music sent from Dial.
    var receivers: [Device] { devices.filter(\.canBeControlled) }

    /// Whether the device playing is another Dial. Dial-to-Dial can also move live radio and the DJ,
    /// which other Jellyfin apps can't play.
    var targetIsDial: Bool {
        guard let id = targetSessionId else { return false }
        return devices.first { $0.id == id }?.isDial ?? false
    }

    /// What only another Dial understands.
    enum Handoff {
        case station(Station, [Station])
        case dj(request: String?)
        /// The whole Marlo session, moving to another Dial with the music.
        case djSession(DJSessionSnapshot, queueIds: [String], index: Int, position: Double)
        /// What Marlo is doing here, for the Dials following this one.
        case djState(DJSharedState)
        case djCommand(DJRemoteCommand)
        /// The songs coming up on the playing Dial, for the Dials following it.
        case queue([String])
        /// "Send me your queue": a Dial that just started following asks.
        case queueRequest
        /// The live station playing on this Dial (radio, Lofi Girl), for the Dials that are idle or following it.
        case stationState(Station, [Station], playing: Bool, startedAt: Date)
        /// "Tell me if a station is playing there": a Dial that just opened asks.
        case stationRequest
    }

    /// Sends a live station or the DJ to the Dial that's playing.
    func handOff(_ handoff: Handoff) {
        guard let id = targetSessionId else { return }
        if case .station = handoff { stationHandoffUntil = Date().addingTimeInterval(10) }
        Task { await send(handoff, to: id) }
    }

    private func send(_ handoff: Handoff, to sessionId: String) async {
        let payload: [String: Any]
        switch handoff {
        case .station(let station, let list):
            guard let stationData = try? JSONEncoder().encode(station),
                  let listData = try? JSONEncoder().encode(Array(list.prefix(30))),
                  let stationJSON = try? JSONSerialization.jsonObject(with: stationData),
                  let listJSON = try? JSONSerialization.jsonObject(with: listData) else { return }
            payload = ["kind": "station", "station": stationJSON, "list": listJSON]
        case .dj(let request):
            payload = ["kind": "dj", "request": request ?? ""]
        case .djSession(let session, let queueIds, let index, let position):
            guard let json = Self.json(session) else { return }
            payload = ["kind": "djSession", "session": json, "queue": queueIds, "index": index, "position": position]
        case .djState(let state):
            guard let json = Self.json(state) else { return }
            payload = ["kind": "djState", "state": json, "from": JellyfinClient.deviceId]
        case .djCommand(let command):
            payload = ["kind": "djCommand", "command": command.rawValue]
        case .queue(let ids):
            payload = ["kind": "queue", "ids": ids, "from": JellyfinClient.deviceId]
        case .queueRequest:
            payload = ["kind": "queueRequest"]
        case .stationRequest:
            payload = ["kind": "stationRequest"]
        case .stationState(let station, let list, let playing, let startedAt):
            guard let stationJSON = Self.json(station), let listJSON = Self.json(Array(list.prefix(30))) else { return }
            payload = ["kind": "stationState", "station": stationJSON, "list": listJSON, "playing": playing,
                       "startedAt": startedAt.timeIntervalSince1970, "from": JellyfinClient.deviceId]
        }
        guard let text = try? JSONSerialization.data(withJSONObject: payload),
              let body = try? JSONSerialization.data(withJSONObject: [
                  "Header": Self.handoffHeader, "Text": String(decoding: text, as: UTF8.self), "TimeoutMs": 1,
              ]) else { return }
        await post("Sessions/\(sessionId)/Message", body: body)
    }

    private static let handoffHeader = "dial.handoff"

    private static func json<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ object: Any?) -> T? {
        guard let object, let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Sharing the queue

    @ObservationIgnored private var queueShareTask: Task<Void, Never>?
    @ObservationIgnored private var lastSharedQueue = ""
    @ObservationIgnored private var lastQueueShare = Date.distantPast
    /// The queue of the Dial being followed, as it last told us.
    @ObservationIgnored private var sharedQueueIds: [String] = []

    /// While this Dial plays, tell your other Dials what's coming up (when it changes, and now and then),
    /// so they can show the same queue without depending on what the server passes along.
    private func startQueueSharing() {
        queueShareTask?.cancel()
        guard !inBackground else { return }
        queueShareTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                await shareQueue()
                await shareStation()
            }
        }
    }

    /// A live station playing here is told to your other Dials too: an idle one shows it at once, like it does for songs.
    /// A station started, paused or changed here: your other Dials hear of it now, not at the next tick.
    func stationChanged() {
        Task { await shareStation(force: true) }
    }

    @ObservationIgnored private var lastStationShare = Date.distantPast

    /// Sent on change (`force`), and otherwise every 30 seconds, so a Dial that opens later still catches up.
    private func shareStation(force: Bool = false) async {
        guard let player, !player.isRemote, let station = player.liveStation else { return }
        guard force || Date().timeIntervalSince(lastStationShare) > 30 else { return }
        lastStationShare = Date()
        for device in devices where device.isDial {
            await send(.stationState(station, player.stationContext, playing: player.isPlaying, startedAt: player.playStartedAt), to: device.id)
        }
    }

    private func shareQueue(force: Bool = false) async {
        guard let player, !player.isRemote, player.queue.count > 1, player.current != nil else { return }
        let start = max(player.index - 20, 0)
        let ids = player.queue[start..<min(start + 100, player.queue.count)].map(\.id)
        let signature = ids.joined(separator: ",")
        guard force || signature != lastSharedQueue || Date().timeIntervalSince(lastQueueShare) > 30 else { return }
        lastSharedQueue = signature
        lastQueueShare = Date()
        for device in devices where device.isDial { await send(.queue(ids), to: device.id) }
    }

    // MARK: Sharing Marlo's session

    @ObservationIgnored private var djShareTask: Task<Void, Never>?
    @ObservationIgnored private var djRepeatTask: Task<Void, Never>?

    /// Marlo changed something here (block, on air, chat): tell your other Dials, shortly
    /// (several changes at once go out as one message), and again every so often while it runs,
    /// so a Dial that opens later catches up.
    func djStateChanged() {
        guard let dj, let player, !player.isRemote, !dj.isMirroring else { return }
        djShareTask?.cancel()
        djShareTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await shareDJState()
        }
        djRepeatTask?.cancel()
        guard dj.isActive, !inBackground else { return }
        djRepeatTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, self.dj?.isActive == true else { return }
                await shareDJState()
            }
        }
    }

    private func shareDJState() async {
        guard let dj else { return }
        let state = dj.sharedState
        for device in devices where device.isDial {
            await send(.djState(state), to: device.id)
        }
    }

    /// Stops showing another device's Marlo (the music moved, or that device went away).
    private func endMirror() {
        dj?.mirror(nil)
    }

    // MARK: Choosing where to play

    /// Plays on another device. Whatever is playing here continues there from the same spot;
    /// if nothing is playing here, Dial takes control of what that device is already doing.
    func select(_ device: Device) async {
        guard let player else { return }
        if case .remote(let id, _) = player.output, id == device.id { return }
        followingAutomatically = false
        switchingTo = device.id
        defer { switchingTo = nil }

        let queue = player.queue
        let index = player.index
        let position = player.currentTime
        let hasSongs = player.current != nil && !player.isLive
        let previous: String? = { if case .remote(let id, _) = player.output { return id } else { return nil } }()
        let station = player.liveStation
        let stations = player.stationContext
        // Marlo running here, or on the device being followed: its session moves with the music.
        let djRunning = dj?.isActive ?? false
        let djRequest = dj?.lastRequest
        let session = dj?.snapshot()
        if djRunning {
            if dj?.isMirroring == true, let previous {
                await send(.djCommand(.stopQuietly), to: previous)
            }
            dj?.stop(silently: true)
            endMirror()
        }
        player.useRemote(id: device.id, name: device.name)
        targetDeviceId = device.deviceId
        lastSeenTarget = Date()
        startPolling()

        if device.isDial, djRunning, let dj {
            // The same Marlo session continues on the other Dial: music, requests, chat, no repeats.
            let start = max(index - 5, 0)
            let window = queue.isEmpty ? [] : Array(queue[start..<min(start + 60, queue.count)])
            await send(.djSession(session ?? dj.snapshot(), queueIds: window.map(\.id), index: index - start, position: position),
                       to: device.id)
            if let previous { await post("Sessions/\(previous)/Playing/Stop") }
            _ = djRequest
        } else if device.isDial, let station {
            await send(.station(station, stations), to: device.id)
            player.showRemoteStation(station, in: stations)
            if let previous { await post("Sessions/\(previous)/Playing/Stop") }
        } else if hasSongs {
            await send(queue, from: index, at: position, to: device.id)
            if let previous { await post("Sessions/\(previous)/Playing/Stop") }
        } else if let song = device.nowPlaying {
            player.applyRemote(queue: [song], index: 0, position: 0, duration: song.duration ?? 0,
                               playing: !device.isPaused, volume: nil)
            if device.isDial {
                await send(.djCommand(.shareState), to: device.id) // is Marlo running there?
                await send(.queueRequest, to: device.id)
            }
        }
        await refresh()
    }

    /// Whether the device this one follows has gone: it is not listed, or it claims to play but has stopped reporting.
    var targetLooksGone: Bool {
        guard let player, case .remote(let id, _) = player.output else { return false }
        guard let device = devices.first(where: { $0.id == id || $0.deviceId == targetDeviceId }) else { return lastSessionsUpdate != .distantPast }
        return device.nowPlaying != nil && !device.isPaused && device.isStale
    }

    /// Brings the music back to this iPhone, from the same spot, and stops it on the other device.
    /// `startPlaying`: you pressed play here, so it plays whatever the other device was doing.
    func selectThisDevice(startPlaying: Bool = false) async {
        guard let player, case .remote(let id, _) = player.output else { return }
        followingAutomatically = false
        autoFollowPausedUntil = Date().addingTimeInterval(30)
        switchingTo = "this"
        defer { switchingTo = nil }

        let other = devices.first { $0.id == id }
        var queue = player.queue
        var index = player.index
        // Following another device, its queue may not have arrived: its current song is still known.
        if !queue.indices.contains(index), let song = player.current ?? other?.nowPlaying {
            queue = [song]
            index = 0
        }
        let position = player.currentTime
        let wasPlaying = startPlaying || player.isPlaying || (other?.isPlaying ?? false)
        let station = player.liveStation
        let stations = player.stationContext

        let mirroredSession = dj?.isMirroring == true ? dj?.snapshot() : nil
        if mirroredSession != nil { await send(.djCommand(.stopQuietly), to: id) }
        stopPolling()
        targetDeviceId = nil
        endMirror()
        player.useThisDevice()
        // Start here first, then silence the other device: waiting for the server before starting left this phone idle.
        if let session = mirroredSession, queue.indices.contains(index) {
            // The same Marlo session continues here.
            dj?.resume(session, queue: queue, index: index, position: position)
        } else if let station {
            player.playStation(station, in: stations)
        } else if queue.indices.contains(index) {
            player.play(queue, startAt: index)
            if position > 1 { player.seek(to: position) }
            if !wasPlaying { player.pause() }
        }
        await post("Sessions/\(id)/Playing/Stop")
    }

    /// Stops following the other device without touching it (the player was closed here).
    func stopFollowing() {
        followingAutomatically = false
        autoFollowPausedUntil = Date().addingTimeInterval(120)
        stopPolling()
        targetDeviceId = nil
        endMirror()
        player?.useThisDevice()
    }

    /// You started something on this device while it was only following another one on its own (you never picked that device):
    /// the newest start wins, so it plays here and the other device stops. Sending the music to a device that may be gone or
    /// stale is how a start could go nowhere, and how two devices ended up fighting over the same song.
    func takeOverIfFollowing() {
        guard let player, case .remote(let id, _) = player.output, followingAutomatically else { return }
        followingAutomatically = false
        autoFollowPausedUntil = Date().addingTimeInterval(30)
        stopPolling()
        targetDeviceId = nil
        endMirror()
        player.useThisDevice()
        Task { await post("Sessions/\(id)/Playing/Stop") }
    }

    // MARK: Commands for the device that's playing (called by the player)

    func play(_ queue: [BaseItem], from index: Int, at position: TimeInterval) {
        guard let id = targetSessionId else { return }
        Task { await send(queue, from: index, at: position, to: id) }
    }

    func command(_ name: String) {
        guard let id = targetSessionId else { return }
        Task { await post("Sessions/\(id)/Playing/\(name)") }
    }

    func seek(to seconds: TimeInterval) {
        guard let id = targetSessionId else { return }
        Task { await post("Sessions/\(id)/Playing/Seek", query: ["seekPositionTicks": String(Int64(seconds * 10_000_000))]) }
    }

    func enqueue(_ tracks: [BaseItem], next: Bool) {
        guard let id = targetSessionId, !tracks.isEmpty else { return }
        for track in tracks { songs[track.id] = track }
        Task {
            await post("Sessions/\(id)/Playing", query: [
                "playCommand": next ? "PlayNext" : "PlayLast",
                "itemIds": tracks.map(\.id).joined(separator: ","),
            ])
        }
    }

    func setVolume(_ volume: Int) {
        generalCommand("SetVolume", ["Volume": String(volume)])
    }

    func setShuffle(_ on: Bool) {
        generalCommand("SetShuffleQueue", ["ShuffleMode": on ? "Shuffle" : "Sorted"])
    }

    func setRepeat(_ mode: RepeatMode) {
        let value: String
        switch mode {
        case .off: value = "RepeatNone"
        case .all: value = "RepeatAll"
        case .one: value = "RepeatOne"
        }
        generalCommand("SetRepeatMode", ["RepeatMode": value])
    }

    private var targetSessionId: String? {
        if case .remote(let id, _) = player?.output { return id }
        return nil
    }

    private func generalCommand(_ name: String, _ arguments: [String: String]) {
        guard let id = targetSessionId,
              let body = try? JSONSerialization.data(withJSONObject: ["Name": name, "Arguments": arguments]) else { return }
        Task { await post("Sessions/\(id)/Command", body: body) }
    }

    private func send(_ queue: [BaseItem], from index: Int, at position: TimeInterval, to sessionId: String) async {
        guard queue.indices.contains(index) else { return }
        // Keep the request reasonable: up to 100 songs around the current one.
        let start = max(index - 20, 0)
        let window = Array(queue[start..<min(start + 100, queue.count)])
        for track in window { songs[track.id] = track }
        await post("Sessions/\(sessionId)/Playing", query: [
            "playCommand": "PlayNow",
            "itemIds": window.map(\.id).joined(separator: ","),
            "startIndex": String(index - start),
            "startPositionTicks": String(Int64(position * 10_000_000)),
        ])
    }

    private func post(_ path: String, query: [String: String] = [:], body: Data? = nil) async {
        guard let client else { return }
        do {
            try await client.request("POST", path, query: query, body: body)
        } catch {
            errorMessage = "The other device didn't respond: \(error.localizedDescription)"
        }
    }

    // MARK: One session: noticing music started on another Dial

    /// Which of your Dial devices were playing at the last update (device id → song id).
    @ObservationIgnored private var lastPlaying: [String: String] = [:]
    @ObservationIgnored private var hasBaseline = false
    /// Right after a station was sent to the playing Dial, the server still lists its old song for a moment.
    @ObservationIgnored private var stationHandoffUntil = Date.distantPast
    /// Right after you bring the music back here, the other device may still look like it's playing.
    @ObservationIgnored private var autoFollowPausedUntil = Date.distantPast
    /// This device started following another on its own (not picked in the device list).
    @ObservationIgnored private(set) var followingAutomatically = false

    /// Like Spotify, there's one listening session across your Dial apps:
    /// - Open Dial while another of your Dials is playing, and this one shows what's playing
    ///   there ("Playing on MacBook") and controls it.
    /// - Start music on another Dial while this one is playing, and this one stops and follows
    ///   the other: the newest playback wins.
    private func autoFollow() {
        guard let player, let client else { return }
        let mine = devices.filter { $0.isDial && ($0.userId == nil || $0.userId == client.userId) }
        // The device that reported most recently first: that is the one actually making sound.
        let playing = mine.filter(\.isPlaying).sorted { ($0.lastCheckIn ?? .distantPast) > ($1.lastCheckIn ?? .distantPast) }
        let startedNow = playing.filter { lastPlaying[$0.deviceId] == nil }
        lastPlaying = Dictionary(playing.map { ($0.deviceId, $0.nowPlaying?.id ?? "") }, uniquingKeysWith: { first, _ in first })
        defer { hasBaseline = true }
        // Just opened: ask the other Dials whether a station is playing (stations don't show in the server's list).
        if !hasBaseline { for device in mine { Task { await send(.stationRequest, to: device.id) } } }

        guard !player.isRemote, Date() > autoFollowPausedUntil else { return }
        let busyHere = player.isPlaying || player.isStarting
        let device: Device?
        if !busyHere {
            device = playing.first // nothing playing here: show what's playing elsewhere
        } else if hasBaseline {
            device = startedNow.first // music just started elsewhere: it takes over
        } else {
            device = nil
        }
        guard let device else { return }
        if busyHere { player.pause() }
        followingAutomatically = true
        player.useRemote(id: device.id, name: device.name)
        targetDeviceId = device.deviceId
        lastSeenTarget = Date()
        startPolling()
        let sessionId = device.id
        Task {
            await send(.djCommand(.shareState), to: sessionId) // is Marlo running there?
            await send(.queueRequest, to: sessionId)           // and what's the queue?
        }
    }

    // MARK: Keeping up with the other devices

    /// `userInitiated`: only when you asked (opened the devices list or pulled it down) is a failure shown; the background
    /// polling failing for a moment (no network, the app just woke up) is not worth a message.
    func refresh(userInitiated: Bool = false) async {
        guard let client else { return }
        isLoading = devices.isEmpty
        defer { isLoading = false }
        do {
            let data = try await client.request("GET", "Sessions", query: ["activeWithinSeconds": "960"])
            await update(from: try JSONDecoder().decode([SessionInfo].self, from: data))
        } catch {
            if userInitiated { errorMessage = "Couldn't list your other devices: \(error.localizedDescription)" }
        }
    }

    private func update(from sessions: [SessionInfo]) async {
        lastSessionsUpdate = Date()
        let userId = client?.userId
        let others = sessions.filter { session in
            session.deviceId != JellyfinClient.deviceId && (session.userId == nil || session.userId == userId)
        }
        // Your other Dials always count: they can play anything Dial sends. Other apps need to
        // say they accept remote control.
        let isControllable: (SessionInfo) -> Bool = { session in
            session.client == JellyfinClient.clientName
                || ((session.supportsRemoteControl ?? false) && (session.playableMediaTypes ?? ["Audio"]).contains("Audio"))
        }
        uncontrollable = others.filter { !isControllable($0) }.map { "\($0.client ?? "App") on \($0.deviceName ?? "a device")" }
        devices = others
            .map { session in
                Device(id: session.id,
                       deviceId: session.deviceId ?? session.id,
                       name: session.deviceName ?? "Unknown device",
                       app: session.client ?? "Jellyfin",
                       canBeControlled: isControllable(session),
                       nowPlaying: session.nowPlayingItem?.isSong == true ? session.nowPlayingItem : nil,
                       isPaused: session.playState?.isPaused ?? false,
                       userId: session.userId,
                       lastCheckIn: session.lastPlaybackCheckIn.flatMap(JellyfinDates.parse),
                       lastActive: session.lastActivityDate.flatMap(JellyfinDates.parse))
            }
        autoFollow()
        await follow(sessions)
    }

    /// Mirrors the device that's playing into the player, so every screen shows what's happening there.
    private func follow(_ sessions: [SessionInfo]) async {
        guard let player, case .remote(let id, let name) = player.output else { return }
        // A device that reconnects gets a new session; recognise it by its device id.
        let session = sessions.first { $0.id == id }
            ?? sessions.first { $0.deviceId != nil && $0.deviceId == targetDeviceId }
        guard let session else {
            if Date().timeIntervalSince(lastSeenTarget) > 15 {
                stopPolling()
                targetDeviceId = nil
                endMirror()
                player.useThisDevice()
                if !followingAutomatically {
                    errorMessage = "\(name) is no longer available, so Dial is back on this \(Platform.deviceKind)."
                }
                followingAutomatically = false
            }
            return
        }
        // A device that says it is playing but has gone silent (turned off, app closed) is not there any more, and one that was only
        // followed automatically and has been quiet for minutes is not worth following: back to this device, without a message.
        let checkIn = session.lastPlaybackCheckIn.flatMap(JellyfinDates.parse)
        let activity = session.lastActivityDate.flatMap(JellyfinDates.parse)
        let claimsPlaying = session.nowPlayingItem != nil && !(session.playState?.isPaused ?? false)
        let silent = claimsPlaying && (checkIn.map { Date().timeIntervalSince($0) > 90 } ?? false)
        let away = followingAutomatically && (activity.map { Date().timeIntervalSince($0) > 180 } ?? false)
        if silent || away {
            stopPolling()
            targetDeviceId = nil
            endMirror()
            player.useThisDevice()
            followingAutomatically = false
            autoFollowPausedUntil = Date().addingTimeInterval(60)
            return
        }
        lastSeenTarget = Date()
        if session.id != id { player.useRemote(id: session.id, name: name) }

        if player.isLive, Date() < stationHandoffUntil { return }
        guard let song = session.nowPlayingItem, song.isSong else {
            if player.isLive { return } // the other Dial is playing the station we sent
            if let current = player.current {
                player.applyRemote(queue: player.queue, index: player.index, position: player.currentTime,
                                   duration: current.duration ?? 0, playing: false,
                                   volume: session.playState?.volumeLevel)
            }
            return
        }
        songs[song.id] = song
        var ids = session.nowPlayingQueue?.map { Self.plainId($0.id) } ?? []
        // The server didn't pass the queue on: use the one the other Dial sent directly.
        if ids.count <= 1, sharedQueueIds.contains(song.id) { ids = sharedQueueIds }
        var queue: [BaseItem]
        if ids.count > 1 {
            queue = await resolve(ids)
        } else if let position = player.queue.firstIndex(where: { $0.id == song.id }) {
            // The other device didn't share its queue (or hasn't yet): keep the one we sent it.
            queue = player.queue
            _ = position
        } else {
            queue = [song]
        }
        if !queue.contains(where: { $0.id == song.id }) { queue = [song] }
        let index = queue.firstIndex { $0.id == song.id } ?? 0
        let state = session.playState
        let quiet = session.lastPlaybackCheckIn.flatMap(JellyfinDates.parse).map { Date().timeIntervalSince($0) > 45 } ?? false
        player.applyRemote(queue: queue, index: index,
                           position: Double(state?.positionTicks ?? 0) / 10_000_000,
                           duration: song.duration ?? 0,
                           playing: !(state?.isPaused ?? false) && !quiet,
                           volume: state?.volumeLevel,
                           repeatMode: state?.repeatMode.map(Self.repeatMode),
                           shuffled: state?.shuffleMode.map { $0 == "Shuffle" })
    }

    /// Jellyfin sometimes writes ids with dashes; Dial uses them without.
    private static func plainId(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func repeatMode(_ value: String) -> RepeatMode {
        switch value {
        case "RepeatAll": .all
        case "RepeatOne": .one
        default: .off
        }
    }

    /// The other device's queue as songs. Songs Dial already knows are reused; the rest are fetched once.
    private func resolve(_ ids: [String]) async -> [BaseItem] {
        let missing = ids.filter { songs[$0] == nil }
        if !missing.isEmpty, let client, let fetched = try? await client.items(ids: missing) {
            for song in fetched { songs[song.id] = song }
        }
        if songs.count > 2_000 { songs = songs.filter { ids.contains($0.key) } }
        return ids.compactMap { songs[$0] }
    }

    /// Live updates come over the socket; if they stop, ask directly. While the socket is connected, the
    /// check is much less frequent (a request every 3 seconds would keep the phone's radio awake).
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if Date().timeIntervalSince(lastSessionsUpdate) > (isLinked ? 15 : 3) { await refresh() }
            }
        }
    }

    /// Called when the app leaves or returns to the foreground. In the background the 4-second sharing,
    /// the Marlo repeat and the 3-second poll stop; the socket stays open so other devices can still reach this one.
    func setInBackground(_ background: Bool) {
        guard background != inBackground else { return }
        inBackground = background
        if background {
            queueShareTask?.cancel()
            djRepeatTask?.cancel()
            pollingPausedForBackground = pollTask != nil
            stopPolling()
        } else {
            startQueueSharing()
            if dj?.isActive == true { djStateChanged() }
            if pollingPausedForBackground {
                pollingPausedForBackground = false
                startPolling()
                Task { await refresh() }
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: The live connection (updates, and commands from other apps)

    private func connect() {
        listenTask?.cancel()
        keepAliveTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        guard let client else { return }
        listenTask = Task { await listen(client: client) }
        startQueueSharing()
    }

    /// Tells the server Dial can be controlled, asks for session updates, then listens.
    /// Reconnects if the connection drops.
    private func listen(client: JellyfinClient) async {
        var delay: Double = 2
        while !Task.isCancelled {
            await reportCapabilities(client: client)
            guard let url = socketURL(for: client) else { return }
            // Newer Jellyfin versions ignore the old "api_key" parameter, so the sign-in also
            // goes in the header (and as "ApiKey"); otherwise the server never sees Dial as remote-controllable.
            var request = URLRequest(url: url)
            request.setValue(JellyfinClient.authHeader(token: client.token), forHTTPHeaderField: "Authorization")
            let task = URLSession.shared.webSocketTask(with: request)
            socket = task
            task.resume()
            try? await task.send(.string(#"{"MessageType":"SessionsStart","Data":"0,1500"}"#))
            do {
                var announced = false
                while !Task.isCancelled {
                    let message = try await task.receive()
                    if !announced {
                        // Connected: tell the server again that Dial can be controlled, now that
                        // there's a live connection to send commands through.
                        announced = true
                        isLinked = true
                        await reportCapabilities(client: client)
                        await refresh()
                    }
                    if case .string(let text) = message { await handle(text) }
                    delay = 2
                }
            } catch {
                // Connection dropped (server restarted, network changed): try again shortly.
            }
            isLinked = false
            try? await Task.sleep(for: .seconds(delay))
            delay = min(delay * 2, 60)
        }
    }

    private func reportCapabilities(client: JellyfinClient) async {
        let capabilities: [String: Any] = [
            "PlayableMediaTypes": ["Audio"],
            "SupportedCommands": ["PlayState", "PlayNext", "PlayMediaSource", "SetShuffleQueue", "SetRepeatMode",
                                  "SetVolume", "VolumeUp", "VolumeDown", "Mute", "Unmute", "ToggleMute", "DisplayMessage"],
            "SupportsMediaControl": true,
            "SupportsPersistentIdentifier": true,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: capabilities) else { return }
        do {
            _ = try await client.request("POST", "Sessions/Capabilities/Full", body: body)
            capabilitiesProblem = nil
        } catch {
            capabilitiesProblem = error.localizedDescription
        }
    }

    private func socketURL(for client: JellyfinClient) -> URL? {
        guard var components = URLComponents(url: client.server.appending(path: "socket"), resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.queryItems = [
            URLQueryItem(name: "ApiKey", value: client.token),
            URLQueryItem(name: "api_key", value: client.token),
            URLQueryItem(name: "deviceId", value: JellyfinClient.deviceId),
        ]
        return components.url
    }

    private func handle(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = message["MessageType"] as? String else { return }

        switch type {
        case "Sessions":
            guard let list = message["Data"],
                  let json = try? JSONSerialization.data(withJSONObject: list),
                  let sessions = try? JSONDecoder().decode([SessionInfo].self, from: json) else { return }
            await update(from: sessions)
        case "UserDataChanged":
            // A favorite or rating changed somewhere (another Dial, the web app): show it here too.
            guard let body = message["Data"] as? [String: Any],
                  let changes = body["UserDataList"] as? [[String: Any]] else { return }
            for change in changes {
                guard let id = change["ItemId"] as? String else { continue }
                library?.applyChange(itemId: Self.plainId(id),
                                     isFavorite: change["IsFavorite"] as? Bool,
                                     rating: change["Rating"] as? Double)
            }
        case "ForceKeepAlive":
            let seconds = (message["Data"] as? Double) ?? 60
            startKeepAlive(every: max(seconds / 2, 10))
        case "Play":
            guard let body = message["Data"] as? [String: Any] else { return }
            await playHere(body)
        case "Playstate":
            guard let body = message["Data"] as? [String: Any], let command = body["Command"] as? String else { return }
            playstateHere(command, ticks: body["SeekPositionTicks"] as? Double)
        case "GeneralCommand":
            guard let body = message["Data"] as? [String: Any], let name = body["Name"] as? String else { return }
            generalCommandHere(name, arguments: body["Arguments"] as? [String: Any] ?? [:])
        default:
            break
        }
    }

    /// Another app sent music to Dial: it plays on this iPhone.
    private func playHere(_ body: [String: Any]) async {
        guard let client, let player, let ids = body["ItemIds"] as? [String], !ids.isEmpty,
              let tracks = try? await client.items(ids: ids), !tracks.isEmpty else { return }
        if player.isRemote {
            stopPolling()
            targetDeviceId = nil
            followingAutomatically = false
            endMirror()
            player.useThisDevice()
        }
        autoFollowPausedUntil = Date().addingTimeInterval(10)
        switch body["PlayCommand"] as? String {
        case "PlayNext":
            player.playNext(tracks)
        case "PlayLast":
            player.addToQueue(tracks)
        default:
            player.play(tracks, startAt: body["StartIndex"] as? Int ?? 0)
            if let ticks = body["StartPositionTicks"] as? Double, ticks > 0 {
                player.seek(to: ticks / 10_000_000)
            }
        }
    }

    /// Another app is controlling Dial's own playback.
    private func playstateHere(_ command: String, ticks: Double?) {
        guard let player, !player.isRemote else { return }
        switch command {
        case "Pause": player.pause()
        case "Unpause": player.resume()
        case "PlayPause": player.togglePlayPause()
        case "NextTrack": player.next()
        case "PreviousTrack": player.previous()
        case "Stop": player.pause()
        case "Seek": if let ticks { player.seek(to: ticks / 10_000_000) }
        default: break
        }
    }

    /// Another app changed Dial's volume, repeat or shuffle, or another Dial handed over a station or the DJ.
    private func generalCommandHere(_ name: String, arguments: [String: Any]) {
        guard let player else { return }
        func number(_ key: String) -> Double? {
            (arguments[key] as? Double) ?? (arguments[key] as? String).flatMap(Double.init)
        }
        switch name {
        case "SetVolume":
            if let volume = number("Volume") { player.setOutputVolume(Float(volume / 100)) }
        case "VolumeUp":
            player.setOutputVolume(player.outputVolume + 0.05)
        case "VolumeDown":
            player.setOutputVolume(player.outputVolume - 0.05)
        case "Mute":
            mutedVolume = player.outputVolume
            player.setOutputVolume(0)
        case "Unmute":
            player.setOutputVolume(mutedVolume ?? 1)
        case "ToggleMute":
            if player.outputVolume == 0 {
                player.setOutputVolume(mutedVolume ?? 1)
            } else {
                mutedVolume = player.outputVolume
                player.setOutputVolume(0)
            }
        case "SetRepeatMode":
            switch arguments["RepeatMode"] as? String {
            case "RepeatAll": player.setRepeat(.all)
            case "RepeatOne": player.setRepeat(.one)
            default: player.setRepeat(.off)
            }
        case "SetShuffleQueue":
            player.setShuffle((arguments["ShuffleMode"] as? String) == "Shuffle")
        case "DisplayMessage":
            guard (arguments["Header"] as? String) == Self.handoffHeader,
                  let text = arguments["Text"] as? String else { return }
            receiveHandoff(text)
        default:
            break
        }
    }

    @ObservationIgnored private var mutedVolume: Float?

    /// Another Dial sent a live station or the DJ to play here.
    private func receiveHandoff(_ text: String, retried: Bool = false) {
        guard let player, let data = text.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = payload["kind"] as? String else { return }
        switch kind {
        case "djState":
            // Only from the device this one is following.
            guard player.isRemote, (payload["from"] as? String) == targetDeviceId,
                  let state = Self.decode(DJSharedState.self, payload["state"]) else { return }
            dj?.mirror(state)
            return
        case "queue":
            // Only from the device this one is following.
            guard player.isRemote, (payload["from"] as? String) == targetDeviceId,
                  let ids = payload["ids"] as? [String], !ids.isEmpty else { return }
            sharedQueueIds = ids.map(Self.plainId)
            Task { await refresh() }
            return
        case "stationState":
            guard let from = payload["from"] as? String,
                  let station = Self.decode(Station.self, payload["station"]) else { return }
            let list = Self.decode([Station].self, payload["list"]) ?? [station]
            let playing = payload["playing"] as? Bool ?? true
            if player.isRemote {
                // Following that device: show what it is playing now.
                guard from == targetDeviceId else { return }
                lastSeenTarget = Date()
                player.showRemoteStation(station, in: list, playing: playing, announce: false)
            } else if playing, Date() > autoFollowPausedUntil {
                let busy = player.isPlaying || player.isStarting
                // Idle: show what plays elsewhere. Busy: only if that was started after what plays here (the newest wins).
                let startedAt = Date(timeIntervalSince1970: payload["startedAt"] as? Double ?? 0)
                guard !busy || startedAt > player.playStartedAt.addingTimeInterval(2) else { return }
                // This Dial's device list may not have the other one yet: look again, then follow.
                guard let device = devices.first(where: { $0.deviceId == from }) else {
                    if !retried { Task { await refresh(); receiveHandoff(text, retried: true) } }
                    return
                }
                if busy { player.pause() }
                followingAutomatically = true
                player.useRemote(id: device.id, name: device.name)
                targetDeviceId = from
                lastSeenTarget = Date()
                startPolling()
                player.showRemoteStation(station, in: list, playing: playing, announce: false)
            }
            return
        case "stationRequest":
            guard !player.isRemote, player.isLive else { return }
            Task { await shareStation(force: true) }
            return
        case "queueRequest":
            guard !player.isRemote else { return }
            Task { await shareQueue(force: true) }
            return
        case "djCommand":
            guard !player.isRemote, let raw = payload["command"] as? String,
                  let command = DJRemoteCommand(rawValue: raw) else { return }
            Task { await dj?.perform(command) }
            return
        case "dj":
            // A message for the Marlo already running here: answer it without touching playback.
            if !player.isRemote, dj?.isActive == true {
                let request = (payload["request"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                Task { if let request { await dj?.handle(request: request) } }
                return
            }
        default:
            break
        }
        if player.isRemote {
            stopPolling()
            targetDeviceId = nil
            followingAutomatically = false
            endMirror()
            player.useThisDevice()
        }
        autoFollowPausedUntil = Date().addingTimeInterval(10)
        switch kind {
        case "station":
            guard let stationJSON = payload["station"],
                  let stationData = try? JSONSerialization.data(withJSONObject: stationJSON),
                  let station = try? JSONDecoder().decode(Station.self, from: stationData) else { return }
            let list = (payload["list"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                .flatMap { try? JSONDecoder().decode([Station].self, from: $0) } ?? [station]
            player.playStation(station, in: list)
        case "dj":
            let request = (payload["request"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            Task {
                if let request { await dj?.handle(request: request) } else { await dj?.start() }
            }
        case "djSession":
            guard let session = Self.decode(DJSessionSnapshot.self, payload["session"]),
                  let ids = payload["queue"] as? [String], !ids.isEmpty else { return }
            let index = payload["index"] as? Int ?? 0
            let position = payload["position"] as? Double ?? 0
            Task {
                guard let client, let songs = try? await client.items(ids: ids) else { return }
                let byId = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let queue = ids.compactMap { byId[$0] }
                let start = queue.firstIndex { $0.id == ids[min(index, ids.count - 1)] } ?? 0
                dj?.resume(session, queue: queue, index: start, position: position)
            }
        default:
            break
        }
    }

    private func startKeepAlive(every seconds: Double) {
        keepAliveTask?.cancel()
        keepAliveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                try? await socket?.send(.string(#"{"MessageType":"KeepAlive"}"#))
            }
        }
    }
}

private struct SessionInfo: Decodable {
    struct PlayState: Decodable {
        let positionTicks: Int64?
        let isPaused: Bool?
        let volumeLevel: Int?
        let repeatMode: String?
        let shuffleMode: String?
        enum CodingKeys: String, CodingKey {
            case positionTicks = "PositionTicks"
            case isPaused = "IsPaused"
            case volumeLevel = "VolumeLevel"
            case repeatMode = "RepeatMode"
            case shuffleMode = "ShuffleMode"
        }
    }

    struct QueueItem: Decodable {
        let id: String
        enum CodingKeys: String, CodingKey { case id = "Id" }
    }

    let id: String
    let userId: String?
    let deviceId: String?
    let deviceName: String?
    let client: String?
    let supportsRemoteControl: Bool?
    let playableMediaTypes: [String]?
    let nowPlayingItem: BaseItem?
    let playState: PlayState?
    let nowPlayingQueue: [QueueItem]?
    let lastPlaybackCheckIn: String?
    let lastActivityDate: String?

    enum CodingKeys: String, CodingKey {
        case lastPlaybackCheckIn = "LastPlaybackCheckIn"
        case lastActivityDate = "LastActivityDate"
        case id = "Id"
        case userId = "UserId"
        case deviceId = "DeviceId"
        case deviceName = "DeviceName"
        case client = "Client"
        case supportsRemoteControl = "SupportsRemoteControl"
        case playableMediaTypes = "PlayableMediaTypes"
        case nowPlayingItem = "NowPlayingItem"
        case playState = "PlayState"
        case nowPlayingQueue = "NowPlayingQueue"
    }
}
