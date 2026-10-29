import AppUpdaterCore
import Foundation
import Testing
@testable import AppUpdater

/// Fixed cask tokens and App Store IDs keyed by bundle ID.
private struct StubResolver: MigrationResolving {
    var tokens: [String: String] = [:]
    var storeIDs: [String: Int] = [:]

    func caskToken(for app: InstalledApp) async -> String? { tokens[app.bundleIdentifier] }
    func appStoreID(for app: InstalledApp) async -> Int? { storeIDs[app.bundleIdentifier] }
}

@MainActor
@Suite("MigrationModel")
struct MigrationModelTests {
    private static func app(_ id: String, _ name: String, appStore: Bool = false) -> InstalledApp {
        InstalledApp(
            bundleIdentifier: id, name: name, url: URL(fileURLWithPath: "/Applications/\(name).app"),
            shortVersion: "1.0", buildVersion: nil, sparkleFeedURL: nil, isFromAppStore: appStore
        )
    }

    private let apps = [
        app("com.example.browser", "Browser"),
        app("com.example.notes", "Notes", appStore: true),
        app("com.example.tool", "Tool"),
    ]
    private let resolver = StubResolver(tokens: ["com.example.browser": "browser"], storeIDs: ["com.example.notes": 7])

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
    }

    @Test func exportsBrewfileAndJSON() async throws {
        let model = MigrationModel(resolver: resolver)
        let brewfile = temporaryURL("Brewfile")
        let json = temporaryURL("AppList.json")
        defer { try? FileManager.default.removeItem(at: brewfile); try? FileManager.default.removeItem(at: json) }

        await model.export(apps, as: .brewfile, to: brewfile)
        await model.export(apps, as: .json, to: json)

        let text = try String(contentsOf: brewfile, encoding: .utf8)
        #expect(text.contains(#"cask "browser""#))
        #expect(text.contains(#"mas "Notes", id: 7"#))
        #expect(text.contains("# Tool (com.example.tool): no Homebrew cask, install manually"))
        let manifest = try MigrationFile.decode(Data(contentsOf: json))
        #expect(manifest.apps.map(\.source) == [.homebrew, .appStore, .manual])
        #expect(model.errorMessage == nil)
    }

    @Test func importListsOnlyMissingApps() async throws {
        let model = MigrationModel(resolver: resolver)
        let file = temporaryURL("Brewfile")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("cask \"browser\"\ncask \"editor\"\nmas \"Notes\", id: 7\n".utf8).write(to: file)

        await model.importList(from: file, installed: apps)

        let result = try #require(model.importResult)
        #expect(result.missing.map(\.caskToken) == ["editor"])
        #expect(result.caskInstallCommand == "brew install --cask editor")
        #expect(result.bundleCommand.hasPrefix("brew bundle --file='"))
    }

    @Test func unreadableImportSetsError() async throws {
        let model = MigrationModel(resolver: resolver)
        let file = temporaryURL("notes.txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("hello\n".utf8).write(to: file)

        await model.importList(from: file, installed: apps)

        #expect(model.importResult == nil)
        #expect(model.errorMessage != nil)
    }
}
