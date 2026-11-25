import SwiftUI

// MARK: - Mixtape cover

/// A mixtape's cover: four covers from its songs under the mix's colors with its name in bold, like Apple's mixes.
/// A decade is a poster of its era and a genre has its own colors and symbol.
struct MixtapeCover: View {
    let mixtape: Mixtape
    var titleFont: Font = .title3.weight(.heavy)

    var body: some View {
        if mixtape.id.hasPrefix("decade-"), let decade = Int(mixtape.id.dropFirst("decade-".count)) {
            EraCover(decade: decade)
        } else if mixtape.id.hasPrefix("genre-") {
            GenreCover(title: mixtape.title, colors: mixtape.colors)
        } else {
            CollageCover(title: mixtape.title, coverIds: mixtape.coverIds, colors: mixtape.colors, titleFont: titleFont)
        }
    }
}

/// Four album covers under a color wash, with a bold title: mixtapes, decades and genres all look like this.
struct CollageCover: View {
    let title: String
    let coverIds: [String]
    let colors: [Color]
    var titleFont: Font = .title3.weight(.heavy)
    var showsDial = true

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow { cell(0); cell(1) }
                    GridRow { cell(2); cell(3) }
                }
            }
            .overlay {
                LinearGradient(colors: colors.map { $0.opacity(0.82) }, startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .overlay(alignment: .bottomLeading) {
                Text(title)
                    .font(titleFont)
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
                    .padding(Theme.Spacing.m)
            }
            .overlay(alignment: .topTrailing) {
                if showsDial {
                    Image(systemName: "dial.medium.fill")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(Theme.Spacing.m)
                        .accessibilityHidden(true)
                }
            }
            // One flat, cached picture per cover instead of five layers with a blur and a mask each,
            // which is what made scrolling past many of them stutter.
            .drawingGroup()
            .clipShape(.rounded(Theme.Radius.tile))
    }

    @ViewBuilder
    private func cell(_ index: Int) -> some View {
        let id = coverIds.isEmpty ? nil : coverIds[index % coverIds.count]
        Color.clear
            .overlay { if let id { ArtworkView(itemId: id, pixels: Theme.Pixels.thumb) } }
            .clipped()
    }
}

/// A decade or genre in the mixtape style: the collage, then a short line under it.
struct CollageTile: View {
    let title: String
    let subtitle: String
    let coverIds: [String]
    let colors: [Color]
    let route: Route

    var body: some View {
        NavigationLink(value: route) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                CollageCover(title: title, coverIds: coverIds, colors: colors, showsDial: false)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(subtitle)")
    }
}

/// A mixtape in a grid: the cover, then what it is.
struct MixtapeTile: View {
    let mixtape: Mixtape
    var width: CGFloat? = nil

    var body: some View {
        NavigationLink(value: Route.mixtape(mixtape)) {
            MixtapeCover(mixtape: mixtape)
                .frame(width: width)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mixtape.title). \(mixtape.subtitle)")
    }
}

// MARK: - Mixtape page

struct MixtapeView: View {
    let mixtape: Mixtape
    @Environment(AppModel.self) private var app
    @State private var tracks: [BaseItem] = []
    @State private var triedEmpty = false

    var body: some View {
        List {
            VStack(spacing: Theme.Spacing.m) {
                MixtapeCover(mixtape: mixtape, titleFont: .largeTitle.weight(.heavy))
                    .frame(maxWidth: Theme.Size.albumHeaderArtwork * 1.2)
                    .artworkShadow()
                Text(mixtape.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(tracks.isEmpty ? (triedEmpty ? "No songs from your library fit this yet" : "Picking songs\u{2026}") : "\(tracks.count) songs from your library")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                PlayShuffleButtons(tracks: tracks, source: mixtape.title)
                    .frame(maxWidth: Theme.Size.formMaxWidth)
            }
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            SongRows(tracks: tracks, keepsOrder: true, source: mixtape.title)
        }
        .listStyle(.plain)
        .navigationTitle(mixtape.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if tracks.isEmpty {
                if mixtape.tracks.isEmpty { await remake() } else { tracks = mixtape.tracks }
            }
        }
    }

    /// The same recipe, different songs.
    private func remake() async {
        guard let client = app.client else { return }
        let fresh = await MixEngine.build(mixtape.recipe, client: client, audioMuse: app.audioMuse) { app.library.isHidden($0) }
        if !fresh.isEmpty { withAnimation { tracks = fresh } } else { triedEmpty = true }
    }
}

// MARK: - The dial

/// Make your own mix: touch the pad for the feel (calm to energetic, dark to bright), choose how familiar,
/// pick decades and genres if you like, and play.
struct MixDialView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var recipe = MixDialView.savedRecipe()
    @State private var genres: [String] = []
    @State private var playing = false

    private static let decades = [1960, 1970, 1980, 1990, 2000, 2010, 2020]

    var body: some View {
        ScrollView {
            Group {
                if sizeClass == .regular {
                    HStack(alignment: .top, spacing: Theme.Spacing.section) {
                        FeelPad(energy: $recipe.energy, mood: $recipe.mood)
                            .frame(maxWidth: Theme.Size.albumHeaderArtwork * 1.6)
                        options
                    }
                } else {
                    VStack(spacing: Theme.Spacing.xl) {
                        FeelPad(energy: $recipe.energy, mood: $recipe.mood)
                        options
                    }
                }
            }
            .padding(Theme.Spacing.l)
        }
        .navigationTitle("Make Your Own")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadGenres() }
        .onChange(of: recipe) { _, value in Self.save(value) }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text("How familiar").font(.headline).foregroundStyle(.secondary)
                Slider(value: $recipe.newness, in: 0...1)
                    .tint(Color.dial)
                HStack {
                    Text("Songs you love")
                    Spacer()
                    Text("New to you")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            chips("Decades", options: Self.decades.map { DecadeView.name($0) }, selected: recipe.decades.map { DecadeView.name($0) }) { name in
                guard let decade = Self.decades.first(where: { DecadeView.name($0) == name }) else { return }
                if recipe.decades.contains(decade) { recipe.decades.removeAll { $0 == decade } } else { recipe.decades.append(decade) }
            }

            if !genres.isEmpty {
                chips("Genres", options: genres, selected: recipe.genres) { genre in
                    if recipe.genres.contains(genre) { recipe.genres.removeAll { $0 == genre } } else { recipe.genres.append(genre) }
                }
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Text(recipe.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.easeOut, value: recipe.summary)
                PrimaryButton(title: playing ? "Finding Songs\u{2026}" : "Play", systemImage: "play.fill", busy: playing) { play() }
                    .frame(maxWidth: Theme.Size.formMaxWidth)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chips(_ title: String, options: [String], selected: [String], toggle: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(title).font(.headline).foregroundStyle(.secondary)
            FlowLayout(spacing: Theme.Spacing.s) {
                ForEach(options, id: \.self) { option in
                    let on = selected.contains(option)
                    Button { toggle(option) } label: {
                        Text(option)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, Theme.Spacing.m)
                            .padding(.vertical, Theme.Spacing.xs + 2)
                            .background(on ? Color.dial : Color(uiColor: .tertiarySystemFill), in: Capsule())
                            .foregroundStyle(on ? Color.black : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }

    private func play() {
        guard let client = app.client else { return }
        let recipe = recipe
        let audioMuse = app.audioMuse
        let library = app.library
        app.player.play(PendingPlayback(title: "Your Dial Mix", subtitle: recipe.summary, artwork: .symbol("dial.medium.fill")),
                        loading: {
                            await MixEngine.build(recipe, client: client, audioMuse: audioMuse) { library.isHidden($0) }
                        })
    }

    /// The genres you play most, then the rest of your library's.
    private func loadGenres() async {
        guard let client = app.client, genres.isEmpty else { return }
        let recent = (try? await client.recentlyPlayedSongs(limit: 200)) ?? []
        var counts: [String: Int] = [:]
        for song in recent { for genre in song.genres ?? [] { counts[genre, default: 0] += 1 } }
        var list = counts.sorted { $0.value > $1.value }.map(\.key)
        if list.count < 12 {
            let all = ((try? await client.genres()) ?? []).map(\.name)
            list += all.filter { !list.contains($0) }
        }
        genres = Array(list.prefix(14))
    }

    private static func savedRecipe() -> MixRecipe {
        guard let data = UserDefaults.standard.data(forKey: "dial.mixRecipe"),
              let recipe = try? JSONDecoder().decode(MixRecipe.self, from: data) else { return MixRecipe() }
        return recipe
    }

    private static func save(_ recipe: MixRecipe) {
        if let data = try? JSONEncoder().encode(recipe) { UserDefaults.standard.set(data, forKey: "dial.mixRecipe") }
    }
}

/// The feel, as a pad: left calm, right energetic, top bright, bottom dark. Drag the dot.
struct FeelPad: View {
    @Binding var energy: Double
    @Binding var mood: Double

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                LinearGradient(colors: [Color(red: 0.2, green: 0.45, blue: 0.75), Color(red: 0.95, green: 0.45, blue: 0.25)],
                               startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.white.opacity(0.35), .clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                labels
                Circle()
                    .fill(.white)
                    .frame(width: Theme.Size.tapTarget * 0.7, height: Theme.Size.tapTarget * 0.7)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                    .overlay { Circle().strokeBorder(Color.dial, lineWidth: 3) }
                    .position(x: energy * size.width, y: (1 - mood) * size.height)
                    .animation(.spring(duration: 0.25), value: energy)
                    .animation(.spring(duration: 0.25), value: mood)
            }
            .clipShape(.rounded(Theme.Radius.hero))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                energy = min(max(value.location.x / size.width, 0.03), 0.97)
                mood = 1 - min(max(value.location.y / size.height, 0.03), 0.97)
            })
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Feel")
        .accessibilityValue("\(energy < 0.34 ? "calm" : energy < 0.67 ? "steady" : "energetic"), \(mood < 0.34 ? "dark" : mood < 0.67 ? "warm" : "bright")")
        .accessibilityAdjustableAction { direction in
            energy = min(max(energy + (direction == .increment ? 0.1 : -0.1), 0.03), 0.97)
        }
    }

    private var labels: some View {
        ZStack {
            Text("Bright").frame(maxHeight: .infinity, alignment: .top)
            Text("Dark").frame(maxHeight: .infinity, alignment: .bottom)
            Text("Calm").frame(maxWidth: .infinity, alignment: .leading)
            Text("Energetic").frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white.opacity(0.85))
        .padding(Theme.Spacing.m)
        .accessibilityHidden(true)
    }
}

/// Chips that wrap onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Radio tab pieces

/// The way into the dial, on the Radio tab: a small pad you can already see.
struct DialCard: View {
    var body: some View {
        NavigationLink(value: Route.mixDial) {
            HStack(spacing: Theme.Spacing.l) {
                ZStack {
                    LinearGradient(colors: [Color(red: 0.2, green: 0.45, blue: 0.75), Color(red: 0.95, green: 0.45, blue: 0.25)],
                                   startPoint: .leading, endPoint: .trailing)
                    LinearGradient(colors: [.white.opacity(0.3), .clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                    Circle().fill(.white).frame(width: Theme.Spacing.l, height: Theme.Spacing.l)
                        .overlay { Circle().strokeBorder(Color.dial, lineWidth: 2) }
                        .offset(x: Theme.Spacing.m, y: -Theme.Spacing.s)
                }
                .frame(width: Theme.Size.compactArtwork, height: Theme.Size.compactArtwork)
                .clipShape(.rounded(Theme.Radius.tile))
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text("Make Your Own").font(.headline)
                    Text("Pick the feel, the era and how familiar, and Dial finds the songs.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(Theme.Spacing.m)
            .background(Color(uiColor: .secondarySystemBackground), in: .rounded(Theme.Radius.hero))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.Spacing.l)
    }
}

/// A decade or genre from your library, as a colored tile.
struct LibraryCategoryTile: View {
    let title: String
    let subtitle: String
    let colors: [Color]
    let route: Route

    var body: some View {
        NavigationLink(value: route) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(title).font(.title2.weight(.heavy)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
                    Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.8))
                }
                .padding(Theme.Spacing.m)
            }
            .frame(height: Theme.Size.categoryCard)
            .clipShape(.rounded(Theme.Radius.tile))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Genre groups

/// One genre as you'd say it, gathering the spellings your files use ("Hip-Hop", "hip hop", "Rap/Hip Hop").
struct GenreGroupView: View {
    let name: String
    let genreIds: [String]
    @Environment(AppModel.self) private var app
    @State private var albums: [BaseItem] = []
    @State private var state: LoadState = .loading

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                HStack(spacing: Theme.Spacing.m) {
                    PillButton(title: "Play", systemImage: "play.fill") { play(shuffle: false) }
                    PillButton(title: "Shuffle", systemImage: "shuffle") { play(shuffle: true) }
                }
                .frame(maxWidth: Theme.Size.formMaxWidth)
                .padding(.horizontal, Theme.Spacing.l)
                .disabled(albums.isEmpty)
                AlbumGrid(albums: albums)
            }
            .padding(.vertical, Theme.Spacing.m)
        }
        .loadState(state, isEmpty: albums.isEmpty,
                   empty: EmptyState(title: "No albums", symbol: "guitars", message: "Nothing in your library is tagged \(name)."),
                   skeleton: .grid, retry: load)
        .navigationTitle(name)
        .task { await load() }
    }

    private func load() async {
        guard let client = app.client else { return }
        let ids = genreIds
        await runLoad($state) {
            var all: [BaseItem] = []
            for id in ids { all += (try? await client.albums(inGenre: id)) ?? [] }
            var seen = Set<String>()
            albums = all.filter { seen.insert($0.id).inserted }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private func play(shuffle: Bool) {
        guard let client = app.client else { return }
        let ids = genreIds
        app.player.play(PendingPlayback(title: name, subtitle: "From your library", artwork: .symbol("guitars")),
                        loading: { try await client.songs(genreIds: ids, years: [], limit: 200) }, shuffle: shuffle)
    }
}

/// Folds the many spellings of a genre into one family by meaning, not exact spelling:
/// "Reggaeton", "Trap Latino" and "Urbano Latino" are all Latin; "Hip-Hop/Rap" is Hip-Hop.
enum GenreNames {
    private struct Rule {
        let family: String
        /// Found anywhere in the tag with spaces and punctuation removed ("trapLatino" → "traplatino").
        var contains: [String] = []
        /// Matches a whole word of the tag.
        var words: [String] = []
        /// Matches the whole tag only.
        var whole: [String] = []
    }

    /// In priority order: the first family that fits a tag wins ("Latin Pop" is Latin, "Pop Rap" is Hip-Hop).
    private static let rules: [Rule] = [
        Rule(family: "Latin", contains: ["latin", "reggaeton", "urbano", "bachata", "salsa", "cumbia", "dembow", "corrido", "regionalmexican",
                                         "banda", "norteno", "merengue", "flamenco", "mariachi", "vallenato", "perreo", "tropical", "mexican",
                                         "reguet", "sertanejo", "bossanova"], words: ["mpb", "tejano"]),
        Rule(family: "K-Pop", contains: ["kpop", "korean", "jpop", "japanese"]),
        Rule(family: "Afrobeats", contains: ["afrobeat", "afropop", "amapiano", "highlife", "afroswing", "naija"]),
        Rule(family: "Reggae", contains: ["reggae", "dancehall"], words: ["ska", "dub"]),
        Rule(family: "Hip-Hop", contains: ["hiphop", "drill", "grime", "boombap", "gangsta", "mumble"], words: ["rap", "trap", "hh"]),
        Rule(family: "R&B", contains: ["rhythmandblues", "contemporaryrb", "alternativerb"], whole: ["rb", "rnb", "randb"]),
        Rule(family: "Soul", contains: ["soul", "motown"]),
        Rule(family: "Funk", contains: ["funk"]),
        Rule(family: "Disco", contains: ["disco"]),
        Rule(family: "Metal", contains: ["metal"]),
        Rule(family: "Punk", contains: ["punk", "hardcore"], words: ["emo"]),
        Rule(family: "Indie", contains: ["indie", "shoegaze", "dreampop"]),
        Rule(family: "Alternative", contains: ["alternative", "grunge", "newwave", "postrock"], words: ["alt"]),
        Rule(family: "Rock", contains: ["rock", "psychedelic"]),
        Rule(family: "Electronic", contains: ["electro", "techno", "trance", "dubstep", "synth", "drumandbass", "ambient", "downtempo",
                                              "idm", "triphop", "chillout", "lofi"], words: ["edm", "dnb"]),
        Rule(family: "Dance", contains: ["dance", "house", "club", "garage", "eurodance"]),
        Rule(family: "Pop", contains: ["pop"]),
        Rule(family: "Jazz", contains: ["jazz", "swing", "bebop", "bigband"]),
        Rule(family: "Blues", contains: ["blues"]),
        Rule(family: "Country", contains: ["country", "bluegrass", "americana"]),
        Rule(family: "Folk", contains: ["folk", "singersongwriter", "acoustic"]),
        Rule(family: "Classical", contains: ["classical", "orchestra", "opera", "baroque", "symphon", "chambermusic"]),
        Rule(family: "Soundtrack", contains: ["soundtrack", "score", "musical"], words: ["ost", "film"]),
        Rule(family: "Gospel", contains: ["gospel", "christian", "worship"]),
    ]

    /// The genres a tag stands for ("Pop, Rock" is two; "Trap Latino" is one: Latin).
    static func canonical(_ tag: String) -> [String] {
        let parts = tag.components(separatedBy: CharacterSet(charactersIn: ",;/|")).map { $0.trimmingCharacters(in: .whitespaces) }
        var seen = Set<String>()
        var names: [String] = []
        for part in parts where !part.isEmpty {
            // "Hip-Hop/Rap" and "R&B/Soul" are written with a slash, but "R&B" itself has none.
            let name = family(of: part) ?? titleCase(part)
            if seen.insert(name).inserted { names.append(name) }
        }
        return names
    }

    /// Every family for a list of tags, in order, without repeats.
    static func families(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.flatMap(canonical).filter { seen.insert($0).inserted }
    }

    private static func family(of part: String) -> String? {
        let lower = part.lowercased()
        let squashed = lower.replacingOccurrences(of: "&", with: "and").filter { $0.isLetter || $0.isNumber }
        let words = Set(lower.replacingOccurrences(of: "&", with: " and ").split { !($0.isLetter || $0.isNumber) }.map(String.init))
        let whole = lower.contains("&") ? lower.filter { $0.isLetter } : squashed
        for rule in rules {
            if rule.whole.contains(whole) || rule.whole.contains(squashed) { return rule.family }
            if rule.contains.contains(where: { squashed.contains($0) }) { return rule.family }
            if rule.words.contains(where: { words.contains($0) }) { return rule.family }
        }
        return nil
    }

    private static func titleCase(_ text: String) -> String {
        text.split(separator: " ").map { word in word.prefix(1).uppercased() + word.dropFirst().lowercased() }.joined(separator: " ")
    }
}

/// All the mixtapes of one kind (Moods, Decades, Genres, Eras and Sounds), in a grid.
struct MixtapeListView: View {
    let title: String
    let mixtapes: [Mixtape]

    private let columns = [GridItem(.adaptive(minimum: Theme.Size.gridTileMin), spacing: Theme.Spacing.m, alignment: .top)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Spacing.l) {
                ForEach(mixtapes) { MixtapeTile(mixtape: $0) }
            }
            .padding(Theme.Spacing.l)
        }
        .navigationTitle(title)
    }
}
