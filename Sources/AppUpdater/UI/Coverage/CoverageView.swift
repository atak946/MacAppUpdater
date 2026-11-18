import AppUpdaterCore
import SwiftUI

/// Per-app actions offered for untracked apps. The caller owns persistence and navigation.
struct CoverageActions {
    var mapGitHubRepo: (InstalledApp) -> Void
    var searchHomebrew: (InstalledApp) -> Void
    var reportMissing: (InstalledApp) -> Void
    var ignore: (InstalledApp) -> Void
    var selectApp: (InstalledApp) -> Void
}

/// Dark glass page showing which apps the update sources cover and which they miss.
/// Stateless: the caller supplies the report (from `CoverageReport(results:)`) and the actions.
struct CoverageView: View {
    let report: CoverageReport?
    let isLoading: Bool
    let actions: CoverageActions
    let onRefresh: () -> Void
    /// Narrows the untracked and failed lists by app name or bundle id.
    @State private var searchText = ""

    var body: some View {
        Group {
            if let report, report.totalApps > 0 {
                content(report)
            } else if isLoading {
                EmptyStateView(
                    symbol: nil,
                    title: String(localized: "Checking sources…"),
                    message: String(localized: "Matching every app against Sparkle, Homebrew, GitHub and the App Store.")
                )
            } else {
                EmptyStateView(
                    symbol: "scope",
                    title: String(localized: "No coverage data"),
                    message: String(localized: "Check for updates to see which apps have a known update source."),
                    actionTitle: String(localized: "Check Now"),
                    action: onRefresh
                )
            }
        }
        .pageBackground()
    }

    private func content(_ report: CoverageReport) -> some View {
        let query = SearchQuery(searchText)
        let untracked = query.filter(report.untracked) { [$0.name, $0.bundleIdentifier] }
        let failed = query.filter(report.failed) { [$0.app.name, $0.app.bundleIdentifier] }
        return ScrollView {
            VStack(alignment: .leading, spacing: InsightsStyle.sectionSpacing) {
                PageHeader(
                    title: String(localized: "Update coverage"),
                    subtitle: String(localized: "Which of your apps we can keep current — and which we can't, yet.")
                ) {
                    refreshButton
                }
                CoverageHeadline(report: report)
                PageToolbar(
                    prompt: String(localized: "Search apps in coverage"),
                    search: $searchText,
                    shownCount: untracked.count + failed.count
                )
                InsightsCard(
                    eyebrow: String(localized: "Blind spots"),
                    title: String(localized: "No update source"),
                    trailing: "\(untracked.count)",
                    contentPadding: Theme.Spacing.s
                ) {
                    CoverageUntrackedList(
                        apps: untracked, ignoredCount: report.ignoredCount, actions: actions, isFiltered: !query.isEmpty
                    )
                }
                if !failed.isEmpty {
                    InsightsCard(
                        eyebrow: String(localized: "Errors"),
                        title: String(localized: "Checks that failed"),
                        trailing: "\(failed.count)"
                    ) {
                        CoverageFailedList(checks: failed, onSelectApp: actions.selectApp)
                    }
                }
            }
            .padding(InsightsStyle.pagePadding)
            .frame(maxWidth: Theme.Spacing.contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var refreshButton: some View {
        if isLoading {
            ProgressView().controlSize(.small).tint(.white)
        } else {
            Button(action: onRefresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.secondary)
        }
    }
}
