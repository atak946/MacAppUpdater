import Foundation
import os

/// Gathers `AppInsight`s for every app with bounded concurrency, then builds the report.
/// Runs off the main actor; safe to `await` from a `@MainActor` view model.
public struct InsightsCollector: Sendable {
    public static let maxConcurrentReads = 3

    private let detailsReader: AppDetailsReader
    private let usageReader: any AppUsageReading
    private let teamStore: any TeamIdentifierStoring
    private let analyzer: CompatibilityAnalyzer
    private let builder: InsightsBuilder
    /// Assesses installed bundles (one `spctl` each); nil skips notarization warnings.
    private let gatekeeper: (any GatekeeperAssessing)?
    private let verdictCache: GatekeeperVerdictCache
    private let downloadHostStore: (any DownloadHostStoring)?
    private let maxConcurrency: Int
    private let logger = Logger(subsystem: "com.macappupdater", category: "InsightsCollector")

    public init(
        detailsReader: AppDetailsReader = AppDetailsReader(),
        usageReader: any AppUsageReading = AppUsageReader(),
        teamStore: any TeamIdentifierStoring = UserDefaultsTeamIdentifierStore(),
        analyzer: CompatibilityAnalyzer = CompatibilityAnalyzer(),
        builder: InsightsBuilder = InsightsBuilder(),
        gatekeeper: (any GatekeeperAssessing)? = nil,
        downloadHostStore: (any DownloadHostStoring)? = nil,
        verdictCache: GatekeeperVerdictCache = GatekeeperVerdictCache(),
        maxConcurrency: Int = InsightsCollector.maxConcurrentReads
    ) {
        self.verdictCache = verdictCache
        self.gatekeeper = gatekeeper
        self.downloadHostStore = downloadHostStore
        self.detailsReader = detailsReader
        self.usageReader = usageReader
        self.teamStore = teamStore
        self.analyzer = analyzer
        self.builder = builder
        self.maxConcurrency = max(1, maxConcurrency)
    }

    /// `vendorManagement` is keyed by bundle identifier (from `VendorManagementDetector`, cached per scan).
    public func collect(
        apps: [InstalledApp],
        updates: [AvailableUpdate] = [],
        vendorManagement: [String: VendorManagement] = [:]
    ) async -> InsightsReport {
        let updatesByID = Dictionary(updates.map { ($0.app.bundleIdentifier, $0) }) { first, _ in first }
        // Background work: it reads every bundle on disk and must not compete with the UI.
        let insights = await Task.detached(priority: .utility) { [self] in
            await gather(apps: apps, updatesByID: updatesByID, vendorManagement: vendorManagement)
        }.value
        logger.info("Collected insights for \(insights.count, privacy: .public) apps")
        return builder.build(from: insights)
    }

    /// Analyzes one app. Records the Team Identifier on first sight only, so a changed
    /// signer keeps warning until the user accepts it via `TeamIdentifierStoring.record`.
    public func insight(
        for app: InstalledApp,
        update: AvailableUpdate?,
        vendorManagement: VendorManagement? = nil
    ) async -> AppInsight {
        let details = await detailsReader.details(for: app)
        let lastUsed = await readLastUsed(app.url)
        let previous = teamStore.lastKnownTeamIdentifier(for: app.bundleIdentifier)
        if previous == nil, case .signed(let team) = details.signature {
            teamStore.record(team, for: app.bundleIdentifier)
        }
        let input = AppAnalysisInput(
            app: app, details: details, update: update,
            lastUsedDate: lastUsed, previousTeamIdentifier: previous,
            installedGatekeeperVerdict: await installedVerdict(for: app),
            downloadHostChange: update.flatMap { downloadHostStore?.check($0) },
            vendorManagement: vendorManagement
        )
        return AppInsight(
            app: app,
            sizeInBytes: details.sizeInBytes,
            lastUsedDate: lastUsed,
            isIntelOnly: CompatibilityAnalyzer.isIntelOnly(details.executableArchitectures),
            warnings: analyzer.warnings(for: input)
        )
    }

    /// Cached per bundle id + version (across launches when the cache has defaults):
    /// `spctl` hashes the whole bundle and may hit the network.
    private func installedVerdict(for app: InstalledApp) async -> GatekeeperVerdict? {
        guard let gatekeeper, !app.isFromAppStore else { return nil }
        return await verdictCache.verdict(for: app, assessor: gatekeeper)
    }

    private func readLastUsed(_ url: URL) async -> Date? {
        let reader = usageReader
        return await Task.detached(priority: .utility) { reader.lastUsedDate(of: url) }.value
    }

    private func gather(
        apps: [InstalledApp],
        updatesByID: [String: AvailableUpdate],
        vendorManagement: [String: VendorManagement]
    ) async -> [AppInsight] {
        await withTaskGroup(of: AppInsight.self, returning: [AppInsight].self) { group in
            var results: [AppInsight] = []
            results.reserveCapacity(apps.count)
            for (index, app) in apps.enumerated() {
                if index >= maxConcurrency, let finished = await group.next() {
                    results.append(finished)
                }
                let update = updatesByID[app.bundleIdentifier]
                let management = vendorManagement[app.bundleIdentifier]
                group.addTask { await insight(for: app, update: update, vendorManagement: management) }
            }
            for await finished in group {
                results.append(finished)
            }
            return results
        }
    }
}

/// Remembers Gatekeeper verdicts per `bundleID@version`. Persisted storage keeps definite
/// verdicts across relaunches; `.unknown` is never stored so a transient failure is retried.
public actor GatekeeperVerdictCache {
    public enum Storage: Sendable {
        case memory
        case standardDefaults
        case defaultsSuite(String)
    }

    public static let defaultsKey = "insights.gatekeeperVerdicts"

    private var verdicts: [String: GatekeeperVerdict]
    private let defaults: UserDefaults?

    public init(storage: Storage = .memory) {
        let defaults: UserDefaults? = switch storage {
        case .memory: nil
        case .standardDefaults: .standard
        case .defaultsSuite(let name): UserDefaults(suiteName: name)
        }
        self.defaults = defaults
        let stored = defaults?.dictionary(forKey: Self.defaultsKey) as? [String: Data] ?? [:]
        verdicts = stored.compactMapValues { try? JSONDecoder().decode(GatekeeperVerdict.self, from: $0) }
    }

    func verdict(for app: InstalledApp, assessor: any GatekeeperAssessing) async -> GatekeeperVerdict {
        let key = "\(app.bundleIdentifier)@\(app.shortVersion)"
        if let cached = verdicts[key] { return cached }
        let verdict = await assessor.assess(app.url)
        verdicts = verdicts.merging([key: verdict]) { _, new in new }
        persist()
        return verdict
    }

    private func persist() {
        guard let defaults else { return }
        let definite = verdicts.filter { if case .unknown = $0.value { false } else { true } }
        let encoded = definite.compactMapValues { try? JSONEncoder().encode($0) }
        defaults.set(encoded, forKey: Self.defaultsKey)
    }
}
