import Foundation
import os

/// Applies a `NotarizationPolicy` to a `GatekeeperVerdict` inside the install pipeline.
public struct NotarizationGate: Sendable {
    private static let logger = Logger(subsystem: "com.macappupdater", category: "Gatekeeper")

    private let assessor: any GatekeeperAssessing
    private let policy: @Sendable () -> NotarizationPolicy

    public init(assessor: any GatekeeperAssessing, policy: @escaping @Sendable () -> NotarizationPolicy) {
        self.assessor = assessor
        self.policy = policy
    }

    /// Assesses `bundleURL` (unless the policy is `.off`) and throws when the policy blocks it.
    /// - Returns: the verdict, or `nil` when the check was skipped.
    @discardableResult
    public func check(_ bundleURL: URL, bundleIdentifier: String) async throws -> GatekeeperVerdict? {
        let currentPolicy = policy()
        guard currentPolicy != .off else { return nil }
        let verdict = await assessor.assess(bundleURL)
        try Self.enforce(verdict, policy: currentPolicy, bundleIdentifier: bundleIdentifier)
        return verdict
    }

    /// Pure decision (M-3):
    /// - `.notarized` always passes.
    /// - `.rejected` (e.g. a revoked certificate) never passes, whatever the policy.
    /// - `.developerIDNotNotarized` and `.unknown` block under `.require` and warn under `.warnOnly`.
    ///
    /// Blocks that the "allow unnotarized" setting could lift throw
    /// `UpdaterError.signatureInvalid("Not notarized: …")` (`isNotarizationBlock`);
    /// Gatekeeper rejections throw `signatureInvalid("Rejected by Gatekeeper: …")`.
    public static func enforce(
        _ verdict: GatekeeperVerdict,
        policy: NotarizationPolicy,
        bundleIdentifier: String
    ) throws {
        switch verdict {
        case .notarized:
            return
        case .rejected:
            logger.error("Blocked \(bundleIdentifier, privacy: .public): \(verdict.summary, privacy: .public)")
            throw UpdaterError.signatureInvalid("\(UpdaterError.gatekeeperRejectedPrefix)\(verdict.summary)")
        case .developerIDNotNotarized, .unknown:
            guard policy == .require else {
                logger.warning("Installing \(bundleIdentifier, privacy: .public) anyway: \(verdict.summary, privacy: .public)")
                return
            }
            logger.error("Blocked \(bundleIdentifier, privacy: .public): \(verdict.summary, privacy: .public)")
            throw UpdaterError.signatureInvalid("\(UpdaterError.notNotarizedPrefix)\(blockMessage(for: verdict))")
        }
    }

    static func blockMessage(for verdict: GatekeeperVerdict) -> String {
        guard case .unknown(let reason) = verdict else { return verdict.summary }
        return "\(UpdaterError.notarizationUnconfirmedPrefix) (\(reason)). "
            + "Try again when online, or allow updates that aren't notarized in Settings."
    }
}

extension UpdaterError {
    /// Prefix of the `signatureInvalid` message thrown when notarization blocks an install.
    public static let notNotarizedPrefix = "Not notarized: "
    /// Prefix of the `signatureInvalid` message thrown for a Gatekeeper rejection (never overridable).
    public static let gatekeeperRejectedPrefix = "Rejected by Gatekeeper: "

    /// True when this error is a notarization block (lets the UI offer the Settings toggle).
    public var isNotarizationBlock: Bool {
        guard case .signatureInvalid(let message) = self else { return false }
        return message.hasPrefix(Self.notNotarizedPrefix)
    }
}
