import AppIntents
import SwiftUI
import WidgetKit

@main
struct DialWidgetBundle: WidgetBundle {
    var body: some Widget { DialLastPlayedWidget() }
}

struct LastEntry: TimelineEntry {
    let date: Date
    let item: DialWidgetItem?
    let artwork: UIImage?
    var playing = false
}

struct LastProvider: TimelineProvider {
    func placeholder(in context: Context) -> LastEntry {
        LastEntry(date: .now, item: DialWidgetItem(kind: .album, id: "", albumId: nil, album: nil, title: "Your music", subtitle: "Dial", station: nil), artwork: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (LastEntry) -> Void) { completion(current()) }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LastEntry>) -> Void) {
        // The app reloads this when a new song starts; refreshing now and then covers what it can't.
        completion(Timeline(entries: [current()], policy: .after(Date().addingTimeInterval(900))))
    }

    private func current() -> LastEntry {
        let stored = DialWidgetStore.load()
        return LastEntry(date: .now, item: stored?.item, artwork: stored?.artwork.flatMap(UIImage.init(data:)), playing: stored?.playing ?? false)
    }
}

private let accent = Color(red: 0.91, green: 0.455, blue: 0.173)

private extension Image {
    /// In the Home Screen's tinted and clear styles the cover is drawn desaturated but solid (not see-through);
    /// in the normal style it stays in full colour.
    @ViewBuilder
    func tintedCover() -> some View {
        if #available(iOS 18.0, *) { self.widgetAccentedRenderingMode(.desaturated) } else { self }
    }

    /// The Home Screen can draw widgets tinted (everything one colour); a cover has to stay in full colour.
    @ViewBuilder
    func keepsColor() -> some View {
        if #available(iOS 18.0, *) { self.widgetAccentedRenderingMode(.fullColor) } else { self }
    }
}

struct DialLastPlayedWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: DialWidgetStore.kind, provider: LastProvider()) { entry in
            LastView(entry: entry)
                .widgetURL(URL(string: "dial://last"))
                .containerBackground(for: .widget) {
                    ZStack {
                        if let art = entry.artwork {
                            Image(uiImage: art).resizable().scaledToFill().blur(radius: 30).scaleEffect(1.4)
                            Color.black.opacity(0.45)
                        } else {
                            LinearGradient(colors: [Color(red: 0.23, green: 0.12, blue: 0.07), Color(red: 0.66, green: 0.31, blue: 0.16)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        }
                    }
                }
        }
        .configurationDisplayName("Last played")
        .description("The last album or station you played. Play it, or open it.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct LastView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LastEntry

    var body: some View {
        if let item = entry.item {
            if family == .systemSmall { small(item) } else { medium(item) }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "opticaldisc").font(.title)
                Text("Play something in Dial").font(.footnote.weight(.semibold)).multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func small(_ item: DialWidgetItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                cover(size: 74)
                Spacer()
                DiscMark().frame(width: 24, height: 24).widgetAccentable()
            }
            Spacer(minLength: 4)
            HStack(alignment: .bottom, spacing: 6) {
                text(item)
                Spacer(minLength: 0)
                play(size: 34)
            }
        }
    }

    private func medium(_ item: DialWidgetItem) -> some View {
        HStack(spacing: 14) {
            cover(size: 124)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.kind == .station ? "LIVE RADIO" : "LAST PLAYED")
                    .font(.caption2.weight(.bold)).foregroundStyle(accent)
                text(item, big: true)
                Spacer(minLength: 0)
                HStack { Spacer(); play(size: 44) }
            }
        }
    }

    private func text(_ item: DialWidgetItem, big: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.title).font(.system(size: big ? 14 : 11, weight: .semibold)).lineLimit(big ? 3 : 2).foregroundStyle(.white)
            Text(item.subtitle).font(.system(size: big ? 12 : 10)).lineLimit(1).foregroundStyle(.white.opacity(0.7))
        }
    }

    private func cover(size: CGFloat) -> some View {
        Group {
            if let art = entry.artwork {
                Image(uiImage: art).resizable().tintedCover().scaledToFill()
            } else {
                ZStack { Color.white.opacity(0.15); Image(systemName: "music.note").foregroundStyle(.white.opacity(0.7)) }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 100 ? 14 : 10, style: .continuous))
    }

    private func play(size: CGFloat) -> some View {
        Button(intent: DialPlayLastIntent()) {
            Image(systemName: entry.playing ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(.white.opacity(0.25), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}


/// Just the disc of the app icon: the thin bright rim, the dark record, the white label and its hole. A plain shape, so it
/// follows every Home Screen style.
private struct DiscMark: View {
    var body: some View {
        ZStack {
            Circle().strokeBorder(.white, lineWidth: 1.8)
            Circle().fill(.white.opacity(0.14)).padding(1.8)
            Circle().fill(.white).frame(width: 8, height: 8)
            Circle().fill(.black.opacity(0.65)).frame(width: 1.5, height: 1.5)
        }
    }
}
