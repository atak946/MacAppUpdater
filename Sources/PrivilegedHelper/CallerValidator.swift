import AppUpdaterCore
import Foundation
import os

/// Restricts incoming XPC connections to the genuine MacAppUpdater app.
///
/// The requirement is enforced by the XPC runtime via
/// `NSXPCConnection.setCodeSigningRequirement` (macOS 13+), which checks the
/// peer's audit token and therefore is not vulnerable to PID reuse.
///
/// Fails closed: in release builds a helper whose own Team ID cannot be read has no
/// requirement and refuses every connection. The identifier-only fallback for ad-hoc
/// signed builds exists only under `#if DEBUG` (see `HelperCodeSigning.currentMode`).
struct CallerValidator: Sendable {
    private static let logger = Logger(subsystem: HelperConstants.machServiceName, category: "CallerValidator")

    /// Requirement every caller must satisfy; nil means "reject everyone".
    let requirement: String?

    init(
        teamIdentifier: String? = HelperCodeSigning.currentTeamIdentifier(),
        mode: HelperCodeSigning.RequirementMode = HelperCodeSigning.currentMode
    ) {
        let requirement = HelperCodeSigning.peerRequirement(
            identifier: HelperConstants.appCodeSigningIdentifier,
            teamIdentifier: teamIdentifier,
            mode: mode
        )
        self.requirement = requirement
        if let requirement {
            if teamIdentifier == nil {
                Self.logger.warning("DEBUG helper is ad-hoc signed; callers are checked by identifier only")
            }
            Self.logger.info("Caller requirement: \(requirement, privacy: .public)")
        } else {
            Self.logger.fault("Helper has no Team ID; rejecting all connections")
        }
    }

    /// Applies the requirement. Returns false when the connection must be refused.
    func apply(to connection: NSXPCConnection) -> Bool {
        guard let requirement else { return false }
        connection.setCodeSigningRequirement(requirement)
        return true
    }
}
