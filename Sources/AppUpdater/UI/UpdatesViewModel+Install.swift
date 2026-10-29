import AppUpdaterCore
import Foundation

/// How a single update gets applied, decided right before installing.
enum InstallRoute: Equatable {
    case appStore
    /// dmg/zip replaced in place by `AppInstaller`.
    case inPlace
    /// .pkg installed as root by the privileged helper.
    case helperPackage
    /// .pkg handed to Installer.app (helper unavailable).
    case installerApp
    /// Setapp / Creative Cloud / MAU / Keystone / Toolbox owns the app: open that updater.
    case vendorUpdater(VendorManagement)
    /// Vendor feed with its own updater (Chrome): open the vendor page, never install.
    case vendorDownloadPage
    /// Unsupported/unknown package format: open the release page in the browser, never
    /// download or open the file (security review H-1).
    case manualDownload
}

extension UpdatesViewModel {
    // MARK: Compatibility

    /// Non-nil when the update requires a newer macOS than this Mac runs.
    func compatibilityWarning(for update: AvailableUpdate) -> AppWarning? {
        services.compatibility.updateCompatibilityWarning(for: update)
    }

    /// Info-level warning when the download host differs from the one used by the last install.
    func downloadHostWarning(for update: AvailableUpdate) -> AppWarning? {
        services.downloadHosts?.check(update).map(services.compatibility.downloadHostWarning(for:))
    }

    /// What to confirm before installing: an incompatible macOS first, then a changed download host.
    func installConfirmationWarning(for update: AvailableUpdate) -> AppWarning? {
        compatibilityWarning(for: update) ?? downloadHostWarning(for: update)
    }

    // MARK: Routing

    func installRoute(for update: AvailableUpdate) async -> InstallRoute {
        if opensVendorUpdater(update) { return .vendorDownloadPage }
        switch resolvedInstallMethod(for: update) {
        case .vendorManaged(let management):
            return .vendorUpdater(management)
        case .standard(.appStore):
            return .appStore
        case .standard(.automatic):
            return .inPlace
        case .standard(.manualDownload):
            return .manualDownload
        case .standard(.installerPackage):
            let status = await refreshHelperStatus()
            return status == .enabled && services.packageInstaller != nil ? .helperPackage : .installerApp
        }
    }

    // MARK: Installing

    /// Installs one update. Updates that need a newer macOS are refused unless the user confirmed.
    func install(_ update: AvailableUpdate, ignoringCompatibility: Bool = false) async {
        guard !installState(for: update).isBusy else { return }
        if !ignoringCompatibility, compatibilityWarning(for: update) != nil {
            logger.notice("Not installing \(update.id, privacy: .public): requires a newer macOS")
            return
        }
        switch await installRoute(for: update) {
        case .appStore:
            openInAppStore(update)
        case .vendorUpdater(let management):
            openVendorUpdater(management)
        case .vendorDownloadPage:
            openVendorDownloadPage(update)
        case .manualDownload:
            openManualDownloadPage(update)
        case .inPlace:
            await runCancellable(update) { await self.installInPlace(update) }
        case .helperPackage:
            await runCancellable(update) { await self.installPackageViaHelper(update) }
        case .installerApp:
            await runCancellable(update) { await self.downloadAndOpenInstaller(update) }
        }
    }

    /// Installs sequentially to avoid competing disk images and quitting many apps at once.
    func installAll() async {
        for update in installableUpdates {
            await install(update)
        }
    }

    // MARK: Progress & cancel

    /// `0...1` while downloading, nil when the size is unknown (indeterminate spinner).
    func progress(for update: AvailableUpdate) -> Double? {
        downloadProgress[update.id]?.fractionCompleted
    }

    /// Received / total, percent, speed and time left while downloading.
    func downloadStatus(for update: AvailableUpdate) -> DownloadStatus? {
        guard installState(for: update) == .downloading else { return nil }
        let report = downloadProgress[update.id] ?? DownloadProgress(receivedBytes: 0, expectedBytes: nil)
        return DownloadStatus(
            progress: report, knownSize: downloadSizes[update.id], startedAt: downloadStarts[update.id]
        )
    }

    /// "1.5 GB" before the download, when the server told us.
    func downloadSizeText(for update: AvailableUpdate) -> String? {
        downloadSizes[update.id].map(DownloadStatus.bytes)
    }

    /// Probes sizes for the listed updates (a few at a time); failures just leave no size.
    func loadDownloadSizes(for updates: [AvailableUpdate]) async {
        guard let probe = services.sizeProbe else { return }
        // Only real packages: an App Store or vendor page would report the HTML page's size.
        let missing = updates.filter { update in
            downloadSizes[update.id] == nil && update.source != .appStore
                && [.dmg, .zip, .pkg].contains(PackageFormat(fileURL: update.downloadURL))
        }
        let sizes = await withTaskGroup(of: (AvailableUpdate.ID, Int64?).self) { group in
            for update in missing.prefix(Self.maxSizeProbes) {
                let url = update.downloadURL
                group.addTask { (update.id, await probe.size(of: url)) }
            }
            var found: [AvailableUpdate.ID: Int64] = [:]
            for await (id, size) in group { if let size { found[id] = size } }
            return found
        }
        downloadSizes = downloadSizes.merging(sizes) { _, new in new }
    }

    private static let maxSizeProbes = 40

    /// Only the download phase can be cancelled; installs run to completion.
    func canCancel(_ update: AvailableUpdate) -> Bool {
        installState(for: update) == .downloading && installTasks[update.id] != nil
    }

    func cancelInstall(_ update: AvailableUpdate) {
        guard canCancel(update) else { return }
        installTasks[update.id]?.cancel()
    }

    private func runCancellable(_ update: AvailableUpdate, _ work: @escaping @MainActor () async -> Void) async {
        let task = Task { await work() }
        installTasks = installTasks.merging([update.id: task]) { _, new in new }
        await task.value
        installTasks = installTasks.filter { $0.key != update.id }
        downloadProgress = downloadProgress.filter { $0.key != update.id }
        downloadStarts = downloadStarts.filter { $0.key != update.id }
    }

    private func download(_ update: AvailableUpdate) async throws -> URL {
        let id = update.id
        downloadStarts = downloadStarts.merging([id: .now]) { _, new in new }
        let record: @Sendable (DownloadProgress) -> Void = { [weak self] report in
            Task { @MainActor in self?.recordProgress(report, for: id) }
        }
        if let detailed = downloader as? any DetailedProgressDownloading {
            return try await detailed.downloadReporting(update, reporting: record)
        }
        if let progressing = downloader as? any ProgressReportingDownloading {
            return try await progressing.download(update) { record(DownloadProgress(fractionCompleted: $0)) }
        }
        return try await downloader.download(update)
    }

    /// Publishes progress in whole-percent (or 1 MB, when the size is unknown) steps so long
    /// downloads don't flood the UI.
    private func recordProgress(_ report: DownloadProgress, for id: AvailableUpdate.ID) {
        guard installStates[id] == .downloading else { return }
        if let previous = downloadProgress[id] {
            let fractionStep = (report.fractionCompleted ?? 0) - (previous.fractionCompleted ?? 0)
            let byteStep = report.receivedBytes - previous.receivedBytes
            let isDone = (report.fractionCompleted ?? 0) >= 1
            guard isDone || fractionStep >= 0.01 || (report.expectedBytes == nil && byteStep >= 1_048_576) else { return }
        }
        downloadProgress = downloadProgress.merging([id: report]) { _, new in new }
    }

    // MARK: Flows

    private func installInPlace(_ update: AvailableUpdate) async {
        do {
            setInstallState(.downloading, for: update)
            let downloaded = try await download(update)
            // The verified download is never handed to the user, so it is always removed
            // (success, failure, cancellation or unsupported format).
            defer { Self.removeDownload(downloaded) }
            try Task.checkCancellation()
            // The final file name may differ from the URL (downloader-chosen name): re-check
            // the real format and never stage or open anything but dmg/zip.
            guard InstallMethod.isInPlaceFormat(PackageFormat(fileURL: downloaded)) else {
                throw UpdaterError.unsupportedFormat(downloaded.pathExtension.isEmpty ? "unknown" : downloaded.pathExtension)
            }
            setInstallState(.installing, for: update)
            try await installer.install(update, from: downloaded)
            await completeInstall(update)
        } catch UpdaterError.unsupportedFormat(let format) {
            logger.notice("Manual install needed for \(update.app.name, privacy: .public) (\(format, privacy: .public))")
            openManualDownloadPage(update)
        } catch {
            await handleInstallError(error, for: update)
        }
    }

    /// Sends the user to the vendor's page in the browser. Downloaded files are never
    /// opened here: LaunchServices would run handlers for types such as `.terminal` (H-1).
    func openManualDownloadPage(_ update: AvailableUpdate) {
        if let page = InstallMethod.manualDownloadPage(for: update) {
            workspace.open(page)
            setInstallState(.needsManualAction(String(localized: "This update can't be installed automatically — download it from the vendor's page.")), for: update)
        } else {
            setInstallState(.needsManualAction(String(localized: "This update can't be installed automatically — download it from the vendor's website.")), for: update)
        }
    }

    private func installPackageViaHelper(_ update: AvailableUpdate) async {
        guard let packageInstaller = services.packageInstaller else { return }
        do {
            setInstallState(.downloading, for: update)
            let packageURL = try await download(update)
            defer { Self.removeDownload(packageURL) }
            try Task.checkCancellation()
            setInstallState(.installing, for: update)
            try await packageInstaller.install(update, from: packageURL)
            await completeInstall(update)
        } catch {
            await handleInstallError(error, for: update)
        }
    }

    /// .pkg without the helper: Installer.app asks for admin rights and shows the vendor's steps.
    private func downloadAndOpenInstaller(_ update: AvailableUpdate) async {
        do {
            setInstallState(.downloading, for: update)
            let packageURL = try await download(update)
            // Only a real .pkg is ever opened (Installer.app); anything else is deleted and
            // replaced by manual guidance. The .pkg itself is kept: Installer.app reads it after
            // `open` returns, so it stays in its AppUpdater-<UUID> folder until the OS purges it.
            guard PackageFormat(fileURL: packageURL) == .pkg else {
                Self.removeDownload(packageURL)
                openManualDownloadPage(update)
                return
            }
            do {
                try Task.checkCancellation()
            } catch {
                Self.removeDownload(packageURL)
                throw error
            }
            workspace.open(packageURL)
            setInstallState(.needsManualAction(String(localized: "Installer opened — follow its steps to finish.")), for: update)
        } catch {
            await handleInstallError(error, for: update)
        }
    }

    private func completeInstall(_ update: AvailableUpdate) async {
        setInstallState(.installed, for: update)
        // Idempotent for in-place installs (AppInstaller records too); needed for helper .pkg installs.
        services.downloadHosts?.record(update)
        logger.info("Installed \(update.app.name, privacy: .public) \(update.newVersion, privacy: .public)")
        await services.versionAliases?.recordInstall(of: update)
        await recordHistory(UpdateHistoryEntry(update: update, outcome: .succeeded))
        await refreshBackup(for: update.app)
    }

    /// Drops updates we already installed whose advertised version the bundle never reports.
    /// Installs from before the alias store existed are recovered from the history: the last
    /// successful install of exactly this version, while the bundle still shows the same
    /// short version it had then and the advertised version merely refines it.
    func reconcileInstalledVersions(_ results: [UpdateCheckResult]) async -> [UpdateCheckResult] {
        guard let aliases = services.versionAliases else { return results }
        let entries = await services.history?.entries() ?? []
        for update in results.compactMap(\.update) where await aliases.alias(for: update.app.bundleIdentifier) == nil {
            let lastSuccess = entries
                .filter { $0.bundleID == update.app.bundleIdentifier && $0.outcome == .succeeded }
                .max { $0.date < $1.date }
            guard let lastSuccess, lastSuccess.toVersion == update.newVersion,
                  lastSuccess.fromVersion == update.app.shortVersion,
                  VersionComparator().isRefinement(update.newVersion, of: update.app.shortVersion)
            else { continue }
            await aliases.record(
                InstalledVersionAlias(
                    advertisedVersion: update.newVersion,
                    shortVersion: update.app.shortVersion,
                    buildVersion: update.app.buildVersion
                ),
                for: update.app.bundleIdentifier
            )
        }
        return await aliases.reconcile(results)
    }

    private func handleInstallError(_ error: any Error, for update: AvailableUpdate) async {
        if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled {
            logger.info("Install of \(update.app.name, privacy: .public) cancelled")
            setInstallState(.pending, for: update)
            return
        }
        let message = InstallBlockReason(error: error) == .notNotarized && managedGate.isNotarizationLocked
            ? Self.notarizationRequiredByOrganizationMessage
            : Self.failureMessage(for: error, appName: update.app.name)
        logger.error("Install of \(update.app.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        setInstallState(.failed(message), for: update)
        await recordHistory(UpdateHistoryEntry(update: update, outcome: .failed(message: message)))
    }

    static let notarizationBlockedMessage = String(
        localized: "Blocked: Apple has not notarized this update. You can allow it in Settings › General (not recommended)."
    )
    static let notarizationRequiredByOrganizationMessage = String(
        localized: "Blocked: Apple has not notarized this update, and your organization requires notarization."
    )
    static let notarizationUnconfirmedMessage = String(
        localized: "Gatekeeper couldn't confirm that Apple notarized this update — you may be offline. Connect to the internet and try again."
    )
    static let gatekeeperRejectedMessage = String(
        localized: "Blocked: Gatekeeper rejected this update (for example, the developer's certificate was revoked). It can't be installed."
    )
    static let untrustedHelperBuildMessage = String(
        localized: "This copy of App Updater isn't signed with a Developer ID, so its privileged helper can't install packages. Install the update from the vendor's website, or use an official build."
    )

    static func unverifiablePublisherMessage(appName: String) -> String {
        String(localized: "Blocked: \(appName) isn't signed with a valid Developer ID, so the publisher of this update can't be verified. Update it manually from the vendor's website.")
    }

    /// User-facing text for an install failure; security blocks get specific guidance.
    static func failureMessage(for error: any Error, appName: String? = nil) -> String {
        switch InstallBlockReason(error: error) {
        case .notNotarized: return notarizationBlockedMessage
        case .notarizationUnconfirmed: return notarizationUnconfirmedMessage
        case .gatekeeperRejected: return gatekeeperRejectedMessage
        case .untrustedHelperBuild: return untrustedHelperBuildMessage
        case .unverifiablePublisher:
            return unverifiablePublisherMessage(appName: appName ?? String(localized: "The installed app"))
        case nil: return error.localizedDescription
        }
    }

    /// Downloads live in their own `AppUpdater-<UUID>` directory; never delete anything else.
    private static func removeDownload(_ fileURL: URL) {
        let directory = fileURL.deletingLastPathComponent()
        guard directory.lastPathComponent.hasPrefix("AppUpdater") else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
