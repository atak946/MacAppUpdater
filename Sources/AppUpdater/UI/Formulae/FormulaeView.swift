import AppUpdaterCore
import SwiftUI

/// Outdated Homebrew formulae (command-line tools) with per-row and bulk upgrades.
struct FormulaeView: View {
    let model: FormulaeModel

    /// Homebrew's amber, used for every terminal-tool tile on this page.
    static let accent = Theme.Palette.warning

    private static let brewURL = URL(string: "https://brew.sh")!

    var body: some View {
        content
            .frame(minWidth: 420, minHeight: 300)
            .pageBackground()
            .task { if model.state == .idle { await model.refresh() } }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle,
             .loading where model.formulae.isEmpty:
            EmptyStateView(
                symbol: nil,
                tint: Self.accent,
                title: String(localized: "Checking command line tools…"),
                message: String(localized: "Asking Homebrew which formulae are outdated.")
            )
        case .unavailable:
            VStack(spacing: Theme.Spacing.s) {
                EmptyStateView(
                    symbol: "terminal",
                    tint: Self.accent,
                    title: String(localized: "Homebrew not installed"),
                    message: String(localized: "Command line tools are updated through Homebrew.")
                )
                .fixedSize(horizontal: false, vertical: true)
                Link("Get Homebrew at brew.sh", destination: Self.brewURL)
                    .buttonStyle(.primary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            EmptyStateView(
                symbol: "exclamationmark.triangle",
                tint: Theme.Palette.warning,
                title: String(localized: "Couldn't check formulae"),
                message: message,
                actionTitle: String(localized: "Try Again"),
                action: { Task { await model.refresh() } }
            )
            .textSelection(.enabled)
        default:
            page
        }
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                PageHeader(title: String(localized: "Command Line Tools"), subtitle: subtitle) { headerActions }
                if model.formulae.isEmpty {
                    EmptyStateView(
                        symbol: "checkmark.seal",
                        tint: Theme.Palette.success,
                        title: String(localized: "All tools up to date"),
                        message: String(localized: "No outdated Homebrew formulae.")
                    )
                    .frame(minHeight: 280)
                    .surface(.raised)
                } else {
                    list
                }
            }
            .padding(Theme.Spacing.page)
            .frame(maxWidth: Theme.Spacing.contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var subtitle: String {
        let count = model.upgradable.count
        if count == 0 { return String(localized: "Homebrew formulae installed on this Mac") }
        return count == 1 ? String(localized: "1 formula can be upgraded") : String(localized: "\(count) formulae can be upgraded")
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.formulae.enumerated()), id: \.element.id) { index, formula in
                if index > 0 {
                    GlassDivider(leadingInset: 58)
                }
                FormulaRowView(
                    formula: formula,
                    upgradeState: model.upgradeState(for: formula),
                    isDisabled: model.isUpgradingAll
                ) { Task { await model.upgrade(formula) } }
            }
        }
        .padding(Theme.Spacing.xs)
        .surface(.raised)
    }

    private var headerActions: some View {
        HStack(spacing: Theme.Spacing.s) {
            if model.isBusy {
                ProgressView().controlSize(.small).tint(.white)
            }
            Button { Task { await model.refresh() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.secondary)
            .disabled(model.isBusy || model.state == .unavailable)
            Button { Task { await model.upgradeAll() } } label: {
                Label("Upgrade All", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.primary)
            .disabled(model.isBusy || model.upgradable.isEmpty)
            .help("Runs brew upgrade for every unpinned formula, one at a time")
        }
    }
}

private struct FormulaRowView: View {
    let formula: OutdatedFormula
    let upgradeState: FormulaeModel.UpgradeState?
    let isDisabled: Bool
    let upgrade: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            IconTile(symbol: "terminal.fill", tint: FormulaeView.accent, size: 32, glows: isHovered)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(formula.name)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                    if formula.pinned { PinnedBadge() }
                }
                versionLine
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            action
        }
        .padding(.vertical, Theme.Spacing.s)
        .padding(.horizontal, Theme.Spacing.m)
        .hoverHighlight(isHovered)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(formula.name), \(formula.installedVersion) to \(formula.currentVersion)")
    }

    private var versionLine: some View {
        HStack(spacing: 4) {
            Text(formula.installedVersion).foregroundStyle(Theme.Palette.textTertiary)
            Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.Palette.textTertiary)
            Text(formula.currentVersion).fontWeight(.medium).foregroundStyle(Theme.Palette.success)
        }
        .font(.system(size: 11, design: .monospaced))
        .lineLimit(1)
    }

    @ViewBuilder
    private var action: some View {
        switch upgradeState {
        case .upgrading:
            HStack(spacing: 6) {
                Text("Upgrading").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.Palette.textSecondary)
                ProgressView().controlSize(.small).tint(.white).tint(.white)
            }
        case .upgraded:
            StatusPill(title: String(localized: "Upgraded"), symbol: "checkmark", tint: Theme.Palette.success)
                .help("Upgraded to \(formula.currentVersion)")
        case .failed(let message):
            Button(action: upgrade) {
                Label("Retry", systemImage: "exclamationmark.triangle.fill")
            }
            .buttonStyle(.secondary(tint: Theme.Palette.warning))
            .controlSize(.small)
            .disabled(isDisabled || formula.pinned)
            .help(message)
        case nil:
            Button("Upgrade", action: upgrade)
                .buttonStyle(.secondary)
                .controlSize(.small)
                .disabled(isDisabled || formula.pinned)
                .help(formula.pinned ? String(localized: "Pinned — run `brew unpin \(formula.name)` first") : String(localized: "Runs brew upgrade \(formula.name)"))
        }
    }
}

private struct PinnedBadge: View {
    var body: some View {
        Label("Pinned", systemImage: "pin.fill")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 9, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(Theme.Palette.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .overlay(Capsule().strokeBorder(Theme.Palette.hairline, lineWidth: 0.5))
            .fixedSize()
    }
}
