import AppUpdaterCore
import SwiftUI

// MARK: - Update banner

/// Shows the update state and lets the user start it right here.
struct UpdateBanner: View {
    let app: InstalledApp
    let viewModel: UpdatesViewModel

    @State private var isConfirmingInstall = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            summaryRow
            if installState == .downloading, let update {
                DownloadProgressBar(status: viewModel.downloadStatus(for: update), style: .large)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Theme.Motion.content, value: installState == .downloading)
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            // Tint bloom from the icon corner: color carries the state, the glass stays calm.
            RadialGradient(colors: [tint.opacity(0.22), .clear], center: .leading, startRadius: 0, endRadius: 220)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
        )
        .surface(.elevated)
        .animation(Theme.Motion.content, value: tint)
        .compatibilityConfirmation(warning: confirmationWarning, isPresented: $isConfirmingInstall) {
            if let update { Task { await viewModel.install(update, ignoringCompatibility: true) } }
        }
    }

    private var summaryRow: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.m) {
            IconTile(symbol: symbol, tint: tint, size: 36, glows: true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs + 1) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .contentTransition(.opacity)
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(installState.isFailure ? Theme.Palette.warning : Theme.Palette.textSecondary)
                    .lineLimit(installState.isFailure ? 6 : 3)
                    .textSelection(.enabled)
            }
            Spacer(minLength: Theme.Spacing.s)
            actions
                .controlSize(.small)
        }
    }

    private var compatibilityWarning: AppWarning? {
        update.flatMap(viewModel.compatibilityWarning(for:))
    }

    private var confirmationWarning: AppWarning? {
        update.flatMap(viewModel.installConfirmationWarning(for:))
    }

    /// Vendor-owned updates open the vendor's updater or page; nothing to confirm.
    private func isVendorRouted(_ update: AvailableUpdate) -> Bool {
        viewModel.opensVendorUpdater(update) || viewModel.vendorManagement(for: app) != nil
    }

    private func requestInstall(_ update: AvailableUpdate) {
        if confirmationWarning != nil, !isVendorRouted(update) {
            isConfirmingInstall = true
        } else {
            Task { await viewModel.install(update) }
        }
    }

    private var update: AvailableUpdate? { viewModel.update(for: app) }
    private var isIgnored: Bool { viewModel.exclusions.isIgnored(app.bundleIdentifier) }
    private var installState: UpdatesViewModel.InstallState {
        update.map(viewModel.installState(for:)) ?? .pending
    }

    @ViewBuilder
    private var actions: some View {
        if let update, !isIgnored {
            switch installState {
            case .pending, .failed:
                HStack(spacing: Theme.Spacing.xs + 2) {
                    Button("Manually…") { viewModel.openDownloadPage(update) }
                        .buttonStyle(.secondary)
                        .help("Open the download page in your browser")
                    Button(primaryTitle(for: update)) { requestInstall(update) }
                        .buttonStyle(.primary(tint: installState.isFailure ? Theme.Palette.warning : Theme.Palette.brand))
                        .keyboardShortcut(.defaultAction)
                }
            case .downloading:
                Button("Cancel") { viewModel.cancelInstall(update) }
                    .buttonStyle(.secondary)
            case .installing:
                ProgressView().controlSize(.small).tint(.white)
            case .needsManualAction:
                Button("Open Download Page") { viewModel.openDownloadPage(update) }
                    .buttonStyle(.primary)
            case .installed:
                EmptyView()
            }
        } else if update == nil, let management = viewModel.vendorManagement(for: app), !isIgnored {
            Button("Open \(management.updaterName)") { viewModel.openVendorUpdater(management) }
                .buttonStyle(.secondary)
        } else if update == nil, !app.isFromAppStore, !isIgnored {
            Button("Search the Web…") { viewModel.searchWebForUpdate(app) }
                .buttonStyle(.secondary)
        }
    }

    private func primaryTitle(for update: AvailableUpdate) -> String {
        if viewModel.opensVendorUpdater(update) { return String(localized: "Open Download Page") }
        switch viewModel.resolvedInstallMethod(for: update) {
        case .vendorManaged(let management): return String(localized: "Open \(management.updaterName)")
        case .standard(.automatic):
            if installState == .pending { return String(localized: "Update Now") }
            if installState == .failed(UpdatesViewModel.notarizationUnconfirmedMessage) {
                return String(localized: "Try Again Online")
            }
            return String(localized: "Retry")
        case .standard(.appStore): return String(localized: "Open App Store")
        case .standard(.installerPackage): return String(localized: "Download & Install…")
        case .standard(.manualDownload): return String(localized: "Open Download Page")
        }
    }

    /// Glyph for the state's icon tile (white on the tint gradient).
    private var symbol: String {
        if isIgnored { return "eye.slash" }
        guard update != nil else { return "checkmark.seal.fill" }
        switch installState {
        case .installed: return "checkmark"
        case .failed: return "exclamationmark.triangle.fill"
        case .needsManualAction: return "hand.point.up.left.fill"
        default: return "arrow.down"
        }
    }

    private var tint: Color {
        if isIgnored { return Color(white: 0.55) }
        guard update != nil else { return Theme.Palette.success }
        switch installState {
        case .installed: return Theme.Palette.success
        case .failed: return Theme.Palette.warning
        default: return Theme.Palette.info
        }
    }

    private var title: String {
        if isIgnored { return String(localized: "Updates ignored") }
        guard let update else {
            if let management = viewModel.vendorManagement(for: app) { return String(localized: "Managed by \(management.updaterName)") }
            return app.isFromAppStore ? String(localized: "Managed by the App Store") : String(localized: "No update found")
        }
        switch installState {
        case .pending: return String(localized: "Version \(update.newVersion) available")
        case .downloading: return String(localized: "Downloading \(update.newVersion)…")
        case .installing: return String(localized: "Installing \(update.newVersion)…")
        case .installed: return String(localized: "Updated to \(update.newVersion)")
        case .needsManualAction: return String(localized: "Finish the update manually")
        case .failed: return String(localized: "Update failed")
        }
    }

    private var message: String {
        if isIgnored { return String(localized: "This app is excluded from update checks.") }
        guard let update else { return noUpdateMessage }
        switch installState {
        case .needsManualAction(let text), .failed(let text): return text
        case .installing:
            return String(localized: "Verifying signature and installing — large apps can take a few minutes")
        default:
            let delta = String(localized: "\(app.shortVersion) → \(update.newVersion) via \(update.source.displayName)")
            if let management = viewModel.vendorManagement(for: app) {
                return String(localized: "\(delta). \(management.updaterName) manages updates for this app.")
            }
            if viewModel.opensVendorUpdater(update) {
                return String(localized: "\(delta). Updated by the vendor's own updater — open the app or the download page.")
            }
            let sized = viewModel.downloadSizeText(for: update).map { String(localized: "\(delta) · \($0) download") } ?? delta
            guard let warning = compatibilityWarning else { return sized }
            return String(localized: "\(delta). \(warning.title).")
        }
    }

    /// Uses the precise check result when there is one, otherwise a guess from the bundle.
    private var noUpdateMessage: String {
        if let result = viewModel.checkResult(for: app) {
            if let source = result.matchedSource, result.isUpToDate {
                return String(localized: "You're on the latest version (via \(source.displayName)).")
            }
            return result.errors.isEmpty
                ? String(localized: "No known update source for this app.")
                : String(localized: "The update check failed: \(result.errors.joined(separator: "; "))")
        }
        return app.sparkleFeedURL == nil && !app.isFromAppStore
            ? String(localized: "Up to date, or no known update source for this app.")
            : String(localized: "You're on the latest version.")
    }
}

