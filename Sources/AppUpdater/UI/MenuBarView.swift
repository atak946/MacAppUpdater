import AppKit
import SwiftUI

/// The popover shown from the menu bar item.
struct MenuBarView: View {
    let viewModel: UpdatesViewModel
    /// Live CPU / memory / network strip; nil hides it.
    var monitorModel: MonitorModel?

    @Environment(\.openWindow) private var openWindow

    private let width: CGFloat = 340
    private let maxListHeight: CGFloat = 380

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            if let monitorModel {
                MenuBarMonitorStrip(model: monitorModel)
            }
            header
            content
                .frame(maxWidth: .infinity)
                .surface(.raised, radius: Theme.Radius.l)
            footer
        }
        .padding(Theme.Spacing.m)
        .padding(.top, Theme.Spacing.s)
        .frame(width: width)
        .background { AppBackdrop(isAnimated: false).ignoresSafeArea() }
        .environment(\.isOnBackdrop, true)
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .task {
            if viewModel.state == .idle { await viewModel.refresh() }
        }
    }

    // MARK: Header

    private var pendingCount: Int { viewModel.pendingUpdates.count }

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.m + 2) {
            CountOrb(count: pendingCount, isBusy: viewModel.isBusy)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs + 1) {
                Text(headline)
                    .font(.system(size: 17, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(Theme.textGradient)
                statusLine
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
            RefreshButton(isBusy: viewModel.isBusy) {
                Task { await viewModel.refresh() }
            }
        }
        .padding(.horizontal, Theme.Spacing.xs)
        .padding(.vertical, Theme.Spacing.xs)
        .animation(Theme.Motion.content, value: pendingCount)
    }

    /// Matches the list below: "Up to date" with nothing pending, a count otherwise.
    private var headline: String {
        switch pendingCount {
        case 0: String(localized: "Up to date")
        case 1: String(localized: "Update available")
        default: String(localized: "\(pendingCount) updates available")
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch viewModel.state {
        case .scanning: Text("Scanning applications…")
        case .checking: Text("Checking for updates…")
        default:
            if let lastChecked = viewModel.lastChecked {
                Text("Checked \(lastChecked, format: .relative(presentation: .named))")
            } else {
                Text("Not checked yet")
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .scanning, .checking:
            if viewModel.updates.isEmpty {
                PlaceholderView(symbol: nil, tint: Theme.Palette.brand, title: String(localized: "Looking for updates"), message: nil)
            } else {
                updateList
            }
        case .failed(let message):
            PlaceholderView(
                symbol: "exclamationmark.triangle.fill",
                tint: Theme.Palette.warning,
                title: String(localized: "Couldn't check for updates"),
                message: message
            )
        case .loaded:
            if viewModel.updates.isEmpty {
                PlaceholderView(
                    symbol: "checkmark.seal.fill",
                    tint: Theme.Palette.success,
                    title: String(localized: "Everything is up to date"),
                    message: String(localized: "We'll keep checking in the background.")
                )
            } else {
                updateList
            }
        }
    }

    private var updateList: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Spacing.xxs) {
                ForEach(viewModel.updates) { update in
                    UpdateRowView(update: update, viewModel: viewModel)
                }
            }
            .padding(Theme.Spacing.xs + 2)
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: maxListHeight)
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Theme.Spacing.xs) {
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(IconButtonStyle())
            .help("Settings")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(IconButtonStyle())
            .help("Quit App Updater")

            Spacer(minLength: Theme.Spacing.s)

            Button {
                openWindow(id: "main")
                NSApp.activate()
            } label: {
                Label("Open App Updater", systemImage: "macwindow")
            }
            .buttonStyle(.secondary)
            .help("Open the main window")

            if !viewModel.installableUpdates.isEmpty {
                Button {
                    Task { await viewModel.installAll() }
                } label: {
                    Label("Update All", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .labelStyle(CompactLabelStyle())
        .animation(Theme.Motion.content, value: viewModel.installableUpdates.isEmpty)
    }
}

// MARK: - Supporting views

/// Glowing glass orb with the pending count as a gradient numeral; a gradient arc spins
/// around it while checking.
private struct CountOrb: View {
    let count: Int
    let isBusy: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation: Double = 0

    private let size: CGFloat = 54

    private var tint: Color { count > 0 ? Theme.Palette.brand : Theme.Palette.success }

    var body: some View {
        ZStack {
            // Bloom.
            Circle()
                .fill(RadialGradient(colors: [tint.opacity(0.6), .clear], center: .center, startRadius: 0, endRadius: size * 0.8))
                .frame(width: size * 1.6, height: size * 1.6)
                .blur(radius: 10)
            // Glass core.
            Circle()
                .fill(Theme.Palette.glass)
                .overlay(
                    Circle().fill(
                        RadialGradient(
                            colors: [tint.opacity(0.55), Theme.Palette.canvas.opacity(0.35)],
                            center: .init(x: 0.35, y: 0.25), startRadius: 0, endRadius: size * 0.7
                        )
                    )
                )
                .overlay(
                    Circle().strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
                )
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
            if count > 0 {
                Text("\(count)")
                    .font(Theme.Typography.numeral(count > 99 ? 17 : 24))
                    .foregroundStyle(Theme.textGradient)
                    .contentTransition(.numericText())
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.textGradient)
            }
            if isBusy {
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(
                        AngularGradient(colors: [Theme.Palette.brandTertiary.opacity(0), Theme.Palette.brandTertiary, Theme.Palette.brandSecondary], center: .center),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .frame(width: size + 8, height: size + 8)
                    .rotationEffect(.degrees(rotation))
                    .glow(Theme.Palette.brandTertiary, radius: 4, opacity: 0.8)
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { rotation = 360 }
                    }
                    .onDisappear { rotation = 0 }
                    .transition(.opacity)
            }
        }
        .frame(width: size + 10, height: size + 10)
        .animation(Theme.Motion.content, value: count)
        .animation(Theme.Motion.hover, value: isBusy)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(count) updates available"))
    }
}

/// Compact empty / loading / error state sized for the popover.
private struct PlaceholderView: View {
    let symbol: String?
    let tint: Color
    let title: String
    let message: String?

    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [tint.opacity(0.45), .clear], center: .center, startRadius: 0, endRadius: 50))
                    .frame(width: 100, height: 100)
                    .blur(radius: 6)
                Circle()
                    .fill(Theme.Palette.glass)
                    .overlay(Circle().fill(tint.opacity(0.14)))
                    .overlay(
                        Circle().strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom),
                            lineWidth: 1
                        )
                    )
                    .frame(width: 58, height: 58)
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(LinearGradient(colors: [.white, tint], startPoint: .top, endPoint: .bottom))
                        .glow(tint, radius: 8, opacity: 0.7)
                } else {
                    ProgressView().controlSize(.small).tint(.white)
                }
            }
            .frame(height: 72)
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .tracking(-0.2)
                .foregroundStyle(Theme.textGradient)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.xl + 4)
        .frame(maxWidth: .infinity)
    }
}

/// Icon plus title with tight spacing, for footer capsules.
private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
            configuration.title
        }
    }
}

private struct RefreshButton: View {
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .symbolEffect(.pulse, options: .repeating, isActive: isBusy)
        }
        .buttonStyle(IconButtonStyle())
        .disabled(isBusy)
        .help("Check for updates")
        .keyboardShortcut("r")
    }
}

/// Borderless icon button for dark glass: white glyph with frosted hover and pressed fills.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration)
    }

    private struct IconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.s + 1, style: .continuous)
                        .fill(Color.white.opacity(fillOpacity))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.s + 1, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom),
                            lineWidth: 1
                        )
                        .opacity(isHovered && isEnabled ? 1 : 0)
                )
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .animation(Theme.Motion.press, value: configuration.isPressed)
                .animation(Theme.Motion.hover, value: isHovered)
                .onHover { isHovered = $0 }
                .contentShape(Rectangle())
        }

        private var foreground: Color {
            guard isEnabled else { return Theme.Palette.textTertiary }
            return isHovered || configuration.isPressed ? Theme.Palette.textPrimary : Theme.Palette.textSecondary
        }

        /// White-on-glass: a faint frost on hover, a brighter one while pressed.
        private var fillOpacity: Double {
            guard isEnabled else { return 0 }
            if configuration.isPressed { return 0.16 }
            return isHovered ? 0.09 : 0
        }
    }
}
