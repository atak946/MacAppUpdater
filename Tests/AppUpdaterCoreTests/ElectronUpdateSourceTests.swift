import Foundation
import Testing
@testable import AppUpdaterCore

@Suite("ElectronUpdateSource")
struct ElectronUpdateSourceTests {
    private static let feedURL = URL(string: "https://github.com/acme/tool/releases/latest/download/latest-mac.yml")!
    private static let githubConfig = "provider: github\nowner: acme\nrepo: tool\nupdaterCacheDirName: tool-updater\n"

    /// Creates `<tmp>/Tool.app/Contents/Resources/app-update.yml` (when `config` is non-nil).
    private static func makeApp(config: String?, version: String = "2.0.0", isFromAppStore: Bool = false) throws -> InstalledApp {
        let appURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ElectronTests-\(UUID().uuidString)/Tool.app", isDirectory: true)
        let resources = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        if let config {
            try Data(config.utf8).write(to: resources.appendingPathComponent("app-update.yml"))
        }
        return InstalledApp(
            bundleIdentifier: "com.acme.tool", name: "Tool", url: appURL, shortVersion: version,
            buildVersion: nil, sparkleFeedURL: nil, isFromAppStore: isFromAppStore
        )
    }

    private static func cleanUp(_ app: InstalledApp) {
        try? FileManager.default.removeItem(at: app.url.deletingLastPathComponent())
    }

    private static func source(
        feed: String = ElectronFeedParserTests.latestMac,
        store: ChecksumStore? = nil,
        architecture: ElectronUpdateSource.Architecture = .appleSilicon
    ) -> ElectronUpdateSource {
        ElectronUpdateSource(
            http: MockHTTPClient(strings: [feedURL.absoluteString: feed]),
            comparator: NumericStubComparator(),
            checksumStore: store,
            architecture: architecture
        )
    }

    @Test("handles only non-App Store apps with app-update.yml")
    func canHandle() throws {
        let electron = try Self.makeApp(config: Self.githubConfig)
        let plain = try Self.makeApp(config: nil)
        let store = try Self.makeApp(config: Self.githubConfig, isFromAppStore: true)
        defer { [electron, plain, store].forEach(Self.cleanUp) }

        #expect(Self.source().canHandle(electron))
        #expect(!Self.source().canHandle(plain))
        #expect(!Self.source().canHandle(store))
    }

    @Test("offers the arm64 zip on Apple Silicon and registers its SHA-512")
    func updateOnAppleSilicon() async throws {
        let app = try Self.makeApp(config: Self.githubConfig)
        defer { Self.cleanUp(app) }
        let store = ChecksumStore()

        let update = try #require(try await Self.source(store: store).lookup(app).update)

        #expect(update.source == .electron)
        #expect(update.newVersion == "2.3.0")
        #expect(update.downloadURL.absoluteString
            == "https://github.com/acme/tool/releases/latest/download/Example-2.3.0-arm64-mac.zip")
        #expect(update.releaseNotes == .markdown("## Changes\n- Fixed things"))
        #expect(update.publishedAt != nil)
        #expect(update.sha256 == nil)
        #expect(await store.checksum(forUpdateID: update.id) == ExpectedChecksum(algorithm: .sha512, value: "YXJt"))
    }

    @Test("offers the unmarked zip on Intel")
    func updateOnIntel() async throws {
        let app = try Self.makeApp(config: Self.githubConfig)
        defer { Self.cleanUp(app) }
        let update = try #require(try await Self.source(architecture: .intel).lookup(app).update)
        #expect(update.downloadURL.lastPathComponent == "Example-2.3.0-mac.zip")
    }

    @Test("falls back to dmg, keeps absolute HTTPS URLs and drops insecure ones")
    func dmgAndAbsoluteURLs() async throws {
        let feed = """
        version: 3.0.0
        files:
          - url: http://insecure.example.com/Tool-3.0.0.zip
            sha512: aaa
          - url: https://cdn.example.com/Tool-3.0.0.dmg
            sha512: bbb
        releaseNotes: <p>HTML notes</p>
        """
        let app = try Self.makeApp(config: Self.githubConfig)
        defer { Self.cleanUp(app) }

        let update = try #require(try await Self.source(feed: feed).lookup(app).update)
        #expect(update.downloadURL.absoluteString == "https://cdn.example.com/Tool-3.0.0.dmg")
        #expect(update.releaseNotes == .html("<p>HTML notes</p>"))
    }

    @Test("up to date when the feed version is not newer")
    func upToDate() async throws {
        let app = try Self.makeApp(config: Self.githubConfig, version: "2.3.0")
        defer { Self.cleanUp(app) }
        #expect(try await Self.source().lookup(app) == .upToDate(latestVersion: "2.3.0"))
    }

    @Test("up to date when no installable file is listed")
    func noInstallableFile() async throws {
        let app = try Self.makeApp(config: Self.githubConfig)
        defer { Self.cleanUp(app) }
        let feed = "version: 9.0.0\nfiles:\n  - url: Tool.AppImage\n"
        #expect(try await Self.source(feed: feed).lookup(app) == .upToDate(latestVersion: "9.0.0"))
    }

    @Test("unsupported providers are not found and never hit the network")
    func unsupportedProvider() async throws {
        let app = try Self.makeApp(config: "provider: custom\nupdateProvider: x\n")
        defer { Self.cleanUp(app) }
        let http = MockHTTPClient()
        let source = ElectronUpdateSource(http: http, comparator: NumericStubComparator())
        #expect(try await source.lookup(app) == .notFound)
        #expect(http.requestedURLs.isEmpty)
    }

    @Test("feeds left pointing at a starter template are ignored without a network call")
    func boilerplateFeed() async throws {
        let app = try Self.makeApp(config: """
        provider: generic
        url: https://github.com/electron-vite/electron-vite-react/releases/download/v0.9.9/
        """)
        defer { Self.cleanUp(app) }
        let http = MockHTTPClient()
        let source = ElectronUpdateSource(http: http, comparator: NumericStubComparator())
        #expect(try await source.lookup(app) == .notFound)
        #expect(http.requestedURLs.isEmpty)
        #expect(!ElectronUpdateSource.isBoilerplateFeed(URL(string: "https://github.com/acme/tool/releases/download/v1/")!))
    }

    @Test("generic provider resolves relative file URLs against the feed")
    func genericProvider() async throws {
        let app = try Self.makeApp(config: "provider: generic\nurl: https://dl.example.com/tool\n")
        defer { Self.cleanUp(app) }
        let feedURL = "https://dl.example.com/tool/latest-mac.yml"
        let source = ElectronUpdateSource(
            http: MockHTTPClient(strings: [feedURL: "version: 2.1.0\npath: mac/Tool-2.1.0-mac.zip\nsha512: eHl6\n"]),
            comparator: NumericStubComparator()
        )
        let update = try #require(try await source.lookup(app).update)
        #expect(update.downloadURL.absoluteString == "https://dl.example.com/tool/mac/Tool-2.1.0-mac.zip")
    }
}
