import Foundation

/// Outcome of a Gatekeeper (`spctl`) assessment of an app bundle.
public enum GatekeeperVerdict: Sendable, Hashable, Codable {
    /// Accepted as notarized Developer ID software (or Apple / Mac App Store signed).
    case notarized
    /// Accepted as Developer ID signed, but without a notarization ticket.
    case developerIDNotNotarized
    /// Gatekeeper would refuse to launch the bundle. Always blocks an install, whatever the policy.
    case rejected(reason: String)
    /// The assessment could not be performed or understood. Blocks under `.require`, warns under `.warnOnly`.
    case unknown(reason: String)

    /// Human-readable summary, suitable for logs and error messages.
    public var summary: String {
        switch self {
        case .notarized: "notarized"
        case .developerIDNotNotarized: "Developer ID signed but not notarized"
        case .rejected(let reason): "rejected by Gatekeeper (\(reason))"
        case .unknown(let reason): "Gatekeeper assessment unavailable (\(reason))"
        }
    }
}

/// How the installer reacts to a bundle that is not notarized.
public enum NotarizationPolicy: String, Sendable, Codable, CaseIterable {
    /// Block `.rejected`, `.developerIDNotNotarized` and `.unknown` verdicts.
    case require
    /// Warn and continue for `.developerIDNotNotarized` / `.unknown`; `.rejected` still blocks.
    case warnOnly
    /// Skip the Gatekeeper assessment entirely (the installed app keeps its quarantine flag,
    /// so Gatekeeper still assesses it on first launch).
    case off

    /// `UserDefaults` key for the "Allow updates that aren't notarized (warn)" toggle.
    public static let allowUnnotarizedDefaultsKey = "security.allowUnnotarizedUpdates"

    /// Maps the Settings toggle to a policy: `true` → `.warnOnly`, otherwise `.require`.
    public static func fromSetting(allowUnnotarized: Bool) -> NotarizationPolicy {
        allowUnnotarized ? .warnOnly : .require
    }
}
