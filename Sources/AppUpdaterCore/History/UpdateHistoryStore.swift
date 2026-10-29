import Foundation
import os

/// One install, failure or rollback, as shown in the History view.
public struct UpdateHistoryEntry: Sendable, Hashable, Identifiable, Codable {
    public enum Outcome: Sendable, Hashable, Codable {
        case succeeded
        case failed(message: String)
        case rolledBack
    }

    public let id: UUID
    public let bundleID: String
    public let appName: String
    public let fromVersion: String
    public let toVersion: String
    /// `nil` for rollbacks and manual operations.
    public let source: UpdateSourceKind?
    public let date: Date
    public let outcome: Outcome

    public init(
        id: UUID = UUID(),
        bundleID: String,
        appName: String,
        fromVersion: String,
        toVersion: String,
        source: UpdateSourceKind?,
        date: Date = Date(),
        outcome: Outcome
    ) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.source = source
        self.date = date
        self.outcome = outcome
    }

    /// Entry for an update attempt (installed version → offered version).
    public init(update: AvailableUpdate, outcome: Outcome, date: Date = Date()) {
        self.init(
            bundleID: update.app.bundleIdentifier, appName: update.app.name,
            fromVersion: update.app.shortVersion, toVersion: update.newVersion,
            source: update.source, date: date, outcome: outcome
        )
    }

    /// Entry for a rollback of `app` to `backup.version`.
    public init(rollbackOf app: InstalledApp, to backup: AppBackup, date: Date = Date()) {
        self.init(
            bundleID: app.bundleIdentifier, appName: app.name,
            fromVersion: app.shortVersion, toVersion: backup.version,
            source: nil, date: date, outcome: .rolledBack
        )
    }
}

/// Persists update history as a JSON array, newest first, capped at `maxEntries`.
///
/// Writes are atomic (temp file + rename). A corrupt file is moved aside to
/// `<name>.corrupt` and history restarts empty instead of failing every call.
public actor UpdateHistoryStore {
    public static let defaultMaxEntries = 500

    private static let logger = Logger(subsystem: "com.macappupdater", category: "UpdateHistory")

    public nonisolated let fileURL: URL
    private let maxEntries: Int
    private var cache: [UpdateHistoryEntry]?

    /// `~/Library/Application Support/MacAppUpdater/UpdateHistory.json`
    public static var defaultFileURL: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("MacAppUpdater", isDirectory: true)
            .appendingPathComponent("UpdateHistory.json")
    }

    public init(fileURL: URL = UpdateHistoryStore.defaultFileURL, maxEntries: Int = UpdateHistoryStore.defaultMaxEntries) {
        self.fileURL = fileURL
        self.maxEntries = max(1, maxEntries)
    }

    /// All entries, newest first.
    public func entries() -> [UpdateHistoryEntry] {
        loaded()
    }

    public func entries(for bundleID: String) -> [UpdateHistoryEntry] {
        loaded().filter { $0.bundleID == bundleID }
    }

    public func record(_ entry: UpdateHistoryEntry) throws {
        let updated = Array(([entry] + loaded()).sorted { $0.date > $1.date }.prefix(maxEntries))
        try persist(updated)
    }

    public func clear() throws {
        try persist([])
    }

    // MARK: - Persistence

    private func loaded() -> [UpdateHistoryEntry] {
        if let cache { return cache }
        let entries = readFromDisk()
        cache = entries
        return entries
    }

    private func readFromDisk() -> [UpdateHistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try Self.decoder.decode([UpdateHistoryEntry].self, from: data)
        } catch {
            Self.logger.error("History file is corrupt, moving aside: \(error.localizedDescription, privacy: .public)")
            let aside = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            return []
        }
    }

    private func persist(_ entries: [UpdateHistoryEntry]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(entries)
        try data.write(to: fileURL, options: .atomic)
        cache = entries
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
