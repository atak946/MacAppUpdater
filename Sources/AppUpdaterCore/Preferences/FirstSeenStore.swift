import Foundation
import os

/// When a release happened, and how honest that date is (for UI wording).
public struct ReleaseDate: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable, Codable {
        /// The source published the date (appcast pubDate, GitHub published_at, …).
        case published
        /// The source had no date; this is when the app first saw the version.
        case firstSeen
    }

    public let date: Date
    public let kind: Kind

    public init(date: Date, kind: Kind) {
        self.date = date
        self.kind = kind
    }

    /// `update.publishedAt` when known, otherwise the first-seen date (if recorded).
    public static func resolve(for update: AvailableUpdate, firstSeen: Date?) -> ReleaseDate? {
        if let published = update.publishedAt { return ReleaseDate(date: published, kind: .published) }
        return firstSeen.map { ReleaseDate(date: $0, kind: .firstSeen) }
    }
}

/// Records when each `bundleID@version` was first offered, so a soak period is honest
/// for sources that publish no release date (e.g. the Homebrew cask API).
public protocol FirstSeenRecording: Sendable {
    /// Records unseen updates as "now", prunes stale keys and returns release dates keyed by `update.id`.
    func record(_ updates: [AvailableUpdate]) async -> [String: ReleaseDate]
    func releaseDate(for update: AvailableUpdate) async -> ReleaseDate?
}

/// UserDefaults-backed JSON map `bundleID@version → Date`.
public actor FirstSeenStore: FirstSeenRecording {
    public static let defaultKey = "firstSeenDates"
    public static let defaultRetention: TimeInterval = 180 * 24 * 60 * 60

    private let defaults: UserDefaults
    private let key: String
    private let retention: TimeInterval
    private let now: @Sendable () -> Date
    private var cache: [String: Date]?
    private static let logger = Logger(subsystem: "com.macappupdater", category: "FirstSeenStore")

    public init(
        defaults: UserDefaults = .standard,
        key: String = FirstSeenStore.defaultKey,
        retention: TimeInterval = FirstSeenStore.defaultRetention,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.key = key
        self.retention = retention
        self.now = now
    }

    public func record(_ updates: [AvailableUpdate]) -> [String: ReleaseDate] {
        let current = now()
        let existing = load()
        let added = Dictionary(
            updates.filter { existing[$0.id] == nil }.map { ($0.id, current) },
            uniquingKeysWith: { first, _ in first }
        )
        let merged = existing.merging(added) { old, _ in old }
        let pruned = Self.prune(merged, offered: updates, cutoff: current.addingTimeInterval(-retention))
        persist(pruned)
        return Dictionary(
            updates.compactMap { update in
                ReleaseDate.resolve(for: update, firstSeen: pruned[update.id]).map { (update.id, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    public func releaseDate(for update: AvailableUpdate) -> ReleaseDate? {
        ReleaseDate.resolve(for: update, firstSeen: load()[update.id])
    }

    public func firstSeen(for update: AvailableUpdate) -> Date? {
        load()[update.id]
    }

    /// Drops entries older than `cutoff` and superseded versions of apps that are offered now.
    static func prune(_ entries: [String: Date], offered: [AvailableUpdate], cutoff: Date) -> [String: Date] {
        let offeredIDs = Set(offered.map(\.id))
        let offeredApps = Set(offered.map { $0.app.bundleIdentifier })
        return entries.filter { key, date in
            if offeredIDs.contains(key) { return true }
            if date < cutoff { return false }
            return !offeredApps.contains(bundleIdentifier(fromKey: key))
        }
    }

    private static func bundleIdentifier(fromKey key: String) -> String {
        key.firstIndex(of: "@").map { String(key[..<$0]) } ?? key
    }

    private func load() -> [String: Date] {
        if let cache { return cache }
        let decoded = defaults.data(forKey: key).flatMap { data -> [String: Date]? in
            do {
                return try JSONDecoder().decode([String: Date].self, from: data)
            } catch {
                Self.logger.error("Discarding unreadable first-seen dates: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        } ?? [:]
        cache = decoded
        return decoded
    }

    private func persist(_ entries: [String: Date]) {
        cache = entries
        do {
            defaults.set(try JSONEncoder().encode(entries), forKey: key)
        } catch {
            Self.logger.error("Saving first-seen dates failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
