import AppUpdaterCore
import Foundation
import Testing
@testable import AppUpdater

@MainActor
@Suite("UpdatesViewModel refresh and exclusions")
struct UpdatesViewModelRefreshTests {
    @Test("a failing scan ends in .failed with the error message and returns nothing")
    func refreshFailure() async {
        let viewModel = makeViewModel(updates: [], extras: ViewModelExtras(scanner: FailingScanner()))

        let found = await viewModel.refresh()

        #expect(found.isEmpty)
        #expect(viewModel.state == .failed("Disk unreadable"))
        #expect(!viewModel.isBusy)
        #expect(viewModel.lastChecked == nil)
    }

    @Test("refresh loads sorted updates, stamps lastChecked and reads the helper status")
    func refreshSuccess() async {
        let zeta = Fixtures.update("zeta")
        let alpha = Fixtures.update("alpha")
        let viewModel = makeViewModel(updates: [zeta, alpha], helper: .enabled)

        let found = await viewModel.refresh()

        #expect(found.map(\.app.bundleIdentifier) == ["alpha", "zeta"])
        #expect(viewModel.lastChecked != nil)
        #expect(viewModel.helperStatus == .enabled)
        #expect(viewModel.installedApps.count == 2)
        #expect(viewModel.update(for: alpha.app) == alpha)
        #expect(viewModel.menuBarSymbol == "arrow.down.app.fill")
    }

    @Test("a second refresh while one is running is ignored")
    func refreshIsReentrancySafe() async {
        let gate = Gate()
        let update = Fixtures.update("app")
        let viewModel = makeViewModel(
            updates: [update], extras: ViewModelExtras(scanner: GatedScanner(apps: [update.app], gate: gate))
        )

        let first = Task { await viewModel.refresh() }
        #expect(await eventually { viewModel.state == .scanning })
        let second = await viewModel.refresh()
        await gate.open()
        let firstResult = await first.value

        #expect(second.isEmpty)
        #expect(firstResult.map(\.id) == [update.id])
    }

    @Test("install states of updates that disappeared are dropped on refresh")
    func refreshPrunesInstallStates() async {
        let update = Fixtures.update("app")
        let stale = Fixtures.update("gone")
        let viewModel = makeViewModel(updates: [update])
        viewModel.setInstallState(.failed("x"), for: stale)
        viewModel.setInstallState(.installed, for: update)

        await viewModel.refresh()

        #expect(viewModel.installStates.keys.sorted() == [update.id])
        #expect(viewModel.pendingUpdates.isEmpty)
        #expect(viewModel.menuBarSymbol == "arrow.down.app")
    }

    @Test("ignoring an app and skipping a version move updates to the excluded list")
    func exclusions() async {
        let ignored = Fixtures.update("ignored")
        let skipped = Fixtures.update("skipped")
        let kept = Fixtures.update("kept")
        let viewModel = makeViewModel(updates: [ignored, skipped, kept])
        await viewModel.refresh()

        viewModel.ignore(ignored.app)
        viewModel.skipVersion(of: skipped)

        #expect(viewModel.updates.map(\.id) == [kept.id])
        #expect(Set(viewModel.excludedUpdates.map(\.id)) == [ignored.id, skipped.id])
        #expect(viewModel.ignoredApps.map(\.bundleIdentifier) == ["ignored"])

        viewModel.include("ignored")
        #expect(viewModel.ignoredApps.isEmpty)
        #expect(viewModel.updates.map(\.id).contains(ignored.id))
    }

    @Test("Stop Ignoring keeps the user's version ceiling")
    func includeKeepsCeiling() async {
        let update = Fixtures.update("capped")
        let viewModel = makeViewModel(updates: [update])
        await viewModel.refresh()

        viewModel.setCeiling("5", for: update.app)
        viewModel.ignore(update.app)
        viewModel.include("capped")

        #expect(!viewModel.exclusions.isIgnored("capped"))
        #expect(viewModel.exclusions.ceiling(for: "capped") == "5")
    }

    @Test("a failing exclusion store keeps the previously saved rules")
    func exclusionSaveFailure() async {
        let update = Fixtures.update("app")
        let viewModel = makeViewModel(updates: [update], extras: ViewModelExtras(exclusionStore: FailingExclusions()))
        await viewModel.refresh()

        viewModel.ignore(update.app)

        #expect(!viewModel.exclusions.isIgnored("app"))
        #expect(viewModel.updates.map(\.id) == [update.id])
    }

    @Test("beta opt-in is persisted, and refused when the organization disables betas")
    func betaChannel() {
        let app = Fixtures.app("app")
        let allowed = makeViewModel(updates: [])
        let locked = makeViewModel(updates: [], extras: ViewModelExtras(managed: ManagedConfiguration(disableBetaChannels: true)))

        allowed.setBeta(true, for: app)
        locked.setBeta(true, for: app)

        #expect(allowed.isBetaOptedIn(app))
        #expect(!locked.isBetaOptedIn(app))
    }

    @Test("replaceChecker swaps the source used by the next refresh")
    func replaceChecker() async {
        let viewModel = makeViewModel(updates: [Fixtures.update("app")])
        viewModel.replaceChecker(StubChecker(updates: []))

        let found = await viewModel.refresh()

        #expect(found.isEmpty)
        #expect(viewModel.state == .loaded([]))
    }
}

@MainActor
@Suite("UpdatesViewModel install flows")
struct UpdatesViewModelInstallFlowTests {
    @Test("App Store updates open the App Store and ask the user to finish there")
    func appStoreRoute() async {
        let update = Fixtures.update("store", source: .appStore)
        let workspace = RecordingWorkspace()
        let installer = RecordingInstaller()
        let viewModel = makeViewModel(updates: [update], installer: installer, extras: ViewModelExtras(workspace: workspace))
        await viewModel.refresh()

        await viewModel.install(update)

        #expect(workspace.opened == [URL(string: "macappstore://showUpdatesPage")!])
        #expect(viewModel.installState(for: update).isManualAction)
        #expect(await installer.installed.isEmpty)
        #expect(viewModel.installableUpdates.isEmpty)
    }

    @Test("pkg without an enabled helper is downloaded and handed to Installer.app")
    func installerAppRoute() async {
        let update = Fixtures.update("pkgapp", file: "setup.pkg")
        let file = URL(fileURLWithPath: "/tmp/stub-2.0.pkg")
        let workspace = RecordingWorkspace()
        let extras = ViewModelExtras(workspace: workspace, downloader: FileDownloader(file: file))
        let viewModel = makeViewModel(updates: [update], helper: .requiresApproval, extras: extras)
        await viewModel.refresh()

        #expect(viewModel.installableUpdates.isEmpty)
        await viewModel.install(update)

        #expect(workspace.opened == [file])
        #expect(viewModel.installState(for: update).isManualAction)
        #expect(viewModel.history.isEmpty)
    }

    @Test("Installer.app fallback never opens a download that is not a .pkg; it is deleted instead")
    func installerAppRefusesNonPackage() async throws {
        let update = Fixtures.update("pkgapp", file: "setup.pkg")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AppUpdater-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("setup.terminal")
        try Data("plist".utf8).write(to: file)
        let workspace = RecordingWorkspace()
        let extras = ViewModelExtras(workspace: workspace, downloader: FileDownloader(file: file))
        let viewModel = makeViewModel(updates: [update], helper: .requiresApproval, extras: extras)
        await viewModel.refresh()

        await viewModel.install(update)

        #expect(workspace.opened == [update.downloadURL])
        #expect(workspace.opened.allSatisfy { !$0.isFileURL })
        #expect(viewModel.installState(for: update).isManualAction)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test("pkg with an enabled helper goes through the package installer, not the in-place installer")
    func helperPackageRoute() async throws {
        let update = Fixtures.update("pkgapp", file: "setup.pkg")
        let packageInstaller = RecordingInstaller()
        let installer = RecordingInstaller()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AppUpdater-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("setup.pkg")
        try Data("pkg".utf8).write(to: file)
        let extras = ViewModelExtras(downloader: FileDownloader(file: file), packageInstaller: packageInstaller)
        let viewModel = makeViewModel(updates: [update], installer: installer, helper: .enabled, extras: extras)
        await viewModel.refresh()

        #expect(viewModel.installableUpdates.map(\.id) == [update.id])
        await viewModel.install(update)

        #expect(await packageInstaller.installed == [update.id])
        #expect(await installer.installed.isEmpty)
        #expect(viewModel.installState(for: update) == .installed)
        #expect(viewModel.history.first?.outcome == .succeeded)
        #expect(!FileManager.default.fileExists(atPath: folder.path), "the AppUpdater-* download folder is cleaned up")
    }

    @Test("the helper never deletes a download outside an AppUpdater-* folder")
    func helperKeepsForeignDownloads() async throws {
        let update = Fixtures.update("pkgapp", file: "setup.pkg")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Foreign-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("setup.pkg")
        try Data("pkg".utf8).write(to: file)
        let viewModel = makeViewModel(
            updates: [update], helper: .enabled, extras: ViewModelExtras(downloader: FileDownloader(file: file))
        )
        await viewModel.refresh()

        await viewModel.install(update)

        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("a helper install failure is recorded as failed")
    func helperPackageFailure() async {
        let update = Fixtures.update("pkgapp", file: "setup.pkg")
        let extras = ViewModelExtras(packageInstaller: RecordingInstaller(failingWith: .installFailed("exit 1")))
        let viewModel = makeViewModel(updates: [update], helper: .enabled, extras: extras)
        await viewModel.refresh()

        await viewModel.install(update)

        let message = UpdaterError.installFailed("exit 1").localizedDescription
        #expect(viewModel.installState(for: update) == .failed(message))
        #expect(viewModel.history.first?.outcome == .failed(message: message))
    }

    @Test("an enabled helper without a package installer falls back to Installer.app")
    func helperWithoutPackageInstaller() async {
        let update = Fixtures.update("pkgapp", file: "setup.pkg")
        let viewModel = makeViewModel(updates: [update], helper: .enabled, extras: ViewModelExtras(packageInstaller: nil))

        #expect(await viewModel.installRoute(for: update) == .installerApp)
    }

    @Test("an unknown download format is never downloaded or opened; only the https page is opened",
          arguments: ["app.tar.gz", "Update.terminal", "download"])
    func unknownFormatOpensPageOnly(file: String) async {
        let update = Fixtures.update("app", file: file)
        let workspace = RecordingWorkspace()
        let installer = RecordingInstaller()
        let viewModel = makeViewModel(
            updates: [update], installer: installer,
            extras: ViewModelExtras(workspace: workspace, downloader: FailingDownloader(error: UpdaterError.network("must not download")))
        )
        await viewModel.refresh()

        #expect(await viewModel.installRoute(for: update) == .manualDownload)
        #expect(viewModel.installableUpdates.isEmpty)
        await viewModel.install(update)

        #expect(workspace.opened == [update.downloadURL])
        #expect(workspace.opened.allSatisfy { $0.scheme == "https" })
        #expect(await installer.installed.isEmpty)
        #expect(viewModel.installState(for: update).isManualAction)
        #expect(viewModel.history.isEmpty)
    }

    @Test("an installer unsupportedFormat error opens the page, never the downloaded file, and deletes it")
    func unsupportedFormatOpensPageNotFile() async throws {
        let update = Fixtures.update("app")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AppUpdater-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("app.dmg")
        try Data("dmg".utf8).write(to: file)
        let workspace = RecordingWorkspace()
        let viewModel = makeViewModel(
            updates: [update], installer: RecordingInstaller(failingWith: .unsupportedFormat("gz")),
            extras: ViewModelExtras(workspace: workspace, downloader: FileDownloader(file: file))
        )
        await viewModel.refresh()

        await viewModel.install(update)

        #expect(workspace.opened == [update.downloadURL])
        #expect(!workspace.opened.contains(file))
        #expect(viewModel.installState(for: update).isManualAction)
        #expect(viewModel.history.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test("a downloaded file whose real format is unknown is deleted and never staged or opened")
    func downloadedUnknownFormatIsDeleted() async throws {
        let update = Fixtures.update("app")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AppUpdater-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Update.terminal")
        try Data("plist".utf8).write(to: file)
        let workspace = RecordingWorkspace()
        let installer = RecordingInstaller()
        let viewModel = makeViewModel(
            updates: [update], installer: installer,
            extras: ViewModelExtras(workspace: workspace, downloader: FileDownloader(file: file))
        )
        await viewModel.refresh()

        await viewModel.install(update)

        #expect(await installer.installed.isEmpty)
        #expect(workspace.opened == [update.downloadURL])
        #expect(viewModel.installState(for: update).isManualAction)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test("a failed in-place install also removes its AppUpdater-* download folder")
    func failedInPlaceInstallCleansDownload() async throws {
        let update = Fixtures.update("app")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AppUpdater-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("app.dmg")
        try Data("dmg".utf8).write(to: file)
        let viewModel = makeViewModel(
            updates: [update], installer: RecordingInstaller(failingWith: .installFailed("boom")),
            extras: ViewModelExtras(downloader: FileDownloader(file: file))
        )
        await viewModel.refresh()

        await viewModel.install(update)

        #expect(viewModel.installState(for: update) == .failed(UpdaterError.installFailed("boom").localizedDescription))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test("download errors fail the install; URL cancellation resets it silently", arguments: [true, false])
    func downloadErrors(cancelled: Bool) async {
        let update = Fixtures.update("app")
        let error: any Error = cancelled ? URLError(.cancelled) : UpdaterError.network("offline")
        let viewModel = makeViewModel(updates: [update], extras: ViewModelExtras(downloader: FailingDownloader(error: error)))
        await viewModel.refresh()

        await viewModel.install(update)

        if cancelled {
            #expect(viewModel.installState(for: update) == .pending)
            #expect(viewModel.history.isEmpty)
        } else {
            #expect(viewModel.installState(for: update) == .failed("Network error: offline"))
            #expect(viewModel.history.count == 1)
        }
    }

    @Test("download progress is published while downloading and cleared afterwards; re-entrant installs are ignored")
    func progressAndReentrancy() async {
        let gate = Gate()
        let update = Fixtures.update("app")
        let installer = RecordingInstaller()
        let downloader = GatedProgressDownloader(fractions: [0.2, 0.205, 0.5], gate: gate)
        let viewModel = makeViewModel(updates: [update], installer: installer, extras: ViewModelExtras(downloader: downloader))
        await viewModel.refresh()

        let install = Task { await viewModel.install(update) }
        #expect(await eventually { viewModel.progress(for: update) == 0.5 })
        #expect(viewModel.installState(for: update) == .downloading)
        #expect(viewModel.canCancel(update))
        await viewModel.install(update)
        await gate.open()
        await install.value

        #expect(await installer.installed == [update.id])
        #expect(viewModel.progress(for: update) == nil)
        #expect(!viewModel.canCancel(update))
    }

    @Test("Update All installs only unattended, compatible, non-vendor updates")
    func installAllFilters() async {
        let dmg = Fixtures.update("dmgapp")
        let pkg = Fixtures.update("pkgapp", file: "setup.pkg")
        let store = Fixtures.update("storeapp", source: .appStore)
        let incompatible = Fixtures.update("newos", minimumSystemVersion: "99.0")
        let installer = RecordingInstaller()
        let workspace = RecordingWorkspace()
        let viewModel = makeViewModel(
            updates: [dmg, pkg, store, incompatible], installer: installer, extras: ViewModelExtras(workspace: workspace)
        )
        await viewModel.refresh()

        await viewModel.installAll()

        #expect(await installer.installed == [dmg.id])
        #expect(workspace.opened.isEmpty)
        #expect(viewModel.installState(for: pkg) == .pending)
    }

    @Test("vendor updaters with an application target are launched")
    func vendorApplicationTarget() async {
        let appURL = URL(fileURLWithPath: "/Applications/Setapp.app")
        let management = VendorManagement(vendor: .setapp, updaterName: "Setapp", openTarget: .application(appURL))
        let update = Fixtures.update("managed")
        let workspace = RecordingWorkspace()
        let viewModel = makeViewModel(
            updates: [update], extras: ViewModelExtras(vendorManaged: ["managed": management], workspace: workspace)
        )
        await viewModel.refresh()

        await viewModel.install(update)

        #expect(workspace.opened == [appURL])
        #expect(viewModel.vendorManagement(for: update.app) == management)
    }

    @Test("the download host recorded by an install raises a warning when the next update moves host")
    func downloadHostChange() async {
        let first = Fixtures.update("app")
        let viewModel = makeViewModel(updates: [first])
        await viewModel.refresh()
        #expect(viewModel.downloadHostWarning(for: first) == nil)

        await viewModel.install(first)
        let moved = AvailableUpdate(
            app: first.app, newVersion: "3.0", downloadURL: URL(string: "https://evil.example.net/app.dmg")!, source: .homebrew
        )

        let warning = viewModel.installConfirmationWarning(for: moved)
        if case .downloadHostChanged = warning?.kind {} else { Issue.record("Expected a host change, got \(String(describing: warning))") }
    }

    @Test("an incompatible macOS warning takes precedence over a host change")
    func confirmationWarningOrder() async {
        let update = Fixtures.update("newos", minimumSystemVersion: "99.0")
        let viewModel = makeViewModel(updates: [update])

        let warning = viewModel.installConfirmationWarning(for: update)

        #expect(warning?.kind == .updateRequiresNewerMacOS(required: "99.0"))
    }

    @Test("failure messages translate notarization blocks and pass other errors through")
    func failureMessages() {
        let blocked = UpdaterError.signatureInvalid(UpdaterError.notNotarizedPrefix + "rejected")

        #expect(UpdatesViewModel.failureMessage(for: blocked) == UpdatesViewModel.notarizationBlockedMessage)
        #expect(UpdatesViewModel.failureMessage(for: UpdaterError.checksumMismatch)
            == UpdaterError.checksumMismatch.localizedDescription)
    }

    @Test("security blocks map to specific guidance")
    func securityBlockMessages() {
        let unconfirmed = UpdaterError.signatureInvalid(
            UpdaterError.notNotarizedPrefix + UpdaterError.notarizationUnconfirmedPrefix + " (offline)"
        )
        #expect(UpdatesViewModel.failureMessage(for: unconfirmed) == UpdatesViewModel.notarizationUnconfirmedMessage)
        let rejected = UpdaterError.signatureInvalid(UpdaterError.gatekeeperRejectedPrefix + "revoked")
        #expect(UpdatesViewModel.failureMessage(for: rejected) == UpdatesViewModel.gatekeeperRejectedMessage)
        #expect(UpdatesViewModel.failureMessage(for: HelperClientError.untrustedBuild)
            == UpdatesViewModel.untrustedHelperBuildMessage)
        let unpinned = UpdaterError.signatureInvalid(UpdaterError.unverifiablePublisherPrefix + "Foo")
        #expect(UpdatesViewModel.failureMessage(for: unpinned, appName: "Foo")
            == UpdatesViewModel.unverifiablePublisherMessage(appName: "Foo"))
    }
}

@MainActor
@Suite("UpdatesViewModel download cleanup (formerly known bug)")
struct UpdatesViewModelKnownBugTests {
    @Test("an in-place install removes its verified AppUpdater-* download folder")
    func inPlaceInstallCleansDownload() async throws {
        let update = Fixtures.update("app")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AppUpdater-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("app.dmg")
        try Data("dmg".utf8).write(to: file)
        let viewModel = makeViewModel(updates: [update], extras: ViewModelExtras(downloader: FileDownloader(file: file)))
        await viewModel.refresh()

        await viewModel.install(update)

        #expect(viewModel.installState(for: update) == .installed)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
