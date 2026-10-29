@testable import AppUpdaterCore
import Foundation
import Testing
@testable import AppUpdater

@MainActor
@Suite("UpdatesViewModel history and revert")
struct UpdatesViewModelHistoryTests {
    @Test("refreshBackups keeps the newest backup per installed app")
    func newestBackupPerApp() async {
        let update = Fixtures.update("app")
        let older = BackupFixtures.backup("app", version: "0.8", age: 1000)
        let newer = BackupFixtures.backup("app", version: "0.9", age: 10)
        let store = StubBackupStore([older, newer, BackupFixtures.backup("uninstalled", version: "1", age: 1)])
        let viewModel = makeViewModel(updates: [update], extras: ViewModelExtras(backupStore: store))

        await viewModel.refresh()

        #expect(viewModel.backup(for: update.app) == newer)
        #expect(viewModel.backups.keys.sorted() == ["app"])
    }

    @Test("reverting restores the backup, records a rollback and rescans")
    func revertSuccess() async throws {
        let update = Fixtures.update("app")
        let backup = BackupFixtures.backup("app", version: "0.9", age: 10)
        let store = StubBackupStore([backup])
        let viewModel = makeViewModel(updates: [update], extras: ViewModelExtras(backupStore: store))
        await viewModel.refresh()

        await viewModel.revertToPreviousVersion(update.app)

        #expect(await store.restored == [backup])
        let entry = try #require(viewModel.history.first)
        #expect(entry.outcome == .rolledBack)
        #expect(entry.toVersion == "0.9")
        #expect(viewModel.backup(for: update.app) == nil)
        #expect(viewModel.actionError == nil)
    }

    @Test("a failing restore keeps the backup and surfaces an alert")
    func revertFailure() async {
        let update = Fixtures.update("app")
        let backup = BackupFixtures.backup("app", version: "0.9", age: 10)
        let viewModel = makeViewModel(
            updates: [update], extras: ViewModelExtras(backupStore: StubBackupStore([backup], failRestore: true))
        )
        await viewModel.refresh()

        await viewModel.revertToPreviousVersion(update.app)

        #expect(viewModel.actionError == "Could not revert App: Backup is damaged")
        #expect(viewModel.backup(for: update.app) == backup)
        #expect(viewModel.history.isEmpty)
    }

    @Test("reverting without a backup does nothing")
    func revertWithoutBackup() async {
        let update = Fixtures.update("app")
        let store = StubBackupStore()
        let viewModel = makeViewModel(updates: [update], extras: ViewModelExtras(backupStore: store))
        await viewModel.refresh()

        await viewModel.revertToPreviousVersion(update.app)

        #expect(await store.restored.isEmpty)
        #expect(viewModel.actionError == nil)
    }

    @Test("history loads and clears through the store")
    func loadAndClear() async {
        let history = InMemoryHistory()
        try? await history.record(UpdateHistoryEntry(update: Fixtures.update("app"), outcome: .succeeded))
        let viewModel = makeViewModel(updates: [], history: history)

        await viewModel.loadHistory()
        #expect(viewModel.history.count == 1)

        await viewModel.clearHistory()
        #expect(viewModel.history.isEmpty)
    }

    @Test("history store failures are logged and the view keeps what the store returns")
    func historyFailures() async {
        let seed = UpdateHistoryEntry(update: Fixtures.update("old"), outcome: .succeeded)
        let update = Fixtures.update("app")
        let viewModel = makeViewModel(updates: [update], extras: ViewModelExtras(historyStore: FailingHistory(seed: [seed])))
        await viewModel.refresh()

        await viewModel.install(update)
        #expect(viewModel.installState(for: update) == .installed)
        #expect(viewModel.history == [seed])

        await viewModel.clearHistory()
        #expect(viewModel.history == [seed])
    }

    @Test("without a history store nothing is recorded")
    func noHistoryStore() async {
        let update = Fixtures.update("app")
        let viewModel = makeViewModel(updates: [update])
        let bare = UpdatesViewModel(
            scanner: StubScanner(apps: [update.app]), checker: StubChecker(updates: [update]),
            downloader: StubDownloader(), installer: RecordingInstaller(),
            services: UpdateServices(
                betaStore: BetaChannelStore(defaults: UserDefaults(suiteName: "VMTests-\(UUID().uuidString)")!),
                runningApps: StubRunningApps(running: []),
                conditions: FixedConditions(value: SystemConditionsSnapshot()),
                firstSeen: StubFirstSeen(), vendorDetector: StubVendorDetector(managed: [:])
            ),
            exclusionStore: InMemoryExclusions(), workspace: RecordingWorkspace()
        )

        await bare.recordHistory(UpdateHistoryEntry(update: update, outcome: .succeeded))
        await bare.loadHistory()
        await bare.refreshBackups()

        #expect(bare.history.isEmpty)
        #expect(bare.backups.isEmpty)
        #expect(await bare.refreshHelperStatus() == .notFound)
        #expect(viewModel.history.isEmpty)
    }
}

@MainActor
@Suite("UpdatesViewModel insights, guidance and hints")
struct UpdatesViewModelLibraryTests {
    @Test("before insights, warnings come from the cheap checks (vendor, compatibility)")
    func cheapWarnings() async {
        let managed = Fixtures.update("managed")
        let newOS = Fixtures.update("newos", minimumSystemVersion: "99.0")
        let viewModel = makeViewModel(
            updates: [managed, newOS], extras: ViewModelExtras(vendorManaged: ["managed": VendorFixtures.setapp])
        )
        await viewModel.refresh()

        #expect(viewModel.warnings(for: managed.app).map(\.kind).contains(.managedByVendor(updaterName: "Setapp")))
        #expect(viewModel.warnings(for: newOS.app).map(\.kind).contains(.updateRequiresNewerMacOS(required: "99.0")))
    }

    @Test("refreshInsights builds a report once a collector is configured")
    func refreshInsights() async throws {
        let update = Fixtures.update("app")
        let collector = InsightsCollector(
            detailsReader: AppDetailsReader(verifier: StubSignatureVerifier()),
            usageReader: NoUsage(), teamStore: NoTeams()
        )
        let viewModel = makeViewModel(updates: [update], extras: ViewModelExtras(insights: collector))
        let none = makeViewModel(updates: [update])
        await viewModel.refresh()

        await viewModel.refreshInsights()
        await none.refreshInsights()

        let report = try #require(viewModel.insights)
        #expect(report.totalApps == 1)
        #expect(!viewModel.isLoadingInsights)
        #expect(viewModel.warnings(for: update.app) == report.warnings(for: "app"))
        #expect(none.insights == nil)
    }

    @Test("refreshInsights before the first scan leaves insights unset instead of caching an empty report")
    func refreshInsightsBeforeScan() async {
        let collector = InsightsCollector(
            detailsReader: AppDetailsReader(verifier: StubSignatureVerifier()),
            usageReader: NoUsage(), teamStore: NoTeams()
        )
        let viewModel = makeViewModel(updates: [Fixtures.update("app")], extras: ViewModelExtras(insights: collector))

        await viewModel.refreshInsights()

        #expect(viewModel.insights == nil)
        #expect(!viewModel.isLoadingInsights)
    }

    @Test("uninstall is allowed for regular apps; a rescan only follows a removed bundle")
    func uninstallGuards() async {
        let app = Fixtures.app("app")
        let scanner = CountingScanner(apps: [app])
        let viewModel = makeViewModel(updates: [], extras: ViewModelExtras(scanner: scanner))
        let report = UninstallReport(app: app, trashed: [], failures: [])

        #expect(viewModel.canUninstall(app))
        #expect(!viewModel.canUninstall(Fixtures.app("com.apple.Safari")))
        viewModel.didUninstall(report)
        for _ in 0..<100 { await Task.yield() }

        #expect(scanner.scans == 0)
    }

    @Test("guidance actions open the right pages and never touch real apps")
    func guidanceURLs() async throws {
        let workspace = RecordingWorkspace()
        let notes = URL(string: "https://example.com/notes")!
        let app = Fixtures.app("app")
        let withNotes = AvailableUpdate(app: app, newVersion: "2.0", downloadURL: URL(string: "https://e.com/a.dmg")!,
                                        source: .github, releaseNotesURL: notes)
        let bare = Fixtures.update("bare")
        let viewModel = makeViewModel(updates: [withNotes, bare], extras: ViewModelExtras(workspace: workspace))

        viewModel.openDownloadPage(withNotes)
        viewModel.openDownloadPage(bare)
        viewModel.searchWebForUpdate(app)
        viewModel.searchHomebrew(for: app)
        viewModel.revealInFinder(bare)
        await viewModel.reportMissingApp(app)

        let opened = workspace.opened
        #expect(opened.count == 5)
        #expect(opened[0] == notes)
        #expect(opened[1] == bare.downloadURL)
        #expect(opened[2].host == "duckduckgo.com")
        #expect(opened[2].query?.contains("App%20mac%20download") == true)
        #expect(opened[4].host == "github.com")
        #expect(workspace.revealed == [bare.app.url])
    }

    @Test("release date label distinguishes published from first-seen dates")
    func releaseDateLabels() async {
        let published = Fixtures.update("published", publishedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let unpublished = Fixtures.update("unpublished")
        let viewModel = makeViewModel(updates: [published, unpublished])
        #expect(viewModel.releaseDateLabel(for: unpublished) == nil)

        await viewModel.refresh()

        #expect(viewModel.releaseDateLabel(for: published)?.hasPrefix("Released ") == true)
        #expect(viewModel.releaseDateLabel(for: unpublished)?.hasPrefix("First seen ") == true)
    }

    @Test("no auto-install hint for excluded, notify-only or non-automatic updates")
    func noHintCases() async {
        let excluded = Fixtures.update("excluded")
        let pkg = Fixtures.update("pkgapp", file: "setup.pkg")
        let notify = Fixtures.update("notify")
        let policies = UpdatePolicies(defaultPolicy: .autoInstall, overrides: ["notify": .notifyOnly]).settingDeferralDays(3)
        let viewModel = makeViewModel(updates: [excluded, pkg, notify], policies: policies)
        await viewModel.refresh()
        viewModel.ignore(excluded.app)

        #expect(viewModel.autoInstallHint(for: excluded) == nil)
        #expect(viewModel.autoInstallHint(for: pkg) == nil)
        #expect(viewModel.autoInstallHint(for: notify) == nil)
    }

    @Test("version ceiling options offer major and minor prefixes", arguments: [
        ("5.2.1", "5", "5.2"),
        ("5.2", "5", "5.2"),
        ("5", "5", nil),
        ("2024", "2024", nil),
        ("", "", nil),
    ] as [(String, String, String?)])
    func ceilingOptions(version: String, major: String, minor: String?) {
        let options = VersionCeilingOptions(version: version)

        #expect(options.major == major)
        #expect(options.minor == minor)
    }
}

private struct NoUsage: AppUsageReading {
    func lastUsedDate(of appURL: URL) -> Date? { nil }
    func bundleSize(of appURL: URL) -> Int64? { nil }
}

private struct NoTeams: TeamIdentifierStoring {
    func lastKnownTeamIdentifier(for bundleIdentifier: String) -> String? { nil }
    func record(_ teamIdentifier: String, for bundleIdentifier: String) {}
    func forget(_ bundleIdentifier: String) {}
}
