import SwiftUI
import UIKit
#if canImport(WidgetKit) && !targetEnvironment(macCatalyst)
import WidgetKit
#endif

/// Tells the Home Screen widget what was played last (the album of the song, or the station), with its cover.
@MainActor
enum WidgetFeed {
    private static var lastId = ""
    private static var lastPlaying: Bool?

    /// The widget's button shows pause while this device plays.
    static func setPlaying(_ playing: Bool) {
        guard playing != lastPlaying else { return }
        lastPlaying = playing
        DialWidgetStore.savePlaying(playing)
        #if canImport(WidgetKit) && !targetEnvironment(macCatalyst)
        WidgetCenter.shared.reloadTimelines(ofKind: DialWidgetStore.kind)
        #endif
    }

    static func record(_ item: DialWidgetItem, artworkURL: URL?) {
        guard item.id != lastId else { return }
        lastId = item.id
        Task {
            var data: Data?
            if let artworkURL, let image = await ImagePipeline.shared.image(for: artworkURL) { data = jpeg(image) }
            DialWidgetStore.save(item, artwork: data)
            #if canImport(WidgetKit) && !targetEnvironment(macCatalyst)
            WidgetCenter.shared.reloadTimelines(ofKind: DialWidgetStore.kind)
            #endif
        }
    }

    private static func jpeg(_ image: UIImage) -> Data? {
        let size = CGSize(width: 360, height: 360)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let ratio = max(size.width / image.size.width, size.height / image.size.height)
            let drawn = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
            image.draw(in: CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2, width: drawn.width, height: drawn.height))
        }
        return scaled.jpegData(compressionQuality: 0.7)
    }
}
