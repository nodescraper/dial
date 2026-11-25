import CoreImage
import SwiftUI
import UIKit

/// Picks two background colors from a cover (from its top and bottom halves),
/// darkened enough that white text always stays readable.
enum ArtworkPalette {
    static let fallback: [Color] = [Color(white: 0.24), Color(white: 0.08)]
    /// The player's background while the DJ is talking.
    static let onAir: [Color] = [Color(red: 0.17, green: 0.08, blue: 0.27), Color(red: 0.05, green: 0.03, blue: 0.09)]

    private static let cache = PaletteCache()
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    static func colors(for url: URL) async -> [Color]? {
        if let cached = await cache.colors(for: url) { return cached }
        // The cover from the image cache (it's on screen anyway), not a second download.
        guard let cgImage = await ImagePipeline.shared.image(for: url)?.cgImage else { return nil }
        let colors = await Task.detached(priority: .utility) { extract(from: CIImage(cgImage: cgImage)) }.value
        if let colors { await cache.store(colors, for: url) }
        return colors
    }

    private static func extract(from image: CIImage) -> [Color]? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        // Core Image measures from the bottom, so the top half starts at midY.
        let top = CGRect(x: extent.minX, y: extent.midY, width: extent.width, height: extent.height / 2)
        let bottom = CGRect(x: extent.minX, y: extent.minY, width: extent.width, height: extent.height / 2)
        guard let topColor = average(of: image, in: top),
              let bottomColor = average(of: image, in: bottom) else { return nil }
        return [tone(topColor, brightness: 1), tone(bottomColor, brightness: 0.55)]
    }

    private static func average(of image: CIImage, in rect: CGRect) -> UIColor? {
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: rect),
        ]), let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                       blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }

    /// Keeps the hue, boosts the color a little, and caps the brightness for contrast with white text.
    private static func tone(_ color: UIColor, brightness factor: CGFloat) -> Color {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let toned = UIColor(hue: hue,
                            saturation: min(saturation * 1.15, 0.9),
                            brightness: min(max(brightness, 0.2), 0.5) * factor,
                            alpha: 1)
        return Color(uiColor: toned)
    }
}

private actor PaletteCache {
    private var entries: [URL: [Color]] = [:]

    func colors(for url: URL) -> [Color]? { entries[url] }

    func store(_ colors: [Color], for url: URL) {
        if entries.count > 200 { entries.removeAll() }
        entries[url] = colors
    }
}
