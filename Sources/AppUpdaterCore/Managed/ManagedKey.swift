import Foundation

/// Preference keys an administrator can force via a configuration profile.
///
/// The raw values are the exact keys used in the `com.macappupdater.app` payload.
/// Documented for IT in `docs/mdm/keys.md`; keep both in sync when adding a key.
public enum ManagedKey: String, Sendable, CaseIterable {
    /// Number (hours) between background checks.
    case checkIntervalHours = "CheckIntervalHours"
    /// Bool shorthand for the default policy; `false` also disables per-app auto-install.
    case autoInstallEnabled = "AutoInstallEnabled"
    /// String: `notifyOnly` or `autoInstall`. Wins over `AutoInstallEnabled`.
    case defaultPolicy = "DefaultPolicy"
    /// Dictionary: bundle identifier → policy string.
    case perAppPolicies = "PerAppPolicies"
    /// Array of bundle identifiers that are never updated.
    case ignoredBundleIdentifiers = "IgnoredBundleIdentifiers"
    /// Number of days a new release must age before it is installed (soak period).
    case deferralDays = "DeferralDays"
    /// Bool: auto-install only while on AC power.
    case requireACPower = "RequireACPower"
    /// Bool: skip auto-install on expensive (cellular / hotspot) networks.
    case avoidExpensiveNetwork = "AvoidExpensiveNetwork"
    /// Bool: hide/disable the uninstaller.
    case disableUninstaller = "DisableUninstaller"
    /// Bool: users cannot opt apps into beta channels.
    case disableBetaChannels = "DisableBetaChannels"
    /// Array of `UpdateSourceKind` raw values that may be queried.
    case allowedSources = "AllowedSources"
    /// Bool: hide the menu bar extra.
    case hideMenuBarIcon = "HideMenuBarIcon"
    /// Bool: `true` forces notarization for every update; the user's
    /// "Allow updates that aren't notarized" toggle is ignored and locked.
    case requireNotarization = "RequireNotarization"
    /// String (https URL). Reserved for future inventory reporting (D2).
    case reportWebhookURL = "ReportWebhookURL"
}
