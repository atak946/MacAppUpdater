import AppKit
import AppUpdaterCore
import SwiftUI

/// Ignored apps and skipped versions, each with a way to bring updates back.
struct ExcludedView: View {
    let viewModel: UpdatesViewModel

    var body: some View {
        Group {
            if isEmpty {
                EmptyStateView(
                    symbol: "eye",
                    title: String(localized: "Nothing excluded"),
                    message: String(localized: "Right-click an update to skip a version or ignore an app.")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                        PageHeader(title: String(localized: "Excluded"), subtitle: summary) { EmptyView() }
                        if !ignoredIDs.isEmpty {
                            section(
                                eyebrow: String(localized: "Never updated"),
                                title: String(localized: "Ignored apps"),
                                count: ignoredIDs.count,
                                tint: Theme.Palette.brandSecondary
                            ) {
                                ForEach(Array(ignoredIDs.enumerated()), id: \.element) { index, bundleID in
                                    divider(before: index)
                                    row(
                                        bundleID: bundleID, detail: String(localized: "All versions"),
                                        symbol: "eye.slash", tint: Theme.Palette.brandSecondary
                                    )
                                }
                            }
                        }
                        if !skipped.isEmpty {
                            section(
                                eyebrow: String(localized: "Newer releases will show up again"),
                                title: String(localized: "Skipped versions"),
                                count: skipped.count,
                                tint: Theme.Palette.info
                            ) {
                                ForEach(Array(skipped.enumerated()), id: \.element.key) { index, entry in
                                    divider(before: index)
                                    row(
                                        bundleID: entry.key,
                                        detail: String(localized: "Skipping \(entry.value)"),
                                        symbol: "forward.end",
                                        tint: Theme.Palette.info
                                    )
                                }
                            }
                        }
                        if !ceilings.isEmpty {
                            section(
                                eyebrow: String(localized: "Newer major or minor versions are held back"),
                                title: String(localized: "Version ceilings"),
                                count: ceilings.count,
                                tint: Theme.Palette.warning
                            ) {
                                ForEach(Array(ceilings.enumerated()), id: \.element.bundleID) { index, entry in
                                    divider(before: index)
                                    row(
                                        bundleID: entry.bundleID,
                                        detail: String(localized: "Staying on \(entry.ceiling).x"),
                                        symbol: "arrow.down.to.line",
                                        tint: Theme.Palette.warning,
                                        actionTitle: "Remove Ceiling"
                                    ) {
                                        viewModel.removeCeiling(entry.bundleID)
                                    }
                                }
                            }
                        }
                    }
                    .padding(Theme.Spacing.page)
                    .frame(maxWidth: Theme.Spacing.contentWidth)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .pageBackground()
    }

    // MARK: Layout

    private var summary: String {
        let total = ignoredIDs.count + skipped.count + ceilings.count
        return total == 1
            ? String(localized: "1 rule keeps updates out of your way")
            : String(localized: "\(total) rules keep updates out of your way")
    }

    /// Section header with a tinted count pill over one glass card of rows; the tint blooms in the card corner.
    private func section<Rows: View>(
        eyebrow: String, title: String, count: Int, tint: Color, @ViewBuilder rows: () -> Rows
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeader(eyebrow: eyebrow, title: title) {
                StatusPill(title: "\(count)", tint: tint).monospacedDigit()
            }
            VStack(spacing: 0) { rows() }
                .padding(.vertical, Theme.Spacing.s)
                .background(
                    RadialGradient(colors: [tint.opacity(0.12), .clear], center: .topLeading, startRadius: 0, endRadius: 260)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
                )
                .surface(.raised)
        }
    }

    @ViewBuilder
    private func divider(before index: Int) -> some View {
        if index > 0 {
            GlassDivider(leadingInset: 62)
                .padding(.trailing, Theme.Spacing.l)
        }
    }

    // MARK: Data

    private var isEmpty: Bool { ignoredIDs.isEmpty && skipped.isEmpty && ceilings.isEmpty }

    private var ceilings: [(bundleID: String, ceiling: String)] {
        viewModel.versionCeilings.sorted { name(for: $0.bundleID) < name(for: $1.bundleID) }
    }

    private var ignoredIDs: [String] {
        viewModel.exclusions.ignoredBundleIdentifiers.sorted { name(for: $0) < name(for: $1) }
    }

    private var skipped: [(key: String, value: String)] {
        viewModel.exclusions.skippedVersions.sorted { name(for: $0.key) < name(for: $1.key) }
    }

    private func app(for bundleID: String) -> InstalledApp? {
        viewModel.installedApps.first { $0.bundleIdentifier == bundleID }
    }

    /// Falls back to the bundle id when the app is no longer installed or not scanned yet.
    private func name(for bundleID: String) -> String {
        app(for: bundleID)?.name ?? bundleID
    }

    /// `onInclude` defaults to `include` (removes the ignore/skip; the version ceiling is kept).
    private func row(
        bundleID: String,
        detail: String,
        symbol: String,
        tint: Color,
        actionTitle: LocalizedStringKey = "Include Again",
        onInclude: (() -> Void)? = nil
    ) -> some View {
        ExcludedRow(
            name: name(for: bundleID), detail: detail, symbol: symbol, tint: tint,
            icon: app(for: bundleID).map(viewModel.icon(for:))
        ) {
            if onInclude == nil, viewModel.isIgnoreLocked(bundleID) {
                ManagedLockBadge(help: String(localized: "Ignored by your organization"))
            } else {
                Button(actionTitle) { (onInclude ?? { viewModel.include(bundleID) })() }
                    .buttonStyle(.secondary)
                    .controlSize(.small)
            }
        }
    }
}

/// One excluded app: icon, name, rule detail and a trailing action, with a hover highlight.
private struct ExcludedRow<Action: View>: View {
    let name: String
    let detail: String
    let symbol: String
    let tint: Color
    /// Nil when the app is no longer installed or not scanned yet.
    let icon: NSImage?
    @ViewBuilder var action: Action

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Group {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1.5)
                } else {
                    Image(systemName: "questionmark.app.dashed")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: symbol)
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(tint)
                    Text(detail)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .font(.system(size: 11.5))
                .lineLimit(1)
            }
            Spacer(minLength: Theme.Spacing.m)
            action
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
        .hoverHighlight(isHovered)
        .padding(.horizontal, Theme.Spacing.s)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
