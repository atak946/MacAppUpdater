import Foundation
import Testing
@testable import AppUpdaterCore

@Suite("Managed stores")
struct ManagedStoresTests {
    // MARK: Exclusions

    @Test func exclusionLoadMergesForcedIgnores() {
        let base = ManagedFakeExclusionStore(ExclusionRules(
            ignoredBundleIdentifiers: ["com.user"], skippedVersions: ["com.skip": "2.0"]
        ))
        let store = ManagedExclusionRulesStore(
            base: base, configuration: ManagedConfiguration(ignoredBundleIdentifiers: ["com.forced"])
        )
        let rules = store.load()
        #expect(rules.ignoredBundleIdentifiers == ["com.user", "com.forced"])
        #expect(rules.skippedVersions == ["com.skip": "2.0"])
        #expect(store.isForced("com.forced"))
        #expect(!store.isForced("com.user"))
    }

    @Test func exclusionSaveStripsForcedIds() throws {
        let base = ManagedFakeExclusionStore()
        let store = ManagedExclusionRulesStore(
            base: base, configuration: ManagedConfiguration(ignoredBundleIdentifiers: ["com.forced"])
        )
        try store.save(store.load().ignoring("com.user"))
        #expect(base.stored.ignoredBundleIdentifiers == ["com.user"])
    }

    @Test func forcedIgnoreCannotBeRemoved() throws {
        let base = ManagedFakeExclusionStore()
        let store = ManagedExclusionRulesStore(
            base: base, configuration: ManagedConfiguration(ignoredBundleIdentifiers: ["com.forced"])
        )
        try store.save(store.load().including("com.forced"))
        #expect(store.load().isIgnored("com.forced"))
    }

    @Test func exclusionSavePreservesUserIgnoreOfForcedId() throws {
        let base = ManagedFakeExclusionStore(ExclusionRules(ignoredBundleIdentifiers: ["com.forced"]))
        let store = ManagedExclusionRulesStore(
            base: base, configuration: ManagedConfiguration(ignoredBundleIdentifiers: ["com.forced"])
        )
        try store.save(store.load().including("com.forced"))
        #expect(base.stored.ignoredBundleIdentifiers == ["com.forced"])
    }

    @Test func unmanagedExclusionStoreIsTransparent() throws {
        let base = ManagedFakeExclusionStore()
        let store = ManagedExclusionRulesStore(base: base, configuration: .unmanaged)
        let rules = ExclusionRules(ignoredBundleIdentifiers: ["a"], skippedVersions: ["b": "1"])
        try store.save(rules)
        #expect(store.load() == rules)
    }

    // MARK: Policies

    @Test func policiesLoadAppliesForcedValues() {
        let base = ManagedFakePoliciesStore(UpdatePolicies(
            defaultPolicy: .autoInstall, overrides: ["com.a": .autoInstall, "com.b": .notifyOnly]
        ))
        let config = ManagedConfiguration(defaultPolicy: .notifyOnly, perAppPolicies: ["com.a": .notifyOnly])
        let policies = ManagedUpdatePoliciesStore(base: base, configuration: config).load()
        #expect(policies.defaultPolicy == .notifyOnly)
        #expect(policies.overrides == ["com.a": .notifyOnly, "com.b": .notifyOnly])
    }

    @Test func policiesSaveKeepsUserValuesForForcedFields() throws {
        let base = ManagedFakePoliciesStore(UpdatePolicies(defaultPolicy: .autoInstall, overrides: ["com.a": .autoInstall]))
        let config = ManagedConfiguration(defaultPolicy: .notifyOnly, perAppPolicies: ["com.a": .notifyOnly])
        let store = ManagedUpdatePoliciesStore(base: base, configuration: config)
        try store.save(store.load().setting(.autoInstall, for: "com.c").setting(nil, for: "com.a"))
        #expect(base.stored.defaultPolicy == .autoInstall)
        #expect(base.stored.overrides == ["com.a": .autoInstall, "com.c": .autoInstall])
    }

    @Test func policiesSaveWritesUnlockedDefault() throws {
        let base = ManagedFakePoliciesStore()
        let config = ManagedConfiguration(perAppPolicies: ["com.a": .autoInstall])
        let store = ManagedUpdatePoliciesStore(base: base, configuration: config)
        try store.save(store.load().settingDefault(.autoInstall))
        #expect(base.stored.defaultPolicy == .autoInstall)
        #expect(base.stored.overrides.isEmpty)
    }

    @Test func autoInstallKillSwitchMasksUserOverrides() throws {
        let base = ManagedFakePoliciesStore(UpdatePolicies(overrides: ["com.user": .autoInstall]))
        let config = ManagedConfiguration(autoInstallEnabled: false, perAppPolicies: ["com.it": .autoInstall])
        let store = ManagedUpdatePoliciesStore(base: base, configuration: config)
        let loaded = store.load()
        #expect(loaded.defaultPolicy == .notifyOnly)
        #expect(loaded.overrides == ["com.it": .autoInstall])
        try store.save(loaded)
        #expect(base.stored.overrides == ["com.user": .autoInstall])
    }

    @Test func exclusionSaveKeepsVersionCeilings() throws {
        let base = ManagedFakeExclusionStore()
        let store = ManagedExclusionRulesStore(
            base: base, configuration: ManagedConfiguration(ignoredBundleIdentifiers: ["com.forced"])
        )
        try store.save(store.load().capping("com.app", at: "5"))
        #expect(base.stored.versionCeilings == ["com.app": "5"])
    }

    @Test func forcedDeferralOverridesAndMasksUserDeferral() throws {
        let user = UpdatePolicies(deferralDays: 1, deferralOverrides: ["com.a": 0])
        let base = ManagedFakePoliciesStore(user)
        let store = ManagedUpdatePoliciesStore(base: base, configuration: ManagedConfiguration(deferralDays: 7))
        let loaded = store.load()
        #expect(store.isDeferralLocked)
        #expect(loaded.deferralDays == 7)
        #expect(loaded.deferralDays(for: "com.a") == 7)
        try store.save(loaded.settingDeferralDays(2))
        #expect(base.stored.deferralDays == 1)
        #expect(base.stored.deferralOverrides == ["com.a": 0])
    }

    @Test func forcedConditionsOverrideOnlyManagedFields() throws {
        let user = UpdatePolicies(conditions: InstallConditions(
            requireACPower: false, avoidExpensiveNetwork: false, skipRunningApps: true
        ))
        let base = ManagedFakePoliciesStore(user)
        let store = ManagedUpdatePoliciesStore(base: base, configuration: ManagedConfiguration(requireACPower: true))
        let loaded = store.load()
        #expect(loaded.conditions.requireACPower)
        #expect(!loaded.conditions.avoidExpensiveNetwork)
        let edited = loaded.conditions.with(avoidExpensiveNetwork: true, skipRunningApps: false)
        try store.save(loaded.settingConditions(edited))
        #expect(!base.stored.conditions.requireACPower)
        #expect(base.stored.conditions.avoidExpensiveNetwork)
        #expect(!base.stored.conditions.skipRunningApps)
    }
}
