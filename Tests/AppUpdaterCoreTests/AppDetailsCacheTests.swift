import Foundation
import os
import Testing
@testable import AppUpdaterCore

/// Counts signature reads so the details cache can be checked; reports a fixed team.
final class CountingVerifier: SignatureVerifying {
    private let team: String
    private let count = OSAllocatedUnfairLock(initialState: 0)

    init(team: String) { self.team = team }
    var reads: Int { count.withLock { $0 } }

    func teamIdentifier(of bundleURL: URL) async throws -> String {
        count.withLock { $0 += 1 }
        return team
    }

    func isApplePlatformCode(_ bundleURL: URL) async -> Bool { false }
}

@Suite("AppDetailsCache")
struct AppDetailsCacheTests {
    private let root = makeInstallTempDirectory("DetailsCache")

    private func app(_ name: String, version: String = "1.0") throws -> InstalledApp {
        let url = root.appendingPathComponent("\(name).app")
        try FakeAppBundle.make(at: url, bundleID: "com.example.\(name.lowercased())", version: version)
        return FakeAppBundle.installedApp(at: url, bundleID: "com.example.\(name.lowercased())", version: version)
    }

    private func collector(_ verifier: CountingVerifier, cache: AppDetailsCache) -> InsightsCollector {
        InsightsCollector(
            detailsReader: AppDetailsReader(verifier: verifier), usageReader: StubUsageReader(),
            teamStore: InMemoryTeamStore(), detailsCache: cache
        )
    }

    private func touch(_ url: URL, secondsFromNow: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: secondsFromNow)], ofItemAtPath: url.path
        )
    }

    @Test("bundle details are read once and reused across launches")
    func reusedAcrossLaunches() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "AppDetailsCacheTests.\(UUID().uuidString)"
        let defaults = try #require(TestDefaults.suite(named: suite))
        defer { defaults.removePersistentDomain(forName: TestDefaults.prefix + suite) }
        let foo = try app("Foo")
        let verifier = CountingVerifier(team: "T1")

        for _ in 0..<2 {
            // A fresh collector and cache per iteration, as after a relaunch.
            let cache = AppDetailsCache(storage: .defaultsSuite(TestDefaults.prefix + suite))
            let report = await collector(verifier, cache: cache).collect(apps: [foo])
            #expect(report.totalApps == 1)
        }

        #expect(verifier.reads == 1)
    }

    @Test("replacing the executable or re-signing invalidates the cached details")
    func changedBundleIsReadAgain() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let foo = try app("Foo")
        let verifier = CountingVerifier(team: "T1")
        let cache = AppDetailsCache()
        let collector = collector(verifier, cache: cache)

        _ = await collector.insight(for: foo, update: nil)
        _ = await collector.insight(for: foo, update: nil)
        #expect(verifier.reads == 1)

        try touch(foo.url.appendingPathComponent("Contents/MacOS/Foo"), secondsFromNow: 60)
        _ = await collector.insight(for: foo, update: nil)
        #expect(verifier.reads == 2)

        let codeResources = foo.url.appendingPathComponent("Contents/_CodeSignature/CodeResources")
        try FileManager.default.createDirectory(
            at: codeResources.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data().write(to: codeResources)
        _ = await collector.insight(for: foo, update: nil)
        #expect(verifier.reads == 3)
    }

    @Test("a new version is read again and uninstalled apps are dropped from storage")
    func newVersionAndPruning() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "AppDetailsCacheTests.\(UUID().uuidString)"
        let defaults = try #require(TestDefaults.suite(named: suite))
        defer { defaults.removePersistentDomain(forName: TestDefaults.prefix + suite) }
        let verifier = CountingVerifier(team: "T1")
        let cache = AppDetailsCache(storage: .defaultsSuite(TestDefaults.prefix + suite))
        let foo = try app("Foo")
        let bar = try app("Bar")

        _ = await collector(verifier, cache: cache).collect(apps: [foo, bar])
        _ = await collector(verifier, cache: cache).collect(apps: [try app("Foo", version: "2.0")])

        #expect(verifier.reads == 3)
        let stored = try #require(defaults.data(forKey: AppDetailsCache.defaultsKey))
        let entries = try JSONDecoder().decode([String: AppDetails].self, from: stored)
        #expect(entries.count == 1)
        #expect(entries.keys.allSatisfy { $0.hasPrefix("com.example.foo@2.0@") })
    }
}
