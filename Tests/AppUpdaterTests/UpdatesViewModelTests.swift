import AppUpdaterCore
import Foundation
import Testing
@testable import AppUpdater

@MainActor
@Suite("UpdatesViewModel")
struct UpdatesViewModelTests {
    @Test("Routes each install method to the right installer")
    func installRouting() async {
        let pkg = Fixtures.update("pkgapp", file: "setup.pkg")
        let dmg = Fixtures.update("dmgapp")
        let store = Fixtures.update("storeapp", source: .appStore)

        let withHelper = makeViewModel(updates: [pkg, dmg, store], helper: .enabled)
        #expect(await withHelper.installRoute(for: pkg) == .helperPackage)
        #expect(await withHelper.installRoute(for: dmg) == .inPlace)
        #expect(await withHelper.installRoute(for: store) == .appStore)

        let withoutHelper = makeViewModel(updates: [pkg], helper: .requiresApproval)
        #expect(await withoutHelper.installRoute(for: pkg) == .installerApp)
    }

    @Test("Successful install is recorded in history")
    func historyOnSuccess() async throws {
        let update = Fixtures.update("app")
        let viewModel = makeViewModel(updates: [update])
        await viewModel.refresh()

        await viewModel.install(update)

        let entry = try #require(viewModel.history.first)
        #expect(entry.outcome == .succeeded)
        #expect(entry.bundleID == "app")
        #expect(entry.toVersion == "2.0")
    }

    @Test("Failed install is recorded in history with its message")
    func historyOnFailure() async throws {
        let update = Fixtures.update("app")
        let viewModel = makeViewModel(updates: [update], installer: RecordingInstaller(failingWith: .checksumMismatch))
        await viewModel.refresh()

        await viewModel.install(update)

        let entry = try #require(viewModel.history.first)
        #expect(entry.outcome == .failed(message: UpdaterError.checksumMismatch.localizedDescription))
        #expect(viewModel.installState(for: update) == .failed(UpdaterError.checksumMismatch.localizedDescription))
    }

    @Test("Updates requiring a newer macOS install only after confirmation")
    func compatibilityGate() async {
        let update = Fixtures.update("newos", minimumSystemVersion: "99.0")
        let installer = RecordingInstaller()
        let viewModel = makeViewModel(updates: [update], installer: installer)
        await viewModel.refresh()

        #expect(viewModel.compatibilityWarning(for: update) != nil)
        #expect(viewModel.installableUpdates.isEmpty)
        await viewModel.install(update)
        #expect(await installer.installed.isEmpty)

        await viewModel.install(update, ignoringCompatibility: true)
        #expect(await installer.installed == [update.id])
    }

    @Test("Cancelling a download resets the state without recording history")
    func cancelDownload() async {
        let update = Fixtures.update("app")
        let installer = RecordingInstaller()
        let viewModel = makeViewModel(
            updates: [update], downloader: StubDownloader(blocksUntilCancelled: true), installer: installer
        )
        await viewModel.refresh()
        #expect(!viewModel.canCancel(update))

        let install = Task { await viewModel.install(update) }
        for _ in 0..<1000 where !viewModel.canCancel(update) {
            await Task.yield()
        }
        #expect(viewModel.canCancel(update))

        viewModel.cancelInstall(update)
        await install.value

        #expect(viewModel.installState(for: update) == .pending)
        #expect(!viewModel.canCancel(update))
        #expect(viewModel.history.isEmpty)
        #expect(await installer.installed.isEmpty)
    }

    @Test("Refresh exposes the precise source per app")
    func checkResults() async {
        let update = Fixtures.update("app", source: .github)
        let viewModel = makeViewModel(updates: [update])

        await viewModel.refresh()

        #expect(viewModel.checkResult(for: update.app)?.matchedSource == .github)
        #expect(viewModel.checkResult(for: update.app)?.sourceLabel == "GitHub")
    }
}
