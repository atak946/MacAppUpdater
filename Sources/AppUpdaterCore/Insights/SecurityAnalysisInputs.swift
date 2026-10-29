import Foundation

// Security inputs for `CompatibilityAnalyzer` reuse the security module's own value types
// (Security/GatekeeperVerdict.swift, Security/DownloadHostStore.swift) so no mapping is needed:
//
//   GatekeeperVerdict.notarized               -> no warning
//   GatekeeperVerdict.developerIDNotNotarized -> .notNotarized(reason:scope:)
//   GatekeeperVerdict.rejected(reason)        -> .notNotarized(reason:scope:)
//   GatekeeperVerdict.unknown(reason)         -> no warning (assessment unavailable)
//   HostChange (from DownloadHostStoring.check) -> .downloadHostChanged(previous:current:)

/// Which bundle a Gatekeeper verdict is about. Drives the `.notNotarized` warning's severity.
public enum GatekeeperScope: String, Sendable, Hashable {
    /// The freshly downloaded bundle of an update (critical: do not install).
    case update
    /// The app already installed on disk (informational).
    case installedApp
}

extension GatekeeperVerdict {
    /// Reason to show when the verdict should raise `.notNotarized`; nil when it should not.
    var notNotarizedReason: String? {
        switch self {
        case .notarized, .unknown: nil
        case .developerIDNotNotarized: String(coreLocalized: "Developer ID signed, but Apple has not notarized it.")
        case .rejected(let reason): reason
        }
    }
}
