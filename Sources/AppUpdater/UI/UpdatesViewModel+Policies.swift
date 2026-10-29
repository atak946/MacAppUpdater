import AppUpdaterCore
import Foundation

/// Policy-driven automatic installs (planner), soak-period hints, version ceilings and MDM gates.
extension UpdatesViewModel {
    // MARK: Managed (MDM)

    var managed: ManagedConfiguration { services.managed }
    var managedGate: ManagedPolicyGate { ManagedPolicyGate(configuration: services.managed) }

    /// Ignored by a configuration profile: the user can't include it again.
    func isIgnoreLocked(_ bundleIdentifier: String) -> Bool {
        services.managed.isIgnoreLocked(bundleIdentifier)
    }

    // MARK: Automatic installs

    /// Plans every update with `AutoInstallPlanner` (policy, exclusions, compatibility, soak period,
    /// quiet hours, power, network, running apps). Vendor-owned updates are always skipped.
    func autoInstallDecisions(from updates: [AvailableUpdate], policies: UpdatePolicies) async -> [AutoInstallDecision] {
        let incompatible = Set(updates.filter { compatibilityWarning(for: $0) != nil }.map(\.id))
        let input = AutoInstallInput(
            updates: updates,
            policies: policies,
            exclusions: exclusions,
            conditions: await services.conditions.snapshot(),
            releaseDates: releaseDates,
            isCompatible: { !incompatible.contains($0.id) }
            // isUrgent: no source flags security releases yet (Sparkle criticalUpdate is not parsed).
        )
        let decisions = AutoInstallPlanner().plan(input).map(vetoVendorOwned)
        for decision in decisions where !decision.shouldInstall {
            let reason = decision.verdict.reason ?? ""
            logger.info("Auto-install \(decision.update.app.name, privacy: .public): \(reason, privacy: .public)")
        }
        lastAutoInstallDecisions = Dictionary(decisions.map { ($0.update.id, $0) }) { _, new in new }
        return decisions
    }

    private func vetoVendorOwned(_ decision: AutoInstallDecision) -> AutoInstallDecision {
        guard decision.shouldInstall else { return decision }
        if let management = vendorManagement(for: decision.update.app) {
            return AutoInstallDecision(
                update: decision.update, verdict: .skip(reason: String(localized: "Updated by \(management.updaterName)"))
            )
        }
        if opensVendorUpdater(decision.update) {
            return AutoInstallDecision(update: decision.update, verdict: .skip(reason: String(localized: "Updated by the vendor's updater")))
        }
        return decision
    }

    /// Scheduled path only: refresh, auto-install per plan, return what still needs the user.
    func runScheduledCheck() async -> [AvailableUpdate] {
        let found = await refresh()
        let decisions = await autoInstallDecisions(from: found, policies: services.policies.load())
        for decision in decisions where decision.shouldInstall {
            await install(decision.update)
        }
        return found.filter { installState(for: $0) != .installed }
    }

    // MARK: Hints

    /// "Auto-installs in N days" while the soak period runs; nil when it would not auto-install.
    func autoInstallHint(for update: AvailableUpdate) -> String? {
        let policies = services.policies.load()
        guard policies.shouldAutoInstall(update), !exclusions.isExcluded(update),
              resolvedInstallMethod(for: update).isAutomatic, !opensVendorUpdater(update)
        else { return nil }
        // Permissive conditions: the hint reflects only the soak period.
        let input = AutoInstallInput(
            updates: [update], policies: policies, exclusions: exclusions,
            conditions: SystemConditionsSnapshot(), releaseDates: releaseDates
        )
        let verdict = AutoInstallPlanner().verdict(for: update, input: input)
        return AutoInstallPlanner.hint(for: verdict, now: Date())
    }

    /// "Released Oct 3, 2026" or "First seen Oct 5, 2026".
    func releaseDateLabel(for update: AvailableUpdate) -> String? {
        guard let release = releaseDates[update.id] ?? ReleaseDate.resolve(for: update, firstSeen: nil) else {
            return nil
        }
        let day = release.date.formatted(date: .abbreviated, time: .omitted)
        return release.kind == .published ? String(localized: "Released \(day)") : String(localized: "First seen \(day)")
    }

    // MARK: Version ceilings

    /// Ceilings for apps, e.g. `[("com.foo", "5")]`, sorted by bundle id.
    var versionCeilings: [(bundleID: String, ceiling: String)] {
        exclusions.versionCeilings.sorted { $0.key < $1.key }.map { (bundleID: $0.key, ceiling: $0.value) }
    }

    func removeCeiling(_ bundleIdentifier: String) {
        setCeiling(nil, forBundleIdentifier: bundleIdentifier)
    }
}

/// "Stay on 5.x" / "Stay on 5.2.x" options for an installed version.
struct VersionCeilingOptions: Equatable {
    let major: String
    let minor: String?

    init(version: String) {
        let parts = version.split(separator: ".").map(String.init)
        major = parts.first ?? version
        let minorPrefix = parts.prefix(2).joined(separator: ".")
        minor = parts.count >= 2 && minorPrefix != major ? minorPrefix : nil
    }
}
