import AppKit
import MaintenanceCore
import SwiftUI

/// Shared column widths for the header and rows.
enum StartupListMetrics {
    static let icon: CGFloat = 28
    static let kind: CGFloat = 116
    static let signer: CGFloat = 128
    static let toggle: CGFloat = 92
    static let rowHorizontal: CGFloat = Theme.Spacing.l
    static let dividerInset: CGFloat = rowHorizontal + icon + Theme.Spacing.m
}

/// One launchd job: icon, name over label and executable, kind and signer pills, enable toggle.
struct StartupItemRow: View {
    let item: StartupItem
    let icon: NSImage?
    let isPending: Bool
    let onToggle: (Bool) -> Void
    let onReveal: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            iconView
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(item.isEnabled ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                    Text(item.label)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .lineLimit(1)
                Text(item.executableURL?.path ?? String(localized: "No executable"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.triggerDescription)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            revealButton
            StatusPill(title: item.kind.title, symbol: item.kind.symbol, tint: item.kind.tint)
                .frame(width: StartupListMetrics.kind, alignment: .leading)
            StartupSignerPill(item: item)
                .frame(width: StartupListMetrics.signer, alignment: .leading)
            toggle
                .frame(width: StartupListMetrics.toggle, alignment: .trailing)
        }
        .padding(.horizontal, StartupListMetrics.rowHorizontal - Theme.Spacing.xs)
        .padding(.vertical, Theme.Spacing.s)
        .hoverHighlight(isHovered, radius: Theme.Radius.m)
        .padding(.horizontal, Theme.Spacing.xs)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: StartupListMetrics.icon, height: StartupListMetrics.icon)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1.5)
        } else {
            IconTile(symbol: item.kind.symbol, tint: item.kind.tint, size: StartupListMetrics.icon)
        }
    }

    private var revealButton: some View {
        Button(action: onReveal) {
            Image(systemName: "folder")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isHovered ? 1 : 0)
        .animation(Theme.Motion.hover, value: isHovered)
        .help(String(localized: "Reveal in Finder"))
        .accessibilityLabel(Text("Reveal in Finder"))
    }

    @ViewBuilder
    private var toggle: some View {
        if isPending {
            ProgressView().controlSize(.small).tint(.white)
        } else {
            GlassToggle(isOn: item.isEnabled, isLocked: !item.isControllable, onChange: onToggle)
                .help(toggleHelp)
        }
    }

    private var toggleHelp: String {
        if item.isAppleItem { return String(localized: "Part of macOS — shown read-only.") }
        if item.requiresAdmin {
            return String(localized: "System daemon — macOS asks for your administrator password to change it.")
        }
        return item.isEnabled ? String(localized: "Disable at login") : String(localized: "Enable at login")
    }
}

// MARK: - Glass toggle

/// Capsule switch with a lit brand track; dims and ignores taps when locked.
struct GlassToggle: View {
    let isOn: Bool
    var isLocked = false
    let onChange: (Bool) -> Void

    private static let size = CGSize(width: 34, height: 20)

    var body: some View {
        Button { onChange(!isOn) } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Color.white.opacity(0.1)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(isOn ? 0.3 : 0.12), lineWidth: 0.5))
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .padding(2)
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .animation(Theme.Motion.press, value: isOn)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
        .opacity(isLocked ? 0.4 : 1)
        .accessibilityLabel(Text("Enabled"))
        .accessibilityValue(Text(isOn ? "On" : "Off"))
    }
}

// MARK: - Filter capsule

/// Segmented glass capsule with counts; the selected segment gets the brand fill.
struct StartupFilterCapsule: View {
    @Binding var selection: StartupFilter
    let count: (StartupFilter) -> Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(StartupFilter.allCases) { segment($0) }
        }
        .padding(3)
        .background(Capsule().fill(Theme.Palette.glass))
        .overlay(Capsule().strokeBorder(Theme.Palette.hairline, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Filter"))
    }

    private func segment(_ option: StartupFilter) -> some View {
        let isSelected = selection == option
        return Button { selection = option } label: {
            HStack(spacing: 6) {
                Text(option.title)
                Text("\(count(option))")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(isSelected ? Theme.Palette.textPrimary : Theme.Palette.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(isSelected ? 0.18 : 0.06)))
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isSelected ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                Capsule()
                    .fill(Theme.brandGradient)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.3), lineWidth: 0.5))
                    .opacity(isSelected ? 1 : 0)
            }
            .animation(Theme.Motion.hover, value: isSelected)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
