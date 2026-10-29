import Foundation
import os
import Testing
@testable import AppUpdaterCore

/// Fixed last-used date per app path; no Spotlight.
struct StubUsageReader: AppUsageReading {
    var lastUsed: [String: Date] = [:]
    func lastUsedDate(of appURL: URL) -> Date? { lastUsed[appURL.lastPathComponent] }
    func bundleSize(of appURL: URL) -> Int64? { nil }
}

/// In-memory team id store that records writes.
final class InMemoryTeamStore: TeamIdentifierStoring, @unchecked Sendable {
    private let state: OSAllocatedUnfairLock<[String: String]>
    private let writes = OSAllocatedUnfairLock(initialState: [String]())

    init(_ initial: [String: String] = [:]) {
        state = OSAllocatedUnfairLock(initialState: initial)
    }

    var recordedBundleIDs: [String] { writes.withLock { $0 } }

    func lastKnownTeamIdentifier(for bundleIdentifier: String) -> String? { state.withLock { $0[bundleIdentifier] } }
    func record(_ teamIdentifier: String, for bundleIdentifier: String) {
        writes.withLock { $0.append(bundleIdentifier) }
        state.withLock { $0[bundleIdentifier] = teamIdentifier }
    }
    func forget(_ bundleIdentifier: String) { state.withLock { $0[bundleIdentifier] = nil } }
}

/// Counts assessments so the per-version cache can be checked.
final class CountingGatekeeper: GatekeeperAssessing {
    private let verdict: GatekeeperVerdict
    private let count = OSAllocatedUnfairLock(initialState: 0)

    init(verdict: GatekeeperVerdict) { self.verdict = verdict }
    var assessments: Int { count.withLock { $0 } }

    func assess(_ bundleURL: URL) async -> GatekeeperVerdict {
        count.withLock { $0 += 1 }
        return verdict
    }
}

struct FailingVerifier: SignatureVerifying {
    func teamIdentifier(of bundleURL: URL) async throws -> String {
        throw UpdaterError.signatureInvalid("code object is not signed at all")
    }
}

@Suite("InsightsCollector")
struct InsightsCollectorTests {
    private let root = makeInstallTempDirectory("Insights")

    private func app(_ name: String, version: String = "1.0", appStore: Bool = false) throws -> InstalledApp {
        let url = root.appendingPathComponent("\(name).app")
        try FakeAppBundle.make(at: url, bundleID: "com.example.\(name.lowercased())", version: version)
        return InstalledApp(
            bundleIdentifier: "com.example.\(name.lowercased())", name: name, url: url,
            shortVersion: version, buildVersion: nil, sparkleFeedURL: nil, isFromAppStore: appStore
        )
    }

    private func kinds(_ insight: AppInsight) -> [AppWarning.Kind] { insight.warnings.map(\.kind) }

    @Test("records a Team ID on first sight only and warns when it later changes")
    func teamIdentifierLifecycle() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let foo = try app("Foo")
        let store = InMemoryTeamStore()
        let first = InsightsCollector(
            detailsReader: AppDetailsReader(verifier: PathTeamVerifier(team: "TEAM1")),
            usageReader: StubUsageReader(), teamStore: store
        )
        let changed = InsightsCollector(
            detailsReader: AppDetailsReader(verifier: PathTeamVerifier(team: "EVIL9")),
            usageReader: StubUsageReader(), teamStore: store
        )

        let initial = await first.insight(for: foo, update: nil)
        let afterChange = await changed.insight(for: foo, update: nil)

        #expect(!kinds(initial).contains { if case .teamIdentifierChanged = $0 { true } else { false } })
        #expect(kinds(afterChange).contains(.teamIdentifierChanged(old: "TEAM1", new: "EVIL9")))
        #expect(store.recordedBundleIDs == [foo.bundleIdentifier])
        #expect(store.lastKnownTeamIdentifier(for: foo.bundleIdentifier) == "TEAM1")
    }

    @Test("unsigned apps get an unsigned warning and no Team ID is recorded")
    func unsignedApp() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InMemoryTeamStore()
        let collector = InsightsCollector(
            detailsReader: AppDetailsReader(verifier: FailingVerifier()), usageReader: StubUsageReader(), teamStore: store
        )

        let insight = await collector.insight(for: try app("Foo"), update: nil)

        #expect(kinds(insight).contains(.unsigned) || kinds(insight).contains { if case .signatureInvalid = $0 { true } else { false } })
        #expect(store.recordedBundleIDs.isEmpty)
    }

    @Test("Gatekeeper is asked once per bundle id and version, never for App Store apps")
    func gatekeeperCache() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let gatekeeper = CountingGatekeeper(verdict: .developerIDNotNotarized)
        let collector = InsightsCollector(
            detailsReader: AppDetailsReader(verifier: PathTeamVerifier(team: "T")),
            usageReader: StubUsageReader(), teamStore: InMemoryTeamStore(), gatekeeper: gatekeeper
        )
        let foo = try app("Foo")
        let store = try app("Store", appStore: true)

        let insight = await collector.insight(for: foo, update: nil)
        _ = await collector.insight(for: foo, update: nil)
        _ = await collector.insight(for: store, update: nil)
        _ = await collector.insight(for: try app("Foo", version: "1.1"), update: nil)

        #expect(gatekeeper.assessments == 2)
        #expect(kinds(insight).contains { if case .notNotarized = $0 { true } else { false } })
    }

    @Test("Gatekeeper verdicts persist across launches; unknown verdicts are asked again")
    func gatekeeperVerdictsPersist() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "InsightsCollectorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let foo = try app("Foo")

        let gatekeeper = CountingGatekeeper(verdict: .developerIDNotNotarized)
        for _ in 0..<2 {
            // A fresh collector and cache per iteration, as after a relaunch.
            let collector = InsightsCollector(
                detailsReader: AppDetailsReader(verifier: PathTeamVerifier(team: "T")),
                usageReader: StubUsageReader(), teamStore: InMemoryTeamStore(), gatekeeper: gatekeeper,
                verdictCache: GatekeeperVerdictCache(storage: .defaultsSuite(suite))
            )
            let insight = await collector.insight(for: foo, update: nil)
            #expect(kinds(insight).contains { if case .notNotarized = $0 { true } else { false } })
        }
        #expect(gatekeeper.assessments == 1)

        let unknownGatekeeper = CountingGatekeeper(verdict: .unknown(reason: "offline"))
        let bar = try app("Bar")
        for _ in 0..<2 {
            let collector = InsightsCollector(
                detailsReader: AppDetailsReader(verifier: PathTeamVerifier(team: "T")),
                usageReader: StubUsageReader(), teamStore: InMemoryTeamStore(), gatekeeper: unknownGatekeeper,
                verdictCache: GatekeeperVerdictCache(storage: .defaultsSuite(suite))
            )
            _ = await collector.insight(for: bar, update: nil)
        }
        #expect(unknownGatekeeper.assessments == 2)
    }

    @Test("collect returns one insight per app with bounded concurrency", arguments: [1, 2, 6])
    func collectAll(maxConcurrency: Int) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let apps = try (0..<5).map { try app("App\($0)") }
        let old = Date(timeIntervalSinceNow: -400 * 86_400)
        let collector = InsightsCollector(
            detailsReader: AppDetailsReader(verifier: PathTeamVerifier(team: "T")),
            usageReader: StubUsageReader(lastUsed: ["App0.app": old]), teamStore: InMemoryTeamStore(),
            maxConcurrency: maxConcurrency
        )

        let report = await collector.collect(apps: apps)

        #expect(report.totalApps == 5)
        #expect(Set(report.apps.map(\.app.bundleIdentifier)) == Set(apps.map(\.bundleIdentifier)))
        #expect(report.unusedApps.map(\.app.name) == ["App0"])
    }

    @Test("vendor management and download host changes flow into the warnings")
    func vendorAndHostWarnings() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let foo = try app("Foo")
        let defaults = UserDefaults(suiteName: "InsightsCollectorTests-\(UUID().uuidString)")!
        let hosts = UserDefaultsDownloadHostStore(defaults: defaults)
        let old = AvailableUpdate(app: foo, newVersion: "1.5", downloadURL: URL(string: "https://good.example.com/a.dmg")!, source: .homebrew)
        hosts.record(old)
        let update = AvailableUpdate(app: foo, newVersion: "2.0", downloadURL: URL(string: "https://other.net/a.dmg")!, source: .homebrew)
        let management = VendorManagement(vendor: .setapp, updaterName: "Setapp", openTarget: .url(URL(string: "setapp://")!))
        let collector = InsightsCollector(
            detailsReader: AppDetailsReader(verifier: PathTeamVerifier(team: "T")),
            usageReader: StubUsageReader(), teamStore: InMemoryTeamStore(), downloadHostStore: hosts
        )

        let report = await collector.collect(apps: [foo], updates: [update], vendorManagement: [foo.bundleIdentifier: management])
        let warnings = report.warnings(for: foo.bundleIdentifier).map(\.kind)

        #expect(warnings.contains(.managedByVendor(updaterName: "Setapp")))
        #expect(warnings.contains { if case .downloadHostChanged = $0 { true } else { false } })
    }
}

@Suite("Error descriptions")
struct ErrorDescriptionTests {
    private static let url = URL(fileURLWithPath: "/Users/x/Library/Caches/com.foo")

    @Test("every UninstallError explains itself in plain English", arguments: [
        (UninstallError.systemApp(name: "Safari"), "Safari is part of macOS and cannot be uninstalled."),
        (.protectedApp(name: "AppUpdater"), "AppUpdater cannot uninstall itself."),
        (.appIsRunning(name: "Foo"), "Foo is running. Quit it before uninstalling."),
        (.invalidBundleIdentifier("../x"), "Invalid bundle identifier: ../x"),
        (.nothingSelected, "Nothing is selected."),
        (.notInPlan(url), "\(url.path) was not part of the scan."),
        (.outsideAllowlist(url), "\(url.path) is outside the allowed folders."),
        (.symlinkEscape(url), "\(url.path) is a symbolic link and was skipped."),
        (.bundleMismatch(url), "\(url.path) no longer contains the scanned app."),
        (.itemMissing(url), "\(url.path) no longer exists."),
        (.skippedBecauseBundleFailed(url), "com.foo was kept because the app could not be moved to the Trash."),
        (.trashFailed(url: url, message: "denied"), "Could not move com.foo to the Trash: denied"),
    ])
    func uninstallErrors(error: UninstallError, expected: String) {
        #expect(error.localizedDescription == expected)
    }

    @Test("every leftover kind has a distinct, non-empty display name")
    func leftoverKindNames() {
        let names = LeftoverItem.Kind.allCases.map(\.displayName)

        #expect(names.allSatisfy { !$0.isEmpty })
        #expect(Set(names).count == LeftoverItem.Kind.allCases.count)
        #expect(LeftoverItem.Kind.appBundle.displayName == "Application")
        #expect(LeftoverItem.Kind.byHostPreferences.displayName == "Preferences (ByHost)")
    }

    @Test("uninstall report sums trashed sizes and exposes failure reasons")
    func uninstallReportSummary() {
        let app = TestApps.make()
        let bundle = LeftoverItem(url: app.url, kind: .appBundle, sizeInBytes: 100, confidence: .exact)
        let cache = LeftoverItem(url: Self.url, kind: .caches, sizeInBytes: 23, confidence: .exact)
        let report = UninstallReport(
            app: app,
            trashed: [.init(item: bundle, trashURL: nil), .init(item: cache, trashURL: nil)],
            failures: [.init(url: Self.url, error: .itemMissing(Self.url))]
        )

        #expect(report.reclaimedBytes == 123)
        #expect(report.removedAppBundle)
        #expect(!report.succeeded)
        #expect(report.failures.first?.reason == "\(Self.url.path) no longer exists.")
        #expect(bundle.id == app.url)
    }
}
