import AppUpdaterCore
import Foundation
import Testing
@testable import AppUpdater

@MainActor
@Suite("UpdatesViewModel round-2 routing")
struct IntegrationRoutingTests {
    @Test("Vendor-managed updates are routed to the vendor updater and left out of Update All")
    func vendorManagedRouting() async {
        let managed = Fixtures.update("setappapp")
        let regular = Fixtures.update("regular")
        let installer = RecordingInstaller()
        let workspace = RecordingWorkspace()
        let extras = ViewModelExtras(vendorManaged: ["setappapp": VendorFixtures.setapp], workspace: workspace)
        let viewModel = makeViewModel(updates: [managed, regular], installer: installer, extras: extras)
        await viewModel.refresh()

        #expect(await viewModel.installRoute(for: managed) == .vendorUpdater(VendorFixtures.setapp))
        #expect(viewModel.installableUpdates.map(\.id) == [regular.id])

        await viewModel.installAll()

        #expect(await installer.installed == [regular.id])
        #expect(workspace.opened.isEmpty)
    }

    @Test("Vendor feeds with openVendorUpdater open the vendor page and never install")
    func openVendorUpdaterNeverInstalls() async {
        let chrome = Fixtures.update("chrome", file: "chrome/", source: .vendor)
        let installer = RecordingInstaller()
        let workspace = RecordingWorkspace()
        let extras = ViewModelExtras(vendorStrategy: ["chrome": .openVendorUpdater], workspace: workspace)
        let viewModel = makeViewModel(
            updates: [chrome], installer: installer,
            policies: UpdatePolicies(defaultPolicy: .autoInstall), extras: extras
        )
        await viewModel.refresh()

        #expect(viewModel.installableUpdates.isEmpty)
        await viewModel.install(chrome)
        _ = await viewModel.runScheduledCheck()

        #expect(await installer.installed.isEmpty)
        #expect(workspace.opened == [chrome.downloadURL])
        if case .needsManualAction = viewModel.installState(for: chrome) {} else {
            Issue.record("Expected manual guidance, got \(viewModel.installState(for: chrome))")
        }
    }

    @Test("MDM-forced ignores can't be included again")
    func forcedIgnoreIsLocked() async {
        let update = Fixtures.update("corp")
        let extras = ViewModelExtras(managed: ManagedConfiguration(ignoredBundleIdentifiers: ["corp"]))
        let viewModel = makeViewModel(updates: [update], extras: extras)
        await viewModel.refresh()

        #expect(viewModel.isIgnoreLocked("corp"))
        #expect(viewModel.updates.isEmpty)

        viewModel.include("corp")
        #expect(viewModel.exclusions.isIgnored("corp"))

        viewModel.ignore(Fixtures.app("other"))
        viewModel.include("other")
        #expect(viewModel.exclusions.isIgnored("corp"))
        #expect(!viewModel.exclusions.isIgnored("other"))
    }

    @Test("Notarization block surfaces as a failed state with a clear message")
    func notarizationBlock() async throws {
        let update = Fixtures.update("app")
        let blocked = UpdaterError.signatureInvalid(UpdaterError.notNotarizedPrefix + "Developer ID, not notarized")
        let viewModel = makeViewModel(updates: [update], installer: RecordingInstaller(failingWith: blocked))
        await viewModel.refresh()

        await viewModel.install(update)

        #expect(viewModel.installState(for: update) == .failed(UpdatesViewModel.notarizationBlockedMessage))
        let entry = try #require(viewModel.history.first)
        #expect(entry.outcome == .failed(message: UpdatesViewModel.notarizationBlockedMessage))
    }

    @Test("Version ceilings hide newer majors and can be removed")
    func versionCeiling() async {
        let update = Fixtures.update("app")
        let viewModel = makeViewModel(updates: [update])
        await viewModel.refresh()

        viewModel.setCeiling("1", for: update.app)
        #expect(viewModel.updates.isEmpty)
        #expect(viewModel.versionCeilings.map(\.ceiling) == ["1"])

        viewModel.removeCeiling("app")
        #expect(viewModel.updates.map(\.id) == [update.id])
    }

    @Test("Coverage report is built from the detailed check results")
    func coverage() async throws {
        let viewModel = makeViewModel(updates: [Fixtures.update("app")])
        #expect(viewModel.coverageReport == nil)
        await viewModel.refresh()

        let report = try #require(viewModel.coverageReport)
        #expect(report.totalApps == 1)
        #expect(report.trackedCount == 1)
    }

    @Test("Uninstaller is hidden when the organization disables it")
    func uninstallerDisabled() {
        let extras = ViewModelExtras(managed: ManagedConfiguration(disableUninstaller: true))
        let viewModel = makeViewModel(updates: [], extras: extras)
        #expect(!viewModel.canUninstall(Fixtures.app("app")))
    }
}
