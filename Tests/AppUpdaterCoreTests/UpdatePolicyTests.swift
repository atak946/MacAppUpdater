import Foundation
import Testing
@testable import AppUpdaterCore

@Suite("UpdatePolicy")
struct UpdatePolicyTests {
    private func makeUpdate(
        _ bundleID: String = "com.example.app",
        url: String = "https://example.com/App.zip",
        source: UpdateSourceKind = .sparkle
    ) -> AvailableUpdate {
        let app = InstalledApp(
            bundleIdentifier: bundleID,
            name: "App",
            url: URL(fileURLWithPath: "/Applications/App.app"),
            shortVersion: "1.0",
            buildVersion: nil,
            sparkleFeedURL: nil,
            isFromAppStore: source == .appStore
        )
        return AvailableUpdate(app: app, newVersion: "2.0", downloadURL: URL(string: url)!, source: source)
    }

    @Test func defaultIsNotifyOnly() {
        let policies = UpdatePolicies()
        #expect(policies.defaultPolicy == .notifyOnly)
        #expect(!policies.shouldAutoInstall(makeUpdate()))
    }

    @Test func globalAutoInstallAppliesToAutomaticInstalls() {
        let policies = UpdatePolicies().settingDefault(.autoInstall)
        #expect(policies.shouldAutoInstall(makeUpdate(url: "https://example.com/App.zip")))
        #expect(policies.shouldAutoInstall(makeUpdate(url: "https://example.com/App.dmg", source: .github)))
    }

    @Test func neverAutoInstallsAppStoreOrPkg() {
        let policies = UpdatePolicies(defaultPolicy: .autoInstall, overrides: ["com.example.app": .autoInstall])
        #expect(!policies.shouldAutoInstall(makeUpdate(source: .appStore)))
        #expect(!policies.shouldAutoInstall(makeUpdate(url: "https://example.com/Installer.pkg")))
    }

    @Test func overrideWinsOverDefault() {
        let optIn = UpdatePolicies().setting(.autoInstall, for: "com.example.app")
        #expect(optIn.shouldAutoInstall(makeUpdate()))
        #expect(!optIn.shouldAutoInstall(makeUpdate("com.other.app")))

        let optOut = UpdatePolicies(defaultPolicy: .autoInstall).setting(.notifyOnly, for: "com.example.app")
        #expect(!optOut.shouldAutoInstall(makeUpdate()))
        #expect(optOut.shouldAutoInstall(makeUpdate("com.other.app")))
    }

    @Test func settingNilRemovesOverride() {
        let policies = UpdatePolicies()
            .setting(.autoInstall, for: "com.example.app")
            .setting(nil, for: "com.example.app")
        #expect(policies == UpdatePolicies())
        #expect(!policies.hasOverride(for: "com.example.app"))
    }

    @Test func settingReplacesExistingOverride() {
        let policies = UpdatePolicies()
            .setting(.autoInstall, for: "a")
            .setting(.notifyOnly, for: "a")
        #expect(policies.overrides == ["a": .notifyOnly])
    }

    @Test func updatesReturnNewValues() {
        let original = UpdatePolicies()
        _ = original.setting(.autoInstall, for: "a")
        _ = original.settingDefault(.autoInstall)
        #expect(original == UpdatePolicies())
    }

    @Test func storeRoundTrips() throws {
        let suite = "UpdatePolicyTests.\(UUID().uuidString)"
        let defaults = try #require(TestDefaults.suite(named: suite))
        defer { defaults.removePersistentDomain(forName: TestDefaults.prefix + suite) }
        let store = UserDefaultsUpdatePoliciesStore(defaults: defaults)
        let policies = UpdatePolicies(defaultPolicy: .autoInstall).setting(.notifyOnly, for: "b")

        try store.save(policies)

        #expect(store.load() == policies)
    }

    @Test func storeReturnsDefaultsWhenEmptyOrCorrupt() throws {
        let suite = "UpdatePolicyTests.\(UUID().uuidString)"
        let defaults = try #require(TestDefaults.suite(named: suite))
        defer { defaults.removePersistentDomain(forName: TestDefaults.prefix + suite) }
        let store = UserDefaultsUpdatePoliciesStore(defaults: defaults)
        #expect(store.load() == UpdatePolicies())

        defaults.set(Data("not json".utf8), forKey: "updatePolicies")
        #expect(store.load() == UpdatePolicies())
    }

    @Test func rawValuesAreStable() {
        #expect(UpdatePolicy.notifyOnly.rawValue == "notifyOnly")
        #expect(UpdatePolicy.autoInstall.rawValue == "autoInstall")
    }
    // MARK: Soak period and conditions

    @Test func deferralDefaultsToZeroAndOverridesWin() {
        let policies = UpdatePolicies().settingDeferralDays(7).settingDeferral(2, for: "a")
        #expect(policies.deferralDays(for: "a") == 2)
        #expect(policies.deferralDays(for: "b") == 7)
        #expect(policies.hasDeferralOverride(for: "a"))
        #expect(!policies.settingDeferral(nil, for: "a").hasDeferralOverride(for: "a"))
        #expect(UpdatePolicies().deferralDays == 0)
    }

    @Test("Deferral is clamped to 0...30", arguments: [(-3, 0), (0, 0), (14, 14), (30, 30), (99, 30)])
    func deferralClamped(input: Int, expected: Int) {
        #expect(UpdatePolicies().settingDeferralDays(input).deferralDays == expected)
        #expect(UpdatePolicies().settingDeferral(input, for: "a").deferralDays(for: "a") == expected)
    }

    @Test func existingSettersPreserveNewFields() {
        let conditions = InstallConditions(requireACPower: true, quietHours: QuietHours(startHour: 22, endHour: 7))
        let policies = UpdatePolicies()
            .settingDeferralDays(5)
            .settingDeferral(1, for: "x")
            .settingConditions(conditions)
            .setting(.autoInstall, for: "a")
            .settingDefault(.autoInstall)
        #expect(policies.deferralDays == 5)
        #expect(policies.deferralOverrides == ["x": 1])
        #expect(policies.conditions == conditions)
    }

    @Test func decodesLegacyJSONWithoutNewKeys() throws {
        let json = #"{"defaultPolicy":"autoInstall","overrides":{"a":"notifyOnly"}}"#
        let policies = try JSONDecoder().decode(UpdatePolicies.self, from: Data(json.utf8))
        #expect(policies.defaultPolicy == .autoInstall)
        #expect(policies.overrides == ["a": .notifyOnly])
        #expect(policies.deferralDays == 0)
        #expect(policies.deferralOverrides.isEmpty)
        #expect(policies.conditions == InstallConditions())
    }

    @Test func decodesPartialConditions() throws {
        let json = #"{"defaultPolicy":"notifyOnly","overrides":{},"conditions":{"requireACPower":true}}"#
        let policies = try JSONDecoder().decode(UpdatePolicies.self, from: Data(json.utf8))
        #expect(policies.conditions.requireACPower)
        #expect(policies.conditions.skipRunningApps)
        #expect(policies.conditions.quietHours == nil)
    }

    @Test func fullPoliciesRoundTripThroughJSON() throws {
        let policies = UpdatePolicies(
            defaultPolicy: .autoInstall,
            deferralDays: 3,
            deferralOverrides: ["a": 10],
            conditions: InstallConditions(avoidExpensiveNetwork: true, quietHours: QuietHours(startHour: 23, endHour: 6))
        )
        let decoded = try JSONDecoder().decode(UpdatePolicies.self, from: JSONEncoder().encode(policies))
        #expect(decoded == policies)
    }

    @Test("Quiet hours membership", arguments: [
        (22, 8, 23, true), (22, 8, 0, true), (22, 8, 7, true), (22, 8, 8, false), (22, 8, 12, false),
        (9, 17, 9, true), (9, 17, 16, true), (9, 17, 17, false), (5, 5, 5, false),
    ])
    func quietHours(start: Int, end: Int, hour: Int, expected: Bool) {
        #expect(QuietHours(startHour: start, endHour: end).contains(hour: hour) == expected)
    }

    @Test func conditionsCopiesAreImmutable() {
        let base = InstallConditions()
        let changed = base.with(requireACPower: true).withQuietHours(QuietHours(startHour: 1, endHour: 2))
        #expect(base == InstallConditions())
        #expect(changed.requireACPower)
        #expect(changed.quietHours == QuietHours(startHour: 1, endHour: 2))
        #expect(changed.withQuietHours(nil).quietHours == nil)
    }
}
