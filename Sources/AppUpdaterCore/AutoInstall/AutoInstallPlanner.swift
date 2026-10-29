import Foundation

/// What a scheduled run should do with one update.
public enum AutoInstallVerdict: Sendable, Equatable {
    case install
    /// Eligible later: soak period or quiet hours end at `until`.
    case `defer`(until: Date, reason: String)
    /// Not installed unattended on this run (policy, exclusions, or an unmet condition).
    case skip(reason: String)

    public var reason: String? {
        switch self {
        case .install: nil
        case .defer(_, let reason), .skip(let reason): reason
        }
    }
}

public struct AutoInstallDecision: Sendable, Equatable {
    public let update: AvailableUpdate
    public let verdict: AutoInstallVerdict

    public init(update: AvailableUpdate, verdict: AutoInstallVerdict) {
        self.update = update
        self.verdict = verdict
    }

    public var shouldInstall: Bool { verdict == .install }
}

/// Everything the planner needs; plain values and closures so it stays pure and testable.
public struct AutoInstallInput: Sendable {
    public let updates: [AvailableUpdate]
    public let policies: UpdatePolicies
    public let exclusions: ExclusionRules
    public let conditions: SystemConditionsSnapshot
    /// Keyed by `AvailableUpdate.id`; missing entries fall back to `update.publishedAt`, then "now".
    public let releaseDates: [String: ReleaseDate]
    public let isCompatible: @Sendable (AvailableUpdate) -> Bool
    /// Security-critical updates bypass the soak period (not the system conditions).
    public let isUrgent: @Sendable (AvailableUpdate) -> Bool

    public init(
        updates: [AvailableUpdate],
        policies: UpdatePolicies,
        exclusions: ExclusionRules = ExclusionRules(),
        conditions: SystemConditionsSnapshot,
        releaseDates: [String: ReleaseDate] = [:],
        isCompatible: @escaping @Sendable (AvailableUpdate) -> Bool = { _ in true },
        isUrgent: @escaping @Sendable (AvailableUpdate) -> Bool = { _ in false }
    ) {
        self.updates = updates
        self.policies = policies
        self.exclusions = exclusions
        self.conditions = conditions
        self.releaseDates = releaseDates
        self.isCompatible = isCompatible
        self.isUrgent = isUrgent
    }
}

/// Decides, per update, whether a scheduled run installs it now, later, or not at all.
public struct AutoInstallPlanner: Sendable {
    public init() {}

    public func plan(_ input: AutoInstallInput) -> [AutoInstallDecision] {
        input.updates.map { AutoInstallDecision(update: $0, verdict: verdict(for: $0, input: input)) }
    }

    public func verdict(for update: AvailableUpdate, input: AutoInstallInput) -> AutoInstallVerdict {
        eligibilityVerdict(for: update, input: input)
            ?? soakVerdict(for: update, input: input)
            ?? conditionsVerdict(for: update, input: input)
            ?? .install
    }

    /// When the soak period for `update` ends (release date + deferral days).
    public func eligibleDate(for update: AvailableUpdate, input: AutoInstallInput) -> Date {
        let release = releaseDate(for: update, input: input)
        let days = input.policies.deferralDays(for: update.app.bundleIdentifier)
        return input.conditions.calendar.date(byAdding: .day, value: days, to: release.date)
            ?? release.date.addingTimeInterval(TimeInterval(days) * 86_400)
    }

    public func releaseDate(for update: AvailableUpdate, input: AutoInstallInput) -> ReleaseDate {
        input.releaseDates[update.id]
            ?? ReleaseDate.resolve(for: update, firstSeen: nil)
            ?? ReleaseDate(date: input.conditions.now, kind: .firstSeen)
    }

    // MARK: Rules

    private func eligibilityVerdict(for update: AvailableUpdate, input: AutoInstallInput) -> AutoInstallVerdict? {
        switch InstallMethod(update: update) {
        case .appStore: return .skip(reason: String(coreLocalized: "App Store updates are installed by the App Store"))
        case .installerPackage: return .skip(reason: String(coreLocalized: "Installer packages need your approval"))
        case .manualDownload: return .skip(reason: String(coreLocalized: "This download format must be installed manually"))
        case .automatic: break
        }
        // Belt and braces: only dmg/zip are ever installed unattended (security review H-1).
        guard InstallMethod.isInPlaceFormat(PackageFormat(fileURL: update.downloadURL)) else {
            return .skip(reason: String(coreLocalized: "This download format must be installed manually"))
        }
        guard input.policies.shouldAutoInstall(update) else {
            return .skip(reason: String(coreLocalized: "Automatic installs are off for this app"))
        }
        if let reason = input.exclusions.exclusionReason(for: update) { return .skip(reason: reason) }
        guard input.isCompatible(update) else { return .skip(reason: String(coreLocalized: "Not compatible with this Mac")) }
        return nil
    }

    private func soakVerdict(for update: AvailableUpdate, input: AutoInstallInput) -> AutoInstallVerdict? {
        guard !input.isUrgent(update),
              input.policies.deferralDays(for: update.app.bundleIdentifier) > 0
        else { return nil }
        let eligible = eligibleDate(for: update, input: input)
        guard input.conditions.now < eligible else { return nil }
        let days = Self.daysRemaining(until: eligible, from: input.conditions.now, calendar: input.conditions.calendar)
        let published = releaseDate(for: update, input: input).kind == .published
        return .defer(until: eligible, reason: Self.soakReason(days: days, published: published))
    }

    private func conditionsVerdict(for update: AvailableUpdate, input: AutoInstallInput) -> AutoInstallVerdict? {
        let rules = input.policies.conditions
        let state = input.conditions
        if let quiet = rules.quietHours, quiet.contains(state.now, calendar: state.calendar) {
            return .defer(until: quiet.end(after: state.now, calendar: state.calendar), reason: String(coreLocalized: "Quiet hours"))
        }
        if rules.requireACPower, !state.isOnACPower { return .skip(reason: String(coreLocalized: "Waiting for AC power")) }
        if let reason = networkReason(rules: rules, network: state.network) { return .skip(reason: reason) }
        if rules.skipRunningApps, state.runningBundleIdentifiers.contains(update.app.bundleIdentifier) {
            return .skip(reason: String(coreLocalized: "\(update.app.name) is running"))
        }
        return nil
    }

    /// Unknown network state counts as unmet when a network condition is enabled (conservative).
    private func networkReason(rules: InstallConditions, network: NetworkStatus?) -> String? {
        guard rules.avoidExpensiveNetwork || rules.avoidConstrainedNetwork else { return nil }
        guard let network else { return String(coreLocalized: "Network status unknown") }
        if rules.avoidExpensiveNetwork, network.isExpensive { return String(coreLocalized: "On an expensive network") }
        if rules.avoidConstrainedNetwork, network.isConstrained { return String(coreLocalized: "Low Data Mode is on") }
        return nil
    }

    // MARK: Wording helpers

    /// Whole days from `date` until `target`, rounded up (0 when `target` has passed).
    public static func daysRemaining(until target: Date, from date: Date, calendar: Calendar = .current) -> Int {
        guard target > date else { return 0 }
        let hours = calendar.dateComponents([.hour], from: date, to: target).hour ?? 0
        return max(1, Int((Double(hours) / 24).rounded(.up)))
    }

    /// "Auto-installs in 3 days" / "Auto-installs tomorrow" style hint for rows.
    public static func hint(for verdict: AutoInstallVerdict, now: Date, calendar: Calendar = .current) -> String? {
        guard case .defer(let until, _) = verdict else { return nil }
        let days = daysRemaining(until: until, from: now, calendar: calendar)
        return days <= 1
            ? String(coreLocalized: "Auto-installs within a day")
            : String(coreLocalized: "Auto-installs in \(days) days")
    }

    /// Full sentences (not fragments) so each language can order the words naturally.
    private static func soakReason(days: Int, published: Bool) -> String {
        switch (days == 1, published) {
        case (true, true): String(coreLocalized: "Waiting 1 more day after release")
        case (true, false): String(coreLocalized: "Waiting 1 more day after it was first seen")
        case (false, true): String(coreLocalized: "Waiting \(days) more days after release")
        case (false, false): String(coreLocalized: "Waiting \(days) more days after it was first seen")
        }
    }
}
