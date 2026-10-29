import AppUpdaterCore
import SwiftUI

/// The stat row that opens the dashboard: apps, disk use, warnings.
struct InsightsHeadline: View {
    let report: InsightsReport

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Theme.Spacing.m) { tiles }
            VStack(alignment: .leading, spacing: Theme.Spacing.m) { tiles }
        }
    }

    @ViewBuilder
    private var tiles: some View {
        StatTile(
            value: report.totalApps.formatted(),
            label: String(localized: "apps installed"),
            symbol: "square.grid.2x2.fill",
            tint: Theme.Palette.brand
        )
        .frame(minWidth: 200)
        StatTile(
            value: InsightsStyle.bytes(report.totalSizeInBytes),
            label: String(localized: "on disk"),
            symbol: "internaldrive.fill",
            tint: Theme.Palette.brandSecondary
        )
        .frame(minWidth: 200)
        StatTile(
            value: report.totalWarnings.formatted(),
            label: report.totalWarnings == 1 ? String(localized: "warning") : String(localized: "warnings"),
            symbol: report.totalWarnings == 0 ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
            tint: warningTint
        )
        .frame(minWidth: 200)
    }

    private var warningTint: Color {
        report.warningGroups.first.map { InsightsStyle.color(for: $0.severity) } ?? Theme.Palette.success
    }
}
