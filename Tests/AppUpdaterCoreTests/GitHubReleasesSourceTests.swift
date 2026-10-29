import Foundation
import Testing
@testable import AppUpdaterCore

struct GitHubReleasesSourceTests {
    private let bundleID = "com.example.tool"
    private let apiURL = URL(string: "https://api.github.com/repos/example/tool/releases/latest")!

    private static let release = """
    {
      "tag_name": "v2.1.0",
      "html_url": "https://github.com/example/tool/releases/tag/v2.1.0",
      "draft": false,
      "prerelease": false,
      "assets": [
        {"name": "checksums.txt", "browser_download_url": "https://github.com/example/tool/releases/download/v2.1.0/checksums.txt"},
        {"name": "Tool-2.1.0-x86_64.dmg", "browser_download_url": "https://github.com/example/tool/releases/download/v2.1.0/Tool-2.1.0-x86_64.dmg"},
        {"name": "Tool-2.1.0-arm64.dmg", "browser_download_url": "https://github.com/example/tool/releases/download/v2.1.0/Tool-2.1.0-arm64.dmg"},
        {"name": "Tool-2.1.0.zip", "browser_download_url": "https://github.com/example/tool/releases/download/v2.1.0/Tool-2.1.0.zip"}
      ]
    }
    """

    private func makeSource(
        architecture: GitHubReleasesSource.Architecture = .appleSilicon,
        repositories: [String: String]? = nil,
        json: String = release
    ) -> GitHubReleasesSource {
        GitHubReleasesSource(
            repositories: repositories ?? [bundleID: "example/tool"],
            http: MockHTTPClient(strings: [apiURL.absoluteString: json]),
            comparator: NumericStubComparator(),
            architecture: architecture
        )
    }

    @Test func prefersArmAssetOnAppleSilicon() async throws {
        let app = TestApps.make(bundleIdentifier: bundleID, shortVersion: "2.0.0")
        let update = try #require(try await makeSource().checkForUpdate(app))
        #expect(update.newVersion == "2.1.0")
        #expect(update.downloadURL.lastPathComponent == "Tool-2.1.0-arm64.dmg")
        #expect(update.releaseNotesURL == URL(string: "https://github.com/example/tool/releases/tag/v2.1.0"))
        #expect(update.source == .github)
    }

    @Test func prefersIntelAssetOnIntel() async throws {
        let app = TestApps.make(bundleIdentifier: bundleID, shortVersion: "2.0.0")
        let update = try #require(try await makeSource(architecture: .intel).checkForUpdate(app))
        #expect(update.downloadURL.lastPathComponent == "Tool-2.1.0-x86_64.dmg")
    }

    @Test func returnsNilWhenUpToDate() async throws {
        let app = TestApps.make(bundleIdentifier: bundleID, shortVersion: "2.1.0")
        #expect(try await makeSource().checkForUpdate(app) == nil)
    }

    @Test func returnsNilWithoutInstallableAsset() async throws {
        let json = #"{"tag_name": "3.0", "assets": [{"name": "src.tar.gz", "browser_download_url": "https://x.com/src.tar.gz"}]}"#
        let app = TestApps.make(bundleIdentifier: bundleID, shortVersion: "1.0")
        #expect(try await makeSource(json: json).checkForUpdate(app) == nil)
    }

    @Test func canHandleOnlyMappedNonAppStoreApps() {
        let source = makeSource()
        #expect(source.canHandle(TestApps.make(bundleIdentifier: bundleID)))
        #expect(!source.canHandle(TestApps.make(bundleIdentifier: "com.other")))
        #expect(!source.canHandle(TestApps.make(bundleIdentifier: bundleID, isFromAppStore: true)))
    }

    @Test func rejectsMalformedRepositories() {
        let source = makeSource(repositories: [bundleID: "../evil?x=1"])
        #expect(!source.canHandle(TestApps.make(bundleIdentifier: bundleID)))
        #expect(GitHubReleasesSource.isValidRepository("owner/repo.name"))
        #expect(!GitHubReleasesSource.isValidRepository("owner/repo/extra"))
        #expect(!GitHubReleasesSource.isValidRepository("owner/.."))
    }

    @Test func stripsLeadingV() {
        #expect(GitHubReleasesSource.normalizedVersion("v1.2.3") == "1.2.3")
        #expect(GitHubReleasesSource.normalizedVersion("1.2.3") == "1.2.3")
    }

    @Test func populatesMarkdownNotesAndReportsUpToDate() async throws {
        let json = #"{"tag_name": "v2.1.0", "html_url": "https://github.com/example/tool/releases/tag/v2.1.0", "body": "Fixes\n- crash", "assets": [{"name": "Tool.dmg", "browser_download_url": "https://github.com/example/tool/releases/download/v2.1.0/Tool.dmg"}]}"#
        let source = makeSource(json: json)
        let update = try #require(try await source.lookup(TestApps.make(bundleIdentifier: bundleID, shortVersion: "2.0")).update)
        #expect(update.releaseNotes == .markdown("Fixes\n- crash"))
        #expect(update.releaseNotesURL == URL(string: "https://github.com/example/tool/releases/tag/v2.1.0"))
        let current = TestApps.make(bundleIdentifier: bundleID, shortVersion: "2.1.0")
        #expect(try await source.lookup(current) == .upToDate(latestVersion: "2.1.0"))
    }

    @Test func blankBodyYieldsNoNotes() async throws {
        let json = #"{"tag_name": "3.0", "body": "  ", "assets": [{"name": "T.zip", "browser_download_url": "https://x.com/T.zip"}]}"#
        let update = try await makeSource(json: json).checkForUpdate(TestApps.make(bundleIdentifier: bundleID))
        #expect(update?.releaseNotes == nil)
    }

    @Test func sendsBearerTokenOnlyWhenPresent() async throws {
        let http = MockHTTPClient(strings: [apiURL.absoluteString: Self.release])
        let app = TestApps.make(bundleIdentifier: bundleID, shortVersion: "2.0.0")
        let anonymous = GitHubReleasesSource(repositories: [bundleID: "example/tool"], http: http, comparator: NumericStubComparator())
        _ = try await anonymous.checkForUpdate(app)
        #expect(http.headers(for: apiURL)?["Authorization"] == nil)
        #expect(http.headers(for: apiURL)?["Accept"] == "application/vnd.github+json")

        let tokens = InMemoryTokenStore(token: "ghp_secret")
        let authed = GitHubReleasesSource(
            repositories: [bundleID: "example/tool"], http: http, comparator: NumericStubComparator(),
            token: tokens.tokenProvider
        )
        _ = try await authed.checkForUpdate(app)
        #expect(http.headers(for: apiURL)?["Authorization"] == "Bearer ghp_secret")
    }

    @Test func dropsUnsafeTokenHeader() {
        #expect(GitHubReleasesSource.headers(token: "bad\r\ntoken")["Authorization"] == nil)
        #expect(GitHubReleasesSource.headers(token: "  ").keys.contains("Authorization") == false)
    }
}
