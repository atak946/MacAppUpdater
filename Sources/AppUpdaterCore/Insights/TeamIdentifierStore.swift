import Foundation

/// Persists the last Team Identifier seen for each bundle so signer changes can be detected.
public protocol TeamIdentifierStoring: Sendable {
    func lastKnownTeamIdentifier(for bundleIdentifier: String) -> String?
    func record(_ teamIdentifier: String, for bundleIdentifier: String)
    func forget(_ bundleIdentifier: String)
}

/// `UserDefaults`-backed store; all ids live in one dictionary under `key`.
public final class UserDefaultsTeamIdentifierStore: TeamIdentifierStoring, @unchecked Sendable {
    public static let defaultKey = "insights.lastKnownTeamIdentifiers"

    // UserDefaults is thread-safe; the lock only makes read-modify-write atomic.
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = UserDefaultsTeamIdentifierStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func lastKnownTeamIdentifier(for bundleIdentifier: String) -> String? {
        lock.withLock { storedMap()[bundleIdentifier] }
    }

    public func record(_ teamIdentifier: String, for bundleIdentifier: String) {
        lock.withLock {
            let updated = storedMap().merging([bundleIdentifier: teamIdentifier]) { _, new in new }
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
