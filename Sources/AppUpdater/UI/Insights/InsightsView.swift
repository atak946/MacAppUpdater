import AppUpdaterCore
import SwiftUI

/// Dark glass dashboard over the user's app library. Stateless: the caller owns loading.
struct InsightsView: View {
    let report: InsightsReport?
    let isLoading: Bool
    let onSelectApp: (InstalledApp) -> Void
    let onRefresh: () -> Void

    var body: some View {
        Group {
            if let report {
                content(report)
            } else if isLoading {
                EmptyStateView(
                    symbol: nil,
                    title: String(localized: "Analyzing your apps…"),
                    message: String(localized: "Measuring bundle sizes, launch dates and architectures.")
                )
            } else {
                EmptyStateView(
                    symbol: "chart.bar.xaxis",
                    title: String(localized: "No insights yet"),
                    message: String(localized: "Scan your applications to see disk usage, unused apps and compatibility warnings."),
                    actionTitle: String(localized: "Analyze Apps"),
                    action: onRefresh
                )
            }
        }
        .pageBackground()
    }

    private func content(_ report: InsightsReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: InsightsStyle.sectionSpacing) {
                PageHeader(
                    title: String(localized: "Your library, at a glance"),
                    subtitle: String(localized: "Updated \(report.generatedAt.formatted(.relative(presentation: .named)))")
                ) {
                    refreshButton
                }
                InsightsHeadline(report: report)
                if !report.largestApps.isEmpty {
                    InsightsCard(eyebrow: String(localized: "Disk"), title: String(localized: "Largest apps")) {
                        LargestAppsChart(apps: report.largestApps, onSelectApp: onSelectApp)
                    }
                }
                InsightsListsRow(report: report, onSelectApp: onSelectApp)
                if !report.warningGroups.isEmpty {
                    InsightsCard(
                        eyebrow: String(localized: "Health"),
                        title: String(localized: "Warnings"),
                        trailing: "\(report.totalWarnings)"
                    ) {
                        InsightsWarningsSection(groups: report.warningGroups, onSelectApp: onSelectApp)
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

/// Unused and Intel-only lists, side by side when there is room.
private struct InsightsListsRow: View {
    let report: InsightsReport
    let onSelectApp: (InstalledApp) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Theme.Spacing.l) { lists }
            VStack(alignment: .leading, spacing: InsightsStyle.sectionSpacing) { lists }
        }
    }

    @ViewBuilder
    private var lists: some View {
        list(eyebrow: String(localized: "Dormant"), title: String(localized: "Not opened in 90+ days"), apps: report.unusedApps,
             empty: String(localized: "Every app has been used recently.")) { insight in
            insight.lastUsedDate.map { $0.formatted(.relative(presentation: .named)) } ?? "—"
        }
        list(eyebrow: String(localized: "Rosetta"), title: String(localized: "Intel-only apps"), apps: report.intelOnlyApps,
             empty: String(localized: "Everything runs natively on Apple Silicon.")) { insight in
            InsightsStyle.bytes(insight.sizeInBytes)
        }
    }

    private func list(
        eyebrow: String, title: String, apps: [AppInsight], empty: String,
        detail: @escaping (AppInsight) -> String
    ) -> some View {
        InsightsCard(eyebrow: eyebrow, title: title, trailing: "\(apps.count)", contentPadding: Theme.Spacing.s) {
            if apps.isEmpty {
                InsightsAllClear(message: empty)
                    .padding(.horizontal, Theme.Spacing.s)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(apps.enumerated()), id: \.element.id) { index, insight in
                        if index > 0 {
                            GlassDivider(leadingInset: 44)
                        }
                        InsightsAppRow(app: insight.app, detail: detail(insight), onSelect: onSelectApp)
                    }
                }
            }
        }
        .frame(minWidth: 300, maxWidth: .infinity, alignment: .topLeading)
    }
}
