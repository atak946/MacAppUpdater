import MaintenanceCore
import SwiftUI

/// Borderless hero: the security score orb, a headline and "Run Check". Orb left + copy right on
/// wide windows, stacked and centered otherwise.
struct SecurityHero: View {
    let model: SecurityModel

    private static let orbDiameter: CGFloat = 200
    private static let copyMaxWidth: CGFloat = 440

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Theme.Spacing.xxxl) {
                orb
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    copy(alignment: .leading)
                    runButton
                }
                .frame(width: Self.copyMaxWidth, alignment: .leading)
            }
            VStack(alignment: .center, spacing: Theme.Spacing.xl) {
                orb
                copy(alignment: .center)
                runButton
            }
            .frame(maxWidth: Self.copyMaxWidth)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Orb

    private var tint: Color { SecurityRating.tint(for: model.score) }

    private var orb: some View {
        ScanOrb(
            tint: tint,
            isActive: model.isChecking,
            diameter: Self.orbDiameter,
            progress: Double(model.score ?? 0) / 100
        ) {
            VStack(spacing: Theme.Spacing.xxs) {
                if model.isChecking {
                    ProgressView().controlSize(.regular).tint(.white)
                } else if let score = model.score {
                    Text("\(score)")
                        .font(Theme.Typography.numeral(60))
                        .contentTransition(.numericText())
                        .foregroundStyle(Theme.textGradient)
                    Text(SecurityRating.title(for: score).uppercased())
                        .font(Theme.Typography.eyebrow)
                        .tracking(1.4)
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } else {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(Theme.textGradient)
                }
            }
            .frame(width: Self.orbDiameter * 0.62)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Security score")
        .accessibilityValue(model.score.map { "\($0), \(SecurityRating.title(for: $0))" } ?? "")
    }

    // MARK: Copy

    private func copy(alignment: HorizontalAlignment) -> some View {
        let textAlignment: TextAlignment = alignment == .center ? .center : .leading
        return VStack(alignment: alignment, spacing: Theme.Spacing.s) {
            Text("SECURITY")
                .font(Theme.Typography.eyebrow)
                .tracking(1.6)
                .foregroundStyle(Theme.brandGradient)
            Text(headline)
                .font(Theme.Typography.hero)
                .tracking(Theme.Typography.displayTracking)
                .foregroundStyle(Theme.textGradient)
                .multilineTextAlignment(textAlignment)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
            Text(detail)
                .font(.system(size: 14))
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(textAlignment)
                .lineLimit(2)
                .contentTransition(.opacity)
        }
    }

    private var headline: String {
        if model.isChecking { return String(localized: "Checking your defenses…") }
        guard let report = model.report else { return String(localized: "How safe is your Mac?") }
        switch report.issues.count {
        case 0: return String(localized: "Your Mac is well protected")
        case 1: return String(localized: "1 setting needs attention")
        case let count: return String(localized: "\(count) settings need attention")
        }
    }

    private var detail: String {
        guard let report = model.report else {
            return String(localized: "Checks encryption, firewall, malware protection and app permissions.")
        }
        var parts = [String(localized: "Checked \(report.checkedAt.formatted(.relative(presentation: .named)))")]
        let flagged = model.flaggedCount
        if flagged > 0 { parts.append(String(localized: "\(flagged) permissions to review")) }
        return parts.joined(separator: " · ")
    }

    private var runButton: some View {
        Button(action: model.runCheck) {
            Label("Run Check", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.primary)
        .controlSize(.large)
        .disabled(model.isChecking)
    }
}
