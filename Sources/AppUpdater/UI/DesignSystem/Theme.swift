import SwiftUI

/// Design tokens shared by every screen. Direction: "dark glass" — a deep, softly moving
/// color backdrop, frosted glass cards with lit edges, glowing gradient accents and
/// large, tightly tracked SF Pro Display type. The main window is always dark.
enum Theme {
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48
        /// Outer padding of a scrolling page.
        static let page: CGFloat = 32
        /// Readable content width for list/dashboard pages.
        static let contentWidth: CGFloat = 960
    }

    enum Radius {
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 18
        static let xl: CGFloat = 26
    }

    enum Motion {
        static let hover = Animation.easeOut(duration: 0.18)
        static let press = Animation.spring(response: 0.25, dampingFraction: 0.7)
        static let content = Animation.spring(response: 0.5, dampingFraction: 0.85)
        /// Live readings that change every sample. Short, so the window is idle between samples.
        static let tick = Animation.easeOut(duration: 0.25)
    }

    enum Palette {
        /// Base of the backdrop behind every glass surface.
        static let canvas = Color(red: 0.035, green: 0.035, blue: 0.075)

        static let brand = Color(red: 0.52, green: 0.38, blue: 1.0)
        static let brandSecondary = Color(red: 0.96, green: 0.36, blue: 0.74)
        static let brandTertiary = Color(red: 0.26, green: 0.78, blue: 1.0)

        static let success = Color(red: 0.24, green: 0.86, blue: 0.62)
        static let warning = Color(red: 1.0, green: 0.71, blue: 0.27)
        static let danger = Color(red: 1.0, green: 0.38, blue: 0.45)
        static let info = Color(red: 0.36, green: 0.66, blue: 1.0)

        static let textPrimary = Color.white
        static let textSecondary = Color.white.opacity(0.62)
        static let textTertiary = Color.white.opacity(0.38)

        /// Hairline used for surface borders.
        static let hairline = Color.white.opacity(0.09)
        static let hoverFill = Color.white.opacity(0.06)
        static let pressedFill = Color.white.opacity(0.11)
        static let selectionFill = Color.white.opacity(0.10)
        /// Frosted-glass tint used instead of live materials. The backdrop is already a soft blur,
        /// so a translucent fill looks the same while avoiding per-frame backdrop blurring in WindowServer.
        static let glass = Color(red: 0.62, green: 0.58, blue: 0.86).opacity(0.10)
    }

    enum Typography {
        /// Big page title.
        static let display = Font.system(size: 34, weight: .bold)
        /// Hero headline on the Overview.
        static let hero = Font.system(size: 44, weight: .heavy)
        static let sectionTitle = Font.system(size: 17, weight: .semibold)
        /// Small caps label above a section title.
        static let eyebrow = Font.system(size: 10.5, weight: .bold)
        /// Large numerals for stats and counters.
        static func numeral(_ size: CGFloat) -> Font {
            .system(size: size, weight: .bold, design: .rounded).monospacedDigit()
        }
        /// Tracking for display sizes; SF Pro Display looks best slightly tightened.
        static let displayTracking: CGFloat = -0.6
    }

    /// Violet → pink signature gradient for primary actions and highlights.
    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [Palette.brand, Palette.brandSecondary],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Gradient for numerals and hero text: bright white fading slightly downwards.
    static var textGradient: LinearGradient {
        LinearGradient(colors: [.white, .white.opacity(0.72)], startPoint: .top, endPoint: .bottom)
    }

    /// Top-lit gradient for a tint, used by icon tiles and tinted buttons.
    static func gradient(for tint: Color) -> LinearGradient {
        LinearGradient(colors: [tint.opacity(0.78), tint], startPoint: .top, endPoint: .bottom)
    }
}
