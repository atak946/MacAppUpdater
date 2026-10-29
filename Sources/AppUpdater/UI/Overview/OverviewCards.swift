import AppUpdaterCore
import SwiftUI

/// Titled card used for the Overview's preview sections.
struct OverviewCard<Content: View>: View {
    let eyebrow: String
    let title: String
    var linkTitle: String?
    var onLink: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeader(eyebrow: eyebrow, title: title) {
                if let linkTitle, let onLink {
                    Button(action: onLink) {
                        HStack(spacing: 3) {
                            Text(linkTitle)
                            Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                        }
                    }
                    .buttonStyle(.secondary(tint: Theme.Palette.brand))
                    .controlSize(.small)
                }
            }
            content
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(.raised, radius: Theme.Radius.xl)
    }
}

/// Preview of the first pending updates, reusing the full update row.
struct OverviewReadyCard: View {
    let viewModel: UpdatesViewModel
    let onSeeAll: () -> Void

    private static let previewLimit = 4

    var body: some View {
        let updates = viewModel.pendingUpdates
        OverviewCard(
            eyebrow: String(localized: "Ready to update"),
            title: updates.isEmpty ? String(localized: "No pending updates") : String(localized: "\(updates.count) apps"),
            linkTitle: updates.count > 0 ? String(localized: "See all") : nil,
            onLink: onSeeAll
        ) {
            if updates.isEmpty {
                OverviewInlineEmpty(
                    symbol: "checkmark.seal.fill",
                    tint: Theme.Palette.success,
                    message: viewModel.isBusy
                        ? String(localized: "Looking for updates…")
                        : String(localized: "All your apps are on their latest version.")
                )
            } else {
                let preview = Array(updates.prefix(Self.previewLimit))
                VStack(spacing: Theme.Spacing.xxs) {
                    ForEach(Array(preview.enumerated()), id: \.element.id) { index, update in
                        if index > 0 { GlassDivider(leadingInset: 60) }
                        UpdateRowView(update: update, viewModel: viewModel)
                    }
                }
            }
        }
    }
}

/// The most recent install, revert and failure records.
struct OverviewRecentCard: View {
    let viewModel: UpdatesViewModel
    let onSeeAll: () -> Void
    let onSelect: (UpdateHistoryEntry) -> Void

    private static let previewLimit = 4

    var body: some View {
        let entries = Array(viewModel.history.prefix(Self.previewLimit))
        OverviewCard(
            eyebrow: String(localized: "History"),
            title: String(localized: "Recently updated"),
            linkTitle: entries.isEmpty ? nil : String(localized: "See all"),
            onLink: onSeeAll
        ) {
            if entries.isEmpty {
                OverviewInlineEmpty(
                    symbol: "clock.arrow.circlepath",
                    tint: Theme.Palette.info,
                    message: String(localized: "Updates you install will appear here.")
                )
            } else {
                VStack(spacing: Theme.Spacing.xxs) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { GlassDivider(leadingInset: 52) }
                        OverviewHistoryRow(entry: entry, icon: icon(for: entry)) { onSelect(entry) }
                    }
                }
            }
        }
    }

    private func icon(for entry: UpdateHistoryEntry) -> NSImage? {
        viewModel.installedApps.first { $0.bundleIdentifier == entry.bundleID }.map(viewModel.icon(for:))
    }
}

/// One history entry: app icon, version change and outcome.
private struct OverviewHistoryRow: View {
    let entry: UpdateHistoryEntry
    let icon: NSImage?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.m) {
                appIcon
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.appName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                    Text("\(entry.fromVersion) → \(entry.toVersion)")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.Spacing.s)
                VStack(alignment: .trailing, spacing: Theme.Spacing.xs) {
                    outcomePill
                    Text(entry.date.formatted(.relative(presentation: .named)))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, Theme.Spacing.xs + 2)
            .hoverHighlight(isHovered)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1.5)
        } else {
            IconTile(symbol: "app.dashed", tint: Theme.Palette.brand, size: 32)
        }
    }

    @ViewBuilder
    private var outcomePill: some View {
        switch entry.outcome {
        case .succeeded:
            StatusPill(title: String(localized: "Updated"), symbol: "checkmark", tint: Theme.Palette.success)
        case .failed:
            StatusPill(title: String(localized: "Failed"), symbol: "xmark", tint: Theme.Palette.danger)
        case .rolledBack:
            StatusPill(title: String(localized: "Reverted"), symbol: "arrow.uturn.backward", tint: Theme.Palette.warning)
        }
    }
}

/// Quiet one-line empty state inside an Overview card.
private struct OverviewInlineEmpty: View {
    let symbol: String
    let tint: Color
    let message: String

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            IconTile(symbol: symbol, tint: tint, size: 32, glows: true)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.m)
        .surface(.inset, radius: Theme.Radius.m)
    }
}
