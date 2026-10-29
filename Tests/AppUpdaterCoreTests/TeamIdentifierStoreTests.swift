import Foundation
import Testing
@testable import AppUpdaterCore

@Suite("TeamIdentifierStore")
struct TeamIdentifierStoreTests {
    private let suiteName = "TeamIdentifierStoreTests-\(UUID().uuidString)"

    private func makeStore() throws -> (UserDefaultsTeamIdentifierStore, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (UserDefaultsTeamIdentifierStore(defaults: defaults), defaults)
    }

    @Test("Unknown bundle returns nil")
    func unknown() throws {
        let (store, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(store.lastKnownTeamIdentifier(for: "com.example.a") == nil)
    }

    @Test("Record, overwrite and forget")
    func roundTrip() throws {
        let (store, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        store.record("TEAM1", for: "com.example.a")
        store.record("TEAM2", for: "com.example.b")
        store.record("TEAM3", for: "com.example.a")
        #expect(store.lastKnownTeamIdentifier(for: "com.example.a") == "TEAM3")
        #expect(store.lastKnownTeamIdentifier(for: "com.example.b") == "TEAM2")
        store.forget("com.example.a")
        #expect(store.lastKnownTeamIdentifier(for: "com.example.a") == nil)
        #expect(store.lastKnownTeamIdentifier(for: "com.example.b") == "TEAM2")
    }

    @Test("Values persist across store instances sharing a suite")
    func persists() throws {
        let (store, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        store.record("TEAM1", for: "com.example.a")
        let reopened = UserDefaultsTeamIdentifierStore(defaults: defaults)
        #expect(reopened.lastKnownTeamIdentifier(for: "com.example.a") == "TEAM1")
    }
}
