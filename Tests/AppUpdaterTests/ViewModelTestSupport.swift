import AppKit
import AppUpdaterCore
import Foundation
@testable import AppUpdater

// Stubs for driving `UpdatesViewModel` without network, disk or running apps.

struct StubScanner: AppScanning {
    let apps: [InstalledApp]
    func scan() async throws -> [InstalledApp] { apps }
}

struct StubChecker: UpdateChecking {
    let updates: [AvailableUpdate]

    func checkAll(_ apps: [InstalledApp]) async -> [AvailableUpdate] {
        await checkAllDetailed(apps).compactMap(\.update)
    }

    func checkAllDetailed(_ apps: [InstalledApp]) async -> [UpdateCheckResult] {
        apps.map { app in
            let update = updates.first { $0.app.bundleIdentifier == app.bundleIdentifier }
            return UpdateCheckResult(
                app: app,
                matchedSource: update?.source ?? .homebrew,
                latestVersion: update?.newVersion ?? app.shortVersion,
                update: update,
                errors: []
            )
        }
    }
}

/// Returns a fixed file, or waits until cancelled when `blocksUntilCancelled`.
struct StubDownloader: UpdateDownloading {
    var blocksUntilCancelled = false

    func download(_ update: AvailableUpdate) async throws -> URL {
        if blocksUntilCancelled {
            try await Task.sleep(for: .seconds(3600))
        }
        return URL(fileURLWithPath: "/tmp/stub-\(update.newVersion).dmg")
    }
}

actor RecordingInstaller: UpdateInstalling {
    private(set) var installed: [AvailableUpdate.ID] = []
    private let error: UpdaterError?

    init(failingWith error: UpdaterError? = nil) {
        self.error = error
    }

    func install(_ update: AvailableUpdate, from packageURL: URL) async throws {
        if let error { throw error }
        installed.append(update.id)
    }
}

struct StubHelper: HelperStatusProviding {
    let status: HelperStatus
}

actor InMemoryHistory: UpdateHistoryRecording {
    private var stored: [UpdateHistoryEntry] = []

    func entries() -> [UpdateHistoryEntry] { stored }
    func record(_ entry: UpdateHistoryEntry) throws { stored.insert(entry, at: 0) }
    func clear() throws { stored = [] }
}

struct StubRunningApps: RunningAppChecking {
    let running: Set<String>
    func isRunning(bundleIdentifier: String) async -> Bool { running.contains(bundleIdentifier) }
}

final class InMemoryPolicies: UpdatePoliciesStoring, @unchecked Sendable {
    let policies: UpdatePolicies
    init(_ policies: UpdatePolicies) { self.policies = policies }
    func load() -> UpdatePolicies { policies }
    func save(_ policies: UpdatePolicies) throws {}
}

final class InMemoryExclusions: ExclusionRulesStoring, @unchecked Sendable {
    private var rules = ExclusionRules()
    func load() -> ExclusionRules { rules }
    func save(_ rules: ExclusionRules) throws { self.rules = rules }
}

/// Fixed power / network / running apps for the auto-install planner.
struct FixedConditions: SystemConditionsProvider {
    let value: SystemConditionsSnapshot
    func snapshot() async -> SystemConditionsSnapshot { value }
}

/// First seen "a long time ago" unless the update carries a published date.
struct StubFirstSeen: FirstSeenRecording {
    var firstSeen = Date(timeIntervalSince1970: 0)

    func record(_ updates: [AvailableUpdate]) async -> [String: ReleaseDate] {
        Dictionary(updates.compactMap { update in
            ReleaseDate.resolve(for: update, firstSeen: firstSeen).map { (update.id, $0) }
        }) { first, _ in first }
    }

    func releaseDate(for update: AvailableUpdate) async -> ReleaseDate? {
        ReleaseDate.resolve(for: update, firstSeen: firstSeen)
    }
}

struct StubVendorDetector: VendorManagementDetecting {
    let managed: [String: VendorManagement]
    func detect(_ app: InstalledApp) -> VendorManagement? { managed[app.bundleIdentifier] }
}

/// Records URLs instead of opening a browser or launching apps.
final class RecordingWorkspace: NSWorkspace, @unchecked Sendable {
    private(set) var opened: [URL] = []

    override func open(_ url: URL) -> Bool {
        opened.append(url)
        return true
    }

    private(set) var revealed: [URL] = []

    override func activateFileViewerSelecting(_ fileURLs: [URL]) {
        revealed.append(contentsOf: fileURLs)
    }

    override func openApplication(
        at applicationURL: URL,
        configuration: NSWorkspace.OpenConfiguration,
        completionHandler: (@Sendable (NSRunningApplication?, (any Error)?) -> Void)? = nil
    ) {
        opened.append(applicationURL)
    }
}

/// Optional collaborators for `makeViewModel`, grouped to keep the factory signature short.
struct ViewModelExtras {
    var managed: ManagedConfiguration = .unmanaged
    var vendorManaged: [String: VendorManagement] = [:]
    var vendorStrategy: [String: VendorInstallStrategy] = [:]
    var workspace = RecordingWorkspace()
    /// Overrides the `downloader:` argument (e.g. a progress-reporting or failing downloader).
    var downloader: (any UpdateDownloading)?
    var packageInstaller: (any UpdateInstalling)? = RecordingInstaller()
    var backupStore: (any AppBackupStoring)?
    var historyStore: (any UpdateHistoryRecording)?
    var scanner: (any AppScanning)?
    var insights: InsightsCollector?
    var exclusionStore: (any ExclusionRulesStoring)?
    /// Never shells out to `codesign`.
    var detailsReader = AppDetailsReader(verifier: StubSignatureVerifier())
}

struct StubSignatureVerifier: SignatureVerifying {
    var team = "TEAM123"
    func teamIdentifier(of bundleURL: URL) async throws -> String { team }
}

enum Fixtures {
    static func app(_ id: String, version: String = "1.0") -> InstalledApp {
        InstalledApp(
            bundleIdentifier: id, name: id.capitalized, url: URL(fileURLWithPath: "/Applications/\(id).app"),
            shortVersion: version, buildVersion: nil, sparkleFeedURL: nil, isFromAppStore: false
        )
    }

    static func update(
        _ id: String,
        file: String = "app.dmg",
        source: UpdateSourceKind = .homebrew,
        minimumSystemVersion: String? = nil,
        publishedAt: Date? = nil
    ) -> AvailableUpdate {
        AvailableUpdate(
            app: app(id), newVersion: "2.0",
            downloadURL: URL(string: "https://example.com/\(file)")!,
            source: source, minimumSystemVersion: minimumSystemVersion, publishedAt: publishedAt
        )
    }
}

@MainActor
func makeViewModel(
    updates: [AvailableUpdate],
    downloader: StubDownloader = StubDownloader(),
    installer: RecordingInstaller = RecordingInstaller(),
    helper: HelperStatus = .notRegistered,
    history: InMemoryHistory = InMemoryHistory(),
    running: Set<String> = [],
    policies: UpdatePolicies = UpdatePolicies(),
    extras: ViewModelExtras = ViewModelExtras()
) -> UpdatesViewModel {
    let defaults = UserDefaults(suiteName: "AppUpdaterTests-\(UUID().uuidString)")!
    let strategies = extras.vendorStrategy
    let services = UpdateServices(
        packageInstaller: extras.packageInstaller,
        helper: StubHelper(status: helper),
        backupStore: extras.backupStore,
        history: extras.historyStore ?? history,
        policies: ManagedUpdatePoliciesStore(base: InMemoryPolicies(policies), configuration: extras.managed),
        betaStore: BetaChannelStore(defaults: defaults),
        insights: extras.insights,
        compatibility: CompatibilityAnalyzer(currentSystemVersion: "14.0"),
        runningApps: StubRunningApps(running: running),
        conditions: FixedConditions(value: SystemConditionsSnapshot(runningBundleIdentifiers: running)),
        firstSeen: StubFirstSeen(),
        vendorDetector: StubVendorDetector(managed: extras.vendorManaged),
        vendorInstallStrategy: { update in update.source == .vendor ? strategies[update.app.bundleIdentifier] : nil },
        downloadHosts: UserDefaultsDownloadHostStore(defaults: defaults),
        managed: extras.managed
    )
    return UpdatesViewModel(
        scanner: extras.scanner ?? StubScanner(apps: updates.map(\.app)),
        checker: StubChecker(updates: updates),
        downloader: extras.downloader ?? downloader,
        installer: installer,
        services: services,
        exclusionStore: ManagedExclusionRulesStore(
            base: extras.exclusionStore ?? InMemoryExclusions(), configuration: extras.managed
        ),
        detailsReader: extras.detailsReader,
        workspace: extras.workspace
    )
}
