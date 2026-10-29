import AppUpdaterCore
import Foundation
import Testing
@testable import AppUpdater

@MainActor
@Suite("UpdatesViewModel auto-install (planner)")
struct AutoInstallViewModelTests {
    @Test("Planner skips running apps, incompatible updates, notify-only apps and packages")
    func plannerFiltering() async {
        let allowed = Fixtures.update("allowed")
        let running = Fixtures.update("running")
        let incompatible = Fixtures.update("newos", minimumSystemVersion: "99.0")
        let notifyOnly = Fixtures.update("manual")
        let pkg = Fixtures.update("pkgapp", file: "setup.pkg")
        let all = [allowed, running, incompatible, notifyOnly, pkg]
        let policies = UpdatePolicies(defaultPolicy: .autoInstall, overrides: ["manual": .notifyOnly])
        let viewModel = makeViewModel(updates: all, running: ["running"], policies: policies)

        let decisions = await viewModel.autoInstallDecisions(from: all, policies: policies)

        #expect(decisions.filter(\.shouldInstall).map(\.update.id) == [allowed.id])
        #expect(viewModel.lastAutoInstallDecisions[running.id]?.verdict.reason == "Running is running")
    }

    @Test("Scheduled check installs allowed updates and returns the rest")
    func scheduledCheck() async {
        let allowed = Fixtures.update("allowed")
        let running = Fixtures.update("running")
        let installer = RecordingInstaller()
        let viewModel = makeViewModel(
            updates: [allowed, running], installer: installer,
            running: ["running"], policies: UpdatePolicies(defaultPolicy: .autoInstall)
        )

        let remaining = await viewModel.runScheduledCheck()

        #expect(await installer.installed == [allowed.id])
        #expect(remaining.map(\.id) == [running.id])
        #expect(viewModel.installState(for: allowed) == .installed)
    }

    @Test("Soak period defers fresh releases and shows a countdown hint")
    func soakPeriod() async {
        let fresh = Fixtures.update("fresh", publishedAt: Date())
        let installer = RecordingInstaller()
        let policies = UpdatePolicies(defaultPolicy: .autoInstall).settingDeferralDays(3)
        let viewModel = makeViewModel(updates: [fresh], installer: installer, policies: policies)

        _ = await viewModel.runScheduledCheck()

        #expect(await installer.installed.isEmpty)
        #expect(viewModel.autoInstallHint(for: fresh) == "Auto-installs in 3 days")
        #expect(viewModel.releaseDateLabel(for: fresh)?.hasPrefix("Released ") == true)
    }

    @Test("Vendor-managed apps are never auto-installed")
    func vendorManagedNotAutoInstalled() async {
        let update = Fixtures.update("setappapp")
        let installer = RecordingInstaller()
        let extras = ViewModelExtras(vendorManaged: ["setappapp": VendorFixtures.setapp])
        let viewModel = makeViewModel(
            updates: [update], installer: installer,
            policies: UpdatePolicies(defaultPolicy: .autoInstall), extras: extras
        )

        _ = await viewModel.runScheduledCheck()

        #expect(await installer.installed.isEmpty)
        #expect(viewModel.lastAutoInstallDecisions[update.id]?.verdict.reason == "Updated by Setapp")
    }

    @Test("MDM AutoInstallEnabled=false stops scheduled installs")
    func managedKillSwitch() async {
        let update = Fixtures.update("allowed")
        let installer = RecordingInstaller()
        let extras = ViewModelExtras(managed: ManagedConfiguration(autoInstallEnabled: false))
        let viewModel = makeViewModel(
            updates: [update], installer: installer,
            policies: UpdatePolicies(defaultPolicy: .autoInstall), extras: extras
        )

        _ = await viewModel.runScheduledCheck()

        #expect(await installer.installed.isEmpty)
    }
}

enum VendorFixtures {
    static let setapp = VendorManagement(
        vendor: .setapp, updaterName: "Setapp",
        openTarget: .url(URL(string: "setapp://open")!)
    )
}
