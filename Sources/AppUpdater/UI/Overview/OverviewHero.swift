import AppUpdaterCore
import SwiftUI

/// Borderless hero of the Overview: a large health orb with the headline and the main call to action,
/// drawn straight on the backdrop. Orb left + copy right on wide windows, stacked and centered otherwise.
struct OverviewHero: View {
    let viewModel: UpdatesViewModel
    let health: OverviewHealth

    private static let orbDiameter: CGFloat = 220
    private static let copyMaxWidth: CGFloat = 460

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Theme.Spacing.xxxl) {
                orb
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    copy(alignment: .leading)
                    actions
                }
                .frame(width: Self.copyMaxWidth, alignment: .leading)
            }
            VStack(alignment: .center, spacing: Theme.Spacing.xl) {
                orb
                copy(alignment: .center)
                actions
            }
            .frame(maxWidth: Self.copyMaxWidth)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Orb

    private var orb: some View {
        ScanOrb(
            tint: health.tint,
            isActive: viewModel.isBusy,
            diameter: Self.orbDiameter,
            progress: health.score
        ) {
            VStack(spacing: Theme.Spacing.xxs) {
                if viewModel.isBusy {
                    ProgressView().controlSize(.regular).tint(.white)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(health.percent)")
                            .font(Theme.Typography.numeral(64))
                            .contentTransition(.numericText())
                        Text(verbatim: "%")
                            .font(Theme.Typography.numeral(26))
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .foregroundStyle(Theme.textGradient)
                    .glow(health.tint, radius: 18, opacity: 0.45)
                    Text(health.rating.uppercased())
                        .font(Theme.Typography.eyebrow)
                        .tracking(1.4)
                        .foregroundStyle(health.tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(width: Self.orbDiameter * 0.62)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Health score")
        .accessibilityValue("\(health.percent) percent, \(health.rating)")
    }

    // MARK: Copy

    private func copy(alignment: HorizontalAlignment) -> some View {
        let textAlignment: TextAlignment = alignment == .center ? .center : .leading
        return VStack(alignment: alignment, spacing: Theme.Spacing.s) {
            Text("CHECK-UP")
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
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.opacity)
        }
    }

    private var headline: String {
        let count = viewModel.pendingUpdates.count
        switch viewModel.state {
        case .idle, .scanning: return String(localized: "Scanning your apps…")
        case .checking: return String(localized: "Checking for updates…")
        case .failed: return String(localized: "Couldn't check for updates")
        case .loaded:
            if count == 0 { return String(localized: "Everything is up to date") }
            return count == 1 ? String(localized: "1 update ready") : String(localized: "\(count) updates ready")
        }
    }

    private var detail: String {
        if case .failed(let message) = viewModel.state { return message }
        var parts: [String] = []
        if health.warnings > 0 { parts.append(String(localized: "\(health.warnings) warnings")) }
        if health.untrackedApps > 0 { parts.append(String(localized: "\(health.untrackedApps) untracked apps")) }
        if let lastChecked = viewModel.lastChecked {
            parts.append(String(localized: "Checked \(lastChecked.formatted(.relative(presentation: .named)))"))
        }
        return parts.isEmpty
            ? String(localized: "\(viewModel.installedApps.count) apps on this Mac.")
            : parts.joined(separator: " · ")
    }

    // MARK: Actions

    /// "Update All" leads when something is installable; otherwise "Check Now" is the primary action.
    @ViewBuilder
    private var actions: some View {
        HStack(spacing: Theme.Spacing.m) {
            if viewModel.installableUpdates.isEmpty {
                checkButton.buttonStyle(.primary)
            } else {
                Button {
                    Task { await viewModel.installAll() }
                } label: {
                    Label("Update All", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.primary)
                checkButton.buttonStyle(.secondary)
            }
        }
        .controlSize(.large)
        .animation(Theme.Motion.content, value: viewModel.installableUpdates.isEmpty)
    }

    private var checkButton: some View {
        Button {
            Task { await viewModel.refresh() }
        } label: {
            Label("Check Now", systemImage: "arrow.clockwise")
        }
        .disabled(viewModel.isBusy)
    }
}
