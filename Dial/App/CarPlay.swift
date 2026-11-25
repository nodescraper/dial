#if canImport(CarPlay) && !targetEnvironment(macCatalyst)
import CarPlay
import UIKit

/// Dial in the car. An audio app for CarPlay: three tabs (Home, Tune In, Library) of short lists, and the system's
/// Now Playing screen. Nothing here is drawn by Dial: CarPlay sets the sizes, so it looks like every other music app.
/// Shows up in the car once Apple has approved the `com.apple.developer.carplay-audio` entitlement (see docs/CARPLAY.md).
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CarPlayController?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        MainActor.assumeIsolated {
            let controller = CarPlayController(interface: interfaceController, app: AppModel.shared)
            self.controller = controller
            controller.start()
        }
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        MainActor.assumeIsolated {
            controller?.stop()
            controller = nil
        }
    }
}

@MainActor
final class CarPlayController {
    private let interface: CPInterfaceController
    private let app: AppModel
    private var images: [String: UIImage] = [:]

    init(interface: CPInterfaceController, app: AppModel) {
        self.interface = interface
        self.app = app
    }

    /// Longest list CarPlay allows (it caps lists to keep drivers' eyes on the road).
    private var limit: Int { max(8, min(CPListTemplate.maximumItemCount, 40)) }

    // MARK: Start

    func start() {
        let home = CPListTemplate(title: "Home", sections: [])
        home.tabTitle = "Home"
        home.tabImage = UIImage(systemName: "house.fill") ?? UIImage()
        let tuneIn = CPListTemplate(title: "Tune In", sections: [])
        tuneIn.tabTitle = "Tune In"
        tuneIn.tabImage = UIImage(systemName: "dot.radiowaves.left.and.right") ?? UIImage()
        let library = CPListTemplate(title: "Library", sections: [])
        library.tabTitle = "Library"
        library.tabImage = UIImage(systemName: "music.note.list") ?? UIImage()

        interface.setRootTemplate(CPTabBarTemplate(templates: [home, tuneIn, library]), animated: false, completion: nil)
        configureNowPlaying()
        Task { await fill(home: home, tuneIn: tuneIn, library: library) }
    }

    func stop() {
        images.removeAll()
    }

    private func fill(home: CPListTemplate, tuneIn: CPListTemplate, library: CPListTemplate) async {
        guard app.client != nil else {
            let message = row("Open Dial on your iPhone", detail: "Sign in to your Jellyfin server, then come back.", symbol: "iphone")
            for template in [home, tuneIn, library] { template.updateSections([CPListSection(items: [message])]) }
            return
        }
        library.updateSections([CPListSection(items: libraryRows())])
        tuneIn.updateSections([CPListSection(items: stationRows())])
        await loadHome(home)
    }

    // MARK: Home

    private func loadHome(_ template: CPListTemplate) async {
        guard let client = app.client else { return }
        var sections: [CPListSection] = []
        let mixes = DailyMixes.saved().filter { !$0.tracks.isEmpty }.prefix(6)
        if !mixes.isEmpty {
            let items = mixes.map { mix in
                row(mix.title, detail: mix.subtitle, symbol: "sparkles") { [weak self] in
                    self?.app.player.play(mix.tracks)
                    self?.showNowPlaying()
                }
            }
            sections.append(CPListSection(items: items, header: "Made for You", sectionIndexTitle: nil))
        }
        let played = ((try? await client.recentlyPlayedSongs(limit: 12)) ?? []).prefix(limit)
        if !played.isEmpty {
            sections.append(CPListSection(items: songRows(Array(played), queue: Array(played)), header: "Recently Played", sectionIndexTitle: nil))
        }
        if sections.isEmpty {
            sections = [CPListSection(items: [row("Nothing yet", detail: "Play something on your iPhone first.", symbol: "music.note")])]
        }
        template.updateSections(sections)
    }

    // MARK: Tune In

    private func stationRows() -> [CPListItem] {
        var items: [CPListItem] = []
        items.append(row(app.dj.name, detail: "Your DJ", symbol: "waveform") { [weak self] in self?.start(.dj) })
        items.append(row("Your Mix", detail: "Your whole library", symbol: "dot.radiowaves.left.and.right") { [weak self] in self?.start(.yourMix) })
        items.append(row("Favorites Mix", detail: "Songs you love, and more like them", symbol: "heart.fill") { [weak self] in self?.start(.favoritesMix) })
        for station in app.stations.saved.prefix(limit - 3) {
            let item = row(station.name, detail: "Live radio", symbol: "antenna.radiowaves.left.and.right", imageURL: station.faviconURL) { [weak self] in
                self?.app.stations.markPlayed(station)
                self?.app.player.playStation(station, in: self?.app.stations.saved ?? [])
                self?.showNowPlaying()
            }
            items.append(item)
        }
        return items
    }

    private func start(_ station: RecentStation) {
        app.play(station)
        showNowPlaying()
    }

    // MARK: Library

    private func libraryRows() -> [CPListItem] {
        [
            row("Playlists", symbol: "music.note.list", disclosure: true) { [weak self] in self?.push("Playlists") { try await self?.playlistRows() ?? [] } },
            row("Artists", symbol: "music.mic", disclosure: true) { [weak self] in self?.push("Artists") { try await self?.artistRows() ?? [] } },
            row("Albums", symbol: "square.stack", disclosure: true) { [weak self] in self?.push("Albums") { try await self?.albumRows(.recentlyAdded) ?? [] } },
            row("Favorites", symbol: "heart", disclosure: true) { [weak self] in
                self?.push("Favorites") { try await self?.favoriteRows() ?? [] }
            },
        ]
    }

    private func playlistRows() async throws -> [CPListItem] {
        guard let client = app.client else { return [] }
        let lists = try await client.playlists().filter { !DailyMixes.isGenerated($0.name) }.prefix(limit)
        return lists.map { list in
            row(list.name, symbol: "music.note.list", imageURL: app.client?.imageURL(for: list.imageItemId, size: 200), disclosure: true) { [weak self] in
                self?.push(list.name) { try await self?.trackRows { try await client.playlistItems(list.id) } ?? [] }
            }
        }
    }

    private func artistRows() async throws -> [CPListItem] {
        guard let client = app.client else { return [] }
        let artists = try await client.artists().prefix(limit)
        return artists.map { artist in
            row(ArtistNames.primary(artist.name), symbol: "music.mic", imageURL: client.imageURL(for: artist.id, size: 200), disclosure: true) { [weak self] in
                self?.push(artist.name) { try await self?.albumRows(artist: artist.id) ?? [] }
            }
        }
    }

    private func albumRows(_ sort: AlbumSort) async throws -> [CPListItem] {
        guard let client = app.client else { return [] }
        return albumItems(try await client.albums(sortedBy: sort).prefix(limit))
    }

    private func albumRows(artist id: String) async throws -> [CPListItem] {
        guard let client = app.client else { return [] }
        return albumItems(try await client.albums(byArtist: id).prefix(limit))
    }

    private func albumItems(_ albums: ArraySlice<BaseItem>) -> [CPListItem] {
        albums.map { album in
            row(album.name, detail: album.albumArtistLine, symbol: "square.stack", imageURL: app.client?.imageURL(for: album.id, size: 200), disclosure: true) { [weak self] in
                guard let client = self?.app.client else { return }
                self?.push(album.name) { try await self?.trackRows { try await client.tracks(inAlbum: album.id) } ?? [] }
            }
        }
    }

    private func favoriteRows() async throws -> [CPListItem] {
        guard let client = app.client else { return [] }
        return try await trackRows { try await client.favoriteSongs() }
    }

    /// A list of songs, with "Shuffle" first when there are enough of them.
    private func trackRows(_ load: () async throws -> [BaseItem]) async throws -> [CPListItem] {
        let tracks = Array(try await load().prefix(limit))
        var items: [CPListItem] = []
        if tracks.count > 2 {
            items.append(row("Shuffle", symbol: "shuffle") { [weak self] in
                self?.app.player.play(tracks, shuffle: true)
                self?.showNowPlaying()
            })
        }
        return items + songRows(tracks, queue: tracks)
    }

    // MARK: Rows

    private func songRows(_ songs: [BaseItem], queue: [BaseItem]) -> [CPListItem] {
        songs.enumerated().map { index, song in
            row(song.name, detail: song.artistLine, symbol: "music.note", imageURL: app.client?.imageURL(for: song.imageItemId, size: 200)) { [weak self] in
                self?.app.player.play(queue, startAt: index)
                self?.showNowPlaying()
            }
        }
    }

    /// One list row. The cover is a symbol until the picture arrives.
    private func row(_ title: String, detail: String? = nil, symbol: String, imageURL: URL? = nil, disclosure: Bool = false,
                     action: (() -> Void)? = nil) -> CPListItem {
        let size = CPListItem.maximumImageSize
        let placeholder = UIImage(systemName: symbol)?.withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal) ?? UIImage()
        let item = CPListItem(text: title, detailText: detail, image: placeholder, accessoryImage: nil,
                              accessoryType: disclosure ? .disclosureIndicator : .none)
        item.handler = { _, completion in
            action?()
            completion()
        }
        if let imageURL {
            Task { [weak item] in
                if let image = await self.image(imageURL, size: size) { item?.setImage(image) }
            }
        }
        return item
    }

    private func image(_ url: URL, size: CGSize) async -> UIImage? {
        if let cached = images[url.absoluteString] { return cached }
        guard let (data, _) = try? await URLSession.shared.data(from: url), let source = UIImage(data: data) else { return nil }
        let fitted = UIGraphicsImageRenderer(size: size).image { _ in source.draw(in: CGRect(origin: .zero, size: size)) }
        images[url.absoluteString] = fitted
        return fitted
    }

    // MARK: Pushed lists

    private func push(_ title: String, rows: @escaping () async throws -> [CPListItem]) {
        let template = CPListTemplate(title: title, sections: [CPListSection(items: [row("Loading\u{2026}", symbol: "hourglass")])])
        interface.pushTemplate(template, animated: true, completion: nil)
        Task {
            let items = (try? await rows()) ?? []
            template.updateSections([CPListSection(items: items.isEmpty ? [row("Nothing here yet", symbol: "tray")] : items)])
        }
    }

    // MARK: Now Playing

    private func configureNowPlaying() {
        let template = CPNowPlayingTemplate.shared
        template.isUpNextButtonEnabled = false
        template.updateNowPlayingButtons([
            CPNowPlayingShuffleButton { [weak self] _ in self?.app.player.toggleShuffle() },
            CPNowPlayingRepeatButton { [weak self] _ in self?.app.player.cycleRepeat() },
        ])
    }

    private func showNowPlaying() {
        guard !(interface.topTemplate is CPNowPlayingTemplate) else { return }
        interface.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }
}
#endif
