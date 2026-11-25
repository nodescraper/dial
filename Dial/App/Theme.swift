import UIKit
import SwiftUI

/// Every spacing, size and corner radius in the app comes from here,
/// so screens stay consistent and the look can be changed in one place.
enum Theme {
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        /// Between the shelves on Home, Radio and Library.
        static let section: CGFloat = 28
    }

    /// Three corner sizes, all with Apple's continuous (squircle) curve:
    /// small artwork in rows, everything at tile or control size, and large artwork.
    enum Radius {
        /// Artwork in song, album and playlist rows.
        static let thumb: CGFloat = 6
        /// Tiles, cards, buttons, text fields, toggles and the floating mini player.
        static let tile: CGFloat = 12
        static let control: CGFloat = tile
        /// Large artwork, hero cards and big headers.
        static let hero: CGFloat = 16
        /// Small labels like LIVE and DJ.
        static let badge: CGFloat = 4

        /// A radius that sits evenly inside a rounded container with the given padding.
        static func nested(in outer: CGFloat, padding: CGFloat) -> CGFloat {
            max(outer - padding, thumb)
        }
    }

    enum Size {
        static let rowArtwork: CGFloat = 48
        static let stationArtwork: CGFloat = 54
        static let miniArtwork: CGFloat = 40
        static let compactArtwork: CGFloat = 56
        static let trackNumber: CGFloat = 28
        static let shelfTile: CGFloat = 150
        static let artistHero: CGFloat = 190
        static let categoryCard: CGFloat = 96
        static let categoryHeader: CGFloat = 150
        /// Apple's minimum comfortable tap target.
        static let tapTarget: CGFloat = 44
        /// Side margin for large artwork on album and playlist pages.
        static let heroInset: CGFloat = 44
        /// The handle at the top of the full-screen player.
        static let grabber = CGSize(width: 38, height: 5)
        /// How much of the screen width a Home hero card or song column takes (the next one peeks in).
        static let carouselFraction: CGFloat = 0.88
        /// Hero cards stop growing past this on big windows (iPad, Mac).
        /// The least room the song's title gets in the Mac and iPad player bar.
        static let barSongMin: CGFloat = 180
        /// The cover beside the title on album and playlist pages on iPad and Mac.
        static let albumHeaderArtwork: CGFloat = 260
        static let heroMaxWidth: CGFloat = 720
        /// Grids fit as many tiles of at least this width as there's room for (2 on iPhone).
        static let gridTileMin: CGFloat = 150
        /// The full-screen player's content stops growing past this on big windows.
        static let playerMaxWidth: CGFloat = 560
        /// Rows per column in Home's scrolling song list.
        static let songGridRows = 4
        /// Height of an artist logo on a hero card.
        static let heroLogo: CGFloat = 40
        /// Widest a form (like sign-in) gets on large screens.
        static let formMaxWidth: CGFloat = 480
    }

    /// The full-screen player, styled after Apple Music.
    enum Player {
        /// Side margins of the player's content.
        static let margin: CGFloat = 30
        /// Height of the progress and volume bars.
        static let barHeight: CGFloat = 7
        /// Artwork shrinks to this size when paused.
        static let pausedArtworkScale: CGFloat = 0.8
        /// Secondary text and icons: white, blended onto the background color.
        static let secondaryOpacity: Double = 0.6
        static let iconOpacity: Double = 0.75
        static let trackOpacity: Double = 0.22
        static let fillOpacity: Double = 0.7
        static let playSize: CGFloat = 44
        static let skipSize: CGFloat = 32
        /// Tap area of the handle at the top.
        static let grabberHitHeight: CGFloat = 24
    }

    /// Pixel sizes requested from the server for each kind of artwork.
    enum Pixels {
        static let thumb = 160
        static let tile = 400
        static let hero = 900
        /// Width requested for wide 16:9 pictures.
        static let wide = 1280
        static let logo = 500
    }
}

extension Color {
    /// Cassette orange from the app icon, the app's only accent color (#E8742C).
    static let dial = Color(red: 0.91, green: 0.455, blue: 0.173)
}

extension Shape where Self == RoundedRectangle {
    /// The app's rounded rectangle: continuous corners, like Apple's own.
    static func rounded(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

extension View {
    /// The soft drop shadow under large artwork.
    func artworkShadow() -> some View {
        shadow(color: .black.opacity(0.25), radius: 16, y: 8)
    }

    /// The deeper shadow under the artwork in the full-screen player.
    func playerArtworkShadow(lifted: Bool = true) -> some View {
        shadow(color: .black.opacity(lifted ? 0.4 : 0.2), radius: lifted ? 24 : 12, y: lifted ? 12 : 6)
    }

    /// Secondary text and icons in the player: white blended onto the artwork color, like Apple Music.
    func playerSecondary() -> some View {
        foregroundStyle(.white.opacity(Theme.Player.secondaryOpacity))
            .blendMode(.plusLighter)
    }
}

enum Platform {
    static var isMac: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    static var isPad: Bool { !isMac && UIDevice.current.userInterfaceIdiom == .pad }

    /// "iPhone", "iPad" or "Mac", for text like "Downloaded songs stay on this Mac".
    static var deviceKind: String { isMac ? "Mac" : isPad ? "iPad" : "iPhone" }
    static var thisDevice: String { "This \(deviceKind)" }
    static var deviceSymbol: String { isMac ? "laptopcomputer" : isPad ? "ipad" : "iphone" }

    /// iOS 26.1 and later have a native bottom accessory for the tab bar (used for the mini player).
    static var hasTabAccessory: Bool {
        #if compiler(>=6.2)
        if isMac { return false } // the Mac shows a player bar at the bottom of the window instead
        if #available(iOS 26.1, *) { return true }
        #endif
        return false
    }
}
