import MaintenanceCore
import SwiftUI

/// Compact hero after a scan: small orb, the selected size as a huge gradient numeral and the actions.
struct CleanupSummaryHero: View {
    let report: CleanupScanReport
    let model: CleanupModel
    let onClean: () -> Void

    private static let orbDiameter: CGFloat = 112

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Theme.Spacing.xl) {
                orb
                summary(alignment: .leading)
                Spacer(minLength: Theme.Spacing.l)
                actions
            }
            VStack(spacing: Theme.Spacing.l) {
                orb
                summary(alignment: .center)
                actions
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Orb

    private var orb: some View {
        ScanOrb(tint: Theme.Palette.brandSecondary, diameter: Self.orbDiameter, progress: fraction) {
            Image(systemName: "sparkles")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [.white, Theme.Palette.brandSecondary], startPoint: .top, endPoint: .bottom))
                .glow(Theme.Palette.brandSecondary, radius: 12, opacity: 0.6)
        }
        .accessibilityHidden(true)
    }

    /// Share of the found space that is selected; drives the orb's ring.
    private var fraction: Double {
        guard report.totalSize > 0 else { return 0 }
        return Double(model.selectedSize) / Double(report.totalSize)
    }

    // MARK: Summary

    private func summary(alignment: HorizontalAlignment) -> some View {
        let parts = CleanupFormat.splitBytes(model.selectedSize)
        return VStack(alignment: alignment, spacing: Theme.Spacing.xs) {
            Text("READY TO CLEAN")
                .font(Theme.Typography.eyebrow)
                .tracking(1.6)
                .foregroundStyle(Theme.brandGradient)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(parts.number)
                    .font(Theme.Typography.numeral(58))
                    .tracking(Theme.Typography.displayTracking)
                    .contentTransition(.numericText())
                Text(parts.unit)
                    .font(Theme.Typography.numeral(24))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .foregroundStyle(Theme.textGradient)
            .glow(Theme.Palette.brandSecondary, radius: 18, opacity: 0.35)
            .animation(Theme.Motion.content, value: model.selectedSize)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
                .contentTransition(.opacity)
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let found = CleanupFormat.bytes(report.totalSize)
        let count = model.selectedItems.count
        return String(localized: "of \(found) found · \(count) items selected")
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: Theme.Spacing.m) {
            Button(action: model.startScan) {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.secondary)
            Button(action: onClean) {
                Label("Clean", systemImage: "sparkles")
            }
            .buttonStyle(.primary)
            .glow(Theme.Palette.brandSecondary, radius: 18, opacity: model.selectedSize > 0 ? 0.45 : 0)
            .disabled(model.selectedItems.isEmpty)
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .fixedSize()
    }
}
