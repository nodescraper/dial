import SwiftUI

// MARK: - Equalizer

struct EqualizerView: View {
    var showsDoneButton = false
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    private var equalizer: Equalizer { app.equalizer }

    var body: some View {
        @Bindable var equalizer = app.equalizer

        Form {
            Section {
                Toggle("Equalizer", isOn: $equalizer.isEnabled)
                EqualizerCurve(gains: equalizer.gains)
                    .frame(height: Theme.Size.categoryCard)
                    .opacity(equalizer.isEnabled ? 1 : 0.35)
                    .listRowInsets(EdgeInsets(top: Theme.Spacing.m, leading: Theme.Spacing.l,
                                              bottom: Theme.Spacing.m, trailing: Theme.Spacing.l))
            } footer: {
                Text("Applies to everything you play in Dial, including live radio.")
            }

            Section("Presets") {
                HScroll {
                    HStack(spacing: Theme.Spacing.s) {
                        ForEach(Equalizer.presets) { preset in
                            let selected = equalizer.presetName == preset.name
                            Button(preset.name) {
                                withAnimation(.easeInOut(duration: 0.25)) { app.equalizer.apply(preset) }
                            }
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, Theme.Spacing.m)
                            .frame(minHeight: Theme.Size.tapTarget)
                            .background(selected ? Color.dial : Color(uiColor: .tertiarySystemFill), in: Capsule())
                            .foregroundStyle(selected ? Color.black : Color.primary)
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: Theme.Spacing.l, bottom: 0, trailing: Theme.Spacing.l))
            }

            Section("Bands") {
                ForEach(Equalizer.frequencies.indices, id: \.self) { band in
                    HStack(spacing: Theme.Spacing.m) {
                        Text(Self.label(for: Equalizer.frequencies[band]))
                            .font(.subheadline.monospacedDigit())
                            .frame(width: Theme.Size.compactArtwork, alignment: .leading)
                        Slider(value: Binding(get: { Double(equalizer.gains[band]) },
                                              set: { app.equalizer.setGain(Float($0), at: band) }),
                               in: Double(Equalizer.range.lowerBound)...Double(Equalizer.range.upperBound),
                               step: 0.5)
                            .tint(Color.dial)
                        Text(Self.decibels(equalizer.gains[band]))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: Theme.Size.compactArtwork, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Self.label(for: Equalizer.frequencies[band]))
                }
                Button("Reset to Flat") { app.equalizer.apply(Equalizer.presets[0]) }
                    .disabled(equalizer.presetName == "Flat")
            }
            .disabled(!equalizer.isEnabled)
        }
        .navigationTitle("Equalizer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private static func label(for frequency: Float) -> String {
        frequency >= 1_000 ? "\(Int(frequency / 1_000)) kHz" : "\(Int(frequency)) Hz"
    }

    private static func decibels(_ gain: Float) -> String {
        gain == 0 ? "0 dB" : String(format: "%+.1f dB", gain)
    }
}

/// A smooth line through the band settings, so the shape of the sound is visible at a glance.
private struct EqualizerCurve: View {
    let gains: [Float]

    var body: some View {
        Canvas { context, size in
            let range = Equalizer.range
            func point(_ index: Int) -> CGPoint {
                let x = size.width * CGFloat(index) / CGFloat(max(gains.count - 1, 1))
                let fraction = CGFloat((gains[index] - range.lowerBound) / (range.upperBound - range.lowerBound))
                return CGPoint(x: x, y: size.height * (1 - fraction))
            }
            var middle = Path()
            middle.move(to: CGPoint(x: 0, y: size.height / 2))
            middle.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(middle, with: .color(.secondary.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

            guard !gains.isEmpty else { return }
            var curve = Path()
            curve.move(to: point(0))
            for index in 1..<gains.count {
                let previous = point(index - 1), current = point(index)
                let mid = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
                curve.addQuadCurve(to: mid, control: previous)
                if index == gains.count - 1 { curve.addQuadCurve(to: current, control: current) }
            }
            context.stroke(curve, with: .color(Color.dial), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
        .animation(.easeInOut(duration: 0.25), value: gains)
        .accessibilityHidden(true)
    }
}

// MARK: - Devices (one session, played wherever you choose)

/// Where the music plays. The current device is at the top; tap another to move the music
/// there from the same spot. This iPhone keeps working as the remote.
struct DevicesSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    private var remote: RemoteControl { app.remote }
    private var player: Player { app.player }

    @State private var airPlay = AirPlayTrigger()

    var body: some View {
        NavigationStack {
            List {
                Section("Current Device") {
                    if let name = player.outputName {
                        DeviceRow(name: name, detail: nowPlayingLine, symbol: Self.symbol(for: name), isCurrent: true)
                    } else {
                        DeviceRow(name: Platform.thisDevice, detail: nowPlayingLine, symbol: Platform.deviceSymbol, isCurrent: true)
                        Button { airPlay.present() } label: {
                            HStack(spacing: Theme.Spacing.m) {
                                AirPlayButton(trigger: airPlay)
                                    .frame(width: Theme.Size.tapTarget, height: Theme.Size.tapTarget)
                                    .allowsHitTesting(false)
                                Text("AirPlay and Bluetooth")
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("AirPlay and Bluetooth speakers")
                    }
                }

                Section {
                    if player.isRemote {
                        Button {
                            Task {
                                await remote.selectThisDevice()
                                dismiss()
                            }
                        } label: {
                            DeviceRow(name: Platform.thisDevice, detail: "Play here", symbol: Platform.deviceSymbol,
                                      isCurrent: false, isSwitching: remote.switchingTo == "this")
                        }
                        .buttonStyle(.plain)
                    }
                    if otherDevices.isEmpty && !player.isRemote {
                        if remote.isLoading {
                            SkeletonRow()
                                .shimmering()
                        } else {
                            Label("No other devices are open right now", systemImage: "laptopcomputer.and.iphone")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(otherDevices) { device in
                        Button {
                            Task {
                                await remote.select(device)
                                dismiss()
                            }
                        } label: {
                            DeviceRow(name: device.name,
                                      detail: device.nowPlaying.map { "Playing \($0.name)" } ?? (device.isDial ? "Dial" : device.app),
                                      symbol: Self.symbol(for: device.name + " " + device.app),
                                      isCurrent: false, isSwitching: remote.switchingTo == device.id)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Select a Device")
                } footer: {
                    Text("Open Dial or Jellyfin on your TV, computer or another phone, signed in to the same account, and it appears here. The music moves there from the same spot, and you keep controlling it from this \(Platform.deviceKind). Between Dial apps, live radio and \(app.dj.name) move too; other Jellyfin apps play songs only.")
                }

                // Why other devices might not appear.
                Section {
                    LabeledContent("Live connection", value: remote.isLinked ? "Connected" : "Not connected")
                    if let problem = remote.capabilitiesProblem {
                        LabeledContent("Server registration", value: problem)
                    }
                    ForEach(remote.uncontrollable, id: \.self) { name in
                        LabeledContent(name, value: "Can't be controlled")
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Text(remote.isLinked
                         ? "Your other Dial apps appear above while they're open."
                         : "Dial can't keep a live connection to your server, so other devices can't see or control this one. If you use a reverse proxy, check that it allows WebSocket connections.")
                }
            }
            .navigationTitle("Devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await remote.refresh(userInitiated: true) }
            .refreshable { await remote.refresh(userInitiated: true) }
        }
        .presentationDetents([.medium, .large])
    }

    /// Every controllable device except the one currently playing.
    private var otherDevices: [RemoteControl.Device] {
        let currentId: String? = { if case .remote(let id, _) = player.output { return id } else { return nil } }()
        return remote.receivers.filter { $0.id != currentId }
    }

    private var nowPlayingLine: String {
        player.hasContent ? player.nowTitle : "Nothing playing"
    }

    static func symbol(for name: String) -> String {
        let name = name.lowercased()
        if name.contains("tv") { return "tv" }
        if name.contains("iphone") || name.contains("android") || name.contains("phone") { return "iphone" }
        if name.contains("ipad") || name.contains("tablet") { return "ipad" }
        if name.contains("web") || name.contains("chrome") || name.contains("safari") || name.contains("firefox") { return "globe" }
        if name.contains("speaker") || name.contains("homepod") || name.contains("sonos") { return "hifispeaker" }
        return "laptopcomputer"
    }
}

private struct DeviceRow: View {
    let name: String
    let detail: String
    let symbol: String
    let isCurrent: Bool
    var isSwitching = false

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(isCurrent ? Color.dial : Color.secondary)
                .frame(width: Theme.Size.rowArtwork, height: Theme.Size.rowArtwork)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(name)
                    .foregroundStyle(isCurrent ? Color.dial : Color.primary)
                    .lineLimit(1)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Spacing.s)
            if isSwitching {
                ProgressView()
            } else if isCurrent {
                Image(systemName: "waveform")
                    .foregroundStyle(Color.dial)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? .isSelected : .isButton)
    }
}
