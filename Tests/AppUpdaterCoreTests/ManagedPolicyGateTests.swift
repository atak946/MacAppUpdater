import Foundation
import Testing
@testable import AppUpdaterCore

@Suite("ManagedPolicyGate")
struct ManagedPolicyGateTests {
    private struct StubSource: UpdateSource {
        let kind: UpdateSourceKind
        func canHandle(_ app: InstalledApp) -> Bool { true }
        func checkForUpdate(_ app: InstalledApp) async throws -> AvailableUpdate? { nil }
    }

    @Test func unmanagedGateAllowsEverything() {
        let gate = ManagedPolicyGate(configuration: .unmanaged)
        #expect(UpdateSourceKind.allCases.allSatisfy(gate.isSourceAllowed))
        #expect(gate.isUninstallerAllowed)
        #expect(gate.areBetaChannelsAllowed)
        #expect(!gate.isMenuBarIconHidden)
        #expect(!gate.isCheckIntervalLocked)
        #expect(gate.effectiveCheckInterval(userValue: 6) == 6)
        #expect(gate.effectiveDeferralDays(userValue: 2) == 2)
        #expect(gate.effectiveRequireACPower(userValue: true))
    }

    @Test func managedGateEnforcesConfiguration() {
        let config = ManagedConfiguration(
            reader: FakeManagedReader([
                .checkIntervalHours: 24,
                .deferralDays: 7,
                .disableUninstaller: true,
                .disableBetaChannels: true,
                .hideMenuBarIcon: true,
                .avoidExpensiveNetwork: true,
                .allowedSources: ["appStore", "sparkle"],
            ])
        )
        let gate = ManagedPolicyGate(configuration: config)
        #expect(gate.isSourceAllowed(.sparkle))
        #expect(!gate.isSourceAllowed(.github))
        #expect(!gate.isUninstallerAllowed)
        #expect(!gate.areBetaChannelsAllowed)
        #expect(gate.isMenuBarIconHidden)
        #expect(gate.isCheckIntervalLocked)
        #expect(gate.effectiveCheckInterval(userValue: 3) == 24)
        #expect(gate.effectiveDeferralDays(userValue: 0) == 7)
        #expect(gate.effectiveAvoidExpensiveNetwork(userValue: false))
    }

    @Test func filtersSources() {
        let gate = ManagedPolicyGate(configuration: ManagedConfiguration(allowedSources: [.homebrew]))
        let sources: [any UpdateSource] = [StubSource(kind: .sparkle), StubSource(kind: .homebrew)]
        #expect(gate.allowedSources(sources).map(\.kind) == [.homebrew])
    }
}
