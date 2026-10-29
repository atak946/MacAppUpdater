import Foundation

/// Layers administrator-forced update policies on top of the user's policies.
///
/// - `load()`: forced default policy, per-app policies, deferral and install conditions
///   override the user's. With `AutoInstallEnabled = false`, user per-app `autoInstall`
///   overrides are masked; with `DeferralDays` forced, user per-app deferrals are masked.
/// - `save(_:)`: persists the user's values for non-forced fields only. For forced fields
///   the previously stored user value is kept, so removing the profile restores it.
public struct ManagedUpdatePoliciesStore: UpdatePoliciesStoring {
    private let base: any UpdatePoliciesStoring
    private let configuration: ManagedConfiguration

    public init(base: any UpdatePoliciesStoring, configuration: ManagedConfiguration) {
        self.base = base
        self.configuration = configuration
    }

    public var isDeferralLocked: Bool { configuration.deferralDays != nil }

    public func load() -> UpdatePolicies {
        let user = base.load()
        let visibleUserOverrides = user.overrides.filter { !isMasked($0.key, $0.value) }
        return UpdatePolicies(
            defaultPolicy: configuration.effectiveDefaultPolicy ?? user.defaultPolicy,
            overrides: visibleUserOverrides.merging(configuration.perAppPolicies) { _, forced in forced },
            deferralDays: configuration.deferralDays ?? user.deferralDays,
            deferralOverrides: isDeferralLocked ? [:] : user.deferralOverrides,
            conditions: forcedConditions(over: user.conditions)
        )
    }

    public func save(_ policies: UpdatePolicies) throws {
        guard configuration.isManaged else { return try base.save(policies) }
        let stored = base.load()
        try base.save(UpdatePolicies(
            defaultPolicy: configuration.isDefaultPolicyLocked ? stored.defaultPolicy : policies.defaultPolicy,
            overrides: userOverrides(incoming: policies.overrides, stored: stored.overrides),
            deferralDays: isDeferralLocked ? stored.deferralDays : policies.deferralDays,
            deferralOverrides: isDeferralLocked ? stored.deferralOverrides : policies.deferralOverrides,
            conditions: userConditions(incoming: policies.conditions, stored: stored.conditions)
        ))
    }

    // MARK: Policies

    /// Incoming user choices for unlocked apps, plus stored values the UI could not see
    /// (forced apps and masked auto-install overrides).
    private func userOverrides(
        incoming: [String: UpdatePolicy],
        stored: [String: UpdatePolicy]
    ) -> [String: UpdatePolicy] {
        let editable = incoming.filter { !configuration.isPolicyLocked(for: $0.key) }
        let hidden = stored.filter { key, value in
            configuration.isPolicyLocked(for: key) || (isMasked(key, value) && editable[key] == nil)
        }
        // Key sets are disjoint by construction; prefer the incoming value defensively.
        return editable.merging(hidden) { incomingValue, _ in incomingValue }
    }

    private func isMasked(_ bundleIdentifier: String, _ policy: UpdatePolicy) -> Bool {
        configuration.isAutoInstallDisabled && policy == .autoInstall
            && !configuration.isPolicyLocked(for: bundleIdentifier)
    }

    // MARK: Conditions

    private func forcedConditions(over conditions: InstallConditions) -> InstallConditions {
        conditions.with(
            requireACPower: configuration.requireACPower,
            avoidExpensiveNetwork: configuration.avoidExpensiveNetwork
        )
    }

    /// Takes the user's incoming conditions but keeps stored values for forced fields.
    private func userConditions(incoming: InstallConditions, stored: InstallConditions) -> InstallConditions {
        incoming.with(
            requireACPower: configuration.requireACPower == nil ? nil : stored.requireACPower,
            avoidExpensiveNetwork: configuration.avoidExpensiveNetwork == nil ? nil : stored.avoidExpensiveNetwork
        )
    }
}
