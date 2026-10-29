import SwiftUI

/// Elevation of a glass container.
enum SurfaceLevel {
    /// Flush grouping inside another surface.
    case inset
    /// Default glass card on the backdrop.
    case raised
    /// Hero or floating element: stronger edge light and a deeper shadow.
    case elevated
}

private struct SurfaceModifier: ViewModifier {
    let level: SurfaceLevel
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                switch level {
                case .inset:
                    shape.fill(Color.white.opacity(0.035))
                case .raised, .elevated:
                    ZStack {
                        shape.fill(Theme.Palette.glass)
                        shape.fill(Color.white.opacity(level == .elevated ? 0.06 : 0.04))
                    }
                }
            }
            .overlay(shape.strokeBorder(edgeLight, lineWidth: 1).allowsHitTesting(false))
            .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, y: shadowRadius / 2)
    }

    /// Light catching the top edge of the glass, fading towards the bottom.
    private var edgeLight: LinearGradient {
        let top = level == .elevated ? 0.26 : level == .raised ? 0.16 : 0.08
        return LinearGradient(
            colors: [.white.opacity(top), .white.opacity(0.03)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var shadowOpacity: Double {
        switch level {
        case .inset: 0
        case .raised: 0.28
        case .elevated: 0.45
        }
    }

    private var shadowRadius: CGFloat {
        switch level {
        case .inset: 0
        // Kept small on purpose: SwiftUI renders shadows on the CPU, cost grows with the radius.
        case .raised: 6
        case .elevated: 10
        }
    }
}

private struct OnBackdropKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True below `AppBackdrop`, so pages don't paint a second background.
    var isOnBackdrop: Bool {
        get { self[OnBackdropKey.self] }
        set { self[OnBackdropKey.self] = newValue }
    }
}

private struct PageBackgroundModifier: ViewModifier {
    @Environment(\.isOnBackdrop) private var isOnBackdrop

    func body(content: Content) -> some View {
        if isOnBackdrop {
            content.scrollContentBackground(.hidden)
        } else {
            content
                .scrollContentBackground(.hidden)
                .background { AppBackdrop(isAnimated: false).ignoresSafeArea() }
                .environment(\.isOnBackdrop, true)
                .environment(\.colorScheme, .dark)
        }
    }
}

private enum GlowLimits {
    static let maxRadius: CGFloat = 5
}

extension View {
    /// Wraps the view in a frosted glass card. Apply padding before calling.
    func surface(_ level: SurfaceLevel = .raised, radius: CGFloat = Theme.Radius.l) -> some View {
        modifier(SurfaceModifier(level: level, radius: radius))
    }

    /// Root of a page: transparent over the app backdrop, or paints its own (sheets, popovers).
    func pageBackground() -> some View {
        modifier(PageBackgroundModifier())
    }

    /// Rounded hover highlight for rows; the caller owns `isHovered`.
    func hoverHighlight(_ isHovered: Bool, radius: CGFloat = Theme.Radius.m) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(isHovered ? Theme.Palette.hoverFill : .clear)
        )
        .animation(Theme.Motion.hover, value: isHovered)
    }

    /// Soft colored halo behind a view (buttons, orbs, icons).
    func glow(_ color: Color, radius: CGFloat = 14, opacity: Double = 0.55) -> some View {
        // Shadows are blurred on the CPU on every redraw; a capped radius keeps the halo cheap.
        shadow(color: color.opacity(opacity), radius: min(radius, GlowLimits.maxRadius))
    }
}
