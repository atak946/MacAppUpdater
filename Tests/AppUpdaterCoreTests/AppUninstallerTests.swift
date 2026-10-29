import Testing
import Foundation
@testable import AppUpdaterCore

@Suite struct AppUninstallerTests {
    private let id = "com.foo.app"

    private func uninstaller(
        _ box: UninstallSandbox,
        running: Set<String> = [],
        trasher: RecordingTrasher
    ) -> AppUninstaller {
        AppUninstaller(
            scanner: box.scanner,
            runningChecker: FakeRunningChecker(running: running),
            trasher: trasher,
            protectedBundleIdentifiers: [AppUninstaller.updaterBundleIdentifier],
            signatureVerifier: BundleTeamStubVerifier(teams: [:]),
            duplicateFinder: FixedDuplicateFinder(bundles: [])
        )
    }

    @Test func scanBuildsPlanWithDefaultSelection() async throws {
        try await UninstallSandbox.run { box in
            let app = try box.makeApp(id: id, name: "Foo")
            let cache = try box.make("Caches/\(id)")
            let possible = try box.make("Application Support/Foo")
            let sut = uninstaller(box, trasher: RecordingTrasher(trashDirectory: box.trash))

            let plan = try await sut.scan(app)

            #expect(plan.bundle.kind == .appBundle)
            #expect(plan.leftovers.count == 2)
            let selectedPaths = Set(plan.defaultSelection.map(\.path))
            #expect(selectedPaths == [app.url.path, cache.path])
            #expect(!selectedPaths.contains(possible.path))
            #expect(plan.totalSize(of: plan.defaultSelection) > 0)
        }
    }

    @Test func uninstallMovesOnlySelectedItemsToTrash() async throws {
        try await UninstallSandbox.run { box in
            let app = try box.makeApp(id: id, name: "Foo")
            let cache = try box.make("Caches/\(id)")
            let possible = try box.make("Application Support/Foo")
            let trasher = RecordingTrasher(trashDirectory: box.trash)
            let sut = uninstaller(box, trasher: trasher)

            let plan = try await sut.scan(app)
            let report = try await sut.uninstall(plan, selected: plan.defaultSelection)

            #expect(report.succeeded)
            #expect(report.removedAppBundle)
            #expect(report.trashed.count == 2)
            #expect(trasher.trashedURLs.first?.path == app.url.standardizedFileURL.path)
            #expect(!FileManager.default.fileExists(atPath: app.url.path))
            #expect(!FileManager.default.fileExists(atPath: cache.path))
            #expect(FileManager.default.fileExists(atPath: possible.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: box.trash.path).count == 2)
        }
    }

    @Test(arguments: [
        ("com.apple.Safari", "/Applications/Safari.app"),
        ("com.example.tool", "/System/Applications/Tool.app"),
        ("com.macappupdater.app", "/Applications/AppUpdater.app"),
    ])
    func refusesSystemAndSelf(bundleID: String, path: String) async throws {
        try await UninstallSandbox.run { box in
            let app = InstalledApp(
                bundleIdentifier: bundleID, name: "X", url: URL(fileURLWithPath: path), shortVersion: "1",
                buildVersion: nil, sparkleFeedURL: nil, isFromAppStore: false
            )
            let trasher = RecordingTrasher(trashDirectory: box.trash)
            let sut = uninstaller(box, trasher: trasher)
            #expect(sut.refusal(for: app) != nil)
            await #expect(throws: UninstallError.self) { try await sut.scan(app) }

            let forged = UninstallPlan(
                app: app, bundle: LeftoverItem(url: app.url, kind: .appBundle, sizeInBytes: 0, confidence: .exact),
                leftovers: []
            )
            await #expect(throws: UninstallError.self) { try await sut.uninstall(forged, selected: [app.url]) }
            #expect(trasher.trashedURLs.isEmpty)
        }
    }

    @Test func refusesWhileAppIsRunning() async throws {
        try await UninstallSandbox.run { box in
            let app = try box.makeApp(id: id, name: "Foo")
            let trasher = RecordingTrasher(trashDirectory: box.trash)
            let sut = uninstaller(box, running: [id], trasher: trasher)

            let plan = try await sut.scan(app)
            await #expect(throws: UninstallError.appIsRunning(name: "Foo")) {
                try await sut.uninstall(plan, selected: plan.defaultSelection)
            }
            #expect(trasher.trashedURLs.isEmpty)
            #expect(FileManager.default.fileExists(atPath: app.url.path))
        }
    }

    @Test func rejectsEmptySelection() async throws {
        try await UninstallSandbox.run { box in
            let app = try box.makeApp(id: id, name: "Foo")
            let sut = uninstaller(box, trasher: RecordingTrasher(trashDirectory: box.trash))
            let plan = try await sut.scan(app)
            await #expect(throws: UninstallError.nothingSelected) { try await sut.uninstall(plan, selected: []) }
        }
    }

    @Test func rejectsURLsNotInPlanAndForgedPlanItems() async throws {
        try await UninstallSandbox.run { box in
            let app = try box.makeApp(id: id, name: "Foo")
            let victim = box.outside.appendingPathComponent("precious.txt")
            try Data("keep".utf8).write(to: victim)
            let trasher = RecordingTrasher(trashDirectory: box.trash)
            let sut = uninstaller(box, trasher: trasher)

            let scanned = try await sut.scan(app)
            let forgedItem = LeftoverItem(url: victim, kind: .caches, sizeInBytes: 4, confidence: .exact)
            let forged = UninstallPlan(app: app, bundle: scanned.bundle, leftovers: [forgedItem])
            let report = try await sut.uninstall(forged, selected: [victim, box.home])

            #expect(report.trashed.isEmpty)
            #expect(report.failures.count == 2)
            #expect(trasher.trashedURLs.isEmpty)
            #expect(FileManager.default.fileExists(atPath: victim.path))
        }
    }

    @Test func rejectsItemReplacedBySymlinkAfterScan() async throws {
        try await UninstallSandbox.run { box in
            let app = try box.makeApp(id: id, name: "Foo")
            let cache = try box.make("Caches/\(id)")
            let target = box.outside.appendingPathComponent("precious")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let trasher = RecordingTrasher(trashDirectory: box.trash)
            let sut = uninstaller(box, trasher: trasher)

            let plan = try await sut.scan(app)
            try FileManager.default.removeItem(at: cache)
            try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: target)
            let report = try await sut.uninstall(plan, selected: [cache.standardizedFileURL])

            #expect(report.trashed.isEmpty)
            #expect(report.failures.count == 1)
            #expect(report.failures.first.map { if case .symlinkEscape = $0.error { true } else { false } } == true)
            #expect(FileManager.default.fileExists(atPath: target.path))
        }
    }

    @Test func keepsLeftoversWhenBundleCannotBeTrashed() async throws {
        try await UninstallSandbox.run { box in
            let app = try box.makeApp(id: id, name: "Foo")
            let cache = try box.make("Caches/\(id)")
            let trasher = RecordingTrasher(
                trashDirectory: box.trash, failingPaths: [app.url.standardizedFileURL.path]
            )
            let sut = uninstaller(box, trasher: trasher)

            let plan = try await sut.scan(app)
            let report = try await sut.uninstall(plan, selected: plan.defaultSelection)

            #expect(report.trashed.isEmpty)
            #expect(report.failures.count == 2)
            #expect(report.failures.contains { $0.error == .skippedBecauseBundleFailed($0.url) && $0.url.path == cache.path })
            #expect(FileManager.default.fileExists(atPath: cache.path))
        }
    }

    @Test func rejectsBundleThatChangedIdentity() async throws {
        try await UninstallSandbox.run { box in
            let app = try box.makeApp(id: id, name: "Foo")
            let sut = uninstaller(box, trasher: RecordingTrasher(trashDirectory: box.trash))
            let plan = try await sut.scan(app)
            _ = try box.makeApp(id: "com.other.app", name: "Foo")

            let report = try await sut.uninstall(plan, selected: [plan.bundle.url])

            #expect(report.failures.map(\.error) == [.bundleMismatch(plan.bundle.url)])
            #expect(FileManager.default.fileExists(atPath: app.url.path))
        }
    }
}
