import Foundation
import Security
import Testing
@testable import AppUpdaterCore

@Suite("KeychainTokenStore queries")
struct KeychainTokenStoreQueryTests {
    private let store = KeychainTokenStore(service: "svc", account: "acct")

    @Test("the default query targets the data-protection keychain")
    func usesDataProtectionKeychain() {
        let query = store.query()
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(query[kSecAttrService as String] as? String == "svc")
        #expect(query[kSecAttrAccount as String] as? String == "acct")
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
    }

    @Test("the legacy fallback query omits the data-protection flag")
    func legacyQuery() {
        #expect(store.query(dataProtection: false)[kSecUseDataProtectionKeychain as String] == nil)
    }

    @Test("add and update both set ThisDeviceOnly accessibility and the value")
    func accessibilityOnAddAndUpdate() {
        let data = Data("tok".utf8)
        let expected = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        let update = KeychainTokenStore.updateAttributes(data: data)
        let add = store.addQuery(data: data)

        #expect(update[kSecAttrAccessible as String] as? String == expected)
        #expect(update[kSecValueData as String] as? Data == data)
        #expect(add[kSecAttrAccessible as String] as? String == expected)
        #expect(add[kSecValueData as String] as? Data == data)
        #expect(add[kSecUseDataProtectionKeychain as String] as? Bool == true)
        // Updates must not try to change the item's identity.
        #expect(update[kSecAttrService as String] == nil)
    }

    @Test("the read query returns one item's data")
    func readQuery() {
        let query = store.readQuery()
        #expect(query[kSecReturnData as String] as? Bool == true)
        #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
    }
}

@Suite("CoreResourceBundle override")
struct CoreResourceBundleOverrideTests {
    @Test("PACKAGE_RESOURCE_BUNDLE_PATH is honoured only in debug builds")
    func overrideIsDebugOnly() {
        let override = CoreResourceBundle.environmentOverride(["PACKAGE_RESOURCE_BUNDLE_PATH": "/tmp/x"])
        #if DEBUG
        #expect(override == URL(fileURLWithPath: "/tmp/x"))
        #else
        #expect(override == nil)
        #endif
        #expect(CoreResourceBundle.environmentOverride([:]) == nil)
    }
}

@Suite("RequireNotarization managed key")
struct RequireNotarizationTests {
    private func gate(_ values: [ManagedKey: Any]) -> ManagedPolicyGate {
        ManagedPolicyGate(configuration: ManagedConfiguration(reader: FakeManagedReader(values)))
    }

    @Test("forced true locks the toggle and overrides the user's choice")
    func forcedTrue() {
        let gate = gate([.requireNotarization: true])
        #expect(gate.configuration.isManaged(.requireNotarization))
        #expect(gate.isNotarizationLocked)
        #expect(gate.effectiveAllowUnnotarized(userValue: true) == false)
        #expect(gate.effectiveNotarizationPolicy(userAllowsUnnotarized: true) == .require)
    }

    @Test("false or unmanaged leaves the user in control")
    func notForced() {
        for gate in [gate([.requireNotarization: false]), gate([:])] {
            #expect(!gate.isNotarizationLocked)
            #expect(gate.effectiveNotarizationPolicy(userAllowsUnnotarized: true) == .warnOnly)
            #expect(gate.effectiveNotarizationPolicy(userAllowsUnnotarized: false) == .require)
        }
    }

    @Test("non-boolean values are ignored")
    func rejectsNonBoolean() {
        let config = ManagedConfiguration(reader: FakeManagedReader([.requireNotarization: 1]))
        #expect(config.requireNotarization == nil)
        #expect(!config.isManaged)
    }
}

@Suite("NotarizationSettingAudit")
struct NotarizationSettingAuditTests {
    private let suite = "NotarizationSettingAuditTests-\(UUID().uuidString)"

    private func withDefaults(_ body: (UserDefaults, NotarizationSettingAudit) -> Void) {
        let defaults = TestDefaults.suite(named: suite)!
        defer { defaults.removePersistentDomain(forName: TestDefaults.prefix + suite) }
        body(defaults, NotarizationSettingAudit(defaults: defaults))
    }

    @Test("a fresh install with the default value is not flagged")
    func freshDefault() {
        withDefaults { _, audit in
            #expect(!audit.wasChangedOutsideApp)
            #expect(!audit.confirmedAllowUnnotarized)
        }
    }

    @Test("defaults write without the UI is flagged and not honoured")
    func externalEnableIsIgnored() {
        withDefaults { defaults, audit in
            defaults.set(true, forKey: NotarizationSettingAudit.settingKey)
            #expect(audit.wasChangedOutsideApp)
            #expect(!audit.confirmedAllowUnnotarized)
        }
    }

    @Test("a UI change is honoured; a later external flip is flagged")
    func uiChangeThenTamper() {
        withDefaults { defaults, audit in
            audit.recordUserChange(true)
            #expect(!audit.wasChangedOutsideApp)
            #expect(audit.confirmedAllowUnnotarized)

            defaults.set(false, forKey: NotarizationSettingAudit.settingKey)
            #expect(audit.wasChangedOutsideApp)
            audit.recordUserChange(false)
            defaults.set(true, forKey: NotarizationSettingAudit.settingKey)
            #expect(audit.wasChangedOutsideApp)
            #expect(!audit.confirmedAllowUnnotarized)
        }
    }

    @Test("confirming accepts the stored value")
    func confirm() {
        withDefaults { defaults, audit in
            defaults.set(true, forKey: NotarizationSettingAudit.settingKey)
            audit.confirmStoredValue()
            #expect(!audit.wasChangedOutsideApp)
            #expect(audit.confirmedAllowUnnotarized)
        }
    }

    @Test("a garbage fingerprint counts as an external change")
    func garbageFingerprint() {
        withDefaults { defaults, audit in
            defaults.set("nope", forKey: NotarizationSettingAudit.fingerprintKey)
            #expect(audit.wasChangedOutsideApp)
        }
    }
}
