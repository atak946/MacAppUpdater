import Foundation

/// Persists which apps (by bundle identifier) opted in to the Sparkle "beta" channel.
public struct BetaChannelStore: @unchecked Sendable {
    public static let betaChannel = "beta"
    public static let defaultsKey = "betaChannelBundleIdentifiers"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    public func save(_ bundleIdentifiers: Set<String>) {
        defaults.set(bundleIdentifiers.sorted(), forKey: Self.defaultsKey)
    }

    public func isOptedIn(_ bundleIdentifier: String) -> Bool {
        load().contains(bundleIdentifier)
    }

    /// Persists and returns the new opted-in set.
    @discardableResult
    public func setOptedIn(_ isOptedIn: Bool, for bundleIdentifier: String) -> Set<String> {
        let updated = Self.updating(load(), bundleIdentifier: bundleIdentifier, isOptedIn: isOptedIn)
        save(updated)
        return updated
    }

    public static func updating(_ current: Set<String>, bundleIdentifier: String, isOptedIn: Bool) -> Set<String> {
        isOptedIn ? current.union([bundleIdentifier]) : current.subtracting([bundleIdentifier])
    }

    /// Channel provider for `SparkleSource`; reads the latest opt-ins on every check.
    public var channelProvider: SparkleSource.ChannelProvider {
        { [self] app in isOptedIn(app.bundleIdentifier) ? [Self.betaChannel] : [] }
    }
}
