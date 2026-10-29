import SwiftUI

/// Glowing gradient capsule for the one primary action on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    /// Nil uses the violet → pink brand gradient.
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, tint: tint)
    }

    private struct StyledBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color?
        @State private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize

        var body: some View {
            configuration.label
                .font(.system(size: metrics.font, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, metrics.horizontal)
                .padding(.vertical, metrics.vertical)
                .background(Capsule().fill(fill))
                .overlay(
                    Capsule().strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
                )
                .shadow(color: glowColor.opacity(isEnabled ? (isHovered ? 0.7 : 0.45) : 0), radius: isHovered ? 16 : 10, y: 4)
                .offset(y: isHovered && !configuration.isPressed ? -1 : 0)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .saturation(isEnabled ? 1 : 0)
                .animation(Theme.Motion.press, value: configuration.isPressed)
                .animation(Theme.Motion.hover, value: isHovered)
                .onHover { isHovered = $0 }
                .contentShape(Capsule())
        }

        private var fill: AnyShapeStyle {
            if let tint { AnyShapeStyle(Theme.gradient(for: tint)) } else { AnyShapeStyle(Theme.brandGradient) }
        }

        private var glowColor: Color { tint ?? Theme.Palette.brand }

        private var metrics: (font: CGFloat, horizontal: CGFloat, vertical: CGFloat) {
            switch controlSize {
            case .mini, .small: (11.5, 12, 5)
            case .large, .extraLarge: (14, 20, 10)
            default: (13, 16, 7.5)
            }
        }
    }
}

/// Frosted glass capsule for secondary actions (row buttons, header extras).
struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.Palette.textPrimary

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, tint: tint)
    }

    private struct StyledBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        @State private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize

        var body: some View {
            configuration.label
                .font(.system(size: metrics.font, weight: .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, metrics.horizontal)
                .padding(.vertical, metrics.vertical)
                .background(Capsule().fill(Color.white.opacity(fillOpacity(configuration.isPressed))))
                .overlay(Capsule().strokeBorder(Color.white.opacity(isHovered ? 0.22 : 0.12), lineWidth: 1))
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .animation(Theme.Motion.press, value: configuration.isPressed)
                .animation(Theme.Motion.hover, value: isHovered)
                .onHover { isHovered = $0 }
                .contentShape(Capsule())
        }

        private func fillOpacity(_ isPressed: Bool) -> Double {
            if isPressed { return 0.16 }
            return isHovered ? 0.11 : 0.06
        }

        private var metrics: (font: CGFloat, horizontal: CGFloat, vertical: CGFloat) {
            switch controlSize {
            case .mini, .small: (11.5, 11, 4.5)
            case .large, .extraLarge: (14, 18, 10)
            default: (12.5, 14, 7)
            }
        }
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static func primary(tint: Color) -> PrimaryButtonStyle { PrimaryButtonStyle(tint: tint) }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
    static func secondary(tint: Color) -> SecondaryButtonStyle { SecondaryButtonStyle(tint: tint) }
}
