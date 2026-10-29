import Foundation

/// What to do when a background check finds an update.
public enum UpdatePolicy: String, Sendable, Codable, CaseIterable {
    case notifyOnly
    case autoInstall
}

/// Global default plus per-app overrides (keyed by bundle identifier),
/// a soak period before unattended installs (B2) and the conditions they need (C3).
public struct UpdatePolicies: Sendable, Codable, Equatable {
    /// Upper bound for any deferral, in days.
    public static let maxDeferralDays = 30

    public let defaultPolicy: UpdatePolicy
    public let overrides: [String: UpdatePolicy]
    /// Days to wait after a release before installing it unattended (0 = immediately).
    public let deferralDays: Int
    /// bundleIdentifier → deferral days, overriding `deferralDays`.
    public let deferralOverrides: [String: Int]
    public let conditions: InstallConditions

    public init(
        defaultPolicy: UpdatePolicy = .notifyOnly,
        overrides: [String: UpdatePolicy] = [:],
        deferralDays: Int = 0,
        deferralOverrides: [String: Int] = [:],
        conditions: InstallConditions = InstallConditions()
    ) {
        self.defaultPolicy = defaultPolicy
        self.overrides = overrides
        self.deferralDays = Self.clampDays(deferralDays)
        self.deferralOverrides = deferralOverrides.mapValues(Self.clampDays)
        self.conditions = conditions
    }

    /// Accepts JSON stored before deferral/conditions existed.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            defaultPolicy: try container.decodeIfPresent(UpdatePolicy.self, forKey: .defaultPolicy) ?? .notifyOnly,
            overrides: try container.decodeIfPresent([String: UpdatePolicy].self, forKey: .overrides) ?? [:],
            deferralDays: try container.decodeIfPresent(Int.self, forKey: .deferralDays) ?? 0,
            deferralOverrides: try container.decodeIfPresent([String: Int].self, forKey: .deferralOverrides) ?? [:],
            conditions: try container.decodeIfPresent(InstallConditions.self, forKey: .conditions)
                ?? InstallConditions()
        )
    }

    public func policy(for bundleIdentifier: String) -> UpdatePolicy {
        overrides[bundleIdentifier] ?? defaultPolicy
    }

    public func hasOverride(for bundleIdentifier: String) -> Bool {
        overrides[bundleIdentifier] != nil
    }

    public func deferralDays(for bundleIdentifier: String) -> Int {
        deferralOverrides[bundleIdentifier] ?? deferralDays
    }

    public func hasDeferralOverride(for bundleIdentifier: String) -> Bool {
        deferralOverrides[bundleIdentifier] != nil
    }

    /// Returns a copy with the override set; `nil` removes it so the app follows the default.
    public func setting(_ policy: UpdatePolicy?, for bundleIdentifier: String) -> UpdatePolicies {
        let newOverrides = policy.map { overrides.merging([bundleIdentifier: $0]) { _, new in new } }
            ?? overrides.filter { $0.key != bundleIdentifier }
        return copy(overrides: newOverrides)
    }

    public func settingDefault(_ policy: UpdatePolicy) -> UpdatePolicies {
        copy(defaultPolicy: policy)
    }

    /// Global soak period, clamped to 0…`maxDeferralDays`.
    public func settingDeferralDays(_ days: Int) -> UpdatePolicies {
        copy(deferralDays: days)
    }

    /// Per-app soak period; `nil` removes the override so the app follows the global value.
    public func settingDeferral(_ days: Int?, for bundleIdentifier: String) -> UpdatePolicies {
        let newOverrides = days.map { deferralOverrides.merging([bundleIdentifier: $0]) { _, new in new } }
            ?? deferralOverrides.filter { $0.key != bundleIdentifier }
        return copy(deferralOverrides: newOverrides)
    }

    public func settingConditions(_ conditions: InstallConditions) -> UpdatePolicies {
        copy(conditions: conditions)
    }

    /// Only dmg/zip updates are installed unattended; App Store and .pkg always need the user.
    public func shouldAutoInstall(_ update: AvailableUpdate) -> Bool {
        guard InstallMethod(update: update) == .automatic else { return false }
        return policy(for: update.app.bundleIdentifier) == .autoInstall
    }

    private func copy(
        defaultPolicy: UpdatePolicy? = nil,
        overrides: [String: UpdatePolicy]? = nil,
        deferralDays: Int? = nil,
        deferralOverrides: [String: Int]? = nil,
        conditions: InstallConditions? = nil
    ) -> UpdatePolicies {
        UpdatePolicies(
            defaultPolicy: defaultPolicy ?? self.defaultPolicy,
            overrides: overrides ?? self.overrides,
            deferralDays: deferralDays ?? self.deferralDays,
            deferralOverrides: deferralOverrides ?? self.deferralOverrides,
            conditions: conditions ?? self.conditions
        )
    }

    private static func clampDays(_ days: Int) -> Int {
        min(max(days, 0), maxDeferralDays)
    }
}

public protocol UpdatePoliciesStoring: Sendable {
    func load() -> UpdatePolicies
    func save(_ policies: UpdatePolicies) throws
}

/// Persists update policies as JSON in UserDefaults (non-sensitive preferences).
public struct UserDefaultsUpdatePoliciesStore: UpdatePoliciesStoring, @unchecked Sendable {
    private static let key = "updatePolicies"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> UpdatePolicies {
        guard let data = defaults.data(forKey: Self.key),
              let policies = try? JSONDecoder().decode(UpdatePolicies.self, from: data)
        else { return UpdatePolicies() }
        return policies
    }

    public func save(_ policies: UpdatePolicies) throws {
        defaults.set(try JSONEncoder().encode(policies), forKey: Self.key)
    }
}
