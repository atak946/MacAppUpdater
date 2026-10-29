import AppUpdaterCore
import SwiftUI

/// Warnings grouped by severity: a severity pill above an inset glass list with hairline rows.
struct InsightsWarningsSection: View {
    let groups: [WarningGroup]
    let onSelectApp: (InstalledApp) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    StatusPill(
                        title: "\(group.severity.displayName) · \(group.entries.count)",
                        symbol: InsightsStyle.symbol(for: group.severity),
                        tint: InsightsStyle.color(for: group.severity)
                    )
                    VStack(spacing: 0) {
                        ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 {
                                GlassDivider(leadingInset: 56)
                            }
                            WarningCard(entry: entry, onSelectApp: onSelectApp, isEmbedded: true)
                        }
                    }
                    .padding(Theme.Spacing.xs)
                    .surface(.inset, radius: Theme.Radius.m)
                }
            }
        }
    }
}

/// One warning: app icon with a severity badge, title, explanation and suggested action.
/// Standalone it draws its own tinted glass card; `isEmbedded` renders it as a list row.
struct WarningCard: View {
    let entry: AppWarningEntry
    let onSelectApp: (InstalledApp) -> Void
    var isEmbedded = false

    @State private var isHovered = false

    private var tint: Color { InsightsStyle.color(for: entry.warning.severity) }

    var body: some View {
        Button { onSelectApp(entry.app) } label: {
            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                appIcon
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HStack(spacing: Theme.Spacing.s) {
                        Text(entry.app.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(1)
                        StatusPill(title: entry.warning.title, tint: tint)
                    }
                    Text(entry.warning.explanation)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Label(entry.warning.suggestedAction, systemImage: "arrow.turn.down.right")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .opacity(isHovered ? 1 : 0)
                    .offset(x: isHovered ? 0 : -3)
            }
            .padding(Theme.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { background }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(Theme.Motion.hover, value: isHovered)
    }

    private var appIcon: some View {
        Image(nsImage: InsightsStyle.icon(for: entry.app))
            .resizable()
            .interpolation(.high)
            .frame(width: 32, height: 32)
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: InsightsStyle.symbol(for: entry.warning.severity))
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(Theme.gradient(for: tint)))
                    .overlay(Circle().strokeBorder(Theme.Palette.canvas, lineWidth: 1.5))
                    .glow(tint, radius: 4, opacity: 0.6)
                    .offset(x: 4, y: 4)
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
        if isEmbedded {
            shape.fill(isHovered ? Theme.Palette.hoverFill : .clear)
        } else {
            shape
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(isHovered ? 0.16 : 0.10), tint.opacity(0.03)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(shape.strokeBorder(tint.opacity(isHovered ? 0.32 : 0.2), lineWidth: 1))
        }
    }
}
