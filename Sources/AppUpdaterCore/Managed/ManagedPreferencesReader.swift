import CoreFoundation
import Foundation

/// Reads values that an administrator forced via a configuration profile (MDM).
///
/// Only *forced* values are returned: anything the user (or `defaults write`) set is
/// invisible here, so a non-nil result always means "locked by the organization".
/// Abstracted behind a protocol so tests can simulate a managed domain in memory.
public protocol ManagedPreferencesReading: Sendable {
    /// The forced property-list value for `key`, or nil when the key is not managed.
    func forcedValue(forKey key: String) -> Any?
}

/// Production reader backed by `CFPreferences` for the app's preferences domain.
///
/// `CFPreferencesCopyAppValue` resolves the value across all levels (managed, user,
/// host, global); `CFPreferencesAppValueIsForced` tells us whether that value comes from
/// a managed (forced) source, i.e. `/Library/Managed Preferences`.
public struct CFPreferencesManagedReader: ManagedPreferencesReading {
    public static let defaultDomain = "com.macappupdater.app"

    public let domain: String

    public init(domain: String = CFPreferencesManagedReader.defaultDomain) {
        self.domain = domain
    }

    public func forcedValue(forKey key: String) -> Any? {
        let cfKey = key as CFString
        let cfDomain = domain as CFString
        guard CFPreferencesAppValueIsForced(cfKey, cfDomain) else { return nil }
        return CFPreferencesCopyAppValue(cfKey, cfDomain)
    }
}

/// Reader that reports no managed values: the default for unmanaged Macs and previews.
public struct UnmanagedPreferencesReader: ManagedPreferencesReading {
    public init() {}

    public func forcedValue(forKey key: String) -> Any? { nil }
}
