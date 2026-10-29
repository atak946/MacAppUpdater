import Foundation
import Testing
@testable import AppUpdaterCore

@Suite("UpdateHistoryStore")
struct UpdateHistoryStoreTests {
    private let directory = makeInstallTempDirectory("UpdateHistoryStoreTests")
    private var fileURL: URL { directory.appendingPathComponent("nested/UpdateHistory.json") }

    private static func entry(
        _ bundleID: String = "com.example.a",
        offset: TimeInterval = 0,
        outcome: UpdateHistoryEntry.Outcome = .succeeded
    ) -> UpdateHistoryEntry {
        UpdateHistoryEntry(
            bundleID: bundleID, appName: "App", fromVersion: "1.0", toVersion: "1.1",
            source: .sparkle, date: Date(timeIntervalSince1970: 1_800_000_000 + offset), outcome: outcome
        )
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("records entries newest first and filters by bundle id")
    func recordsAndFilters() async throws {
        defer { cleanUp() }
        let store = UpdateHistoryStore(fileURL: fileURL)
        let old = Self.entry("com.example.a", offset: 0)
        let new = Self.entry("com.example.b", offset: 60, outcome: .failed(message: "boom"))
        try await store.record(old)
        try await store.record(new)

        #expect(await store.entries() == [new, old])
        #expect(await store.entries(for: "com.example.a") == [old])
    }

    @Test("persists across instances, including every outcome")
    func persists() async throws {
        defer { cleanUp() }
        let entries = [
            Self.entry(offset: 3),
            Self.entry(offset: 2, outcome: .failed(message: "Checksum mismatch")),
            Self.entry(offset: 1, outcome: .rolledBack),
        ]
        let writer = UpdateHistoryStore(fileURL: fileURL)
        for entry in entries.reversed() { try await writer.record(entry) }

        let reader = UpdateHistoryStore(fileURL: fileURL)
        #expect(await reader.entries() == entries)
    }

    @Test("caps the history at maxEntries, dropping the oldest")
    func capsEntries() async throws {
        defer { cleanUp() }
        let store = UpdateHistoryStore(fileURL: fileURL, maxEntries: 3)
        for index in 0..<5 {
            try await store.record(Self.entry(offset: TimeInterval(index)))
        }

        let dates = await store.entries().map(\.date.timeIntervalSince1970)
        #expect(dates == [1_800_000_004, 1_800_000_003, 1_800_000_002])
    }

    @Test("defaults to 500 entries")
    func defaultCap() {
        #expect(UpdateHistoryStore.defaultMaxEntries == 500)
    }

    @Test("clear empties memory and disk")
    func clears() async throws {
        defer { cleanUp() }
        let store = UpdateHistoryStore(fileURL: fileURL)
        try await store.record(Self.entry())

        try await store.clear()

        #expect(await store.entries().isEmpty)
        #expect(await UpdateHistoryStore(fileURL: fileURL).entries().isEmpty)
    }

    @Test("a corrupt file is moved aside and history restarts empty")
    func corruptFile() async throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)
        let store = UpdateHistoryStore(fileURL: fileURL)

        #expect(await store.entries().isEmpty)
        #expect(FileManager.default.fileExists(atPath: fileURL.appendingPathExtension("corrupt").path))
        try await store.record(Self.entry())
        #expect(await store.entries().count == 1)
    }

    @Test("builds entries from an update and from a rollback")
    func convenienceInitialisers() {
        let app = TestApps.make(bundleIdentifier: "com.example.x", name: "X", shortVersion: "1.0")
        let update = AvailableUpdate(
            app: app, newVersion: "2.0", downloadURL: URL(string: "https://example.com/x.zip")!, source: .github
        )
        let installed = UpdateHistoryEntry(update: update, outcome: .succeeded)
        #expect(installed.fromVersion == "1.0" && installed.toVersion == "2.0" && installed.source == .github)

        let backup = AppBackup(
            bundleIdentifier: "com.example.x", appName: "X", version: "1.0",
            createdAt: Date(), bundleURL: URL(fileURLWithPath: "/tmp/X.app")
        )
        let updatedApp = TestApps.make(bundleIdentifier: "com.example.x", name: "X", shortVersion: "2.0")
        let rollback = UpdateHistoryEntry(rollbackOf: updatedApp, to: backup)
        #expect(rollback.fromVersion == "2.0" && rollback.toVersion == "1.0" && rollback.outcome == .rolledBack)
    }
}
