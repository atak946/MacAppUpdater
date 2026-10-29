import AppKit
import AppUpdaterCore
import SwiftUI

/// One app in the updates list: icon, name, version delta, source badge and action.
struct UpdateRowView: View {
    let update: AvailableUpdate
    let icon: NSImage
    let installState: UpdatesViewModel.InstallState
    var progress: Double?
    /// Amount, percent, speed and time left while downloading.
    var downloadStatus: DownloadStatus?
    /// "1.5 GB" before downloading, when the server reported it.
    var downloadSize: String?
    /// Set when the update needs a newer macOS (shown as a badge).
    var compatibilityWarning: AppWarning?
    /// Asked before installing: incompatible macOS or a changed download host.
    var confirmationWarning: AppWarning?
    /// How the primary button installs (vendor updater, App Store, in place, .pkg).
    var installMethod: ResolvedInstallMethod
    /// Vendor feed with its own updater (Chrome): the button opens the vendor page.
    var opensVendorPage = false
    /// "Auto-installs in N days" while the soak period runs.
    var autoInstallHint: String?
    /// "Released …" / "First seen …".
    var releaseDateLabel: String?
    var isIgnoreLocked = false
    let actions: UpdateRowActions

    @State private var isHovered = false
    @State private var showsNotes = false
    @State private var isConfirmingInstall = false
    @State private var isConfirmingRevert = false

    private func titleLine(showsSource: Bool, showsPills: Bool) -> some View {
        HStack(spacing: 6) {
            Text(update.app.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            if showsSource {
                SourceBadge(source: update.source)
            }
            if showsPills, let securityInfo = update.securityInfo {
                SecurityUpdatePill(info: securityInfo)
            }
            if showsPills, let compatibilityWarning {
                WarningBadge(warnings: [compatibilityWarning])
            }
        }
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 40, height: 40)
                .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                .shadow(color: Theme.Palette.brand.opacity(isHovered ? 0.35 : 0), radius: 10)
                .opacity(installState == .installed ? 0.55 : 1)
                .saturation(installState == .installed ? 0.6 : 1)

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                // In the narrow menu bar panel the badges don't all fit: the source badge goes first,
                // then the rest, so the fixed-size badges never push the row out of its card.
                ViewThatFits(in: .horizontal) {
                    titleLine(showsSource: true, showsPills: true)
                    titleLine(showsSource: false, showsPills: true)
                    titleLine(showsSource: false, showsPills: false)
                }
                versionLine
                statusLine
            }
            .layoutPriority(1)

            Spacer(minLength: 4)
            if update.releaseNotes != nil {
                notesButton
            }
            // Buttons keep their natural width; the name and version column truncates instead.
            // In the narrow menu bar panel a compressed button wrapped its title one letter per line.
            action.fixedSize()
        }
        .padding(.horizontal, Theme.Spacing.s)
        .padding(.vertical, Theme.Spacing.s)
        .background(
            // Soft brand bloom behind the icon on hover, on top of the standard highlight.
            RadialGradient(
                colors: [Theme.Palette.brand.opacity(isHovered ? 0.14 : 0), .clear],
                center: .leading, startRadius: 0, endRadius: 180
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
            .animation(Theme.Motion.hover, value: isHovered)
        )
        .hoverHighlight(isHovered)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(Theme.Motion.content, value: installState)
        .contextMenu { contextMenu }
        .compatibilityConfirmation(
            warning: confirmationWarning, isPresented: $isConfirmingInstall, onConfirm: actions.installAnyway
        )
        .revertConfirmation(
            appName: update.app.name, isPresented: $isConfirmingRevert, onConfirm: actions.revert ?? {}
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(update.app.name), \(update.app.shortVersion) to \(update.newVersion)")
    }

    /// Old version muted, new version in a glowing brand-gradient capsule (green once installed).
    /// Where the row is narrow (menu bar panel) the size, then the old version, are left out
    /// rather than both versions being clipped to "1…3 → …".
    private var versionLine: some View {
        ViewThatFits(in: .horizontal) {
            versionRow(showsOldVersion: true, showsSize: true)
            versionRow(showsOldVersion: true, showsSize: false)
            versionRow(showsOldVersion: false, showsSize: false)
        }
    }

    private func versionRow(showsOldVersion: Bool, showsSize: Bool) -> some View {
        HStack(spacing: 5) {
            if showsOldVersion {
                Text(update.app.shortVersion)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .truncationMode(.middle)
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            Text(update.newVersion)
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .truncationMode(.middle)
                .padding(.horizontal, 7)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(newVersionFill))
                .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                .glow(newVersionTint, radius: 5, opacity: 0.4)
                // The new version is the point of the row: never clipped, the old one gives way.
                .fixedSize()
            // Whole or not at all: a clipped size ("3" of "378,8 MB") reads as a wrong number.
            if showsSize, let downloadSize, installState == .pending {
                Text(downloadSize)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .help("Download size")
            }
        }
        .font(.system(size: 11, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
    }

    private var newVersionTint: Color {
        installState == .installed ? Theme.Palette.success : Theme.Palette.brand
    }

    private var newVersionFill: AnyShapeStyle {
        installState == .installed
            ? AnyShapeStyle(Theme.gradient(for: Theme.Palette.success))
            : AnyShapeStyle(Theme.brandGradient)
    }

    /// Download detail or the failure reason replace the policy line while they apply.
    @ViewBuilder
    private var statusLine: some View {
        switch installState {
        case .downloading:
            DownloadProgressBar(status: downloadStatus)
                .frame(minWidth: 220, maxWidth: 420)
                .padding(.top, 2)
        case .installing:
            Text("Verifying signature and installing — large apps can take a few minutes")
                .font(.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Theme.Palette.warning)
                .lineLimit(2)
                .textSelection(.enabled)
                .help(message)
        default:
            policyLine
        }
    }

    @ViewBuilder
    private var policyLine: some View {
        if autoInstallHint != nil || releaseDateLabel != nil {
            HStack(spacing: 8) {
                if let autoInstallHint {
                    Label(autoInstallHint, systemImage: "clock.badge.checkmark")
                }
                if let releaseDateLabel {
                    Text(releaseDateLabel).foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.Palette.textSecondary)
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private var action: some View {
        switch installState {
        case .pending:
            if isPlainUpdate {
                Button(pendingTitle, action: requestInstall)
                    .buttonStyle(.primary)
                    .controlSize(.small)
                    .help(pendingHelp)
            } else {
                Button(pendingTitle, action: requestInstall)
                    .buttonStyle(.secondary)
                    .controlSize(.small)
                    .help(pendingHelp)
            }
        case .downloading:
            Button("Cancel", systemImage: "xmark.circle.fill", action: actions.cancel)
                .labelStyle(.iconOnly)
                .buttonStyle(IconButtonStyle())
                .help("Cancel download")
        case .installing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).tint(Theme.Palette.brand)
                StatusPill(title: String(localized: "Installing"), tint: Theme.Palette.brand)
            }
        case .installed:
            StatusPill(title: String(localized: "Updated"), symbol: "checkmark.circle.fill", tint: Theme.Palette.success)
                .help("Updated to \(update.newVersion)")
                .transition(.scale(scale: 0.8).combined(with: .opacity))
        case .needsManualAction(let message):
            Button(action: actions.openDownloadPage) {
                Label("Manual", systemImage: "hand.point.up.left.fill")
            }
            .buttonStyle(.secondary(tint: Theme.Palette.info))
            .controlSize(.small)
            .help("\(message)\nClick to open the download page.")
        case .failed(let message):
            HStack(spacing: 2) {
                Button(action: requestInstall) {
                    Label("Retry", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Theme.Palette.warning)
                }
                .buttonStyle(IconButtonStyle())
                .help(message == UpdatesViewModel.notarizationUnconfirmedMessage
                    ? LocalizedStringKey("\(message)\nClick to try again once you're online.")
                    : LocalizedStringKey("\(message)\nClick to retry."))
                Button(action: actions.openDownloadPage) {
                    Label("Download manually", systemImage: "safari")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(IconButtonStyle())
                .help("Automatic update failed. Download it manually from the website.")
            }
        }
    }

    private var notesButton: some View {
        Button { showsNotes.toggle() } label: {
            Label("Release Notes", systemImage: "doc.text").labelStyle(.iconOnly)
        }
        .buttonStyle(IconButtonStyle())
        .help("What's new in \(update.newVersion)")
        .popover(isPresented: $showsNotes, arrowEdge: .trailing) {
            ReleaseNotesView(notes: update.releaseNotes, loader: actions.releaseNotesLoader)
                .frame(width: 420, height: 360)
        }
    }

    /// Incompatible updates and changed download hosts ask first; everything else installs right away.
    private func requestInstall() {
        if confirmationWarning != nil, installMethod.vendorManagement == nil, !opensVendorPage {
            isConfirmingInstall = true
        } else {
            actions.install()
        }
    }

    /// The in-place "Update" gets the prominent style; vendor, App Store and package flows stay quiet.
    private var isPlainUpdate: Bool {
        !opensVendorPage && installMethod == .standard(.automatic)
    }

    private var pendingTitle: String {
        if opensVendorPage { return String(localized: "Open…") }
        switch installMethod {
        case .vendorManaged(let management): return String(localized: "Open \(management.updaterName)")
        case .standard(.automatic): return String(localized: "Update")
        case .standard(.appStore): return String(localized: "Open")
        case .standard(.installerPackage): return String(localized: "Install…")
        case .standard(.manualDownload): return String(localized: "Open…")
        }
    }

    private var pendingHelp: String {
        if opensVendorPage { return String(localized: "Updated by the vendor's own updater — opens the download page") }
        switch installMethod {
        case .vendorManaged(let management): return String(localized: "\(management.updaterName) manages updates for this app")
        case .standard(.automatic): return String(localized: "Download, verify and replace automatically")
        case .standard(.appStore): return String(localized: "Opens the App Store updates page")
        case .standard(.installerPackage): return String(localized: "Downloads the installer package and opens it — admin password required")
        case .standard(.manualDownload): return String(localized: "This download format can't be installed automatically — opens the vendor's page")
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Download Manually…", systemImage: "safari", action: actions.openDownloadPage)
        if update.releaseNotes != nil {
            Button("What's New…", systemImage: "doc.text.magnifyingglass") { showsNotes = true }
        }
        if let notes = update.releaseNotesURL {
            Button("Release Notes", systemImage: "doc.text") { NSWorkspace.shared.open(notes) }
        }
        Button("Show in Finder", systemImage: "folder", action: actions.reveal)
        if actions.revert != nil {
            Button("Revert to Previous Version", systemImage: "arrow.uturn.backward") { isConfirmingRevert = true }
        }
        Divider()
        Button("Skip Version \(update.newVersion)", systemImage: "forward.end", action: actions.skipVersion)
        VersionCeilingMenu(
            version: update.app.shortVersion, current: actions.ceiling, onSelect: actions.setCeiling
        )
        if !isIgnoreLocked {
            Button("Ignore \(update.app.name)", systemImage: "eye.slash", action: actions.ignoreApp)
        }
    }
}

/// "Security" capsule for updates whose release notes mention security fixes; the tooltip lists CVEs.
struct SecurityUpdatePill: View {
    let info: SecurityUpdateInfo

    var body: some View {
        StatusPill(title: String(localized: "Security"), symbol: "lock.shield.fill", tint: Theme.Palette.danger)
            .help(helpText)
            .accessibilityLabel(helpText)
    }

    private var helpText: String {
        info.cveIDs.isEmpty
            ? String(localized: "The release notes mention security fixes")
            : String(localized: "Security fixes: \(info.cveIDs.joined(separator: ", "))")
    }
}

/// Everything a row can trigger; built from the view model in one place.
struct UpdateRowActions {
    let install: () -> Void
    let reveal: () -> Void
    let openDownloadPage: () -> Void
    let skipVersion: () -> Void
    let ignoreApp: () -> Void
    let cancel: () -> Void
    /// Installs despite a compatibility warning (after the user confirmed).
    let installAnyway: () -> Void
    /// Nil when no backup of the previous version exists.
    let revert: (() -> Void)?
    let releaseNotesLoader: any ReleaseNotesLoading
    /// Current "stay on" prefix, e.g. "5".
    let ceiling: String?
    let setCeiling: (String?) -> Void

    @MainActor
    init(update: AvailableUpdate, viewModel: UpdatesViewModel) {
        install = { Task { await viewModel.install(update) } }
        installAnyway = { Task { await viewModel.install(update, ignoringCompatibility: true) } }
        cancel = { viewModel.cancelInstall(update) }
        revert = viewModel.backup(for: update.app).map { _ in
            { Task { await viewModel.revertToPreviousVersion(update.app) } }
        }
        releaseNotesLoader = viewModel.releaseNotesLoader
        reveal = { viewModel.revealInFinder(update) }
        openDownloadPage = { viewModel.openDownloadPage(update) }
        skipVersion = { viewModel.skipVersion(of: update) }
        ignoreApp = { viewModel.ignore(update.app) }
        ceiling = viewModel.exclusions.ceiling(for: update.app.bundleIdentifier)
        setCeiling = { viewModel.setCeiling($0, for: update.app) }
    }
}

extension UpdateRowView {
    /// Row fed entirely from the view model (updates list and menu bar).
    @MainActor
    init(update: AvailableUpdate, viewModel: UpdatesViewModel) {
        self.init(
            update: update,
            icon: viewModel.icon(for: update.app),
            installState: viewModel.installState(for: update),
            progress: viewModel.progress(for: update),
            downloadStatus: viewModel.downloadStatus(for: update),
            downloadSize: viewModel.downloadSizeText(for: update),
            compatibilityWarning: viewModel.compatibilityWarning(for: update),
            confirmationWarning: viewModel.installConfirmationWarning(for: update),
            installMethod: viewModel.resolvedInstallMethod(for: update),
            opensVendorPage: viewModel.opensVendorUpdater(update),
            autoInstallHint: viewModel.autoInstallHint(for: update),
            releaseDateLabel: viewModel.releaseDateLabel(for: update),
            isIgnoreLocked: viewModel.isIgnoreLocked(update.app.bundleIdentifier),
            actions: UpdateRowActions(update: update, viewModel: viewModel)
        )
    }
}
