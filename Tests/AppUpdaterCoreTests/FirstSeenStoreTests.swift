import Foundation
import Testing
@testable import AppUpdaterCore

enum AutoInstallFixtures {
    static let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func update(
        _ bundleID: String = "com.example.app",
        version: String = "2.0",
        url: String = "https://example.com/App.zip",
        source: UpdateSourceKind = .sparkle,
        publishedAt: Date? = nil
    ) -> AvailableUpdate {
        let app = InstalledApp(
            bundleIdentifier: bundleID,
            name: "App",
            url: URL(fileURLWithPath: "/Applications/App.app"),
            shortVersion: "1.0",
            buildVersion: nil,
            sparkleFeedURL: nil,
            isFromAppStore: source == .appStore
        )
        return AvailableUpdate(
            app: app, newVersion: version, downloadURL: URL(string: url)!, source: source, publishedAt: publishedAt
        )
    }
}

/// Mutable clock for tests; access is serialized by the lock.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date) { current = date }

    var now: Date { lock.withLock { current } }

    func advance(days: Int) {
        lock.withLock { current = current.addingTimeInterval(TimeInterval(days) * 86_400) }
    }
}

@Suite("FirstSeenStore")
struct FirstSeenStoreTests {
    private let suite = "FirstSeenStoreTests.\(UUID().uuidString)"

    private func makeStore(clock: TestClock, retentionDays: Int = 180) throws -> (FirstSeenStore, UserDefaults) {
        // Separate instances of the same suite: one is handed to the actor, one stays with the test.
        let defaults = try #require(UserDefaults(suiteName: suite))
        let storeDefaults = try #require(UserDefaults(suiteName: suite))
        let store = FirstSeenStore(
            defaults: storeDefaults,
            retention: TimeInterval(retentionDays) * 86_400,
            now: { clock.now }
        )
        return (store, defaults)
    }

    @Test func recordsFirstSeenOnceAndKeepsOriginalDate() async throws {
        let clock = TestClock(AutoInstallFixtures.referenceDate)
        let (store, defaults) = try makeStore(clock: clock)
        defer { defaults.removePersistentDomain(forName: suite) }
        let update = AutoInstallFixtures.update()

        let first = await store.record([update])
        clock.advance(days: 3)
        let second = await store.record([update])

        #expect(first[update.id] == ReleaseDate(date: AutoInstallFixtures.referenceDate, kind: .firstSeen))
        #expect(second[update.id] == first[update.id])
    }

    @Test func publishedDateWinsOverFirstSeen() async throws {
        let clock = TestClock(AutoInstallFixtures.referenceDate)
        let (store, defaults) = try makeStore(clock: clock)
        defer { defaults.removePersistentDomain(forName: suite) }
        let published = AutoInstallFixtures.referenceDate.addingTimeInterval(-86_400)
        let update = AutoInstallFixtures.update(publishedAt: published)

        let dates = await store.record([update])

        #expect(dates[update.id] == ReleaseDate(date: published, kind: .published))
        #expect(await store.releaseDate(for: update)?.kind == .published)
    }

    @Test func persistsAcrossInstances() async throws {
        let clock = TestClock(AutoInstallFixtures.referenceDate)
        let (store, defaults) = try makeStore(clock: clock)
        defer { defaults.removePersistentDomain(forName: suite) }
        let update = AutoInstallFixtures.update()
        _ = await store.record([update])

        clock.advance(days: 5)
        let reopened = FirstSeenStore(defaults: try #require(UserDefaults(suiteName: suite)), now: { clock.now })

        #expect(await reopened.firstSeen(for: update) == AutoInstallFixtures.referenceDate)
    }

    @Test func prunesSupersededVersionsAndExpiredEntries() async throws {
        let clock = TestClock(AutoInstallFixtures.referenceDate)
        let (store, defaults) = try makeStore(clock: clock, retentionDays: 10)
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = AutoInstallFixtures.update(version: "2.0")
        let other = AutoInstallFixtures.update("com.other.app")
        _ = await store.record([old, other])

        clock.advance(days: 1)
        let newer = AutoInstallFixtures.update(version: "2.1")
        _ = await store.record([newer])
        #expect(await store.firstSeen(for: old) == nil)
        #expect(await store.firstSeen(for: other) != nil)

        clock.advance(days: 20)
        _ = await store.record([newer])
        #expect(await store.firstSeen(for: other) == nil)
        #expect(await store.firstSeen(for: newer) != nil)
    }

    @Test func unknownUpdateHasNoDate() async throws {
        let clock = TestClock(AutoInstallFixtures.referenceDate)
        let (store, defaults) = try makeStore(clock: clock)
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(await store.releaseDate(for: AutoInstallFixtures.update()) == nil)
    }

    @Test func corruptDataIsDiscarded() async throws {
        let clock = TestClock(AutoInstallFixtures.referenceDate)
        let (store, defaults) = try makeStore(clock: clock)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("nope".utf8), forKey: FirstSeenStore.defaultKey)
        let update = AutoInstallFixtures.update()

        let dates = await store.record([update])

        #expect(dates[update.id]?.kind == .firstSeen)
    }
}
