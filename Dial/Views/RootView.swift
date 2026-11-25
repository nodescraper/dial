import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    /// Lets the full-screen player zoom out of the mini player, like Apple Music.
    @Namespace private var playerTransition
    @Environment(\.scenePhase) private var scenePhase

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        @Bindable var nav = app.navigator
        Group {
            if sizeClass == .regular {
                DesktopRoot()
                    .modifier(PlayerPresentation(isPresented: $nav.showNowPlaying, transition: playerTransition, app: app))
            } else {
                tabs
            }
        }
        // YouTube streams (Lofi Girl) play in a web page that has to be in the window: small and nearly clear.
        .background(alignment: .topLeading) {
            YouTubeHost(embed: app.player.youtube)
                .frame(width: 240, height: 240)
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onAppear { nav.isDesktop = sizeClass == .regular }
        .onChange(of: sizeClass) { _, size in nav.isDesktop = size == .regular }
        .alert(
            nav.deletionRequest.map { "Delete \u{201C}\($0.name)\u{201D} from your server?" } ?? "",
            isPresented: Binding(get: { nav.deletionRequest != nil }, set: { if !$0 { nav.deletionRequest = nil } }),
            presenting: nav.deletionRequest
        ) { item in
            // The item comes with the alert: the request is cleared when it closes, which can happen before this runs.
            Button("Delete", role: .destructive) {
                Task {
                    if await app.library.deleteFromServer(item), item.type == "MusicAlbum" { nav.goBack() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(item.type == "MusicAlbum"
                 ? "This deletes the album and all its songs from your Jellyfin server, files included. It can\u{2019}t be undone."
                 : "This deletes the song from your Jellyfin server, file included. It can\u{2019}t be undone.")
        }
        .sheet(item: $nav.playlistRequest) { request in
            AddToPlaylistSheet(tracks: request.tracks).environment(app)
        }
        .sheet(item: $nav.songInfo) { track in
            SongInfoSheet(track: track).environment(app)
        }
        .sheet(isPresented: $nav.showDevices) {
            DevicesSheet().environment(app)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { app.errorText != nil }, set: { if !$0 { app.clearErrors() } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.errorText ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            app.remote.setInBackground(phase != .active)
            if phase == .active {
                Task {
                    await app.connectivity.check()
                    await app.library.refresh() // favorites changed on other devices while away
                }
                prefetchDiscovery(after: 5)
            }
        }
        // Soon after the app opens, Discovery is brought up to date in the background, so it is ready when you get there.
        // The saved Discovery page is read into memory at once, so the tab opens with it; the refresh comes later.
        .task { _ = await Snapshots.load(DiscoveryFeed.self, DiscoveryEngine.snapshotKey) }
        .task { prefetchDiscovery(after: 20) }
        .onAppear(perform: setMinimumWindowSize)
    }

    private var homeTab: some View {
        @Bindable var nav = app.navigator
        return NavigationStack(path: $nav.homePath) { ZoomScope { HomeView().routeDestinations() } }
            .floatingMiniPlayer(transition: playerTransition)
    }

    private var radioTab: some View {
        @Bindable var nav = app.navigator
        return NavigationStack(path: $nav.radioPath) { ZoomScope { RadioView().routeDestinations() } }
            .floatingMiniPlayer(transition: playerTransition)
    }

    private var libraryTab: some View {
        @Bindable var nav = app.navigator
        return NavigationStack(path: $nav.libraryPath) { ZoomScope { LibraryView().routeDestinations() } }
            .floatingMiniPlayer(transition: playerTransition)
    }

    private var discoveryTab: some View {
        @Bindable var nav = app.navigator
        return NavigationStack(path: $nav.searchPath) { ZoomScope { LibrarySearchContainer(outside: true) { DiscoveryView() }.routeDestinations() } }
            .floatingMiniPlayer(transition: playerTransition)
    }

    /// iPhone: the tabs with a mini player above them.
    @ViewBuilder
    private var tabs: some View {
        @Bindable var nav = app.navigator
        Group {
            if #available(iOS 18.0, *) {
                TabView(selection: $nav.tab) {
                    Tab("Home", systemImage: "house.fill", value: AppTab.home) { homeTab }
                    // Offline only what is on this device works: Home and Library.
                    if !app.connectivity.isOffline {
                        Tab("Tune In", systemImage: "dot.radiowaves.left.and.right", value: AppTab.radio) { radioTab }
                        if app.hasPlugin {
                            Tab("Discovery", systemImage: "safari", value: AppTab.search) { discoveryTab }
                        }
                    }
                    Tab("Library", systemImage: "text.magnifyingglass", value: AppTab.library) { libraryTab }
                }
            } else {
                TabView(selection: $nav.tab) {
                    homeTab.tabItem { Label("Home", systemImage: "house.fill") }.tag(AppTab.home)
                    if !app.connectivity.isOffline {
                        radioTab.tabItem { Label("Tune In", systemImage: "dot.radiowaves.left.and.right") }.tag(AppTab.radio)
                        if app.hasPlugin {
                            discoveryTab.tabItem { Label("Discovery", systemImage: "safari") }.tag(AppTab.search)
                        }
                    }
                    libraryTab.tabItem { Label("Library", systemImage: "text.magnifyingglass") }.tag(AppTab.library)
                }
            }
        }
        .modifier(NativeMiniPlayer(isVisible: app.player.hasContent && !Platform.isMac, transition: playerTransition))
        .modifier(PlayerPresentation(isPresented: $nav.showNowPlaying, transition: playerTransition, app: app))
        // Going offline while on a tab that needs the server: back to Home.
        .onChange(of: app.connectivity.isOffline) { _, offline in
            if offline, nav.tab == .radio || nav.tab == .search { nav.tab = .home }
        }
    }

    /// On the Mac, the window can't shrink below a usable size.
    /// Brings Discovery up to date quietly (cheap when nothing is out of date), a little after the app opens or returns.
    private func prefetchDiscovery(after seconds: Int) {
        Task(priority: .utility) {
            try? await Task.sleep(for: .seconds(seconds))
            guard let client = app.client, !app.connectivity.isOffline else { return }
            await DiscoveryEngine.prefetch(client: client)
        }
    }

    private func setMinimumWindowSize() {
        #if targetEnvironment(macCatalyst)
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.sizeRestrictions?.minimumSize = CGSize(width: 900, height: 640)
        }
        #endif
    }
}

/// The tabs become a sidebar on iPad and Mac (and stay a tab bar on iPhone).
private struct SidebarOnLargeScreens: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.tabViewStyle(.sidebarAdaptable)
        } else {
            content
        }
    }
}

// MARK: - Opening the full-screen player

enum PlayerTransition {
    static let id = "player"
}

/// iOS 18 and later: a full-screen player that zooms out of the mini player and can be
/// swiped down to close. iOS 17: a regular sheet.
private struct PlayerPresentation: ViewModifier {
    @Binding var isPresented: Bool
    let transition: Namespace.ID
    let app: AppModel

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            // The full-screen player zooms out of the mini player (on every iOS 18 and later, also with the tab bar's accessory).
            content.fullScreenCover(isPresented: $isPresented) {
                NowPlayingView()
                    .environment(app)
                    .navigationTransition(.zoom(sourceID: PlayerTransition.id, in: transition))
            }
        } else {
            content.sheet(isPresented: $isPresented) {
                NowPlayingView()
                    .environment(app)
                    .presentationDragIndicator(.hidden)
            }
        }
    }
}

/// Marks the mini player as the place the full-screen player zooms out of.
private struct PlayerTransitionSource: ViewModifier {
    let transition: Namespace.ID
    /// The tab bar's accessory draws the mini player in two sizes: only one of them may be the source, or the zoom
    /// has two sources and bounces back without opening.
    var enabled = true

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), enabled {
            content.matchedTransitionSource(id: PlayerTransition.id, in: transition)
        } else {
            content
        }
    }
}

// MARK: - Mini player

/// On iOS 26.1 and later the mini player lives in the tab bar's native bottom accessory,
/// with Liquid Glass and the tab bar shrinking as you scroll, like Apple Music.
private struct NativeMiniPlayer: ViewModifier {
    let isVisible: Bool
    let transition: Namespace.ID

    #if compiler(>=6.2)
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content
                .tabViewBottomAccessory(isEnabled: isVisible) { MiniPlayerAccessory(transition: transition) }
                .tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
    }
    #else
    func body(content: Content) -> some View { content }
    #endif
}

extension View {
    /// On older iOS versions the mini player floats above the tab bar instead.
    @ViewBuilder
    func floatingMiniPlayer(transition: Namespace.ID) -> some View {
        if Platform.hasTabAccessory {
            self
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) { FloatingMiniPlayer(transition: transition) }
        }
    }
}

#if compiler(>=6.2)
@available(iOS 26.0, *)
private struct MiniPlayerAccessory: View {
    let transition: Namespace.ID
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        // The cover sits as far from the capsule's left edge as from its top and bottom (the capsule already insets it a little).
        MiniPlayerContent(compact: placement == .inline)
            .padding(.leading, 6)
            .padding(.trailing, Theme.Spacing.s)
            .modifier(PlayerTransitionSource(transition: transition, enabled: placement != .inline))
    }
}
#endif

private struct FloatingMiniPlayer: View {
    let transition: Namespace.ID
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.player.hasContent {
            MiniPlayerContent(compact: false)
                .padding(.horizontal, Theme.Spacing.s)
                .padding(.vertical, Theme.Spacing.s)
                .modifier(FloatingBackground())
                .overlay(alignment: .bottom) { MiniProgress() }
                .modifier(PlayerTransitionSource(transition: transition))
                .padding(.horizontal, Theme.Spacing.s)
                .padding(.bottom, Theme.Spacing.s)
        }
    }
}

/// Liquid Glass on iOS 26, a material background before that.
private struct FloatingBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: Theme.Radius.control, style: .continuous))
        } else {
            materialBackground(content)
        }
        #else
        materialBackground(content)
        #endif
    }

    private func materialBackground(_ content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
    }
}

private struct MiniProgress: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if !app.player.isLive {
            GeometryReader { geo in
                Capsule()
                    .fill(Color.dial)
                    .frame(width: geo.size.width * app.player.progress, height: Theme.Spacing.xxs)
            }
            .frame(height: Theme.Spacing.xxs)
            .padding(.horizontal, Theme.Spacing.l)
            .accessibilityHidden(true)
        }
    }
}

/// What the mini player shows. `compact` is the narrow version beside a shrunken tab bar.
/// Fades something slowly in and out while `active`, back to normal when not.
private struct LoadingPulse: ViewModifier {
    /// Starting a song: pulses at once.
    let active: Bool
    /// Buffering while a song plays: only after it has lasted a moment, so the short stalls of a stream never make the cover flicker.
    var slowActive = false
    @State private var dim = false
    @State private var slowShown = false
    @State private var wait: Task<Void, Never>?
    @State private var loop: Task<Void, Never>?

    private var pulsing: Bool { active || slowShown }

    // The fade is driven by explicit steps (not a repeating animation attached to the view), so it can never leak onto the
    // cover's size or position when the player moves between its big and small forms.
    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.35 : 1)
            .scaleEffect(dim ? 0.92 : 1)
            .onChange(of: pulsing, initial: true) { _, now in
                loop?.cancel()
                guard now else {
                    withAnimation(.easeOut(duration: 0.25)) { dim = false }
                    return
                }
                loop = Task {
                    while !Task.isCancelled {
                        withAnimation(.easeInOut(duration: 1.0)) { dim.toggle() }
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
            }
            .onChange(of: slowActive, initial: true) { _, now in
                wait?.cancel()
                if now {
                    wait = Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        if !Task.isCancelled { slowShown = true }
                    }
                } else {
                    slowShown = false
                }
            }
            .onDisappear { loop?.cancel(); wait?.cancel() }
    }
}

struct MiniPlayerContent: View {
    let compact: Bool
    @Environment(AppModel.self) private var app
    /// How far the mini player has been pulled sideways to close it.
    @State private var pulled: CGFloat = 0

    var body: some View {
        let player = app.player
        HStack(spacing: Theme.Spacing.m) {
            NowPlayingArtwork(pixels: Theme.Pixels.thumb)
                .artworkFrame(size: Theme.Size.miniArtwork, .circle)
                // A slow breathing while the song is loading, so it never looks frozen.
                .modifier(LoadingPulse(active: !compact && (player.isStarting || player.isLoadingAudio), slowActive: !compact && player.isBuffering && !player.isLive))

            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(app.dj.isOnAir ? app.dj.name : player.nowTitle)
                    .font(.subheadline.weight(.semibold))
                    .marquee(id: player.nowTitle)
                if !compact {
                    HStack(spacing: Theme.Spacing.xs) {
                        if let device = player.outputName {
                            Image(systemName: "hifispeaker.fill")
                                .foregroundStyle(Color.dial)
                                .accessibilityHidden(true)
                        } else if player.isLive {
                            LiveBadge()
                        } else if app.dj.isActive {
                            DJBadge()
                        } else if let source = player.source {
                            SourceBadge(text: source)
                        } else if player.radioOn {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .foregroundStyle(Color.dial)
                                .accessibilityLabel("Radio on")
                        }
                        Text(player.outputName.map { "Playing on \($0)" } ?? (app.dj.isOnAir ? "On air" : player.nowSubtitle))
                            .foregroundStyle(player.isRemote ? Color.dial : Color.secondary)
                            .lineLimit(1)
                    }
                    .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { app.navigator.openPlayer() }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens the player")

            if !compact {
                IconButton(symbol: player.isRemote ? "hifispeaker.fill" : "laptopcomputer.and.iphone", label: "Devices") {
                    app.navigator.showDevices = true
                }
            }
            IconButton(symbol: player.isPlaying ? "pause.fill" : "play.fill",
                       label: player.isStarting ? "Loading" : (player.isPlaying ? "Pause" : "Play")) {
                player.togglePlayPause()
            }
            .disabled(player.isStarting)
            .opacity(player.isStarting ? 0.4 : 1)
            if !compact {
                IconButton(symbol: "forward.fill", label: player.isLive ? "Next station" : "Next song") {
                    player.next()
                }
            }
        }
        // Swipe the mini player sideways to close it (stops the music and clears the queue).
        .offset(x: pulled)
        .opacity(1 - min(abs(pulled) / 300, 0.6))
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onChanged { value in
                    if abs(value.translation.width) > abs(value.translation.height) { pulled = value.translation.width }
                }
                .onEnded { value in
                    let wide = abs(value.translation.width) > 110 || abs(value.predictedEndTranslation.width) > 260
                    if wide, abs(value.translation.width) > abs(value.translation.height) * 1.5 {
                        withAnimation(.easeIn(duration: 0.15)) { pulled = value.translation.width > 0 ? 500 : -500 }
                        Task {
                            try? await Task.sleep(for: .milliseconds(150))
                            player.close()
                            pulled = 0
                        }
                    } else {
                        withAnimation(.spring(duration: 0.25)) { pulled = 0 }
                    }
                }
        )
        .accessibilityAction(named: "Close player") { player.close() }
    }
}

// MARK: - Sign in

/// The first screen, in two steps: where your server is, then how you sign in (a Quick Connect code from a
/// device that's already signed in, or your username and password).
struct LoginView: View {
    private enum Step { case server, account }
    private enum Field { case server, username, password }

    @Environment(AppModel.self) private var app
    @State private var step = Step.server
    @State private var server = ""
    @State private var serverName: String? = nil
    @State private var quickConnectAvailable = false
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String? = nil
    /// The code shown while waiting for you to approve it in Jellyfin.
    @State private var quickCode: String? = nil
    @State private var quickTask: Task<Void, Never>? = nil
    @FocusState private var focus: Field?

    private var canContinue: Bool { !busy && !server.trimmingCharacters(in: .whitespaces).isEmpty }
    private var canSignIn: Bool { !busy && !username.isEmpty }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.section) {
                header
                if step == .server { serverStep } else { accountStep }
            }
            .padding(.horizontal, Theme.Player.margin)
            .padding(.vertical, Theme.Spacing.xl)
            .frame(maxWidth: Theme.Size.formMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background {
            LinearGradient(colors: ArtworkPalette.onAir, startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.25), value: step)
        .animation(.easeInOut(duration: 0.25), value: quickCode)
        .onAppear {
            if server.isEmpty { server = app.session.lastServer ?? "" }
        }
        .onDisappear { quickTask?.cancel() }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image("DialLogo")
                .resizable()
                .scaledToFit()
                .frame(width: step == .server ? 112 : 72, height: step == .server ? 112 : 72)
                .clipShape(RoundedRectangle(cornerRadius: step == .server ? 26 : 17, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
                .accessibilityHidden(true)
            Text("Dial")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            if step == .server {
                Text("Your music, from your own server.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                VStack(spacing: Theme.Spacing.xxs) {
                    Text(serverName ?? "Jellyfin")
                        .font(.headline)
                    Text(displayAddress)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Change server") { changeServer() }
                        .font(.footnote.weight(.semibold))
                        .padding(.top, Theme.Spacing.xxs)
                }
            }
        }
        .padding(.top, Theme.Spacing.l)
    }

    private var displayAddress: String {
        (try? JellyfinClient.normalizedServer(server))?.absoluteString ?? server
    }

    // MARK: Step 1: the server

    private var serverStep: some View {
        VStack(spacing: Theme.Spacing.l) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text("Server address")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Server address", text: $server, prompt: Text("192.168.1.10:8096"))
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .server)
                    .submitLabel(.go)
                    .onSubmit { if canContinue { Task { await connect() } } }
                    .inputField()
            }
            errorLabel
            PrimaryButton(title: "Continue", busy: busy) { Task { await connect() } }
                .disabled(!canContinue)
                .opacity(canContinue ? 1 : 0.5)
            Text("Use the address you open Jellyfin with. Your device has to reach the server, for example on your home Wi-Fi.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: Step 2: signing in

    private var accountStep: some View {
        VStack(spacing: Theme.Spacing.l) {
            if quickConnectAvailable { quickConnectCard }

            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                if quickConnectAvailable {
                    Text("Or use your account")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                    .inputField()
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { if canSignIn { Task { await signIn() } } }
                    .inputField()
            }
            errorLabel
            PrimaryButton(title: "Sign In", busy: busy && quickCode == nil) { Task { await signIn() } }
                .disabled(!canSignIn)
                .opacity(canSignIn ? 1 : 0.5)
        }
    }

    /// Quick Connect: Dial shows a code; you approve it in Jellyfin on a device that's already signed in.
    @ViewBuilder
    private var quickConnectCard: some View {
        VStack(spacing: Theme.Spacing.m) {
            if let code = quickCode {
                Text("Your code")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(code)
                    .font(.system(size: 44, weight: .bold, design: .monospaced))
                    .tracking(8)
                    .textSelection(.enabled)
                Text("On a device where you're signed in to Jellyfin, open your profile, choose Quick Connect and enter this code.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: Theme.Spacing.s) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for approval\u{2026}")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Cancel") { cancelQuickConnect() }
                    .font(.subheadline.weight(.semibold))
            } else {
                Button {
                    startQuickConnect()
                } label: {
                    Label("Sign in with Quick Connect", systemImage: "qrcode.viewfinder")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: Theme.Size.tapTarget)
                }
                .buttonStyle(.plain)
                Text("No password to type: approve a code from Jellyfin on another device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity)
        .background(Color.dial.opacity(0.16), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Color.dial.opacity(0.45), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var errorLabel: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Actions

    /// Checks the address is a Jellyfin server and whether it offers Quick Connect.
    private func connect() async {
        focus = nil
        busy = true
        error = nil
        defer { busy = false }
        do {
            let url = try JellyfinClient.normalizedServer(server)
            let info = try await JellyfinClient.serverInfo(url)
            serverName = info.serverName
            quickConnectAvailable = await JellyfinClient.quickConnectEnabled(url)
            server = url.absoluteString
            step = .account
        } catch {
            self.error = "Couldn't reach a Jellyfin server at that address. Check it, and that you're on the same network."
        }
    }

    private func changeServer() {
        cancelQuickConnect()
        error = nil
        step = .server
    }

    private func signIn() async {
        focus = nil
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await app.signIn(server: server, username: username, password: password)
        } catch JellyfinError.http(401) {
            self.error = "That username or password isn't right."
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func startQuickConnect() {
        quickTask?.cancel()
        error = nil
        let address = server
        quickTask = Task { @MainActor in
            do {
                let url = try JellyfinClient.normalizedServer(address)
                let request = try await JellyfinClient.startQuickConnect(url)
                quickCode = request.code
                let deadline = Date().addingTimeInterval(5 * 60)
                while !Task.isCancelled, Date() < deadline {
                    try await Task.sleep(for: .seconds(2))
                    if try await JellyfinClient.quickConnectState(url, secret: request.secret).authenticated {
                        busy = true
                        try await app.signIn(server: address, quickConnectSecret: request.secret)
                        return
                    }
                }
                if !Task.isCancelled {
                    quickCode = nil
                    error = "That code expired. Try again."
                }
            } catch is CancellationError {
                // Cancelled by the user or by leaving the screen.
            } catch {
                busy = false
                quickCode = nil
                self.error = "Quick Connect didn't work. Make sure it's turned on in Jellyfin's settings."
            }
        }
    }

    private func cancelQuickConnect() {
        quickTask?.cancel()
        quickTask = nil
        quickCode = nil
        busy = false
    }
}
