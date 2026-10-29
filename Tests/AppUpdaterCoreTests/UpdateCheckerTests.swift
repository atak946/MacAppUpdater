import Foundation
import os
import Testing
@testable import AppUpdaterCore

/// Scripted source used to verify ordering, fallback and concurrency limits.
private struct ScriptedSource: UpdateSource {
    let kind: UpdateSourceKind
    var handles: @Sendable (InstalledApp) -> Bool = { _ in true }
    var result: @Sendable (InstalledApp) throws -> String? = { _ in nil }
    var tracker: ConcurrencyTracker?

    func canHandle(_ app: InstalledApp) -> Bool { handles(app) }

    func checkForUpdate(_ app: InstalledApp) async throws -> AvailableUpdate? {
        tracker?.enter()
        defer { tracker?.leave() }
        if tracker != nil { try await Task.sleep(for: .milliseconds(5)) }
        guard let version = try result(app) else { return nil }
        return AvailableUpdate(
            app: app, newVersion: version,
            downloadURL: URL(string: "https://example.com/\(kind.rawValue).zip")!, source: kind
        )
    }
}

private final class ConcurrencyTracker: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (current: 0, peak: 0))
    var peak: Int { state.withLock { $0.peak } }
    func enter() { state.withLock { $0.current += 1; $0.peak = max($0.peak, $0.current) } }
    func leave() { state.withLock { $0.current -= 1 } }
}

struct UpdateCheckerTests {
    @Test func usesPriorityOrderRegardlessOfRegistrationOrder() async {
        let checker = UpdateChecker(sources: [
            ScriptedSource(kind: .homebrew, result: { _ in "9.0" }),
            ScriptedSource(kind: .sparkle, result: { _ in "2.0" }),
        ])
        let updates = await checker.checkAll([TestApps.make()])
        #expect(updates.map(\.source) == [.sparkle])
    }

    @Test func fallsThroughOnErrorAndNil() async {
        let checker = UpdateChecker(sources: [
            ScriptedSource(kind: .sparkle, result: { _ in throw UpdaterError.network("down") }),
            ScriptedSource(kind: .github, result: { _ in nil }),
            ScriptedSource(kind: .homebrew, result: { _ in "3.0" }),
        ])
        let update = await checker.check(TestApps.make())
        #expect(update?.source == .homebrew)
        #expect(update?.newVersion == "3.0")
    }

    @Test func skipsSourcesThatCannotHandleApp() async {
        let checker = UpdateChecker(sources: [
            ScriptedSource(kind: .appStore, handles: { $0.isFromAppStore }, result: { _ in "5.0" }),
            ScriptedSource(kind: .homebrew, result: { _ in "1.1" }),
        ])
        let updates = await checker.checkAll([TestApps.make()])
        #expect(updates.map(\.source) == [.homebrew])
    }

    @Test func preservesInputOrderAndOmitsUpToDateApps() async {
        let apps = (0..<20).map { TestApps.make(bundleIdentifier: "com.example.\($0)") }
        let checker = UpdateChecker(sources: [
            ScriptedSource(kind: .homebrew, result: { app in
                Int(app.bundleIdentifier.split(separator: ".").last!)!.isMultiple(of: 2) ? "2.0" : nil
            }),
        ])
        let updates = await checker.checkAll(apps)
        #expect(updates.map(\.app.bundleIdentifier) == apps.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element.bundleIdentifier))
    }

    @Test func boundsConcurrency() async {
        let tracker = ConcurrencyTracker()
        let apps = (0..<24).map { TestApps.make(bundleIdentifier: "com.example.\($0)") }
        let checker = UpdateChecker(
            sources: [ScriptedSource(kind: .homebrew, result: { _ in "2.0" }, tracker: tracker)],
            maxConcurrency: 3
        )
        let updates = await checker.checkAll(apps)
        #expect(updates.count == 24)
        #expect(tracker.peak <= 3)
        #expect(tracker.peak >= 1)
    }

    @Test func appStoreSourceReportsStorePage() async throws {
        let lookup = URL(string: "https://itunes.apple.com/lookup?bundleId=com.example.mas&entity=macSoftware")!
        let json = #"{"resultCount":1,"results":[{"version":"4.2","bundleId":"com.example.mas","trackViewUrl":"https://apps.apple.com/app/id123?mt=12"}]}"#
        let source = AppStoreSource(http: MockHTTPClient(strings: [lookup.absoluteString: json]), comparator: NumericStubComparator())
        let app = TestApps.make(bundleIdentifier: "com.example.mas", shortVersion: "4.1", isFromAppStore: true)
        #expect(source.lookupURL(for: app.bundleIdentifier) == lookup)
        let update = try #require(try await source.checkForUpdate(app))
        #expect(update.source == .appStore)
        #expect(update.newVersion == "4.2")
        #expect(update.downloadURL.host == "apps.apple.com")
        #expect(!source.canHandle(TestApps.make()))
        let empty = AppStoreSource(http: MockHTTPClient(strings: [lookup.absoluteString: #"{"resultCount":0,"results":[]}"#]), comparator: NumericStubComparator())
        #expect(try await empty.checkForUpdate(app) == nil)
    }
}
