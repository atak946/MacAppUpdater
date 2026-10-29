import AppKit
import AppUpdaterCore
import Observation
import os

/// Finds updates for a set of installed apps. Implemented by the core `UpdateChecker`.
protocol UpdateChecking: Sendable {
    func checkAll(_ apps: [InstalledApp]) async -> [AvailableUpdate]
    /// One result per app (matched source, latest version, errors), in input order.
    func checkAllDetailed(_ apps: [InstalledApp]) async -> [UpdateCheckResult]
}

/// Reports whether the privileged helper can install packages. Implemented by `HelperClient`.
protocol HelperStatusProviding: Sendable {
    var status: HelperStatus { get async }
}

/// Persists install outcomes. Implemented by `UpdateHistoryStore`.
protocol UpdateHistoryRecording: Sendable {
    func entries() async -> [UpdateHistoryEntry]
    func record(_ entry: UpdateHistoryEntry) async throws
    func clear() async throws
}

/// Optional collaborators of the view model; the composition root passes real implementations.
struct UpdateServices {
    /// Installs `.pkg` updates through the privileged helper.
    var packageInstaller: (any UpdateInstalling)?
    var helper: (any HelperStatusProviding)?
    var backupStore: (any AppBackupStoring)?
    var history: (any UpdateHistoryRecording)?
    var policies: any UpdatePoliciesStoring = UserDefaultsUpdatePoliciesStore()
    var betaStore = BetaChannelStore()
    var uninstaller = AppUninstaller()
    var insights: InsightsCollector?
    var compatibility = CompatibilityAnalyzer()
    var runningApps: any RunningAppChecking = WorkspaceRunningAppChecker()
    var releaseNotesLoader: any ReleaseNotesLoading = ReleaseNotesLoader()
    /// Power, network and running apps for the auto-install planner.
    var conditions: any SystemConditionsProvider = LiveSystemConditionsProvider()
    /// Starts the soak-period clock for updates without a published date.
    var firstSeen: any FirstSeenRecording = FirstSeenStore()
    /// Setapp / Creative Cloud / MAU / Keystone / Toolbox detection; run once per scan.
    var vendorDetector: any VendorManagementDetecting = VendorManagementDetector()
    /// Vendor-feed install strategy (`VendorFeedSource.installStrategy(for:)`); nil for other sources.
    var vendorInstallStrategy: @Sendable (AvailableUpdate) -> VendorInstallStrategy? = { _ in nil }
    /// Vendor updater name for `.openVendorUpdater` updates (e.g. "Google Chrome").
    var vendorName: @Sendable (AvailableUpdate) -> String? = { _ in nil }
    /// Last known download host per app (B3); recorded after successful installs.
    var downloadHosts: (any DownloadHostStoring)?
    /// Administrator-forced settings (MDM), read once at launch.
    var managed: ManagedConfiguration = .unmanaged
    /// HEAD request for the size shown before downloading; nil (tests) skips it.
    var sizeProbe: (any DownloadSizeProbing)?
    /// Keeps installed updates from being offered again when the source's version string
    /// differs from the bundle's (Homebrew `2026.2.2.8` vs Android Studio `2026.2`).
    var versionAliases: (any InstalledVersionAliasing)?
}

/// Detects vendor-managed apps. Implemented by the core `VendorManagementDetector`.
protocol VendorManagementDetecting: Sendable {
    func detect(_ app: InstalledApp) -> VendorManagement?
}

extension VendorManagementDetector: VendorManagementDetecting {}

@MainActor
@Observable
final class UpdatesViewModel {
    enum State: Equatable {
        case idle
        case scanning
        case checking
        case loaded([AvailableUpdate])
        case failed(String)
    }

    enum InstallState: Equatable {
        case pending
        case downloading
        case installing
        case installed
        /// Automatic install isn't possible; the user has to finish it (Installer.app, dmg, website).
        case needsManualAction(String)
        case failed(String)

        var isBusy: Bool { self == .downloading || self == .installing }
        var isFailure: Bool { if case .failed = self { true } else { false } }
    }

    private(set) var state: State = .idle
    private(set) var lastChecked: Date?
    private(set) var installedApps: [InstalledApp] = []
    private(set) var exclusions: ExclusionRules
    private(set) var checkResults: [String: UpdateCheckResult] = [:]
    private(set) var betaOptIns: Set<String>

    // Written by the install / history / insights extensions in sibling files.
    var installStates: [AvailableUpdate.ID: InstallState] = [:]
    var downloadProgress: [AvailableUpdate.ID: DownloadProgress] = [:]
    var downloadStarts: [AvailableUpdate.ID: Date] = [:]
    /// Package size from a HEAD request, known before the download starts.
    var downloadSizes: [AvailableUpdate.ID: Int64] = [:]
    var installTasks: [AvailableUpdate.ID: Task<Void, Never>] = [:]
    var helperStatus: HelperStatus = .notRegistered
    var backups: [String: AppBackup] = [:]
    var history: [UpdateHistoryEntry] = []
    var insights: InsightsReport?
    var isLoadingInsights = false
    /// Last revert / uninstall problem, shown as an alert.
    var actionError: String?
    /// Published / first-seen dates keyed by `AvailableUpdate.id`, refreshed after every check.
    var releaseDates: [String: ReleaseDate] = [:]
    /// Planner verdicts from the last scheduled run, keyed by `AvailableUpdate.id`.
    var lastAutoInstallDecisions: [String: AutoInstallDecision] = [:]
    /// Vendor updaters owning apps, keyed by bundle id; detected once per scan.
    var vendorManagementCache: [String: VendorManagement] = [:]

    private(set) var checker: any UpdateChecking
    let scanner: any AppScanning
    let downloader: any UpdateDownloading
    let installer: any UpdateInstalling
    let services: UpdateServices
    let workspace: NSWorkspace
    let logger = Logger(subsystem: "com.macappupdater", category: "UpdatesViewModel")
    let exclusionStore: any ExclusionRulesStoring
    let detailsReader: AppDetailsReader

    init(
        scanner: any AppScanning,
        checker: any UpdateChecking,
        downloader: any UpdateDownloading,
        installer: any UpdateInstalling,
        services: UpdateServices = UpdateServices(),
        exclusionStore: any ExclusionRulesStoring = UserDefaultsExclusionRulesStore(),
        detailsReader: AppDetailsReader = AppDetailsReader(),
        workspace: NSWorkspace = .shared
    ) {
        self.scanner = scanner
        self.checker = checker
        self.downloader = downloader
        self.installer = installer
        self.services = services
        self.exclusionStore = exclusionStore
        self.exclusions = exclusionStore.load()
        self.betaOptIns = services.betaStore.load()
        self.detailsReader = detailsReader
        self.workspace = workspace
    }

    /// Swaps the checker, e.g. after GitHub repository mappings changed.
    func replaceChecker(_ checker: any UpdateChecking) {
        self.checker = checker
    }

    // MARK: Derived state

    /// Every update found in the last check, including excluded ones.
    var allUpdates: [AvailableUpdate] {
        if case .loaded(let updates) = state { return updates }
        return []
    }

    /// Updates the user hasn't excluded.
    var updates: [AvailableUpdate] {
        allUpdates.filter { !exclusions.isExcluded($0) }
    }

    /// Updates hidden by an ignored app or a skipped version.
    var excludedUpdates: [AvailableUpdate] {
        allUpdates.filter { exclusions.isExcluded($0) }
    }

    /// Ignored apps, resolved against the last scan where possible.
    var ignoredApps: [InstalledApp] {
        installedApps.filter { exclusions.isIgnored($0.bundleIdentifier) }
    }

    var isBusy: Bool { state == .scanning || state == .checking }

    /// Updates that still need action (not installed yet).
    var pendingUpdates: [AvailableUpdate] {
        updates.filter { installState(for: $0) != .installed }
    }

    /// Updates "Update All" may install without asking: in place (or .pkg via an enabled helper),
    /// compatible with this Mac, and not owned by a vendor updater.
    var installableUpdates: [AvailableUpdate] {
        pendingUpdates.filter { update in
            installState(for: update) == .pending
                && compatibilityWarning(for: update) == nil
                && !opensVendorUpdater(update)
                && isUnattended(resolvedInstallMethod(for: update))
        }
    }

    private func isUnattended(_ method: ResolvedInstallMethod) -> Bool {
        switch method {
        case .standard(.automatic): true
        case .standard(.installerPackage): helperStatus == .enabled && services.packageInstaller != nil
        case .standard(.appStore), .standard(.manualDownload), .vendorManaged: false
        }
    }

    var menuBarSymbol: String {
        pendingUpdates.isEmpty ? "arrow.down.app" : "arrow.down.app.fill"
    }

    func update(for app: InstalledApp) -> AvailableUpdate? {
        allUpdates.first { $0.app.bundleIdentifier == app.bundleIdentifier }
    }

    func installState(for update: AvailableUpdate) -> InstallState {
        installStates[update.id] ?? .pending
    }

    /// Precise result of the last check for this app (nil before the first check).
    func checkResult(for app: InstalledApp) -> UpdateCheckResult? {
        checkResults[app.bundleIdentifier]
    }

    var releaseNotesLoader: any ReleaseNotesLoading { services.releaseNotesLoader }

    // MARK: Checking

    /// Scans installed apps and checks all sources. Returns the found, non-excluded updates.
    @discardableResult
    func refresh() async -> [AvailableUpdate] {
        guard !isBusy else { return updates }
        state = .scanning
        do {
            let apps = try await scanner.scan()
            installedApps = apps
            state = .checking
            let results = await reconcileInstalledVersions(await checker.checkAllDetailed(apps))
            checkResults = Dictionary(results.map { ($0.app.bundleIdentifier, $0) }) { first, _ in first }
            let found = results.compactMap(\.update)
                .sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
            installStates = installStates.filter { id, _ in found.contains { $0.id == id } }
            vendorManagementCache = await detectVendorManagement(in: apps)
            // Manual and scheduled checks both start the first-seen clock.
            releaseDates = await services.firstSeen.record(found)
            state = .loaded(found)
            lastChecked = .now
            Task { await loadDownloadSizes(for: found) }
            await refreshHelperStatus()
            await refreshBackups()
            return updates
        } catch {
            logger.error("Refresh failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
            return []
        }
    }

    @discardableResult
    func refreshHelperStatus() async -> HelperStatus {
        helperStatus = await services.helper?.status ?? .notFound
        return helperStatus
    }

    // MARK: Manual guidance

    func openInAppStore(_ update: AvailableUpdate) {
        let url = URL(string: "macappstore://showUpdatesPage") ?? update.downloadURL
        workspace.open(url)
        setInstallState(.needsManualAction(String(localized: "Update it from the App Store.")), for: update)
    }

    /// Opens the release page (or the raw download) in the browser.
    func openDownloadPage(_ update: AvailableUpdate) {
        workspace.open(update.releaseNotesURL ?? update.downloadURL)
    }

    /// For apps without a known update source: search the developer's site.
    func searchWebForUpdate(_ app: InstalledApp) {
        var components = URLComponents(string: "https://duckduckgo.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: "\(app.name) mac download latest version")]
        if let url = components?.url { workspace.open(url) }
    }

    func revealInFinder(_ update: AvailableUpdate) {
        revealInFinder(update.app)
    }

    func revealInFinder(_ app: InstalledApp) {
        workspace.activateFileViewerSelecting([app.url])
    }

    func details(for app: InstalledApp) async -> AppDetails {
        await detailsReader.details(for: app)
    }

    func icon(for app: InstalledApp) -> NSImage {
        workspace.icon(forFile: app.url.path)
    }

    // MARK: Beta channel

    func isBetaOptedIn(_ app: InstalledApp) -> Bool {
        betaOptIns.contains(app.bundleIdentifier)
    }

    /// The Sparkle source reads opt-ins on every check, so only a refresh is needed.
    func setBeta(_ enabled: Bool, for app: InstalledApp) {
        guard managedGate.areBetaChannelsAllowed else { return }
        betaOptIns = services.betaStore.setOptedIn(enabled, for: app.bundleIdentifier)
        Task { await refresh() }
    }

    // MARK: Exclusions

    func ignore(_ app: InstalledApp) {
        applyExclusions(exclusions.ignoring(app.bundleIdentifier))
    }

    func skipVersion(of update: AvailableUpdate) {
        applyExclusions(exclusions.skipping(version: update.newVersion, of: update.app.bundleIdentifier))
    }

    /// Stops ignoring the app and un-skips its skipped version. A version ceiling is kept, and an
    /// administrator-forced ignore (MDM) cannot be removed.
    func include(_ bundleIdentifier: String) {
        guard !isIgnoreLocked(bundleIdentifier) else { return }
        applyExclusions(exclusions.unignoring(bundleIdentifier))
    }

    func setCeiling(_ prefix: String?, for app: InstalledApp) {
        setCeiling(prefix, forBundleIdentifier: app.bundleIdentifier)
    }

    func setCeiling(_ prefix: String?, forBundleIdentifier bundleIdentifier: String) {
        applyExclusions(exclusions.capping(bundleIdentifier, at: prefix))
    }

    /// Re-reads after saving so administrator-forced ignores reappear (they can't be removed).
    private func applyExclusions(_ rules: ExclusionRules) {
        do {
            try exclusionStore.save(rules)
        } catch {
            logger.error("Saving exclusions failed: \(error.localizedDescription, privacy: .public)")
        }
        exclusions = exclusionStore.load()
    }

    func setInstallState(_ newState: InstallState, for update: AvailableUpdate) {
        installStates = installStates.merging([update.id: newState]) { _, new in new }
    }
}
