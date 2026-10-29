import Foundation
import Testing
@testable import AppUpdaterCore

/// Source scripted with a fixed `SourceLookup` per app.
private struct MatchingStub: SourceMatching {
    let kind: UpdateSourceKind
    var outcome: @Sendable (InstalledApp) throws -> SourceLookup

    func canHandle(_ app: InstalledApp) -> Bool { true }
    func checkForUpdate(_ app: InstalledApp) async throws -> AvailableUpdate? { try await lookup(app).update }
    func lookup(_ app: InstalledApp) async throws -> SourceLookup { try outcome(app) }
}

private func update(_ app: InstalledApp, _ version: String, _ kind: UpdateSourceKind) -> AvailableUpdate {
    AvailableUpdate(app: app, newVersion: version, downloadURL: URL(string: "https://example.com/a.zip")!, source: kind)
}

struct UpdateCheckerDetailedTests {
    @Test func reportsMatchedSourceWhenUpToDate() async {
        let app = TestApps.make()
        let checker = UpdateChecker(sources: [
            MatchingStub(kind: .homebrew, outcome: { _ in .upToDate(latestVersion: "1.0") }),
            MatchingStub(kind: .sparkle, outcome: { _ in .notFound }),
        ])
        let result = await checker.checkDetailed(app)
        #expect(result.matchedSource == .homebrew)
        #expect(result.latestVersion == "1.0")
        #expect(result.update == nil)
        #expect(result.isUpToDate)
    }

    @Test func notFoundEverywhereHasNoMatchedSource() async {
        let checker = UpdateChecker(sources: [MatchingStub(kind: .homebrew, outcome: { _ in .notFound })])
        let result = await checker.checkDetailed(TestApps.make())
        #expect(result.matchedSource == nil)
        #expect(!result.isUpToDate)
    }

    @Test func laterSourceUpdateWinsOverEarlierUpToDate() async {
        let checker = UpdateChecker(sources: [
            MatchingStub(kind: .sparkle, outcome: { _ in .upToDate(latestVersion: "1.0") }),
            MatchingStub(kind: .homebrew, outcome: { app in .update(update(app, "2.0", .homebrew)) }),
        ])
        let result = await checker.checkDetailed(TestApps.make())
        #expect(result.matchedSource == .homebrew)
        #expect(result.update?.newVersion == "2.0")
    }

    @Test func collectsErrorsAndKeepsOrder() async {
        let apps = (0..<10).map { TestApps.make(bundleIdentifier: "com.example.\($0)") }
        let checker = UpdateChecker(sources: [
            MatchingStub(kind: .sparkle, outcome: { _ in throw UpdaterError.network("down") }),
            MatchingStub(kind: .homebrew, outcome: { _ in .upToDate(latestVersion: "1.0") }),
        ], maxConcurrency: 3)
        let results = await checker.checkAllDetailed(apps)
        #expect(results.map(\.app) == apps)
        #expect(results.allSatisfy { $0.errors == ["sparkle: Network error: down"] && $0.matchedSource == .homebrew })
        #expect(await checker.checkAll(apps).isEmpty)
    }
}

struct UpdateCheckerSourceLookupTests {
    @Test func homebrewDistinguishesNotFoundAndUpToDate() async throws {
        let api = URL(string: "https://formulae.brew.sh/api/cask.json")!
        let json = #"[{"token":"example","version":"1.0,42","url":"https://example.com/e.dmg","artifacts":[{"app":["Example.app"]}]}]"#
        let source = HomebrewCaskSource(http: MockHTTPClient(strings: [api.absoluteString: json]), comparator: NumericStubComparator())
        #expect(try await source.lookup(TestApps.make(shortVersion: "1.0")) == .upToDate(latestVersion: "1.0"))
        #expect(try await source.lookup(TestApps.make(fileName: "Other.app")) == .notFound)
        let found = try await source.lookup(TestApps.make(shortVersion: "0.9"))
        #expect(found.update?.newVersion == "1.0")
        #expect(found.update?.releaseNotes == nil)
    }

    @Test func appStoreLookupMatchesAndPopulatesNotes() async throws {
        let lookup = URL(string: "https://itunes.apple.com/lookup?bundleId=com.example.mas&entity=macSoftware")!
        let json = #"{"results":[{"version":"4.2","bundleId":"com.example.mas","trackViewUrl":"https://apps.apple.com/app/id1","releaseNotes":"Fixes","minimumOsVersion":"13.0"}]}"#
        let source = AppStoreSource(http: MockHTTPClient(strings: [lookup.absoluteString: json]), comparator: NumericStubComparator())
        let current = TestApps.make(bundleIdentifier: "com.example.mas", shortVersion: "4.2", isFromAppStore: true)
        #expect(try await source.lookup(current) == .upToDate(latestVersion: "4.2"))
        let old = TestApps.make(bundleIdentifier: "com.example.mas", shortVersion: "4.0", isFromAppStore: true)
        let update = try #require(try await source.lookup(old).update)
        #expect(update.releaseNotes == .markdown("Fixes"))
        #expect(update.minimumSystemVersion == "13.0")
        #expect(try await source.lookup(TestApps.make()) == .notFound)
    }

    @Test("iOS apps on the Mac (kind software, e.g. TestFlight) never report an update")
    func appStoreIgnoresIOSVersion() async throws {
        let lookup = URL(string: "https://itunes.apple.com/lookup?bundleId=com.apple.TestFlight&entity=macSoftware")!
        let json = #"{"results":[{"version":"4.4.1","kind":"software","bundleId":"com.apple.TestFlight","trackViewUrl":"https://apps.apple.com/app/id2"}]}"#
        let source = AppStoreSource(http: MockHTTPClient(strings: [lookup.absoluteString: json]), comparator: NumericStubComparator())
        let app = TestApps.make(bundleIdentifier: "com.apple.TestFlight", shortVersion: "4.4.0", isFromAppStore: true)
        #expect(try await source.lookup(app) == .upToDate(latestVersion: "4.4.0"))

        let mac = json.replacingOccurrences(of: #""kind":"software""#, with: #""kind":"mac-software""#)
        let macSource = AppStoreSource(http: MockHTTPClient(strings: [lookup.absoluteString: mac]), comparator: NumericStubComparator())
        #expect(try await macSource.lookup(app).update?.newVersion == "4.4.1")
    }

    @Test func githubUnmappedAppIsNotFound() async throws {
        let source = GitHubReleasesSource(repositories: [:], http: MockHTTPClient(), comparator: NumericStubComparator())
        #expect(try await source.lookup(TestApps.make()) == .notFound)
    }
}
