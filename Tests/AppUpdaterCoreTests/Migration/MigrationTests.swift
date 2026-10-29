import Foundation
import Testing
@testable import AppUpdaterCore

@Suite("Migration")
struct MigrationTests {
    // MARK: Validation

    @Test(arguments: [
        "firefox", "google-chrome", "visual-studio-code@insiders", "1password", "font-fira-code",
        "temurin@21", "homebrew/cask-versions/firefox-developer-edition", "c++-tool", "app.name",
    ])
    func acceptsCaskTokens(_ token: String) {
        #expect(MigrationValidation.isValidCaskToken(token))
    }

    @Test(arguments: [
        "", "-x", "--force", "Firefox", "fire fox", "a;b", "a$(id)", "a`id`", "a'b", "a\"b",
        "a/b", "../etc", "a..b", "user/tap/", "/abs", "a\nb", String(repeating: "a", count: 129),
    ])
    func rejectsCaskTokens(_ token: String) {
        #expect(!MigrationValidation.isValidCaskToken(token))
    }

    @Test func sanitizesControlCharacters() {
        #expect(MigrationValidation.sanitizedText(" A\nB\tC\u{0}D ") == "A B C D")
        #expect(MigrationValidation.sanitizedText(String(repeating: "x", count: 400)).count == 256)
    }

    // MARK: Entries

    @Test func entryFromInstalledApp() {
        let caskApp = TestApps.make(bundleIdentifier: "org.mozilla.firefox", name: "Firefox", shortVersion: "131.0")
        let entry = MigrationEntry(app: caskApp, caskToken: "firefox", appStoreID: nil)
        #expect(entry.source == .homebrew)
        #expect(entry.caskToken == "firefox")
        #expect(entry.version == "131.0")

        let manual = MigrationEntry(app: caskApp, caskToken: "bad token", appStoreID: nil)
        #expect(manual.source == .manual)
        #expect(manual.caskToken == nil)

        let storeApp = TestApps.make(bundleIdentifier: "com.example.store", isFromAppStore: true)
        let store = MigrationEntry(app: storeApp, caskToken: "ignored", appStoreID: 77)
        #expect(store.source == .appStore)
        #expect(store.caskToken == nil)
        #expect(store.appStoreID == 77)
    }

    // MARK: JSON

    @Test func jsonRoundTrip() throws {
        let manifest = MigrationManifest(
            apps: BrewfileTests.manifest.apps, formulae: ["wget"],
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try MigrationFile.encodeJSON(manifest)
        let decoded = try MigrationFile.decode(data)
        #expect(decoded == manifest)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains(#""caskToken" : "firefox""#))
        #expect(text.contains(#""appStoreID" : 123456789"#))
    }

    @Test func jsonDropsUnsafeValues() throws {
        let json = """
        {
          "formatVersion": 1,
          "apps": [
            {"bundleIdentifier": "com.example.a", "name": "A", "caskToken": "a; rm -rf ~", "source": "homebrew"},
            {"bundleIdentifier": "com.example.b", "name": "B", "appStoreID": -5},
            {"name": "C", "caskToken": "c-app"}
          ],
          "formulae": ["git", "--evil"]
        }
        """
        let manifest = try MigrationFile.decode(Data(json.utf8))
        #expect(manifest.apps.map(\.caskToken) == [nil, nil, "c-app"])
        #expect(manifest.apps[1].appStoreID == nil)
        #expect(manifest.apps[1].source == .manual)
        #expect(manifest.apps[2].source == .homebrew)
        #expect(manifest.formulae == ["git"])
    }

    @Test func rejectsNewerFormatAndGarbage() {
        #expect(throws: MigrationFileError.unsupportedVersion(99)) {
            try MigrationFile.decode(Data(#"{"formatVersion": 99, "apps": []}"#.utf8))
        }
        #expect(throws: MigrationFileError.unreadable) {
            try MigrationFile.decode(Data(#"{"apps": 5}"#.utf8))
        }
        #expect(throws: MigrationFileError.unreadable) {
            try MigrationFile.decode(Data("just some text\n".utf8))
        }
        #expect(throws: MigrationFileError.tooLarge) {
            try MigrationFile.decode(Data(count: MigrationFile.maxBytes + 1))
        }
    }

    @Test func decodeDetectsBrewfile() throws {
        let manifest = try MigrationFile.decode(Data("cask \"firefox\"\n".utf8))
        #expect(manifest.apps.compactMap(\.caskToken) == ["firefox"])
    }

    // MARK: Diff

    @Test func missingMatchesByBundleIDTokenAndName() {
        let installed = [
            TestApps.make(bundleIdentifier: "org.mozilla.firefox", name: "Firefox"),
            TestApps.make(bundleIdentifier: "com.example.chrome", name: "Chrome Browser"),
            TestApps.make(bundleIdentifier: "com.example.notes", name: "Some Notes"),
        ]
        let entries = [
            MigrationEntry(bundleIdentifier: "ORG.MOZILLA.FIREFOX", name: "Firefox", version: nil, source: .homebrew),
            MigrationEntry(bundleIdentifier: nil, name: "google-chrome", version: nil, source: .homebrew,
                           caskToken: "google-chrome"),
            MigrationEntry(bundleIdentifier: nil, name: "some notes", version: nil, source: .appStore, appStoreID: 1),
            MigrationEntry(bundleIdentifier: nil, name: "iterm2", version: nil, source: .homebrew, caskToken: "iterm2"),
            MigrationEntry(bundleIdentifier: nil, name: "iterm2", version: nil, source: .homebrew, caskToken: "iterm2"),
            MigrationEntry(bundleIdentifier: "com.example.tool", name: "Tool", version: nil, source: .manual),
        ]
        let missing = MigrationDiff.missing(
            entries, installed: installed, installedCaskTokens: ["homebrew/cask/google-chrome", "firefox"]
        )
        #expect(missing.map(\.id) == ["cask:iterm2", "com.example.tool"])
    }

    // MARK: Commands

    @Test func caskInstallCommandUsesOnlyValidTokens() {
        let entries = [
            MigrationEntry(bundleIdentifier: nil, name: "a", version: nil, source: .homebrew, caskToken: "iterm2"),
            MigrationEntry(bundleIdentifier: nil, name: "b", version: nil, source: .homebrew, caskToken: "iterm2"),
            MigrationEntry(bundleIdentifier: nil, name: "c", version: nil, source: .homebrew, caskToken: "rectangle"),
            MigrationEntry(bundleIdentifier: "x", name: "d", version: nil, source: .manual),
        ]
        #expect(MigrationCommands.caskInstallCommand(for: entries) == "brew install --cask iterm2 rectangle")
        #expect(MigrationCommands.caskInstallCommand(for: [entries[3]]) == nil)
    }

    @Test func bundleCommandQuotesThePath() {
        let url = URL(fileURLWithPath: "/tmp/it's $HOME/Brewfile")
        #expect(MigrationCommands.bundleCommand(fileURL: url) == #"brew bundle --file='/tmp/it'\''s $HOME/Brewfile'"#)
    }

    @Test func appStoreURLOnlyForValidIDs() {
        let entry = MigrationEntry(bundleIdentifier: nil, name: "A", version: nil, source: .appStore, appStoreID: 42)
        #expect(MigrationCommands.appStoreURL(for: entry)?.absoluteString == "macappstore://apps.apple.com/app/id42")
        let none = MigrationEntry(bundleIdentifier: nil, name: "A", version: nil, source: .appStore)
        #expect(MigrationCommands.appStoreURL(for: none) == nil)
    }

    // MARK: Resolver

    @Test func resolverBuildsEntriesInOrder() async {
        let apps = [
            TestApps.make(bundleIdentifier: "com.example.one", name: "One"),
            TestApps.make(bundleIdentifier: "com.example.two", name: "Two", isFromAppStore: true),
            TestApps.make(bundleIdentifier: "com.example.three", name: "Three"),
        ]
        let resolver = StubMigrationResolver(tokens: ["com.example.one": "one-app"], storeIDs: ["com.example.two": 9])
        let entries = await resolver.entries(for: apps)
        #expect(entries.map(\.bundleIdentifier) == ["com.example.one", "com.example.two", "com.example.three"])
        #expect(entries.map(\.source) == [.homebrew, .appStore, .manual])
        #expect(entries[1].appStoreID == 9)
        #expect(await resolver.installedCaskTokens(for: apps) == ["one-app"])
    }

    @Test func liveResolverReadsCaskIndexAndStoreLookup() async throws {
        let caskURL = HomebrewCaskSource.defaultAPIURL
        let lookupBase = try #require(URL(string: "https://store.example.test/lookup"))
        let storeApp = TestApps.make(bundleIdentifier: "com.example.store", isFromAppStore: true)
        let source = AppStoreSource(http: MockHTTPClient(), comparator: NumericStubComparator(), lookupBaseURL: lookupBase)
        let lookupURL = try #require(source.lookupURL(for: storeApp.bundleIdentifier))
        let http = MockHTTPClient(strings: [
            caskURL.absoluteString: #"[{"token": "firefox", "artifacts": [{"app": ["Firefox.app"]}]}]"#,
            lookupURL.absoluteString: """
            {"results": [{"version": "1", "trackViewUrl": "https://apps.apple.com/app/id55",
                          "trackId": 55, "bundleId": "com.example.store"}]}
            """,
        ])
        let resolver = LiveMigrationResolver(
            caskSource: HomebrewCaskSource(http: http, comparator: NumericStubComparator()),
            appStoreSource: AppStoreSource(http: http, comparator: NumericStubComparator(), lookupBaseURL: lookupBase)
        )
        #expect(await resolver.caskToken(for: TestApps.make(fileName: "Firefox.app")) == "firefox")
        #expect(await resolver.caskToken(for: TestApps.make(fileName: "Other.app")) == nil)
        #expect(await resolver.appStoreID(for: storeApp) == 55)
    }
}

private struct StubMigrationResolver: MigrationResolving {
    let tokens: [String: String]
    let storeIDs: [String: Int]

    func caskToken(for app: InstalledApp) async -> String? { tokens[app.bundleIdentifier] }
    func appStoreID(for app: InstalledApp) async -> Int? { storeIDs[app.bundleIdentifier] }
}
