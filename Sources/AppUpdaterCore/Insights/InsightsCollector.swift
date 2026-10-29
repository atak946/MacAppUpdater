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

    /// Cached per bundle id, version and fingerprint (across launches when the cache has defaults):
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

/// Remembers Gatekeeper verdicts per bundle id, version and bundle fingerprint (the modification
/// date of `Contents`, which a reinstall or a stapled ticket changes). Persisted storage keeps
/// definite verdicts across relaunches; `.unknown` is never stored so a transient failure is
/// retried. Negative verdicts expire after `negativeLifetime`: an app can become notarized without
/// any file changing, because Gatekeeper also looks the ticket up online.
public actor GatekeeperVerdictCache {
    public enum Storage: Sendable {
        case memory
        case standardDefaults
        case defaultsSuite(String)
    }

    /// v2 entries carry the assessment date; v1 (`insights.gatekeeperVerdicts`) is dropped.
    public static let defaultsKey = "insights.gatekeeperVerdicts.v2"
    static let legacyDefaultsKey = "insights.gatekeeperVerdicts"
    public static let defaultNegativeLifetime: TimeInterval = 86_400

    struct Entry: Codable, Sendable {
        let verdict: GatekeeperVerdict
        let assessedAt: Date
    }

    private var entries: [String: Entry]
    private let defaults: UserDefaults?
    private let negativeLifetime: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        storage: Storage = .memory,
        negativeLifetime: TimeInterval = GatekeeperVerdictCache.defaultNegativeLifetime,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        let defaults: UserDefaults? = switch storage {
        case .memory: nil
        case .standardDefaults: .standard
        case .defaultsSuite(let name): UserDefaults(suiteName: name)
        }
        self.defaults = defaults
        self.negativeLifetime = negativeLifetime
        self.now = now
        defaults?.removeObject(forKey: Self.legacyDefaultsKey)
        let stored = defaults?.dictionary(forKey: Self.defaultsKey) as? [String: Data] ?? [:]
        entries = stored.compactMapValues { try? JSONDecoder().decode(Entry.self, from: $0) }
    }

    func verdict(for app: InstalledApp, assessor: any GatekeeperAssessing) async -> GatekeeperVerdict {
        let key = Self.key(for: app)
        if let cached = entries[key], isFresh(cached) { return cached.verdict }
        let verdict = await assessor.assess(app.url)
        entries = entries.merging([key: Entry(verdict: verdict, assessedAt: now())]) { _, new in new }
        persist()
        return verdict
    }

    static func key(for app: InstalledApp) -> String {
        let contents = app.url.appendingPathComponent("Contents")
        let modified = (try? contents.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let fingerprint = modified.map { String(Int($0.timeIntervalSince1970)) } ?? "-"
        return "\(app.bundleIdentifier)@\(app.shortVersion)@\(fingerprint)"
    }

    private func isFresh(_ entry: Entry) -> Bool {
        switch entry.verdict {
        case .notarized: true
        case .developerIDNotNotarized, .rejected: now().timeIntervalSince(entry.assessedAt) < negativeLifetime
        case .unknown: false
        }
    }

    private func persist() {
        guard let defaults else { return }
        let definite = entries.filter { if case .unknown = $0.value.verdict { false } else { true } }
        let encoded = definite.compactMapValues { try? JSONEncoder().encode($0) }
        defaults.set(encoded, forKey: Self.defaultsKey)
    }
}
