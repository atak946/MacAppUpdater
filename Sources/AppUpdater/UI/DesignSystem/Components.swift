import SwiftUI

/// Glossy rounded square with a white glyph on a tinted gradient and a soft halo.
struct IconTile: View {
    let symbol: String
    var tint: Color = Theme.Palette.brand
    var size: CGFloat = 20
    var glows = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            .frame(width: size, height: size)
            .background(shape.fill(Theme.gradient(for: tint)))
            .overlay(
                // Glass highlight on the upper half.
                shape.fill(
                    LinearGradient(colors: [.white.opacity(0.32), .clear], startPoint: .top, endPoint: .center)
                )
            )
            .overlay(shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
            .shadow(color: tint.opacity(glows ? 0.6 : 0.25), radius: glows ? size * 0.4 : 3, y: 1)
            .accessibilityHidden(true)
    }
}

/// Eyebrow + title opening a page section, with optional trailing content.
struct SectionHeader<Trailing: View>: View {
    let eyebrow: String?
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                if let eyebrow {
                    Text(eyebrow.uppercased())
                        .font(Theme.Typography.eyebrow)
                        .tracking(1.4)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                Text(title)
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            Spacer(minLength: Theme.Spacing.m)
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(eyebrow: String? = nil, title: String) {
        self.init(eyebrow: eyebrow, title: title) { EmptyView() }
    }
}

/// Large page title with subtitle and trailing actions.
struct PageHeader<Actions: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.l) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(title)
                    .font(Theme.Typography.display)
                    .tracking(Theme.Typography.displayTracking)
                    .foregroundStyle(Theme.textGradient)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .contentTransition(.opacity)
                }
            }
            Spacer(minLength: Theme.Spacing.l)
            actions
        }
        .padding(.bottom, Theme.Spacing.xs)
    }
}

/// Glass stat card: glowing icon tile, big gradient numeral and a label.
struct StatTile: View {
    let value: String
    let label: String
    let symbol: String
    var tint: Color = Theme.Palette.brand
    var action: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
                    .onHover { isHovered = $0 }
            } else {
                content
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            HStack {
                IconTile(symbol: symbol, tint: tint, size: 30, glows: isHovered)
                Spacer()
                if action != nil {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .opacity(isHovered ? 1 : 0)
                        .offset(x: isHovered ? 0 : -4, y: isHovered ? 0 : 4)
                }
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(value)
                    .font(Theme.Typography.numeral(32))
                    .foregroundStyle(Theme.textGradient)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                Text(label)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(Theme.Spacing.l + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            // Tint bloom in the corner, stronger on hover.
            RadialGradient(colors: [tint.opacity(isHovered ? 0.32 : 0.16), .clear], center: .topLeading, startRadius: 0, endRadius: 160)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
        )
        .surface(isHovered ? .elevated : .raised)
        .offset(y: isHovered ? -2 : 0)
        .animation(Theme.Motion.hover, value: isHovered)
        .contentShape(Rectangle())
    }
}

/// Circular progress ring with a glowing gradient stroke and a centered label.
struct ProgressRing<Label: View>: View {
    /// 0...1
    let value: Double
    var tint: Color = Theme.Palette.brand
    var lineWidth: CGFloat = 10
    @ViewBuilder var label: Label

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.07), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(value, 1)))
                .stroke(
                    AngularGradient(colors: [tint.opacity(0.35), tint, tint], center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * max(value, 0.01))),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .glow(tint, radius: lineWidth, opacity: 0.6)
                .animation(Theme.Motion.content, value: value)
            label
        }
    }
}

/// Hero orb: glowing glass sphere with a gradient ring that spins while `isActive`.
struct ScanOrb<Content: View>: View {
    var tint: Color = Theme.Palette.brand
    var isActive = false
    var diameter: CGFloat = 200
    /// 0...1 fill of the ring when idle (e.g. a health score).
    var progress: Double = 1
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation: Double = 0
    @State private var breathe = false

    var body: some View {
        ZStack {
            // Outer bloom.
            Circle()
                .fill(RadialGradient(colors: [tint.opacity(0.55), .clear], center: .center, startRadius: diameter * 0.2, endRadius: diameter * 0.75))
                .frame(width: diameter * 1.5, height: diameter * 1.5)
                .scaleEffect(breathe ? 1.06 : 0.96)
            // Track + ring.
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: ringWidth)
                .frame(width: diameter, height: diameter)
            Circle()
                .trim(from: 0, to: isActive ? 0.72 : max(0.001, min(progress, 1)))
                .stroke(
                    AngularGradient(colors: [Theme.Palette.brandTertiary, tint, Theme.Palette.brandSecondary, Theme.Palette.brandTertiary], center: .center),
                    style: StrokeStyle(lineWidth: ringWidth, lineCap: .round)
                )
                .frame(width: diameter, height: diameter)
                .rotationEffect(.degrees(-90 + rotation))
                .glow(tint, radius: 12, opacity: 0.8)
            // Glass core.
            Circle()
                .fill(Theme.Palette.glass)
                .overlay(Circle().fill(RadialGradient(colors: [tint.opacity(0.35), Theme.Palette.canvas.opacity(0.4)], center: .init(x: 0.35, y: 0.25), startRadius: 0, endRadius: diameter * 0.6)))
                .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.4), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
                .frame(width: diameter - ringWidth * 4, height: diameter - ringWidth * 4)
                .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
            content
        }
        .frame(width: diameter * 1.15, height: diameter * 1.15)
        .animation(Theme.Motion.content, value: progress)
        .onAppear(perform: startMotion)
        .onChange(of: isActive) { _, _ in startMotion() }
    }

    private var ringWidth: CGFloat { max(6, diameter * 0.045) }

    private func startMotion() {
        // Idle orbs stay still: endless animations keep the whole window re-rendering.
        guard !reduceMotion, isActive else {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.9)) { rotation = 0; breathe = false }
            return
        }
        withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) { breathe = true }
        if isActive {
            rotation = 0
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { rotation = 360 }
        } else {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.9)) { rotation = 0 }
        }
    }
}

/// Designed empty / error / loading state for a page or card.
struct EmptyStateView: View {
    /// Nil shows a spinner.
    let symbol: String?
    var tint: Color = Theme.Palette.brand
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [tint.opacity(0.45), .clear], center: .center, startRadius: 0, endRadius: 70))
                    .frame(width: 140, height: 140)
                Circle()
                    .fill(Theme.Palette.glass)
                    .overlay(Circle().fill(tint.opacity(0.14)))
                    .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
                    .frame(width: 84, height: 84)
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(LinearGradient(colors: [.white, tint], startPoint: .top, endPoint: .bottom))
                        .glow(tint, radius: 10, opacity: 0.7)
                } else {
                    ProgressView().controlSize(.regular).tint(.white)
                }
            }
            VStack(spacing: Theme.Spacing.s) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(Theme.textGradient)
                    .multilineTextAlignment(.center)
                if let message {
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.primary)
                    .controlSize(.large)
                    .padding(.top, Theme.Spacing.xs)
            }
        }
        .padding(Theme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Small tinted capsule for status text ("Up to date", "3 warnings").
struct StatusPill: View {
    let title: String
    var symbol: String?
    var tint: Color = Theme.Palette.textSecondary

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(title)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.16)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.28), lineWidth: 0.5))
        .fixedSize()
    }
}

/// Hairline divider for rows inside glass cards.
struct GlassDivider: View {
    var leadingInset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Theme.Palette.hairline)
            .frame(height: 1)
            .padding(.leading, leadingInset)
    }
}
