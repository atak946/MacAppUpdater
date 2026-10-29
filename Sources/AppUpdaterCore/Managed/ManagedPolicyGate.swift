import Foundation

/// Answers "is this allowed / what value applies?" for features governed by MDM.
///
/// Every helper fails open to the unmanaged behaviour when the key is not managed.
public struct ManagedPolicyGate: Sendable, Equatable {
    public let configuration: ManagedConfiguration

    public init(configuration: ManagedConfiguration) {
        self.configuration = configuration
    }

    public func isSourceAllowed(_ kind: UpdateSourceKind) -> Bool {
        configuration.allowedSources?.contains(kind) ?? true
    }

    /// Filters checker sources down to the allowed kinds.
    public func allowedSources(_ sources: [any UpdateSource]) -> [any UpdateSource] {
        sources.filter { isSourceAllowed($0.kind) }
    }

    public var isUninstallerAllowed: Bool {
        configuration.disableUninstaller != true
    }

    public var areBetaChannelsAllowed: Bool {
        configuration.disableBetaChannels != true
    }

    public var isMenuBarIconHidden: Bool {
        configuration.hideMenuBarIcon == true
    }

    /// Check interval in hours: the forced value when managed, otherwise the user's.
    public func effectiveCheckInterval(userValue: Double) -> Double {
        configuration.checkIntervalHours ?? userValue
    }

    public var isCheckIntervalLocked: Bool {
        configuration.isManaged(.checkIntervalHours)
    }

    /// Forced soak period in days, or the user's value when unmanaged.
    public func effectiveDeferralDays(userValue: Int) -> Int {
        configuration.deferralDays ?? userValue
    }

    public func effectiveRequireACPower(userValue: Bool) -> Bool {
        configuration.requireACPower ?? userValue
    }

    public func effectiveAvoidExpensiveNetwork(userValue: Bool) -> Bool {
        configuration.avoidExpensiveNetwork ?? userValue
    }

    /// Only a forced `RequireNotarization = true` locks the toggle; `false` leaves it to the user.
    public var isNotarizationLocked: Bool {
        configuration.requireNotarization == true
    }

    /// Whether unnotarized updates may install (with a warning): never when forced.
    public func effectiveAllowUnnotarized(userValue: Bool) -> Bool {
        isNotarizationLocked ? false : userValue
    }

    /// The installer's policy for the user's toggle value, after the managed override.
    public func effectiveNotarizationPolicy(userAllowsUnnotarized: Bool) -> NotarizationPolicy {
        NotarizationPolicy.fromSetting(allowUnnotarized: effectiveAllowUnnotarized(userValue: userAllowsUnnotarized))
    }
}
