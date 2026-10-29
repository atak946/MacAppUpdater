import AppUpdaterCore
import Foundation
import MaintenanceCore
import MonitorCore

/// The app's real view models wired to demo services, the screenshot counterpart of `AppEnvironment`.
/// Every store uses the throwaway defaults suite; nothing is started, scheduled or fetched.
@MainActor
final class DemoStage {
    let environment: DemoEnvironment
    let viewModel: UpdatesViewModel
    let menuBarViewModel: UpdatesViewModel
    let formulaeModel: FormulaeModel
    let cleanupModel: CleanupModel
    let startupModel: StartupModel
    let securityModel: SecurityModel
    let monitorModel: MonitorModel
    private let apps: [InstalledApp]
    private let bundleURLs: [String: URL]
    private let now: Date

    init(now: Date) throws {
        let environment = try DemoEnvironment()
        let defaults = environment.defaults
        let bundleURLs = try DemoBundles.make(in: environment.subdirectory("Applications"))
        let apps = DemoFixtures.apps.map { fixture in
            InstalledApp(
                bundleIdentifier: fixture.bundleID, name: fixture.name,
                url: bundleURLs[fixture.bundleID] ?? environment.directory,
                shortVersion: fixture.version, buildVersion: nil, sparkleFeedURL: nil,
                isFromAppStore: fixture.isFromAppStore
            )
        }
        let updates = Self.updates(for: apps, now: now)
        self.environment = environment
        self.apps = apps
        self.bundleURLs = bundleURLs
        self.now = now

        viewModel = Self.makeViewModel(apps: apps, updates: updates, defaults: defaults, now: now)
        // The menu bar panel shows a short list, as on a Mac that was checked recently.
        menuBarViewModel = Self.makeViewModel(
            apps: apps,
            updates: updates.filter { DemoFixtures.menuBarUpdateIDs.contains($0.app.bundleIdentifier) },
            defaults: defaults, now: now
        )
        formulaeModel = FormulaeModel(homebrew: DemoHomebrew())
        cleanupModel = CleanupModel(
            scanner: DemoCleanupScanner(report: DemoFixtures.cleanupReport(
                home: FileManager.default.homeDirectoryForCurrentUser, now: now
            )),
            cleaner: DemoCleaner()
        )
        startupModel = StartupModel(scanner: DemoStartupScanner(), controller: DemoStartupScanner())
        securityModel = SecurityModel(checker: DemoSecurityChecker(), auditor: DemoSecurityChecker())
        monitorModel = MonitorModel(
            system: DemoSystemSampler(),
            processes: DemoProcessSampler(bundleURLs: bundleURLs),
            ports: DemoPortScanner(),
            network: DemoNetworkSampler(),
            terminator: DemoPortScanner(),
            currentUserID: DemoMonitorFixtures.userID
        )
        monitorModel.usageHistory = UsageHistoryModel(
            recorder: DemoUsageRecorder(bundleURLs: bundleURLs, now: now),
            store: nil, notifier: nil, defaults: defaults
        )
    }

    /// Runs every model once against the demo services, like a first launch would.
    func prepare() async {
        await viewModel.refresh()
        await menuBarViewModel.refresh()
        await viewModel.loadHistory()
        viewModel.insights = DemoFixtures.insightsReport(apps: apps, now: now)
        await formulaeModel.refresh()
        await cleanupModel.scan()
        // Fill the charts: one tick per two seconds, the network column reads every third tick.
        let start = now.addingTimeInterval(-Double(DemoMonitorFixtures.warmUpTicks) * 2)
        for tick in 0..<DemoMonitorFixtures.warmUpTicks {
            await monitorModel.sampleOnce(including: .ports, now: start.addingTimeInterval(Double(tick) * 2))
        }
        if let history = monitorModel.usageHistory {
            for minute in stride(from: 24 * 60, through: 0, by: -1) {
                await history.recordOnce(now: now.addingTimeInterval(-Double(minute) * 60))
            }
        }
    }

    private static func makeViewModel(
        apps: [InstalledApp], updates: [AvailableUpdate], defaults: UserDefaults, now: Date
    ) -> UpdatesViewModel {
        let services = UpdateServices(
            packageInstaller: DemoRefusingInstaller(),
            helper: DemoHelper(),
            backupStore: nil,
            history: DemoHistory(DemoFixtures.history(now: now)),
            policies: UserDefaultsUpdatePoliciesStore(defaults: defaults),
            betaStore: BetaChannelStore(defaults: defaults),
            insights: nil,
            compatibility: CompatibilityAnalyzer(currentSystemVersion: DemoFixtures.systemVersion),
            runningApps: DemoRunningApps(),
            releaseNotesLoader: DemoReleaseNotes(),
            conditions: DemoConditions(),
            firstSeen: DemoFirstSeen(),
            vendorDetector: DemoVendorDetector(),
            downloadHosts: UserDefaultsDownloadHostStore(defaults: defaults),
            managed: .unmanaged,
            sizeProbe: DemoSizeProbe(sizes: downloadSizes(updates)),
            versionAliases: nil
        )
        return UpdatesViewModel(
            scanner: DemoScanner(apps: apps),
            checker: DemoChecker(updates: updates),
            downloader: DemoRefusingInstaller(),
            installer: DemoRefusingInstaller(),
            services: services,
            exclusionStore: UserDefaultsExclusionRulesStore(defaults: defaults)
        )
    }

    private static func updates(for apps: [InstalledApp], now: Date) -> [AvailableUpdate] {
        DemoFixtures.updates.compactMap { fixture in
            guard let app = apps.first(where: { $0.bundleIdentifier == fixture.bundleID }) else { return nil }
            let file = app.name.replacingOccurrences(of: " ", with: "-") + "-\(fixture.newVersion).dmg"
            return AvailableUpdate(
                app: app,
                newVersion: fixture.newVersion,
                downloadURL: URL(string: "https://downloads.example.com/\(file)") ?? URL(fileURLWithPath: "/"),
                source: fixture.source,
                releaseNotes: fixture.notes,
                minimumSystemVersion: fixture.minimumSystemVersion,
                publishedAt: now.addingTimeInterval(-fixture.publishedDaysAgo * 86_400)
            )
        }
    }

    private static func downloadSizes(_ updates: [AvailableUpdate]) -> [URL: Int64] {
        Dictionary(updates.compactMap { update in
            DemoFixtures.updates.first { $0.bundleID == update.app.bundleIdentifier }
                .map { (update.downloadURL, Int64($0.downloadMegabytes * 1_000_000)) }
        }) { first, _ in first }
    }
}
