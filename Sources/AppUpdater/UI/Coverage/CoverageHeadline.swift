import AppUpdaterCore
import SwiftUI

/// Hero card: glowing coverage orb, tracked vs untracked split and the per-source breakdown.
struct CoverageHeadline: View {
    let report: CoverageReport

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Theme.Spacing.xxl) { ring; breakdown }
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) { ring; breakdown }
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            // Tint bloom behind the ring.
            RadialGradient(colors: [tint.opacity(0.22), .clear], center: .leading, startRadius: 0, endRadius: 320)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
        )
        .surface(.elevated, radius: Theme.Radius.xl)
    }

    /// Tint reflects how healthy coverage is.
    private var tint: Color {
        switch report.trackedFraction {
        case 0.8...: Theme.Palette.success
        case 0.5..<0.8: Theme.Palette.brand
        default: Theme.Palette.warning
        }
    }

    private var ring: some View {
        ScanOrb(tint: tint, diameter: 150, progress: report.trackedFraction) {
            VStack(spacing: 0) {
                Text("\(report.trackedPercentage)%")
                    .font(Theme.Typography.numeral(36))
                    .foregroundStyle(Theme.textGradient)
                    .contentTransition(.numericText())
                Text("tracked")
                    .font(Theme.Typography.eyebrow)
                    .tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(report.trackedPercentage) percent of apps tracked")
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Text("\(report.trackedCount) of \(report.totalApps) apps have an update source")
                .font(.system(size: 22, weight: .bold))
                .tracking(Theme.Typography.displayTracking / 2)
                .foregroundStyle(Theme.textGradient)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Spacing.xl) {
                splitStat(value: report.trackedCount, label: String(localized: "covered"), tint: tint)
                splitStat(value: report.untracked.count, label: String(localized: "untracked"), tint: Theme.Palette.textTertiary)
            }
            FlowingSourceChips(sources: report.bySource)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func splitStat(value: Int, label: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
            Circle().fill(tint).frame(width: 7, height: 7).glow(tint, radius: 4, opacity: 0.8)
            Text(value.formatted())
                .font(Theme.Typography.numeral(20))
                .foregroundStyle(Theme.Palette.textPrimary)
                .contentTransition(.numericText())
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One capsule per source: "Sparkle 42".
private struct FlowingSourceChips: View {
    let sources: [SourceCoverage]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)],
            alignment: .leading,
            spacing: Theme.Spacing.s
        ) {
            ForEach(sources) { source in
                chip(label: source.source.coverageLabel, count: source.apps.count)
            }
        }
    }

    private func chip(label: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.Palette.textSecondary)
            Text(count.formatted())
                .font(Theme.Typography.numeral(13))
                .foregroundStyle(Theme.Palette.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Theme.Palette.hairline, lineWidth: 1))
    }
}

extension UpdateSourceKind {
    /// Lookup instead of a switch so new source kinds never break this file.
    private static let coverageLabels: [UpdateSourceKind: String] = [
        .sparkle: "Sparkle", .homebrew: "Homebrew", .github: "GitHub",
        .appStore: "App Store", .electron: "Electron", .vendor: String(localized: "Vendor feed"),
    ]

    var coverageLabel: String { Self.coverageLabels[self] ?? rawValue.capitalized }
}
