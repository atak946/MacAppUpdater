import Foundation

/// A change in the registrable download domain for one app.
public struct HostChange: Sendable, Hashable {
    public let bundleIdentifier: String
    /// Normalized host recorded after the last successful install.
    public let previous: String
    /// Normalized host of the update being considered.
    public let current: String

    public init(bundleIdentifier: String, previous: String, current: String) {
        self.bundleIdentifier = bundleIdentifier
        self.previous = previous
        self.current = current
    }
}

/// Remembers the last host each app was successfully downloaded from (B3).
/// A change is informational: callers surface a warning, they do not block.
public protocol DownloadHostStoring: Sendable {
    func lastKnownHost(for bundleIdentifier: String) -> String?
    /// Returns a change when the update's domain family differs from the recorded one.
    func check(_ update: AvailableUpdate) -> HostChange?
    /// Records `update.downloadURL`'s host; call only after a successful install.
    func record(_ update: AvailableUpdate)
    func forget(_ bundleIdentifier: String)
}

/// `UserDefaults`-backed store; all hosts live in one dictionary under `key`.
public final class UserDefaultsDownloadHostStore: DownloadHostStoring, @unchecked Sendable {
    public static let defaultKey = "security.lastKnownDownloadHosts"

    // UserDefaults is thread-safe; the lock only makes read-modify-write atomic.
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = UserDefaultsDownloadHostStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func lastKnownHost(for bundleIdentifier: String) -> String? {
        lock.withLock { storedMap()[bundleIdentifier] }
    }

    public func check(_ update: AvailableUpdate) -> HostChange? {
        let bundleID = update.app.bundleIdentifier
        guard let current = RegistrableDomain.normalizedHost(update.downloadURL.host()),
              let previous = lastKnownHost(for: bundleID) else { return nil }
        guard RegistrableDomain.familyKey(of: previous) != RegistrableDomain.familyKey(of: current) else {
            return nil
        }
        return HostChange(bundleIdentifier: bundleID, previous: previous, current: current)
    }

    public func record(_ update: AvailableUpdate) {
        guard let host = RegistrableDomain.normalizedHost(update.downloadURL.host()) else { return }
        let bundleID = update.app.bundleIdentifier
        lock.withLock {
            let updated = storedMap().merging([bundleID: host]) { _, new in new }
            defaults.set(updated, forKey: key)
        }
    }

    public func forget(_ bundleIdentifier: String) {
        lock.withLock {
            let updated = storedMap().filter { $0.key != bundleIdentifier }
            defaults.set(updated, forKey: key)
        }
    }

    private func storedMap() -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}
