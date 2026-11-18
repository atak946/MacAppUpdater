import AppUpdaterCore
import Foundation
import Testing
@testable import AppUpdater

@MainActor
@Suite("Extension-less downloads")
struct DetectedDownloadFlowTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "DetectedDownloadFlowTests.\(UUID().uuidString)")!
    }

    @Test("a link the server reports as a web page is opened, never downloaded")
    func htmlHintOpensPage() async {
        let update = Fixtures.update("app", file: "download")
        let workspace = RecordingWorkspace()
        let probe = StubDownloadProbe(hints: [update.downloadURL: DownloadHint(size: 900, fileName: "download.html", mimeType: "text/html")])
        let viewModel = makeViewModel(
            updates: [update],
            extras: ViewModelExtras(
                workspace: workspace, downloader: FailingDownloader(error: UpdaterError.network("must not download")),
                sizeProbe: probe
            )
        )
        await viewModel.refresh()
        await viewModel.loadDownloadSizes(for: [update])

        #expect(await viewModel.installRoute(for: update) == .manualDownload)
        #expect(viewModel.downloadSizeText(for: update) == nil)
        await viewModel.install(update)
        #expect(workspace.opened == [update.downloadURL])
    }

    @Test("a server-announced disk image is sized and installed in place")
    func announcedDiskImageIsAutomatic() async {
        let update = Fixtures.update("app", file: "download")
        let probe = StubDownloadProbe(hints: [update.downloadURL: DownloadHint(size: 5_000_000, fileName: "App-2.0.dmg", mimeType: "application/x-apple-diskimage")])
        let viewModel = makeViewModel(updates: [update], extras: ViewModelExtras(sizeProbe: probe))
        await viewModel.refresh()
        await viewModel.loadDownloadSizes(for: [update])

        #expect(await viewModel.installRoute(for: update) == .inPlace)
        #expect(viewModel.downloadSizeText(for: update) != nil)
    }

    @Test("a format remembered for the same app and host makes the update automatic")
    func rememberedFormat() async {
        let update = Fixtures.update("app", file: "download")
        let store = UserDefaultsDetectedFormatStore(defaults: defaults())
        store.record(.zip, for: update)
        let viewModel = makeViewModel(updates: [update], extras: ViewModelExtras(detectedFormats: store))
        await viewModel.refresh()

        #expect(viewModel.resolvedInstallMethod(for: update) == .standard(.automatic))
        #expect(await viewModel.installRoute(for: update) == .inPlace)
    }

    @Test("a detected download records its format for next time")
    func detectionIsRemembered() async throws {
        let update = Fixtures.update("app", file: "download")
        let store = UserDefaultsDetectedFormatStore(defaults: defaults())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AppUpdater-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("download.zip")
        try Data("zip".utf8).write(to: file)
        let viewModel = makeViewModel(
            updates: [update],
            extras: ViewModelExtras(downloader: FileDownloader(file: file), detectedFormats: store)
        )
        await viewModel.refresh()

        await viewModel.install(update)

        #expect(store.format(for: update) == .zip)
    }
}
