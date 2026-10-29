import Foundation
import Testing
@testable import AppUpdaterCore

@Suite("ManagedConfiguration parsing")
struct ManagedConfigurationTests {
    private func parse(_ values: [ManagedKey: Any]) -> ManagedConfiguration {
        ManagedConfiguration(reader: FakeManagedReader(values))
    }

    @Test func emptyDomainIsUnmanaged() {
        let config = parse([:])
        #expect(config == .unmanaged)
        #expect(!config.isManaged)
        #expect(ManagedConfiguration(reader: UnmanagedPreferencesReader()) == .unmanaged)
    }

    @Test func parsesEveryValidKey() {
        let config = parse([
            .checkIntervalHours: 12,
            .autoInstallEnabled: true,
            .defaultPolicy: "notifyOnly",
            .perAppPolicies: ["com.example.a": "autoInstall"],
            .ignoredBundleIdentifiers: ["com.example.b"],
            .deferralDays: 3,
            .requireACPower: true,
            .avoidExpensiveNetwork: false,
            .disableUninstaller: true,
            .disableBetaChannels: true,
            .allowedSources: ["sparkle", "homebrew"],
            .hideMenuBarIcon: false,
            .requireNotarization: true,
            .reportWebhookURL: "https://reports.example.com/hook",
        ])
        #expect(config.managedKeys == Set(ManagedKey.allCases))
        #expect(config.requireNotarization == true)
        #expect(config.checkIntervalHours == 12)
        #expect(config.effectiveDefaultPolicy == .notifyOnly)
        #expect(config.perAppPolicies == ["com.example.a": .autoInstall])
        #expect(config.ignoredBundleIdentifiers == ["com.example.b"])
        #expect(config.deferralDays == 3)
        #expect(config.requireACPower == true)
        #expect(config.avoidExpensiveNetwork == false)
        #expect(config.allowedSources == [.sparkle, .homebrew])
        #expect(config.reportWebhookURL?.host == "reports.example.com")
    }

    @Test(arguments: [0.0, 0.5, 169, -1, Double.nan, Double.infinity])
    func rejectsOutOfRangeInterval(_ hours: Double) {
        let config = parse([.checkIntervalHours: hours])
        #expect(config.checkIntervalHours == nil)
        #expect(!config.isManaged(.checkIntervalHours))
    }

    @Test func rejectsWrongTypes() {
        let config = parse([
            .checkIntervalHours: "6",
            .autoInstallEnabled: "yes",
            .requireACPower: 1,
            .defaultPolicy: "always",
            .perAppPolicies: ["a", "b"],
            .ignoredBundleIdentifiers: "com.example.a",
            .deferralDays: 2.5,
            .disableUninstaller: true as Any,
        ])
        #expect(config.managedKeys == [.disableUninstaller])
    }

    @Test func booleanIsNotAcceptedAsNumber() {
        #expect(parse([.checkIntervalHours: true]).checkIntervalHours == nil)
    }

    @Test func dropsInvalidEntriesButKeepsValidOnes() {
        let config = parse([
            .perAppPolicies: ["com.ok": "autoInstall", "com.bad": "sometimes", "bad id": "notifyOnly"],
            .ignoredBundleIdentifiers: ["com.ok", "", "has space", 42],
            .allowedSources: ["github", "ftp"],
        ])
        #expect(config.perAppPolicies == ["com.ok": .autoInstall])
        #expect(config.ignoredBundleIdentifiers == ["com.ok"])
        #expect(config.allowedSources == [.github])
    }

    @Test func allowedSourcesWithoutKnownKindsFailsOpen() {
        let config = parse([.allowedSources: ["ftp", "scp"]])
        #expect(config.allowedSources == nil)
        #expect(!config.isManaged(.allowedSources))
    }

    @Test(arguments: [
        "http://reports.example.com", "ftp://example.com", "https://", "not a url",
        "https://user:secret@example.com/hook",
    ])
    func rejectsNonHTTPSWebhook(_ value: String) {
        #expect(parse([.reportWebhookURL: value]).reportWebhookURL == nil)
    }

    @Test func autoInstallEnabledIsShorthandForDefaultPolicy() {
        #expect(parse([.autoInstallEnabled: true]).effectiveDefaultPolicy == .autoInstall)
        #expect(parse([.autoInstallEnabled: false]).effectiveDefaultPolicy == .notifyOnly)
        #expect(parse([.autoInstallEnabled: false]).isAutoInstallDisabled)
        let both = parse([.autoInstallEnabled: true, .defaultPolicy: "notifyOnly"])
        #expect(both.effectiveDefaultPolicy == .notifyOnly)
    }

    @Test func readsNSTypesFromPropertyLists() {
        let config = parse([
            .checkIntervalHours: NSNumber(value: 24),
            .hideMenuBarIcon: kCFBooleanTrue as Any,
            .ignoredBundleIdentifiers: NSArray(array: ["com.example.a"]),
        ])
        #expect(config.checkIntervalHours == 24)
        #expect(config.hideMenuBarIcon == true)
        #expect(config.ignoredBundleIdentifiers == ["com.example.a"])
    }
}
