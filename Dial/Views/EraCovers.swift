import SwiftUI

// MARK: - Decade covers

/// How a decade looks on its cover: the colors, lettering and decoration of its time.
/// The 70s are brown, orange and mustard arcs in a chunky rounded face; the 80s a neon sunset over a grid.
struct EraStyle {
    enum Decoration { case deco, diner, psychedelic, seventies, neon, memphis, y2k, pastel, now }

    let background: [Color]
    let ink: Color
    let design: Font.Design
    let weight: Font.Weight
    let italic: Bool
    let decoration: Decoration

    static func of(_ decade: Int) -> EraStyle {
        switch decade {
        case ..<1950:
            return EraStyle(background: [Color(hex: "#13203A")!, Color(hex: "#0A1226")!], ink: Color(hex: "#E8C468")!,
                            design: .serif, weight: .bold, italic: false, decoration: .deco)
        case 1950..<1960:
            return EraStyle(background: [Color(hex: "#F6E7C8")!, Color(hex: "#EBD3A3")!], ink: Color(hex: "#C2364A")!,
                            design: .serif, weight: .black, italic: true, decoration: .diner)
        case 1960..<1970:
            return EraStyle(background: [Color(hex: "#FF7A18")!, Color(hex: "#E4007C")!], ink: Color(hex: "#FFF4D6")!,
                            design: .rounded, weight: .black, italic: false, decoration: .psychedelic)
        case 1970..<1980:
            return EraStyle(background: [Color(hex: "#5B2A12")!, Color(hex: "#3E1B0B")!], ink: Color(hex: "#F7E3B5")!,
                            design: .rounded, weight: .heavy, italic: false, decoration: .seventies)
        case 1980..<1990:
            return EraStyle(background: [Color(hex: "#1B0B3A")!, Color(hex: "#4A1068")!], ink: .white,
                            design: .default, weight: .black, italic: true, decoration: .neon)
        case 1990..<2000:
            return EraStyle(background: [Color(hex: "#00A7B5")!, Color(hex: "#007E8C")!], ink: Color(hex: "#FFE14D")!,
                            design: .monospaced, weight: .black, italic: false, decoration: .memphis)
        case 2000..<2010:
            return EraStyle(background: [Color(hex: "#C9DCFF")!, Color(hex: "#5C7FE0")!], ink: .white,
                            design: .rounded, weight: .bold, italic: false, decoration: .y2k)
        case 2010..<2020:
            return EraStyle(background: [Color(hex: "#FFD9E2")!, Color(hex: "#C9B8FF")!], ink: Color(hex: "#2B2350")!,
                            design: .default, weight: .light, italic: false, decoration: .pastel)
        default:
            return EraStyle(background: [Color(hex: "#0E1B2C")!, Color(hex: "#1D5B6B")!], ink: .white,
                            design: .default, weight: .semibold, italic: false, decoration: .now)
        }
    }
}

/// A decade as a poster of its time. Everything is drawn relative to the size, so it is as good as a tile and as a page header.
struct EraCover: View {
    let decade: Int

    private var label: String { DecadeView.name(decade) }

    var body: some View {
        let style = EraStyle.of(decade)
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    let size = proxy.size
                    ZStack(alignment: .topLeading) {
                        LinearGradient(colors: style.background, startPoint: .top, endPoint: .bottom)
                        Canvas { context, canvasSize in
                            Self.draw(style.decoration, in: &context, size: canvasSize)
                        }
                        title(style, size: size)
                    }
                }
            }
            .drawingGroup()
            .clipShape(.rounded(Theme.Radius.tile))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("The \(label)")
    }

    @ViewBuilder
    private func title(_ style: EraStyle, size: CGSize) -> some View {
        let font = Font.system(size: size.width * (label.count > 3 ? 0.27 : 0.36), weight: style.weight, design: style.design)
        let text = Text(label)
            .font(style.italic ? font.italic() : font)
            .tracking(style.decoration == .seventies ? -size.width * 0.012 : 0)
            .foregroundStyle(style.ink)
        Group {
            switch style.decoration {
            case .neon:
                text.shadow(color: Color(hex: "#FF3CAC")!, radius: size.width * 0.04)
                    .shadow(color: Color(hex: "#2DE2E6")!.opacity(0.7), radius: size.width * 0.08)
            case .y2k:
                text.shadow(color: Color(hex: "#2B4BB5")!.opacity(0.55), radius: 0, x: size.width * 0.012, y: size.width * 0.012)
            case .seventies:
                text.shadow(color: Color(hex: "#E0701A")!, radius: 0, x: size.width * 0.018, y: size.width * 0.018)
            case .memphis:
                text.shadow(color: Color(hex: "#E83E8C")!, radius: 0, x: size.width * 0.02, y: size.width * 0.02)
            default:
                text
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .padding(size.width * 0.08)
    }

    // MARK: Decoration

    private static func draw(_ kind: EraStyle.Decoration, in context: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        switch kind {
        case .seventies:
            // Rainbow arcs rising from the bottom-right corner: mustard, orange, rust, cream.
            let colors = ["#F2B531", "#E0701A", "#B8431C", "#F7E3B5"].map { Color(hex: $0)! }
            let center = CGPoint(x: w, y: h)
            let band = w * 0.075
            for (index, color) in colors.enumerated() {
                let radius = w * 0.88 - CGFloat(index) * band
                var path = Path()
                path.addArc(center: center, radius: radius, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: band * 0.85, lineCap: .butt))
            }
            var sun = Path()
            sun.addEllipse(in: CGRect(x: w * 0.69, y: h * 0.69, width: w * 0.31, height: h * 0.31))
            context.fill(sun, with: .color(Color(hex: "#F2B531")!))
        case .neon:
            // A striped sun over a perspective grid.
            let horizon = h * 0.64
            let sun = CGRect(x: w * 0.25, y: h * 0.30, width: w * 0.5, height: w * 0.5)
            var disc = context
            disc.clip(to: Path(CGRect(x: 0, y: 0, width: w, height: horizon)))
            disc.fill(Path(ellipseIn: sun), with: .linearGradient(
                Gradient(colors: [Color(hex: "#FFE14D")!, Color(hex: "#FF3CAC")!]),
                startPoint: CGPoint(x: 0, y: sun.minY), endPoint: CGPoint(x: 0, y: sun.maxY)))
            for index in 0..<5 {
                let y = sun.midY + CGFloat(index) * w * 0.045
                disc.fill(Path(CGRect(x: 0, y: y, width: w, height: w * 0.012 + CGFloat(index) * w * 0.006)),
                          with: .color(Color(hex: "#2A0F4F")!))
            }
            let grid = Color(hex: "#2DE2E6")!.opacity(0.85)
            context.stroke(Path { $0.move(to: CGPoint(x: 0, y: horizon)); $0.addLine(to: CGPoint(x: w, y: horizon)) },
                           with: .color(grid), lineWidth: w * 0.006)
            for index in 1...5 {
                let t = pow(CGFloat(index) / 5, 2)
                let y = horizon + (h - horizon) * t
                context.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: w, y: y)) },
                               with: .color(grid.opacity(0.7)), lineWidth: w * 0.005)
            }
            for index in -6...6 {
                let x = w / 2 + CGFloat(index) * w * 0.28
                context.stroke(Path { $0.move(to: CGPoint(x: w / 2 + CGFloat(index) * w * 0.03, y: horizon)); $0.addLine(to: CGPoint(x: x, y: h)) },
                               with: .color(grid.opacity(0.7)), lineWidth: w * 0.005)
            }
        case .psychedelic:
            let colors = ["#E4007C", "#FF7A18", "#FFD23F", "#6A1B9A", "#E4007C"].map { Color(hex: $0)! }
            let center = CGPoint(x: w * 0.78, y: h * 0.82)
            for (index, color) in colors.enumerated() {
                let radius = w * (0.78 - CGFloat(index) * 0.15)
                context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                             with: .color(color.opacity(0.9)))
            }
        case .diner:
            // A sunburst from the top and a cherry-red band along the bottom.
            let teal = Color(hex: "#2A9D8F")!.opacity(0.55)
            let center = CGPoint(x: w / 2, y: -h * 0.1)
            for index in 0..<14 where index % 2 == 0 {
                var ray = Path()
                let a0 = Angle.degrees(Double(index) * 180 / 14).radians, a1 = Angle.degrees(Double(index + 1) * 180 / 14).radians
                ray.move(to: center)
                ray.addLine(to: CGPoint(x: center.x + cos(a0) * w * 2, y: center.y + sin(a0) * w * 2))
                ray.addLine(to: CGPoint(x: center.x + cos(a1) * w * 2, y: center.y + sin(a1) * w * 2))
                ray.closeSubpath()
                context.fill(ray, with: .color(teal))
            }
            context.fill(Path(CGRect(x: 0, y: h * 0.82, width: w, height: h * 0.18)), with: .color(Color(hex: "#C2364A")!))
            context.fill(Path(CGRect(x: 0, y: h * 0.80, width: w, height: h * 0.02)), with: .color(Color(hex: "#FFF4D6")!))
        case .deco:
            // Gold fan rays from the bottom centre.
            let gold = Color(hex: "#E8C468")!
            let center = CGPoint(x: w / 2, y: h * 1.05)
            for index in 0...8 {
                let angle = Angle.degrees(200 + Double(index) * 17.5).radians
                context.stroke(Path { $0.move(to: center); $0.addLine(to: CGPoint(x: center.x + cos(angle) * w, y: center.y + sin(angle) * w)) },
                               with: .color(gold.opacity(0.75)), lineWidth: w * 0.01)
            }
            for index in 1...3 {
                let radius = w * 0.2 * CGFloat(index)
                var arc = Path()
                arc.addArc(center: center, radius: radius, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
                context.stroke(arc, with: .color(gold.opacity(0.8)), lineWidth: w * 0.012)
            }
        case .memphis:
            let pink = Color(hex: "#E83E8C")!, yellow = Color(hex: "#FFE14D")!, purple = Color(hex: "#5B2C9F")!
            context.fill(Path(ellipseIn: CGRect(x: w * 0.62, y: h * 0.58, width: w * 0.26, height: w * 0.26)), with: .color(pink))
            var triangle = Path()
            triangle.move(to: CGPoint(x: w * 0.1, y: h * 0.9)); triangle.addLine(to: CGPoint(x: w * 0.34, y: h * 0.9))
            triangle.addLine(to: CGPoint(x: w * 0.22, y: h * 0.66)); triangle.closeSubpath()
            context.fill(triangle, with: .color(purple))
            var squiggle = Path()
            squiggle.move(to: CGPoint(x: w * 0.42, y: h * 0.76))
            for step in 0..<5 {
                let x = w * (0.42 + 0.1 * CGFloat(step))
                squiggle.addQuadCurve(to: CGPoint(x: x + w * 0.1, y: h * 0.76), control: CGPoint(x: x + w * 0.05, y: h * (step % 2 == 0 ? 0.68 : 0.84)))
            }
            context.stroke(squiggle, with: .color(yellow), style: StrokeStyle(lineWidth: w * 0.026, lineCap: .round))
            for point in [CGPoint(x: 0.82, y: 0.2), CGPoint(x: 0.9, y: 0.32), CGPoint(x: 0.74, y: 0.36)] {
                context.fill(Path(ellipseIn: CGRect(x: w * point.x, y: h * point.y, width: w * 0.04, height: w * 0.04)), with: .color(yellow))
            }
        case .y2k:
            // A glossy sphere and a few four-point stars.
            let sphere = CGRect(x: w * 0.42, y: h * 0.4, width: w * 0.62, height: w * 0.62)
            context.fill(Path(ellipseIn: sphere), with: .radialGradient(
                Gradient(colors: [.white, Color(hex: "#8FB0FF")!, Color(hex: "#2B4BB5")!]),
                center: CGPoint(x: sphere.minX + sphere.width * 0.35, y: sphere.minY + sphere.height * 0.3),
                startRadius: 0, endRadius: sphere.width * 0.8))
            for (x, y, s) in [(0.12, 0.62, 0.1), (0.26, 0.84, 0.06), (0.9, 0.32, 0.07)] as [(CGFloat, CGFloat, CGFloat)] {
                var star = Path()
                let c = CGPoint(x: w * x, y: h * y), r = w * s
                star.move(to: CGPoint(x: c.x, y: c.y - r))
                star.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: c)
                star.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: c)
                star.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: c)
                star.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: c)
                context.fill(star, with: .color(.white.opacity(0.9)))
            }
        case .pastel:
            for (x, y, s, hex) in [(0.5, 0.45, 0.62, "#FFFFFF"), (0.1, 0.55, 0.5, "#FFB3C7"), (0.55, 0.62, 0.55, "#A8C8FF")] as [(CGFloat, CGFloat, CGFloat, String)] {
                context.fill(Path(ellipseIn: CGRect(x: w * x, y: h * y, width: w * s, height: w * s)),
                             with: .color(Color(hex: hex)!.opacity(0.55)))
            }
        case .now:
            context.fill(Path(ellipseIn: CGRect(x: w * 0.3, y: h * 0.35, width: w * 0.9, height: w * 0.9)),
                         with: .radialGradient(Gradient(colors: [Color(hex: "#2FD4A6")!.opacity(0.8), .clear]),
                                               center: CGPoint(x: w * 0.75, y: h * 0.8), startRadius: 0, endRadius: w * 0.55))
            context.fill(Path(ellipseIn: CGRect(x: -w * 0.2, y: h * 0.5, width: w * 0.8, height: w * 0.8)),
                         with: .radialGradient(Gradient(colors: [Color(hex: "#5B7CFF")!.opacity(0.7), .clear]),
                                               center: CGPoint(x: w * 0.15, y: h * 0.95), startRadius: 0, endRadius: w * 0.5))
        }
    }
}

// MARK: - Genre covers

/// A genre: its colors, a big faded symbol that suits it, and its name in a heavy rounded face.
struct GenreCover: View {
    let title: String
    let colors: [Color]

    private var symbol: String {
        let name = title.lowercased()
        let table: [(String, String)] = [
            ("hip", "headphones"), ("rap", "headphones"), ("rock", "guitars.fill"), ("metal", "bolt.fill"), ("punk", "bolt.fill"),
            ("jazz", "music.quarternote.3"), ("blues", "music.quarternote.3"), ("electronic", "waveform"), ("dance", "waveform"),
            ("house", "waveform"), ("pop", "sparkles"), ("classical", "pianokeys"), ("folk", "tree.fill"), ("country", "tree.fill"),
            ("soul", "heart.fill"), ("r&b", "heart.fill"), ("latin", "flame.fill"), ("reggae", "sun.max.fill"), ("ambient", "moon.stars.fill"),
            ("indie", "leaf.fill"), ("alternative", "leaf.fill"), ("funk", "music.mic"),
        ]
        return table.first { name.contains($0.0) }?.1 ?? "music.note"
    }

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    ZStack(alignment: .bottomLeading) {
                        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: symbol)
                            .font(.system(size: proxy.size.width * 0.62, weight: .black))
                            .foregroundStyle(.white.opacity(0.18))
                            .rotationEffect(.degrees(-12))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .offset(x: proxy.size.width * 0.08, y: -proxy.size.width * 0.04)
                            .accessibilityHidden(true)
                        Text(title)
                            .font(.system(size: proxy.size.width * 0.17, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                            .padding(proxy.size.width * 0.08)
                    }
                }
            }
            .drawingGroup()
            .clipShape(.rounded(Theme.Radius.tile))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title) genre")
    }
}
