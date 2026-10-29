import AppUpdaterCore
import SwiftUI

/// Updates list for the main window: a summary header over one grouped card of rows.
struct UpdatesListView: View {
    let viewModel: UpdatesViewModel
    let updates: [AvailableUpdate]

    var body: some View {
        let ordered = Self.securityFirst(updates)
        Group {
            if ordered.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                        UpdatesSummaryHeader(viewModel: viewModel, updates: ordered)
                        rowsCard(ordered)
                    }
                    .padding(Theme.Spacing.page)
                    .frame(maxWidth: Theme.Spacing.contentWidth)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .pageBackground()
    }

    /// Security updates float to the top; the stable partition keeps the incoming order otherwise.
    static func securityFirst(_ updates: [AvailableUpdate]) -> [AvailableUpdate] {
        updates.filter { $0.securityInfo != nil } + updates.filter { $0.securityInfo == nil }
    }

    /// Rows share one raised card, separated by inset hairlines.
    private func rowsCard(_ updates: [AvailableUpdate]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(updates.enumerated()), id: \.element.id) { index, update in
                if index > 0 {
                    GlassDivider(leadingInset: 72)
                        .padding(.trailing, Theme.Spacing.l)
                }
                UpdateRowView(update: update, viewModel: viewModel)
                    .padding(.horizontal, Theme.Spacing.s)
                    .padding(.vertical, Theme.Spacing.xs)
            }
        }
        .padding(.vertical, Theme.Spacing.s)
        .surface(.raised)
    }

    @ViewBuilder
    private var emptyState: some View {
        switch viewModel.state {
        case .idle, .scanning, .checking:
            EmptyStateView(
                symbol: nil,
                title: String(localized: "Looking for updates…"),
                message: String(localized: "Checking every app against its update source.")
            )
        case .failed(let message):
            EmptyStateView(
                symbol: "exclamationmark.triangle.fill",
                tint: Theme.Palette.warning,
                title: String(localized: "Couldn't check for updates"),
                message: message,
                actionTitle: String(localized: "Try Again"),
                action: { Task { await viewModel.refresh() } }
            )
        case .loaded:
            EmptyStateView(
                symbol: "checkmark.seal.fill",
                tint: Theme.Palette.success,
                title: String(localized: "Everything is up to date"),
                message: String(localized: "\(viewModel.installedApps.count) apps checked. Nice and tidy.")
            )
        }
    }
}

/// Big glowing gradient count with "Ready to install · 1.2 GB to download" and the page's single primary action.
private struct UpdatesSummaryHeader: View {
    let viewModel: UpdatesViewModel
    let updates: [AvailableUpdate]

    @State private var isInstallingAll = false

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.l) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text("Updates")
                    .textCase(.uppercase)
                    .font(Theme.Typography.eyebrow)
                    .tracking(1.4)
                    .foregroundStyle(Theme.Palette.textTertiary)
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
                    Text(verbatim: "\(updates.count)")
                        .font(Theme.Typography.numeral(64))
                        .tracking(-1.5)
                        .foregroundStyle(Theme.brandGradient)
                        .glow(Theme.Palette.brand, radius: 22, opacity: 0.45)
                        .contentTransition(.numericText())
                    Text(updates.count == 1 ? String(localized: "update available") : String(localized: "updates available"))
                        .font(.system(size: 22, weight: .bold))
                        .tracking(Theme.Typography.displayTracking)
                        .foregroundStyle(Theme.textGradient)
                }
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .contentTransition(.opacity)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: "\(title), \(subtitle)"))
            Spacer(minLength: Theme.Spacing.l)
            Button(action: installAll) {
                Label("Update All", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.primary)
            .controlSize(.large)
            .disabled(installable.isEmpty || isInstallingAll)
            .help(installable.isEmpty
                ? String(localized: "These updates need your attention one by one")
                : String(localized: "Install \(installable.count) updates one after another"))
            .padding(.bottom, Theme.Spacing.xxs)
        }
        .padding(.bottom, Theme.Spacing.xs)
    }

    private var title: String {
        updates.count == 1
            ? String(localized: "1 update")
            : String(localized: "\(updates.count) updates")
    }

    /// Size covers only updates whose download size the server reported.
    private var subtitle: String {
        let sizes = updates.compactMap { viewModel.downloadSizes[$0.id] }
        let pending = updates.filter { viewModel.installState(for: $0) != .installed }.count
        var parts = [pending == updates.count
            ? String(localized: "Ready to install")
            : String(localized: "\(pending) still to install")]
        if !sizes.isEmpty {
            let total = DownloadStatus.bytes(sizes.reduce(0, +))
            parts.append(sizes.count == updates.count
                ? String(localized: "\(total) to download")
                : String(localized: "At least \(total) to download"))
        }
        let security = updates.filter { $0.securityInfo != nil }.count
        if security > 0 {
            parts.append(security == 1
                ? String(localized: "1 security update")
                : String(localized: "\(security) security updates"))
        }
        return parts.joined(separator: " · ")
    }

    /// Installable updates limited to the ones this page shows (a source filter may apply).
    private var installable: [AvailableUpdate] {
        let shown = Set(updates.map(\.id))
        return viewModel.installableUpdates.filter { shown.contains($0.id) }
    }

    /// Sequential, like `installAll`, to avoid competing disk images.
    private func installAll() {
        let queue = installable
        isInstallingAll = true
        Task {
            for update in queue { await viewModel.install(update) }
            isInstallingAll = false
        }
    }
}
