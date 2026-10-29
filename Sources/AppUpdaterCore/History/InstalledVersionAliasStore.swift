import Foundation
import os

/// What a bundle reported right after we installed an advertised version.
public struct InstalledVersionAlias: Sendable, Hashable, Codable {
    public let advertisedVersion: String
    public let shortVersion: String
    public let buildVersion: String?

    public init(advertisedVersion: String, shortVersion: String, buildVersion: String?) {
        self.advertisedVersion = advertisedVersion
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
    }

    /// True while the installed bundle is still the one we put there.
    func covers(_ update: AvailableUpdate) -> Bool {
        update.newVersion == advertisedVersion
            && update.app.shortVersion == shortVersion
            && update.app.buildVersion == buildVersion
    }
}

/// Remembers "advertised version → bundle versions" after successful installs.
///
/// Some sources advertise a version the bundle never shows: Homebrew lists Android Studio as
/// `2026.2.2.8` while its Info.plist says `2026.2`. Without this record the update would be
/// offered again after every check. `reconcile` turns such results into "up to date".
public protocol InstalledVersionAliasing: Sendable {
    func recordInstall(of update: AvailableUpdate) async
    /// Records the bundle's *current* versions for `advertisedVersion` (history migration).
    func record(_ alias: InstalledVersionAlias, for bundleIdentifier: String) async
    func reconcile(_ results: [UpdateCheckResult]) async -> [UpdateCheckResult]
    func alias(for bundleIdentifier: String) async -> InstalledVersionAlias?
}

/// UserDefaults-backed JSON map `bundleID → InstalledVersionAlias`.
public actor InstalledVersionAliasStore: InstalledVersionAliasing {
    public static let defaultKey = "installedVersionAliases"

    private let defaults: UserDefaults
    private let key: String
    private var cache: [String: InstalledVersionAlias]?
    private static let logger = Logger(subsystem: "com.macappupdater", category: "InstalledVersionAlias")

    public init(defaults: UserDefaults = .standard, key: String = InstalledVersionAliasStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    /// Reads the freshly installed bundle at `update.app.url`.
    public func recordInstall(of update: AvailableUpdate) {
        guard let version = AppBundleLocator.version(of: update.app.url) else {
            Self.logger.notice("No version to record for \(update.app.bundleIdentifier, privacy: .public)")
            return
        }
        record(
            InstalledVersionAlias(
                advertisedVersion: update.newVersion, shortVersion: version.shortVersion, buildVersion: version.build
            ),
            for: update.app.bundleIdentifier
        )
    }

    public func record(_ alias: InstalledVersionAlias, for bundleIdentifier: String) {
        save(load().merging([bundleIdentifier: alias]) { _, new in new })
    }

    public func reconcile(_ results: [UpdateCheckResult]) -> [UpdateCheckResult] {
        let aliases = load()
        return results.map { result in
            guard let update = result.update,
                  let alias = aliases[update.app.bundleIdentifier],
                  alias.covers(update)
            else { return result }
            return UpdateCheckResult(
                app: result.app, matchedSource: result.matchedSource,
                latestVersion: update.newVersion, update: nil, errors: result.errors
            )
        }
    }

    public func alias(for bundleIdentifier: String) -> InstalledVersionAlias? {
        load()[bundleIdentifier]
    }

    private func load() -> [String: InstalledVersionAlias] {
        if let cache { return cache }
        let decoded = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([String: InstalledVersionAlias].self, from: $0) } ?? [:]
        cache = decoded
        return decoded
    }

    private func save(_ aliases: [String: InstalledVersionAlias]) {
        cache = aliases
        do {
            defaults.set(try JSONEncoder().encode(aliases), forKey: key)
        } catch {
            Self.logger.error("Cannot save aliases: \(error.localizedDescription, privacy: .public)")
        }
    }
}
