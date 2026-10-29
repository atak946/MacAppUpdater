import Foundation
import Testing
@testable import MaintenanceCore

/// Fixed app list; `knownToLaunchServices` simulates the second check.
private struct FakeCatalog: InstalledAppCataloging {
    var installed: Set<String> = ["com.example.Installed"]
    var running: Set<String> = []
    var teams: Set<String> = []
    var knownToLaunchServices: Set<String> = []
    var fails = false

    struct Failure: Error {}

    func snapshot() async throws -> InstalledAppSnapshot {
        if fails { throw Failure() }
        return InstalledAppSnapshot(installedBundleIdentifiers: installed, runningBundleIdentifiers: running, teamIdentifiers: teams)
    }

    func isKnownToLaunchServices(_ bundleIdentifier: String) -> Bool {
        knownToLaunchServices.contains(bundleIdentifier)
    }
}

@Suite("Removed-app leftovers")
struct RemovedAppLeftoverTests {
    private func scan(_ home: FakeHome, catalog: FakeCatalog = FakeCatalog()) async throws -> CleanupScanReport {
        try await FileSystemCleanupScanner(homeDirectory: home.url, now: { FakeHome.now }, installedApps: catalog)
            .scan(categories: [.removedAppLeftovers]) { _ in }
    }

    @Test("data named after a removed app is found in every allowlisted folder, with evidence")
    func matchedOrphan() async throws {
        let home = try FakeHome()
        try home.file("Library/Application Support/org.gone.Editor/db.sqlite", bytes: 8_192, ageInDays: 40)
        try home.file("Library/Preferences/org.gone.Editor.plist")
        try home.file("Library/Caches/org.gone.Editor/blob")
        try home.file("Library/Saved Application State/org.gone.Editor.savedState/window.data")
        try home.file("Library/Containers/org.gone.Editor/Data/file")
        try home.file("Library/Group Containers/ABCDE12345.org.gone.Editor/shared")

        let items = try await scan(home).items(.removedAppLeftovers)

        #expect(Set(items.map(\.url.lastPathComponent)) == [
            "org.gone.Editor", "org.gone.Editor.plist", "org.gone.Editor.savedState", "ABCDE12345.org.gone.Editor",
        ])
        #expect(items.count == 6)
        #expect(items.allSatisfy { $0.ownerBundleIdentifier == "org.gone.Editor" && $0.sizeInBytes > 0 })
        let support = try #require(items.first { $0.url.path.contains("Application Support") })
        #expect(support.lastModified != nil)
        #expect(support.displayName.hasSuffix("org.gone.Editor"))
        #expect(!CleanupCategory.removedAppLeftovers.isSelectedByDefault)
    }

    @Test("installed, running, same-vendor, same-team and LaunchServices-known apps are not flagged")
    func installedAppNotFlagged() async throws {
        let home = try FakeHome()
        try home.file("Library/Preferences/com.example.Installed.plist")
        try home.file("Library/Caches/COM.EXAMPLE.INSTALLED/x")
        try home.file("Library/Application Support/com.example.Installed.Helper/x")
        try home.file("Library/Application Support/com.example.OtherTool/x")
        try home.file("Library/Caches/net.agent.Daemon/x")
        try home.file("Library/Group Containers/TEAM123456.io.shared.Group/x")
        try home.file("Library/Containers/io.known.App/x")
        try home.file("Library/Logs/org.gone.Editor/x")
        let catalog = FakeCatalog(
            running: ["net.agent.Daemon"], teams: ["TEAM123456"], knownToLaunchServices: ["io.known.App"]
        )

        let items = try await scan(home, catalog: catalog).items(.removedAppLeftovers)

        #expect(items.map(\.ownerBundleIdentifier) == ["org.gone.Editor"])
    }

    @Test("com.apple and this app's own data are skipped")
    func appleSkipped() async throws {
        let home = try FakeHome()
        try home.file("Library/Preferences/com.apple.Safari.plist")
        try home.file("Library/Caches/com.apple.gone.Thing/x")
        try home.file("Library/Application Support/com.macappupdater.AppUpdater/x")

        #expect(try await scan(home).items(.removedAppLeftovers).isEmpty)
    }

    @Test("an item reached through a symlinked folder outside home is refused")
    func protectedPathSkipped() async throws {
        let home = try FakeHome()
        let outside = try FakeHome()
        try outside.file("Preferences/org.gone.Editor.plist")
        try home.folder("Library")
        try FileManager.default.createSymbolicLink(
            at: home.url.appendingPathComponent("Library/Preferences"),
            withDestinationURL: outside.url.appendingPathComponent("Preferences")
        )
        let entry = home.url.appendingPathComponent("Library/Preferences/org.gone.Editor.plist")

        #expect(throws: CleanupPathError.outsideHome) { try CleanupPathGuard(home: home.url).validate(entry) }
        #expect(try await scan(home).items(.removedAppLeftovers).isEmpty)
    }

    @Test("names with fewer than three components or not reverse-DNS are skipped")
    func shortNamesSkipped() async throws {
        let home = try FakeHome()
        try home.file("Library/Application Support/com.gone/x")
        try home.file("Library/Application Support/Gone Editor/x")
        try home.file("Library/Preferences/gone.plist")
        try home.file("Library/Caches/org..Editor/x")
        try home.file("Library/Group Containers/group.org.gone.Editor/x")

        #expect(try await scan(home).items(.removedAppLeftovers).isEmpty)
    }

    @Test("launch agents need a matching Label")
    func launchAgentLabel() async throws {
        let home = try FakeHome()
        let matching = try PropertyListSerialization.data(fromPropertyList: ["Label": "org.gone.Agent"], format: .xml, options: 0)
        let other = try PropertyListSerialization.data(fromPropertyList: ["Label": "org.else.Agent"], format: .xml, options: 0)
        try home.folder("Library/LaunchAgents")
        try matching.write(to: home.url.appendingPathComponent("Library/LaunchAgents/org.gone.Agent.plist"))
        try other.write(to: home.url.appendingPathComponent("Library/LaunchAgents/org.fake.Agent.plist"))

        #expect(try await scan(home).names(.removedAppLeftovers) == ["org.gone.Agent.plist"])
    }

    @Test("no catalog, a failing catalog or an empty app list finds nothing")
    func unknownAppListFindsNothing() async throws {
        let home = try FakeHome()
        try home.file("Library/Preferences/org.gone.Editor.plist")

        #expect(try await home.scan([.removedAppLeftovers]).groups.isEmpty)
        #expect(try await scan(home, catalog: FakeCatalog(fails: true)).groups.isEmpty)
        #expect(try await scan(home, catalog: FakeCatalog(installed: [])).groups.isEmpty)
    }

    @Test("found leftovers go to the Trash, never a permanent delete")
    func removalUsesTrash() async throws {
        let home = try FakeHome()
        try home.file("Library/Preferences/org.gone.Editor.plist")
        let items = try await scan(home).items(.removedAppLeftovers)
        let remover = RecordingRemover()

        let result = await TrashCleaner(homeDirectory: home.url, remover: remover).clean(items)

        #expect(result.removed.count == 1)
        #expect(remover.trashed.map(\.lastPathComponent) == ["org.gone.Editor.plist"])
        #expect(remover.deleted.isEmpty)
    }
}
