import AppKit
import AppUpdaterCore
import SwiftUI

/// One history entry: app icon, name, version delta, outcome pill and time.
struct HistoryRow: View {
    let entry: UpdateHistoryEntry
    var onSelect: ((UpdateHistoryEntry) -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.m) {
            HistoryAppIcon(bundleID: entry.bundleID, outcome: entry.outcome)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Spacing.s) {
                    Text(entry.appName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                    StatusPill(title: outcome.label, symbol: outcome.symbol, tint: outcome.tint)
                }
                versionDelta
                if case .failed(let message) = entry.outcome {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.danger)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: Theme.Spacing.s)
            VStack(alignment: .trailing, spacing: 3) {
                Text(entry.date.formatted(date: .omitted, time: .shortened))
                    .font(Theme.Typography.numeral(12))
                    .foregroundStyle(Theme.Palette.textSecondary)
                if let source = entry.source {
                    Text(source.coverageLabel)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            if onSelect != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .opacity(isHovered ? 1 : 0)
                    .offset(x: isHovered ? 0 : -3)
            }
        }
        .padding(.vertical, Theme.Spacing.s)
        .padding(.horizontal, Theme.Spacing.m)
        .contentShape(Rectangle())
        .hoverHighlight(isHovered)
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { onSelect?(entry) }
        .help(onSelect == nil ? outcome.label : String(localized: "Double-click to show \(entry.appName)"))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(onSelect == nil ? [] : .isButton)
        .accessibilityAction { onSelect?(entry) }
    }

    private var versionDelta: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(entry.fromVersion).foregroundStyle(Theme.Palette.textTertiary)
            Image(systemName: entry.outcome == .rolledBack ? "arrow.uturn.left" : "arrow.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(entry.toVersion)
                .fontWeight(.medium)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .font(.system(size: 11, design: .monospaced))
        .lineLimit(1)
    }

    private var outcome: HistoryOutcomeStyle { HistoryOutcomeStyle(entry.outcome) }
}

/// Label, symbol and tint for an entry outcome.
struct HistoryOutcomeStyle {
    let label: String
    let symbol: String
    let tint: Color

    init(_ outcome: UpdateHistoryEntry.Outcome) {
        switch outcome {
        case .succeeded:
            label = String(localized: "Updated")
            symbol = "checkmark"
            tint = Theme.Palette.success
        case .failed:
            label = String(localized: "Failed")
            symbol = "xmark"
            tint = Theme.Palette.danger
        case .rolledBack:
            label = String(localized: "Rolled back")
            symbol = "arrow.uturn.backward"
            tint = Theme.Palette.warning
        }
    }
}

/// The installed app's icon (resolved from its bundle ID) with a small outcome badge;
/// falls back to a tinted tile when the app is no longer installed.
private struct HistoryAppIcon: View {
    let bundleID: String
    let outcome: UpdateHistoryEntry.Outcome

    var body: some View {
        icon
            .frame(width: 34, height: 34)
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            .overlay(alignment: .bottomTrailing) {
                let style = HistoryOutcomeStyle(outcome)
                Image(systemName: style.symbol)
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(Theme.gradient(for: style.tint)))
                    .overlay(Circle().strokeBorder(Theme.Palette.canvas, lineWidth: 1.5))
                    .glow(style.tint, radius: 4, opacity: 0.6)
                    .offset(x: 4, y: 4)
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var icon: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .interpolation(.high)
        } else {
            IconTile(symbol: "app.dashed", tint: Theme.Palette.brand, size: 30)
        }
    }
}
