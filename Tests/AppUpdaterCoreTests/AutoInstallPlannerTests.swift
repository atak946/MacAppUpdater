import Foundation
import Testing
@testable import AppUpdaterCore

@Suite("AutoInstallPlanner")
struct AutoInstallPlannerTests {
    private let planner = AutoInstallPlanner()
    private let autoPolicies = UpdatePolicies(defaultPolicy: .autoInstall)

    /// 2027-01-15 08:00 UTC plus `hour` offset — a deterministic "now".
    private func date(hour: Int, dayOffset: Int = 0) -> Date {
        let components = DateComponents(year: 2027, month: 1, day: 15 + dayOffset, hour: hour)
        return AutoInstallFixtures.utcCalendar.date(from: components)!
    }

    private func snapshot(
        hour: Int = 12,
        onAC: Bool = true,
        network: NetworkStatus? = NetworkStatus(),
        running: Set<String> = []
    ) -> SystemConditionsSnapshot {
        SystemConditionsSnapshot(
            isOnACPower: onAC,
            network: network,
            runningBundleIdentifiers: running,
            now: date(hour: hour),
            calendar: AutoInstallFixtures.utcCalendar
        )
    }

    private func verdict(
        _ update: AvailableUpdate = AutoInstallFixtures.update(),
        policies: UpdatePolicies? = nil,
        exclusions: ExclusionRules = ExclusionRules(),
        conditions: SystemConditionsSnapshot? = nil,
        releaseDates: [String: ReleaseDate] = [:],
        compatible: Bool = true,
        urgent: Bool = false
    ) -> AutoInstallVerdict {
        let input = AutoInstallInput(
            updates: [update],
            policies: policies ?? autoPolicies,
            exclusions: exclusions,
            conditions: conditions ?? snapshot(),
            releaseDates: releaseDates,
            isCompatible: { _ in compatible },
            isUrgent: { _ in urgent }
        )
        return planner.plan(input)[0].verdict
    }

    @Test func installsWhenEverythingAllows() {
        #expect(verdict() == .install)
    }

    @Test func skipsWhenPolicyIsNotifyOnly() {
        #expect(verdict(policies: UpdatePolicies()).reason == "Automatic installs are off for this app")
    }

    @Test("App Store and pkg are never auto-installed", arguments: [
        ("macappstore://apps.apple.com/app/id1", UpdateSourceKind.appStore),
        ("https://example.com/Installer.pkg", .sparkle),
        ("https://example.com/Installer.mpkg", .github),
    ])
    func neverAppStoreOrPackage(url: String, source: UpdateSourceKind) {
        let policies = autoPolicies.setting(.autoInstall, for: "com.example.app")
        let result = verdict(AutoInstallFixtures.update(url: url, source: source), policies: policies)
        guard case .skip = result else {
            Issue.record("Expected skip, got \(result)")
            return
        }
    }

    // H-1: only dmg/zip are installed unattended; unknown and extension-less formats never are.
    @Test("Unknown download formats are never auto-installed", arguments: [
        "https://example.com/Update.terminal",
        "https://example.com/Update.tar.gz",
        "https://example.com/download",
        "https://example.com/Update.webloc",
    ])
    func neverUnknownFormat(url: String) {
        let policies = autoPolicies.setting(.autoInstall, for: "com.example.app")
        let result = verdict(AutoInstallFixtures.update(url: url, source: .sparkle), policies: policies)
        #expect(result == .skip(reason: "This download format must be installed manually"))
    }

    @Test func skipsIncompatibleAndExcluded() {
        #expect(verdict(compatible: false).reason == "Not compatible with this Mac")
        let ceiling = ExclusionRules().capping("com.example.app", at: "1")
        #expect(verdict(exclusions: ceiling).reason?.contains("ceiling") == true)
        #expect(verdict(exclusions: ExclusionRules().ignoring("com.example.app")) != .install)
    }

    @Test("Soak period by days since release", arguments: [
        (0, 7, false), (6, 7, false), (7, 7, true), (10, 7, true), (0, 0, true),
    ])
    func deferral(daysAgo: Int, deferralDays: Int, installs: Bool) {
        let released = date(hour: 12, dayOffset: -daysAgo)
        let update = AutoInstallFixtures.update(publishedAt: released)
        let result = verdict(update, policies: autoPolicies.settingDeferralDays(deferralDays))
        if installs {
            #expect(result == .install)
        } else {
            let expected = date(hour: 12, dayOffset: deferralDays - daysAgo)
            guard case .defer(let until, let reason) = result else {
                Issue.record("Expected defer, got \(result)")
                return
            }
            #expect(until == expected)
            #expect(reason.contains("after release"))
        }
    }

    @Test func firstSeenDateIsUsedWhenUnpublishedAndWordedHonestly() {
        let update = AutoInstallFixtures.update()
        let seen = ReleaseDate(date: date(hour: 12, dayOffset: -1), kind: .firstSeen)
        let result = verdict(update, policies: autoPolicies.settingDeferralDays(3), releaseDates: [update.id: seen])
        #expect(result == .defer(until: date(hour: 12, dayOffset: 2), reason: "Waiting 2 more days after it was first seen"))
        #expect(AutoInstallPlanner.hint(for: result, now: date(hour: 12), calendar: AutoInstallFixtures.utcCalendar)
            == "Auto-installs in 2 days")
    }

    @Test func missingReleaseDateStartsSoakNow() {
        let result = verdict(policies: autoPolicies.settingDeferralDays(2))
        guard case .defer(let until, _) = result else {
            Issue.record("Expected defer, got \(result)")
            return
        }
        #expect(until == date(hour: 12, dayOffset: 2))
    }

    @Test func perAppDeferralOverridesGlobal() {
        let update = AutoInstallFixtures.update(publishedAt: date(hour: 12, dayOffset: -2))
        let policies = autoPolicies.settingDeferralDays(10).settingDeferral(1, for: "com.example.app")
        #expect(verdict(update, policies: policies) == .install)
    }

    @Test func urgentBypassesSoakButNotConditions() {
        let update = AutoInstallFixtures.update(publishedAt: date(hour: 12))
        let policies = autoPolicies.settingDeferralDays(14).settingConditions(InstallConditions(requireACPower: true))
        #expect(verdict(update, policies: policies, urgent: true) == .install)
        #expect(verdict(update, policies: policies, conditions: snapshot(onAC: false), urgent: true)
            == .skip(reason: "Waiting for AC power"))
    }

    @Test("AC power requirement", arguments: [(true, true, true), (true, false, false), (false, false, true)])
    func acPower(required: Bool, onAC: Bool, installs: Bool) {
        let policies = autoPolicies.settingConditions(InstallConditions(requireACPower: required))
        #expect((verdict(policies: policies, conditions: snapshot(onAC: onAC)) == .install) == installs)
    }

    @Test("Network conditions", arguments: [
        (true, false, NetworkStatus(isExpensive: true), "On an expensive network"),
        (false, true, NetworkStatus(isConstrained: true), "Low Data Mode is on"),
        (true, true, nil, "Network status unknown"),
        (true, true, NetworkStatus(), nil),
        (false, false, NetworkStatus(isExpensive: true, isConstrained: true), nil),
        (false, false, nil, nil),
    ] as [(Bool, Bool, NetworkStatus?, String?)])
    func network(avoidExpensive: Bool, avoidConstrained: Bool, network: NetworkStatus?, reason: String?) {
        let rules = InstallConditions(avoidExpensiveNetwork: avoidExpensive, avoidConstrainedNetwork: avoidConstrained)
        let result = verdict(policies: autoPolicies.settingConditions(rules), conditions: snapshot(network: network))
        #expect(result.reason == reason)
    }

    @Test("Quiet hours, including across midnight", arguments: [
        (22, 8, 23, 1, 8), (22, 8, 3, 0, 8), (22, 8, 8, nil, nil), (22, 8, 12, nil, nil),
        (13, 15, 14, 0, 15), (13, 15, 15, nil, nil),
    ] as [(Int, Int, Int, Int?, Int?)])
    func quietHours(start: Int, end: Int, hour: Int, endDayOffset: Int?, endHour: Int?) {
        let rules = InstallConditions(quietHours: QuietHours(startHour: start, endHour: end))
        let result = verdict(policies: autoPolicies.settingConditions(rules), conditions: snapshot(hour: hour))
        if let endDayOffset, let endHour {
            #expect(result == .defer(until: date(hour: endHour, dayOffset: endDayOffset), reason: "Quiet hours"))
        } else {
            #expect(result == .install)
        }
    }

    @Test("Running apps", arguments: [(true, true, false), (true, false, true), (false, true, true)])
    func runningApp(skipRunning: Bool, isRunning: Bool, installs: Bool) {
        let policies = autoPolicies.settingConditions(InstallConditions(skipRunningApps: skipRunning))
        let running: Set<String> = isRunning ? ["com.example.app"] : []
        let result = verdict(policies: policies, conditions: snapshot(running: running))
        #expect((result == .install) == installs)
        if !installs { #expect(result.reason == "App is running") }
    }

    @Test func planKeepsOrderAndFlagsEachUpdate() {
        let updates = [
            AutoInstallFixtures.update("a"),
            AutoInstallFixtures.update("b", url: "https://example.com/B.pkg"),
        ]
        let input = AutoInstallInput(updates: updates, policies: autoPolicies, conditions: snapshot())
        let decisions = planner.plan(input)
        #expect(decisions.map(\.update.app.bundleIdentifier) == ["a", "b"])
        #expect(decisions.map(\.shouldInstall) == [true, false])
    }

    @Test("Days remaining rounds up", arguments: [(0, 0), (1, 1), (23, 1), (24, 1), (25, 2), (72, 3)])
    func daysRemaining(hours: Int, expected: Int) {
        let now = date(hour: 0)
        let target = now.addingTimeInterval(TimeInterval(hours) * 3600)
        #expect(AutoInstallPlanner.daysRemaining(until: target, from: now, calendar: AutoInstallFixtures.utcCalendar) == expected)
    }
}
