import Foundation

/// Validated snapshot of everything an administrator forced via MDM.
///
/// Every field is optional: `nil` means "not managed, the user decides". Invalid
/// values are dropped while parsing (with an `os.Logger` warning) and never crash.
/// Build it once at launch with `ManagedConfiguration(reader:)`; managed preferences
/// only change when a profile is installed/removed, so a relaunch picks up changes.
public struct ManagedConfiguration: Sendable, Equatable {
    public static let unmanaged = ManagedConfiguration()

    public let checkIntervalHours: Double?
    public let autoInstallEnabled: Bool?
    public let defaultPolicy: UpdatePolicy?
    public let perAppPolicies: [String: UpdatePolicy]
    public let ignoredBundleIdentifiers: Set<String>
    public let deferralDays: Int?
    public let requireACPower: Bool?
    public let avoidExpensiveNetwork: Bool?
    public let disableUninstaller: Bool?
    public let disableBetaChannels: Bool?
    public let allowedSources: Set<UpdateSourceKind>?
    public let hideMenuBarIcon: Bool?
    /// `true` forces Gatekeeper notarization; `false` leaves it to the user.
    public let requireNotarization: Bool?
    /// Reserved for future inventory reporting (D2). Always https.
    public let reportWebhookURL: URL?
    /// Keys that carry a (valid) managed value; derived from the fields.
    public let managedKeys: Set<ManagedKey>

    public init(
        checkIntervalHours: Double? = nil,
        autoInstallEnabled: Bool? = nil,
        defaultPolicy: UpdatePolicy? = nil,
        perAppPolicies: [String: UpdatePolicy] = [:],
        ignoredBundleIdentifiers: Set<String> = [],
        deferralDays: Int? = nil,
        requireACPower: Bool? = nil,
        avoidExpensiveNetwork: Bool? = nil,
        disableUninstaller: Bool? = nil,
        disableBetaChannels: Bool? = nil,
        allowedSources: Set<UpdateSourceKind>? = nil,
        hideMenuBarIcon: Bool? = nil,
        requireNotarization: Bool? = nil,
        reportWebhookURL: URL? = nil
    ) {
        self.checkIntervalHours = checkIntervalHours
        self.autoInstallEnabled = autoInstallEnabled
        self.defaultPolicy = defaultPolicy
        self.perAppPolicies = perAppPolicies
        self.ignoredBundleIdentifiers = ignoredBundleIdentifiers
        self.deferralDays = deferralDays
        self.requireACPower = requireACPower
        self.avoidExpensiveNetwork = avoidExpensiveNetwork
        self.disableUninstaller = disableUninstaller
        self.disableBetaChannels = disableBetaChannels
        self.allowedSources = allowedSources
        self.hideMenuBarIcon = hideMenuBarIcon
        self.requireNotarization = requireNotarization
        self.reportWebhookURL = reportWebhookURL
        let candidates: [(ManagedKey, Bool)] = [
            (.checkIntervalHours, checkIntervalHours != nil),
            (.autoInstallEnabled, autoInstallEnabled != nil),
            (.defaultPolicy, defaultPolicy != nil),
            (.perAppPolicies, !perAppPolicies.isEmpty),
            (.ignoredBundleIdentifiers, !ignoredBundleIdentifiers.isEmpty),
            (.deferralDays, deferralDays != nil),
            (.requireACPower, requireACPower != nil),
            (.avoidExpensiveNetwork, avoidExpensiveNetwork != nil),
            (.disableUninstaller, disableUninstaller != nil),
            (.disableBetaChannels, disableBetaChannels != nil),
            (.allowedSources, allowedSources != nil),
            (.hideMenuBarIcon, hideMenuBarIcon != nil),
            (.requireNotarization, requireNotarization != nil),
            (.reportWebhookURL, reportWebhookURL != nil),
        ]
        self.managedKeys = Set(candidates.filter(\.1).map(\.0))
    }

    /// True when at least one valid managed value exists (show the organization banner).
    public var isManaged: Bool { !managedKeys.isEmpty }

    public func isManaged(_ key: ManagedKey) -> Bool {
        managedKeys.contains(key)
    }

    /// The forced global default: `DefaultPolicy` wins, otherwise `AutoInstallEnabled`.
    public var effectiveDefaultPolicy: UpdatePolicy? {
        if let defaultPolicy { return defaultPolicy }
        return autoInstallEnabled.map { $0 ? .autoInstall : .notifyOnly }
    }

    /// Whether the user can no longer change the global default policy.
    public var isDefaultPolicyLocked: Bool { effectiveDefaultPolicy != nil }

    /// `AutoInstallEnabled = false` is a kill switch: no app installs unattended
    /// unless the administrator forced `autoInstall` for it in `PerAppPolicies`.
    public var isAutoInstallDisabled: Bool { autoInstallEnabled == false }

    public func isPolicyLocked(for bundleIdentifier: String) -> Bool {
        perAppPolicies[bundleIdentifier] != nil
    }

    public func isIgnoreLocked(_ bundleIdentifier: String) -> Bool {
        ignoredBundleIdentifiers.contains(bundleIdentifier)
    }
}
