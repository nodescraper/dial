import AVFoundation
import SwiftUI

/// Settings, organized like the iPhone's own: your account at the top, then grouped rows that each open a page.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var userName: String?

    var body: some View {
        List {
            Section {
                NavigationLink { AccountSettingsView() } label: { AccountCard(name: userName) }
            }

            Section {
                SettingsRow("Playback", symbol: "play.fill", color: .orange, value: app.settings.quality.label) {
                    PlaybackSettingsView()
                }
                NavigationLink(value: Route.equalizer) {
                    SettingsLabel("Equalizer", symbol: "slider.vertical.3", color: .pink,
                                  value: app.equalizer.isEnabled ? (app.equalizer.presetName ?? "Custom") : "Off")
                }
                SettingsRow(app.dj.name, symbol: "dot.radiowaves.left.and.right", color: Color.dial, value: nil) {
                    MarloSettingsView()
                }
                SettingsRow("Discovery", symbol: "safari.fill", color: .teal, value: DiscoveryEngine.concertsEnabled ? "Concerts on" : nil) {
                    DiscoverySettingsView()
                }
            }

            Section {
                SettingsRow("Downloads", symbol: "arrow.down.circle.fill", color: .blue,
                            value: app.downloads.records.isEmpty ? "None" : "\(app.downloads.records.count) songs") {
                    DownloadSettingsView()
                }
                SettingsRow("Storage", symbol: "internaldrive.fill", color: .gray, value: nil) { StorageSettingsView() }
                SettingsRow("Hidden Songs", symbol: "eye.slash.fill", color: .dial,
                            value: app.library.hiddenSongs.isEmpty ? "None" : "\(app.library.hiddenSongs.count)") {
                    HiddenSongsSettingsView()
                }
                SettingsRow("Playlists", symbol: "music.note.list", color: .red, value: nil) {
                    Form { PlaylistFilesSection() }.navigationTitle("Playlists")
                }
                SettingsRow("Export Library", symbol: "square.and.arrow.up.fill", color: .indigo, value: nil) {
                    ExportLibraryView()
                }
            }

            Section {
                SettingsRow("Server Add-ons", symbol: "puzzlepiece.extension.fill", color: .green,
                            value: app.hasPlugin ? "Dial" : (SoundAnalysisStatus(app.audioMuse) == .active ? "AudioMuse" : nil)) {
                    SoundAnalysisView()
                }
                Button { app.navigator.showDevices = true } label: {
                    SettingsLabel("Devices", symbol: "hifispeaker.2.fill", color: .teal,
                                  value: app.player.outputName ?? "This \(Platform.deviceKind)")
                }
                .foregroundStyle(.primary)
            }

            Section {
                SettingsRow("About Dial", symbol: "info.circle.fill", color: .gray, value: JellyfinClient.version) { AboutView() }
            }
        }
        .navigationTitle("Settings")
        .task { userName = await app.client?.userName() }
    }
}

// MARK: - Building blocks

/// The colored square icon, like the iPhone's Settings.
struct SettingsIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: Theme.Size.tapTarget * 0.66, height: Theme.Size.tapTarget * 0.66)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: Theme.Radius.thumb, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct SettingsLabel: View {
    let title: String
    let symbol: String
    let color: Color
    let value: String?

    init(_ title: String, symbol: String, color: Color, value: String?) {
        self.title = title
        self.symbol = symbol
        self.color = color
        self.value = value
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            SettingsIcon(symbol: symbol, color: color)
            Text(title)
            Spacer()
            if let value { Text(value).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}

/// A row that opens a settings page.
struct SettingsRow<Destination: View>: View {
    let title: String
    let symbol: String
    let color: Color
    let value: String?
    @ViewBuilder let destination: () -> Destination

    init(_ title: String, symbol: String, color: Color, value: String?, @ViewBuilder destination: @escaping () -> Destination) {
        self.title = title
        self.symbol = symbol
        self.color = color
        self.value = value
        self.destination = destination
    }

    var body: some View {
        NavigationLink { destination() } label: { SettingsLabel(title, symbol: symbol, color: color, value: value) }
    }
}

/// Your picture, name and server at the top of Settings.
private struct AccountCard: View {
    let name: String?
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            AccountAvatar(name: name)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(name ?? "Your Account").font(.title3.weight(.semibold))
                Text(app.client?.server.host() ?? "Not signed in").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: Theme.Spacing.xs) {
                    Circle().fill(app.connectivity.isOffline ? Color.orange : Color.green)
                        .frame(width: Theme.Spacing.s, height: Theme.Spacing.s)
                    Text(app.connectivity.isOffline ? "Can\u{2019}t reach your server" : "Connected")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }
}

private struct AccountAvatar: View {
    let name: String?
    @Environment(AppModel.self) private var app

    var body: some View {
        RemoteImage(url: app.client?.userImageURL) {
            ZStack {
                Circle().fill(Color.dial.gradient)
                Text(initials).font(.title2.weight(.semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: Theme.Size.rowArtwork * 1.2, height: Theme.Size.rowArtwork * 1.2)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var initials: String {
        let parts = (name ?? "").split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

// MARK: - Pages

private struct AccountSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmingSignOut = false
    @State private var scanning = false
    @State private var scanMessage: String?
    @State private var name: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: Theme.Spacing.s) {
                        AccountAvatar(name: name).scaleEffect(1.3).padding(Theme.Spacing.m)
                        Text(name ?? "").font(.title2.bold())
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
            Section("Server") {
                LabeledContent("Address", value: app.client?.server.absoluteString ?? "")
                LabeledContent("Status", value: app.connectivity.isOffline ? "Offline" : "Connected")
            }
            Section {
                Button {
                    Task { await scan() }
                } label: {
                    HStack {
                        Text("Scan Library")
                        if scanning { Spacer(); ProgressView() }
                    }
                }
                .disabled(scanning)
            } footer: {
                Text(scanMessage ?? "Finds new, changed and removed music on your server. Server administrators only.")
            }
            Section {
                Button("Sign Out", role: .destructive) { confirmingSignOut = true }
            } footer: {
                Text("Downloaded songs stay on this \(Platform.deviceKind).")
            }
        }
        .navigationTitle("Account")
        .task { name = await app.client?.userName() }
        .confirmationDialog("Sign out of your server?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { app.signOut() }
        }
    }

    private func scan() async {
        scanning = true
        defer { scanning = false }
        do {
            try await app.client?.scanLibrary()
            await JellyfinClient.clearCache()
            scanMessage = "Scan started. New music appears in a few minutes."
        } catch JellyfinError.http(403) {
            scanMessage = "Only server administrators can start a scan."
        } catch {
            scanMessage = "Couldn\u{2019}t start the scan: \(error.localizedDescription)"
        }
    }
}

private struct PlaybackSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Picker("Streaming Quality", selection: $settings.quality) {
                    ForEach(StreamingQuality.allCases) { Text($0.label).tag($0) }
                }
            } footer: {
                Text("Original plays your files exactly as stored. Lower settings save mobile data; your server converts the music.")
            }
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    LabeledContent("Crossfade", value: settings.crossfadeSeconds == 0 ? "Off" : "\(Int(settings.crossfadeSeconds)) seconds")
                    Slider(value: $settings.crossfadeSeconds, in: 0...12, step: 1)
                        .tint(Color.dial)
                        .accessibilityLabel("Crossfade length")
                }
                Toggle("Volume Leveling", isOn: $settings.volumeLeveling)
                    .onChange(of: settings.volumeLeveling) { app.player.refreshLeveling() }
            } footer: {
                Text("With crossfade off, songs follow each other with no gap; albums that run into the next song never crossfade. Volume leveling plays loud and quiet songs at a similar volume.")
            }
            Section {
                Toggle("Open Player When Playing", isOn: $settings.opensPlayerOnPlay)
            }
        }
        .navigationTitle("Playback")
    }
}

private struct MarloSettingsView: View {
    var body: some View {
        Form { DJVoiceSection() }
            .navigationTitle("Voice")
    }
}

private struct DownloadSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var confirming = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Songs", value: "\(app.downloads.records.count)")
                LabeledContent("Space Used", value: ByteCountFormatter.string(fromByteCount: app.downloads.totalBytes, countStyle: .file))
            } footer: {
                Text("Downloads keep going in the background, even when Dial is closed. When your server can\u{2019}t be reached, Dial plays these.")
            }
            Section {
                Button("Remove All Downloads", role: .destructive) { confirming = true }
                    .disabled(app.downloads.records.isEmpty)
            }
        }
        .navigationTitle("Downloads")
        .confirmationDialog("Remove all downloaded songs from this \(Platform.deviceKind)?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Remove All Downloads", role: .destructive) { app.downloads.deleteAll() }
        }
    }
}

private struct StorageSettingsView: View {
    @State private var imageBytes: Int64 = 0

    var body: some View {
        Form {
            Section {
                LabeledContent("Saved Covers and Photos", value: ByteCountFormatter.string(fromByteCount: imageBytes, countStyle: .file))
                Button("Clear Saved Covers") {
                    ImagePipeline.shared.clearDisk()
                    Task { imageBytes = await ImagePipeline.diskBytes() }
                }
            } footer: {
                Text("Covers and photos are kept so pages open instantly and work offline. They download again when needed.")
            }
            Section {
                Button("Clear Saved Pages") { Snapshots.clear() }
            } footer: {
                Text("Home, Search, Radio and artist pages are saved so they open instantly. Clearing them makes each page load fresh once.")
            }
        }
        .navigationTitle("Storage")
        .task { imageBytes = await ImagePipeline.diskBytes() }
    }
}

private struct HiddenSongsSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section {
                if app.library.hiddenSongs.isEmpty {
                    Text("No hidden songs").foregroundStyle(.secondary)
                } else {
                    ForEach(app.library.hiddenSongs.values.sorted { $0.name < $1.name }) { song in
                        HStack {
                            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                Text(song.name)
                                Text(song.artistLine).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Allow") { app.library.setHidden(song, false) }.buttonStyle(.borderless)
                        }
                    }
                }
            } footer: {
                Text("Radio, mixes and \(app.dj.name) skip songs you hide. You can still play one by tapping it.")
            }
            if !app.library.hiddenSongs.isEmpty {
                Section { Button("Allow All Songs") { app.library.unhideAll() } }
            }
        }
        .navigationTitle("Hidden Songs")
    }
}

private struct AboutView: View {
    private let sources: [(String, String)] = [
        ("Your Jellyfin server", "Your music, play counts, favorites and playlists"),
        ("MusicBrainz", "Discographies, tracklists, genres and search"),
        ("ListenBrainz", "Charts, new releases and similar artists"),
        ("Cover Art Archive", "Covers of albums not in your library"),
        ("Wikidata and Wikimedia Commons", "Artist photos"),
        ("LRCLIB", "Lyrics your server doesn\u{2019}t have"),
        ("Radio Browser", "Live radio stations"),
        ("AudioMuse", "How songs sound (optional, on your server)"),
    ]

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: JellyfinClient.version)
            }
            Section {
                ForEach(sources, id: \.0) { source in
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(source.0)
                        Text(source.1).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Where Dial\u{2019}s Information Comes From")
            } footer: {
                Text("Dial has no account of its own and no tracking. It talks to your server and to these open, free services, and keeps everything else on this \(Platform.deviceKind).")
            }
        }
        .navigationTitle("About")
    }
}

/// Picks the DJ's voice from the voices installed on this iPhone.
private struct DJVoiceSection: View {
    @Environment(AppModel.self) private var app
    @State private var previewer = Speaker()

    private var voices: [AVSpeechSynthesisVoice] { Speaker.availableVoices }

    var body: some View {
        @Bindable var settings = app.settings

        Section {
            Picker("DJ Voice", selection: $settings.djVoiceId) {
                Text("Best Available").tag(String?.none)
                ForEach(voices, id: \.identifier) { voice in
                    Text("\(voice.name) (\(qualityLabel(voice)))").tag(String?.some(voice.identifier))
                }
            }
            Button("Preview Voice") {
                Task { await previewer.say("Hey, it's \(settings.displayDJName). Let's get this going.", voiceId: settings.djVoiceId) }
            }
        } header: {
            Text("DJ")
        } footer: {
            Text((Platform.isMac
                 ? "For a more natural DJ, download an Enhanced or Premium English voice in System Settings \u{2192} Accessibility \u{2192} Spoken Content \u{2192} System Voice \u{2192} Manage Voices. It will appear here."
                 : "For a more natural DJ, download an Enhanced or Premium English voice in Settings \u{2192} Accessibility \u{2192} Spoken Content \u{2192} Voices. It will appear here."))
        }
    }

    private func qualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Standard"
        }
    }
}

// MARK: - Sound analysis (AudioMuse)

/// How AudioMuse is doing, in one word and a color.
enum SoundAnalysisStatus {
    case checking, active, notInstalled

    @MainActor init(_ audioMuse: AudioMuse) {
        if !audioMuse.hasChecked { self = .checking }
        else if audioMuse.isConnected { self = .active }
        else { self = .notInstalled }
    }

    var summary: String {
        switch self {
        case .checking: "Checking your server\u{2026}"
        case .active: "Active: picking songs by how they sound"
        case .notInstalled: "Not installed: using Jellyfin\u{2019}s genre matching"
        }
    }

    var color: Color {
        switch self {
        case .checking: .secondary
        case .active: .green
        case .notInstalled: .orange
        }
    }
}

struct SoundAnalysisStatusDot: View {
    let status: SoundAnalysisStatus

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: Theme.Spacing.m, height: Theme.Spacing.m)
            .overlay { if status == .active { Circle().stroke(status.color.opacity(0.35), lineWidth: Theme.Spacing.xs) } }
            .accessibilityHidden(true)
    }
}

/// Everything about the AudioMuse setup: whether it's there, what it powers right now,
/// and which features this version offers.
struct SoundAnalysisView: View {
    @Environment(AppModel.self) private var app
    @State private var checking = false
    @State private var dial: DialPluginStatus?
    @State private var dialChecked = false

    private var audioMuse: AudioMuse { app.audioMuse }
    private var status: SoundAnalysisStatus { SoundAnalysisStatus(audioMuse) }

    var body: some View {
        List {
            // The Dial plugin: Discovery and mixtapes, and everything it builds on, as the server reports it.
            Section {
                HStack(spacing: Theme.Spacing.m) {
                    Circle()
                        .fill(app.hasPlugin ? Color.green : Color.orange)
                        .frame(width: Theme.Spacing.m, height: Theme.Spacing.m)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(app.hasPlugin ? "Dial plugin is active" : dialChecked ? "Dial plugin isn\u{2019}t installed" : "Checking\u{2026}")
                            .font(.headline)
                        Text(app.hasPlugin ? "Discovery and mixtapes" : "Discovery and mixtapes need it")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
            } footer: {
                Text("The Dial plugin on your server makes Discovery and your mixtapes once a day, so every device shows the same and opens instantly. Without it those two parts are hidden; everything else works.")
            }
            ForEach(dial?.groups ?? []) { group in
                Section {
                    ForEach(group.rows) { row in
                        HStack(alignment: .top, spacing: Theme.Spacing.m) {
                            Circle()
                                .fill(row.active ? Color.green : Color.orange)
                                .frame(width: Theme.Spacing.m, height: Theme.Spacing.m)
                                .padding(.top, 6)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                Text(row.name)
                                Text(row.provides).font(.subheadline).foregroundStyle(.secondary)
                                if let note = row.note { Text(note).font(.footnote).foregroundStyle(.tertiary) }
                            }
                        }
                        .padding(.vertical, Theme.Spacing.xxs)
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text(group.title)
                }
            }

            Section {
                HStack(spacing: Theme.Spacing.m) {
                    SoundAnalysisStatusDot(status: status)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(status == .active ? "AudioMuse is active" : status == .checking ? "Checking\u{2026}" : "AudioMuse isn\u{2019}t installed")
                            .font(.headline)
                        if let version = audioMuse.version {
                            Text("Version \(version)").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        Task {
                            checking = true
                            await audioMuse.check()
                            checking = false
                        }
                    } label: {
                        if checking { ProgressView() } else { Text("Check Again") }
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, Theme.Spacing.xs)
            } footer: {
                Text("AudioMuse is a plugin for your Jellyfin server that listens to every song once and learns how it sounds: mood, energy and instruments.")
            }

            Section {
                HStack(spacing: Theme.Spacing.m) {
                    Circle()
                        .fill(app.history.isAvailable ? Color.green : Color.orange)
                        .frame(width: Theme.Spacing.m, height: Theme.Spacing.m)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(app.history.isAvailable ? "Playback Reporting is active" : "Playback Reporting isn\u{2019}t installed")
                        Text(app.history.isAvailable
                             ? "\(app.history.totalPlays) plays recorded"
                             : "\(app.dj.name) estimates from play counts instead")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Listening History")
            } footer: {
                Text("Jellyfin\u{2019}s Playback Reporting plugin records every play with its date, so \(app.dj.name) knows what you\u{2019}ve had on repeat lately.")
            }

            Section("What it powers now") {
                LabeledContent("Radio, mixes and \(app.dj.name)",
                               value: status == .active ? "Sound-based" : "Genre-based")
                LabeledContent("Similar artists",
                               value: audioMuse.canFindSimilarArtists ? "Sound-based" : "Listening data (ListenBrainz)")
            }

            Section {
                feature("Sound-based radio and mixes", available: status == .active,
                        detail: "Radio, Your Mix and \(app.dj.name)\u{2019}s sets follow how songs sound.")
                feature("Mood stations and sound search", available: audioMuse.canSearchBySound,
                        detail: "Chill, Focus, Late Night and more, and searches like \u{201C}calm piano\u{201D}. Needs text search turned on in AudioMuse.")
                feature("Smooth DJ transitions", available: audioMuse.canFindPaths,
                        detail: "\(app.dj.name) glides into a new direction over a couple of songs.")
                feature("Your Sound", available: audioMuse.canMakeYourSound,
                        detail: "A station that matches what you play most.")
                feature("Sound-alike artists", available: audioMuse.canFindSimilarArtists,
                        detail: "Similar Artists on artist pages, by sound.")
            } header: {
                Text("Features")
            } footer: {
                Text(status == .active
                     ? "Features your AudioMuse version doesn\u{2019}t offer stay hidden in Dial. Updating the plugin on your server can add them."
                     : "Without AudioMuse everything still works, using Jellyfin\u{2019}s genre-based matching. Install the AudioMuse-AI plugin on your server to turn these on.")
            }
        }
        .navigationTitle("Server Add-ons")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let client = app.client { dial = await client.dialPluginStatus() }
            dialChecked = true
        }
    }

    private func feature(_ title: String, available: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            Image(systemName: available ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(available ? Color.green : Color.secondary)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(title)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityValue(available ? "On" : "Not available")
    }
}

/// Playlist files that came with your music (.m3u files in album folders): hidden from your playlists by default,
/// with how to remove them from the server for good.
private struct PlaylistFilesSection: View {
    @Environment(AppModel.self) private var app
    @AppStorage("dial.showPlaylistFiles") private var showFiles = false
    @State private var showingList = false

    var body: some View {
        Section {
            Toggle("Show Playlist Files", isOn: $showFiles)
                .onChange(of: showFiles) { Task { await app.library.refreshPlaylists() } }
            if !app.library.playlistFiles.isEmpty {
                DisclosureGroup("\(app.library.playlistFiles.count) playlist files", isExpanded: $showingList) {
                    ForEach(app.library.playlistFiles) { playlist in
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text(playlist.name)
                            if let path = playlist.path {
                                Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Playlists")
        } footer: {
            Text("Many albums come with a playlist file (.m3u), often called \u{201C}Play Me\u{201D} or after the album. Jellyfin lists each one as a playlist but can\u{2019}t delete them, because they\u{2019}re files in your music folder. Dial hides them unless this is on. To remove them for good, delete the .m3u files on your server; Jellyfin drops them on its next library scan.")
        }
    }
}
