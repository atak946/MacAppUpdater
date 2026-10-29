import AppUpdaterCore
import SwiftUI

/// Apps no source recognised, each with mapping / search / report / ignore actions.
struct CoverageUntrackedList: View {
    let apps: [InstalledApp]
    let ignoredCount: Int
    let actions: CoverageActions

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            if apps.isEmpty {
                InsightsAllClear(message: String(localized: "Every app has an update source."))
                    .padding(.horizontal, Theme.Spacing.s)
            } else {
                ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                    if index > 0 {
                        GlassDivider(leadingInset: 50)
                    }
                    UntrackedAppRow(app: app, actions: actions)
                }
            }
            if ignoredCount > 0 {
                Text(ignoredCount == 1
                     ? String(localized: "1 ignored app hidden")
                     : String(localized: "\(ignoredCount) ignored apps hidden"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .padding(.horizontal, Theme.Spacing.s)
                    .padding(.top, Theme.Spacing.xs)
            }
        }
    }
}

private struct UntrackedAppRow: View {
    let app: InstalledApp
    let actions: CoverageActions

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Button { actions.selectApp(app) } label: {
                HStack(spacing: Theme.Spacing.m) {
                    Image(nsImage: InsightsStyle.icon(for: app))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 30, height: 30)
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(1)
                        Text("\(app.bundleIdentifier) · \(app.shortVersion)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            rowActions
        }
        .padding(.vertical, Theme.Spacing.s)
        .padding(.horizontal, Theme.Spacing.s)
        .hoverHighlight(isHovered)
        .onHover { isHovered = $0 }
    }

    private var rowActions: some View {
        HStack(spacing: 6) {
            Button("Map GitHub Repo…") { actions.mapGitHubRepo(app) }
                .buttonStyle(.secondary)
            Button("Search Homebrew") { actions.searchHomebrew(app) }
                .buttonStyle(.secondary)
            Menu {
                Button("Report Missing App", systemImage: "exclamationmark.bubble") { actions.reportMissing(app) }
                Divider()
                Button("Ignore", systemImage: "eye.slash") { actions.ignore(app) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("More actions")
        }
        .controlSize(.small)
    }
}

/// Sources that threw while checking, with the raw error text.
struct CoverageFailedList: View {
    let checks: [FailedCoverageCheck]
    let onSelectApp: (InstalledApp) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(checks.enumerated()), id: \.element.id) { index, check in
                if index > 0 {
                    GlassDivider(leadingInset: 50)
                }
                Button { onSelectApp(check.app) } label: { FailedCheckCard(check: check) }
                    .buttonStyle(.plain)
            }
        }
    }
}

private struct FailedCheckCard: View {
    let check: FailedCoverageCheck

    @State private var isHovered = false

    private var tint: Color { check.fallbackSource == nil ? Theme.Palette.danger : Theme.Palette.warning }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            Image(nsImage: InsightsStyle.icon(for: check.app))
                .resizable()
                .interpolation(.high)
                .frame(width: 30, height: 30)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(Theme.gradient(for: tint)))
                        .overlay(Circle().strokeBorder(Theme.Palette.canvas, lineWidth: 1.5))
                        .glow(tint, radius: 4, opacity: 0.6)
                        .offset(x: 4, y: 4)
                }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.s) {
                    Text(check.app.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    if let fallback = check.fallbackSource {
                        StatusPill(
                            title: String(localized: "still tracked via \(fallback.coverageLabel)"),
                            symbol: "arrow.triangle.branch",
                            tint: Theme.Palette.warning
                        )
                    }
                }
                ForEach(check.errors, id: \.self) { error in
                    Text(error)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hoverHighlight(isHovered)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(Theme.Motion.hover, value: isHovered)
    }
}
