import AppKit
import AppUpdaterCore
import Foundation

/// Coverage report, vendor-managed apps and vendor-feed manual routes.
extension UpdatesViewModel {
    // MARK: Coverage

    /// Built from the last detailed check; nil before the first one.
    var coverageReport: CoverageReport? {
        guard !checkResults.isEmpty else { return nil }
        return CoverageReport(
            results: installedApps.compactMap { checkResults[$0.bundleIdentifier] },
            ignoredBundleIdentifiers: exclusions.ignoredBundleIdentifiers
        )
    }

    /// Opens a prefilled, PII-free GitHub issue for an app no source knows.
    func reportMissingApp(_ app: InstalledApp) async {
        let details = await details(for: app)
        let team: String? = if case .signed(let id) = details.signature { id } else { nil }
        guard let url = MissingAppReport(app: app, teamIdentifier: team).issueURL() else {
            logger.error("Could not build a missing-app report for \(app.bundleIdentifier, privacy: .public)")
            return
        }
        workspace.open(url)
    }

    func searchHomebrew(for app: InstalledApp) {
        if let url = CoverageConstants.homebrewSearchURL(for: app.name) { workspace.open(url) }
    }

    // MARK: Vendor-managed apps

    /// File I/O per app, so it runs off the main actor once per scan.
    func detectVendorManagement(in apps: [InstalledApp]) async -> [String: VendorManagement] {
        let detector = services.vendorDetector
        return await Task.detached(priority: .utility) {
            let pairs = apps.compactMap { app in detector.detect(app).map { (app.bundleIdentifier, $0) } }
            return Dictionary(pairs) { first, _ in first }
        }.value
    }

    func vendorManagement(for app: InstalledApp) -> VendorManagement? {
        vendorManagementCache[app.bundleIdentifier]
    }

    func resolvedInstallMethod(for update: AvailableUpdate) -> ResolvedInstallMethod {
        ResolvedInstallMethod(update: update, vendorManagement: vendorManagement(for: update.app))
    }

    func openVendorUpdater(_ management: VendorManagement) {
        switch management.openTarget {
        case .application(let url):
            workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        case .url(let url):
            workspace.open(url)
        }
    }

    // MARK: Vendor feeds that never install (Chrome / Keystone)

    /// Vendor-feed update whose download URL is the vendor page: open it, never install.
    func opensVendorUpdater(_ update: AvailableUpdate) -> Bool {
        services.vendorInstallStrategy(update) == .openVendorUpdater
    }

    func openVendorDownloadPage(_ update: AvailableUpdate) {
        workspace.open(update.downloadURL)
        let name = services.vendorName(update) ?? update.app.name
        setInstallState(.needsManualAction(String(localized: "Updated by \(name)'s own updater — open the app or the download page.")), for: update)
    }
}
