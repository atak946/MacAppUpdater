import CryptoKit
import Foundation

/// Detects when `security.allowUnnotarizedUpdates` was changed outside App Updater
/// (e.g. `defaults write`), which any same-user process can do.
///
/// The Settings UI records a fingerprint of every value it writes. A stored value whose
/// fingerprint doesn't match is treated as *not confirmed*: `confirmedAllowUnnotarized`
/// then returns `false` (notarization required) until the user confirms it in Settings.
///
/// This is tamper *evidence* against naive edits, not a security boundary: the fingerprint
/// lives in the same defaults domain and a determined local attacker can recompute it.
public final class NotarizationSettingAudit: @unchecked Sendable {
    // @unchecked: `UserDefaults` is documented thread-safe but not annotated `Sendable`.
    public static let settingKey = NotarizationPolicy.allowUnnotarizedDefaultsKey
    public static let fingerprintKey = "security.allowUnnotarizedUpdates.uiFingerprint"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The raw stored toggle value.
    public var storedValue: Bool {
        defaults.bool(forKey: Self.settingKey)
    }

    /// True when the stored value was not written by the app's Settings UI.
    /// An unset fingerprint with the default value (`false`) is not a change.
    public var wasChangedOutsideApp: Bool {
        guard let fingerprint = defaults.string(forKey: Self.fingerprintKey) else { return storedValue }
        return fingerprint != Self.fingerprint(for: storedValue)
    }

    /// The value the installer may honour: the stored value only when it was confirmed in the UI.
    public var confirmedAllowUnnotarized: Bool {
        storedValue && !wasChangedOutsideApp
    }

    /// Called by the Settings UI whenever the user flips the toggle.
    public func recordUserChange(_ value: Bool) {
        defaults.set(value, forKey: Self.settingKey)
        defaults.set(Self.fingerprint(for: value), forKey: Self.fingerprintKey)
    }

    /// Accepts the current stored value as the user's choice.
    public func confirmStoredValue() {
        recordUserChange(storedValue)
    }

    static func fingerprint(for value: Bool) -> String {
        let input = Data("com.macappupdater|\(settingKey)|\(value)".utf8)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }
}
