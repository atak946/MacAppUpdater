import Foundation

/// The single rule (M-5 / H-4) that both installers use to decide which Developer ID team an
/// update must be signed by. `AppInstaller` (dmg/zip) and `PackageInstaller` (.pkg) call it with
/// the installed app's Apple-anchored team and the update source's curated pin.
///
/// | Installed app team | Source pin        | Result                                   |
/// |--------------------|-------------------|------------------------------------------|
/// | present            | absent            | installed team                           |
/// | present            | equal             | installed team                           |
/// | present            | different         | `teamIdentifierMismatch(pin, installed)` |
/// | absent / invalid   | present           | the pin                                  |
/// | absent / invalid   | absent            | refused (`isUnverifiablePublisher`)      |
/// | any                | malformed         | refused (`isUnverifiablePublisher`)      |
///
/// There is never an "any Developer ID" fallback.
public enum TeamPin {
    public static func resolve(
        installedTeam: String?,
        pinnedTeam: String?,
        appName: String,
        installedProblem: String? = nil
    ) throws -> String {
        let pin = pinnedTeam?.trimmingCharacters(in: .whitespacesAndNewlines)
        let curated = (pin?.isEmpty ?? true) ? nil : pin
        if let curated, !CodeSigningRequirement.isValidTeamIdentifier(curated) {
            throw UpdaterError.signatureInvalid(
                "\(UpdaterError.unverifiablePublisherPrefix)the update source's Team ID pin is malformed"
            )
        }
        switch (installedTeam, curated) {
        case let (installed?, curated?) where installed != curated:
            throw UpdaterError.teamIdentifierMismatch(expected: curated, actual: installed)
        case let (installed?, _):
            return installed
        case let (nil, curated?):
            return curated
        case (nil, nil):
            let detail = installedProblem.map { " (\($0))" } ?? ""
            throw UpdaterError.signatureInvalid(
                "\(UpdaterError.unverifiablePublisherPrefix)\(appName) is not signed with a valid Developer ID "
                    + "and the update source does not pin a team\(detail). Update it manually."
            )
        }
    }
}

/// Why an install was refused, for user-facing messages. Derived from the thrown error so the
/// core keeps throwing plain `UpdaterError`s.
public enum InstallBlockReason: Sendable, Equatable {
    /// Apple has not notarized the update; the "allow unnotarized" setting could lift it.
    case notNotarized
    /// Gatekeeper could not answer (often offline). Retrying online may succeed.
    case notarizationUnconfirmed
    /// Gatekeeper rejected the bundle (e.g. revoked certificate). Never overridable.
    case gatekeeperRejected
    /// No trusted Team ID to pin the update to (unsigned/ad-hoc installed app, no source pin).
    case unverifiablePublisher
    /// The privileged helper refused this (non-Developer ID) build of the app.
    case untrustedHelperBuild

    public init?(error: any Error) {
        if let helperError = error as? HelperClientError {
            guard helperError == .untrustedBuild else { return nil }
            self = .untrustedHelperBuild
            return
        }
        guard case .signatureInvalid(let message) = error as? UpdaterError else { return nil }
        if message.hasPrefix(UpdaterError.notNotarizedPrefix + UpdaterError.notarizationUnconfirmedPrefix) {
            self = .notarizationUnconfirmed
        } else if message.hasPrefix(UpdaterError.notNotarizedPrefix) {
            self = .notNotarized
        } else if message.hasPrefix(UpdaterError.gatekeeperRejectedPrefix) {
            self = .gatekeeperRejected
        } else if message.hasPrefix(UpdaterError.unverifiablePublisherPrefix) {
            self = .unverifiablePublisher
        } else {
            return nil
        }
    }
}

extension UpdaterError {
    /// Prefix of the `signatureInvalid` message thrown when no trusted team can be pinned.
    public static let unverifiablePublisherPrefix = "Publisher cannot be verified: "
    /// Follows `notNotarizedPrefix` when Gatekeeper returned no verdict (`.unknown`).
    public static let notarizationUnconfirmedPrefix = "Gatekeeper could not confirm notarization"
}
