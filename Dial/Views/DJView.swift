import SwiftUI

// MARK: - The dial ring

/// Dial's on-air visual: a ring of tick marks, like the scale on a radio dial,
/// that ripples each time the DJ starts a word and breathes slowly in between.
struct DialRing: View {
    /// When the DJ last started a word; ticks swell from this moment and settle again.
    var lastWordAt: Date = .distantPast
    /// Moves on its own (breathing). Off for small, static artwork.
    var animated = true
    var tickCount = 72
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if animated && !reduceMotion {
            TimelineView(.animation) { timeline in
                ring(at: timeline.date)
            }
        } else {
            ring(at: .distantPast)
        }
    }

    private func ring(at date: Date) -> some View {
        Canvas { context, size in
            let time = date.timeIntervalSinceReferenceDate
            let since = date.timeIntervalSince(lastWordAt)
            let pulse = since >= 0 ? exp(-since * 4) : 0
            let breath = animated ? 0.5 + 0.5 * sin(time * 1.4) : 0.5
            let radius = min(size.width, size.height) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let inner = radius * 0.62
            let maxLength = radius * 0.34

            for index in 0..<tickCount {
                let angle = Double(index) / Double(tickCount) * 2 * .pi - .pi / 2
                // Each tick rides its own wave, so a pulse looks like sound moving around the dial.
                let wave = 0.5 + 0.5 * sin(Double(index) * 0.55 + time * 3.2)
                let energy = 0.18 + 0.12 * breath + pulse * (0.35 + 0.65 * wave)
                let length = maxLength * min(energy, 1)
                let major = index % 6 == 0
                let start = CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner)
                let end = CGPoint(x: center.x + cos(angle) * (inner + length * (major ? 1.15 : 1)),
                                  y: center.y + sin(angle) * (inner + length * (major ? 1.15 : 1)))
                var path = Path()
                path.move(to: start)
                path.addLine(to: end)
                context.stroke(path, with: .color(Color.dial.opacity(0.45 + 0.55 * min(energy * 1.4, 1))),
                               style: StrokeStyle(lineWidth: major ? radius * 0.035 : radius * 0.022, lineCap: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The DJ station's artwork, used on tiles and in the mini player.
struct DJArtwork: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.14, green: 0.07, blue: 0.22), Color(red: 0.05, green: 0.03, blue: 0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            DialRing(animated: false)
                .padding(Theme.Spacing.s)
            Text(app.settings.displayDJName)
                .font(.headline)
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(.horizontal, Theme.Spacing.l)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - On air (inside the full-screen player)

/// Shown in the player while the DJ talks: the ring moves with the voice,
/// the words appear underneath, and the next song waits below.
struct DJOnAirPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            Spacer(minLength: Theme.Spacing.l)
            ZStack {
                DialRing(lastWordAt: app.dj.lastWordAt)
                VStack(spacing: Theme.Spacing.xxs) {
                    Text(app.dj.name)
                        .font(.title2.bold())
                    Text("On air")
                        .font(.subheadline)
                        .playerSecondary()
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .padding(.horizontal, Theme.Spacing.xl)

            Text(app.dj.caption ?? " ")
                .font(.title3.weight(.medium))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: Theme.Size.compactArtwork, alignment: .top)
                .contentTransition(.opacity)
                .animation(.easeInOut, value: app.dj.caption)
                .accessibilityLabel(app.dj.caption.map { "\(app.dj.name) says: \($0)" } ?? "\(app.dj.name) is on air")

            Spacer(minLength: Theme.Spacing.l)

            if let next = app.player.current {
                HStack(spacing: Theme.Spacing.m) {
                    MediaRow(title: next.name, subtitle: next.artistLine) {
                        ArtworkView(itemId: next.imageItemId, pixels: Theme.Pixels.thumb)
                    }
                    Button("Skip") { app.dj.skipBreak() }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.bordered)
                        .tint(.white)
                        .accessibilityHint("Skips the DJ and starts the song")
                }
                .padding(Theme.Spacing.m)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            }
        }
    }
}

// MARK: - Requests

/// Pick a vibe for the DJ with a tap: no typing. Used as a page and as a sheet from the player's DJ button.
struct DJRequestView: View {
    var showsDoneButton = false
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    private var dj: DJ { app.dj }

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Theme.Spacing.m)]

    var body: some View {
        Group {
            if let prep = dj.prep {
                DJPreparingView(prep: prep, name: dj.name)
            } else {
                vibePicker
            }
        }
        .animation(.easeInOut(duration: 0.25), value: dj.prep == nil)
        .navigationTitle(dj.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var vibePicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                Text(dj.isActive ? "Jump to another vibe" : "What's the vibe?")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, Theme.Spacing.l)

                LazyVGrid(columns: columns, spacing: Theme.Spacing.m) {
                    if dj.isActive {
                        Button { switchItUp() } label: { VibeTile(title: "Switch it up", subtitle: "A little different", symbol: "arrow.triangle.branch", colors: [Color.dial, Color.dial.opacity(0.6)]) }
                            .buttonStyle(.plain)
                    } else {
                        Button { play(nil) } label: { VibeTile(title: "Let \(dj.name) pick", subtitle: "Surprise me", symbol: "dot.radiowaves.left.and.right", colors: [Color.dial, Color.dial.opacity(0.6)]) }
                            .buttonStyle(.plain)
                    }
                    ForEach(MixCatalog.moods, id: \.id) { mood in
                        Button { play(mood.sound, title: mood.title) } label: { VibeTile(title: mood.title, subtitle: mood.subtitle, symbol: nil, colors: mood.palette.compactMap(Color.init(hex:))) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.Spacing.l)

            }
            .padding(.vertical, Theme.Spacing.l)
        }
    }

    /// Moves the DJ somewhere new without a specific request.
    private func switchItUp() {
        guard !dj.isPreparing else { return }
        Task {
            await dj.changeDirection()
            if showsDoneButton { dismiss() }
        }
    }

    /// Jumps to a vibe, or with nil lets the DJ choose.
    private func play(_ request: String?, title: String? = nil) {
        guard !dj.isPreparing else { return }
        let text = request?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        app.stations.markPlayed(.dj)
        Task {
            if text.isEmpty { await dj.start() }
            else if let title { await dj.play(sound: text, title: title) } // a tapped vibe needs no interpreting
            else { await dj.handle(request: text) }
            if showsDoneButton && dj.isActive { dismiss() }
        }
    }
}

// MARK: - Getting ready

/// What Marlo is doing while a set is put together: the request, the steps with where it is, and what it has decided so far
/// (the block, the first songs, why, and the intro it is about to say).
struct DJPreparingView: View {
    let prep: DJPrep
    let name: String

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                ZStack {
                    DialRing(lastWordAt: .distantPast)
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.title).foregroundStyle(Color.dial).accessibilityHidden(true)
                }
                .frame(width: 150, height: 150)
                .padding(.top, Theme.Spacing.l)

                VStack(spacing: Theme.Spacing.xs) {
                    Text("\(name) is getting your set ready").font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                    if let request = prep.request {
                        Text("\u{201C}\(request)\u{201D}").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }

                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    ForEach(prep.steps) { step in
                        HStack(spacing: Theme.Spacing.m) {
                            Group {
                                if step.rawValue < prep.step.rawValue {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                } else if step == prep.step {
                                    ProgressView()
                                } else {
                                    Image(systemName: "circle").foregroundStyle(.tertiary)
                                }
                            }
                            .frame(width: 24, height: 24)
                            Text(step.title)
                                .foregroundStyle(step.rawValue > prep.step.rawValue ? .secondary : .primary)
                                .font(step == prep.step ? .body.weight(.semibold) : .body)
                        }
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)
                .padding(.horizontal, Theme.Spacing.l)

                if let block = prep.blockTitle {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        Text("First up").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(block).font(.headline)
                        ForEach(prep.songs, id: \.self) { song in
                            Label(song, systemImage: "music.note").font(.subheadline).lineLimit(1)
                        }
                        ForEach(prep.why, id: \.self) { reason in
                            Text(reason).font(.footnote).foregroundStyle(.secondary)
                        }
                        if let line = prep.line {
                            Text("\u{201C}\(line)\u{201D}").font(.callout.italic()).padding(.top, Theme.Spacing.xs)
                        }
                    }
                    .frame(maxWidth: 420, alignment: .leading)
                    .padding(Theme.Spacing.m)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: Theme.Radius.tile, style: .continuous))
                    .padding(.horizontal, Theme.Spacing.l)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, Theme.Spacing.section)
            .animation(.easeInOut(duration: 0.3), value: prep)
        }
    }
}

private struct VibeTile: View {
    let title: String
    let subtitle: String
    let symbol: String?
    let colors: [Color]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            if let symbol { Image(systemName: symbol).font(.title3).accessibilityHidden(true) }
            Spacer(minLength: 0)
            Text(title).font(.headline)
            Text(subtitle).font(.caption).opacity(0.85).lineLimit(2)
        }
        .multilineTextAlignment(.leading)
        .foregroundStyle(.white)
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(LinearGradient(colors: colors.isEmpty ? [.gray, .black] : colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
    }
}

/// A small "DJ" tag shown in the mini player while the DJ is on.
struct DJBadge: View {
    var body: some View {
        Text("DJ")
            .font(.caption2.weight(.heavy))
            .padding(.horizontal, Theme.Spacing.xs)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(Color.dial, in: RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
            .foregroundStyle(.black)
            .accessibilityLabel("DJ on")
    }
}

/// A small, quiet tag for what the music was started from (a station, a mix, a mixtape).
struct SourceBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, Theme.Spacing.xs)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(Color.dial.opacity(0.18), in: RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
            .foregroundStyle(Color.dial)
            .frame(maxWidth: 130, alignment: .leading)
            .accessibilityLabel("Playing from \(text)")
    }
}
