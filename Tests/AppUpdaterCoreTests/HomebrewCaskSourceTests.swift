import Foundation
import Testing
@testable import AppUpdaterCore

struct HomebrewCaskSourceTests {
    private let apiURL = HomebrewCaskSource.defaultAPIURL

    private static let casks = """
    [
      {
        "token": "firefox",
        "version": "131.0.3",
        "url": "https://download.mozilla.org/firefox-131.0.3.dmg",
        "sha256": "abc123",
        "artifacts": [
          {"uninstall": [{"quit": "org.mozilla.firefox"}]},
          {"app": ["Firefox.app"]},
          {"zap": [{"trash": ["~/Library/Caches/Firefox"]}]},
          "unexpected-string-artifact"
        ]
      },
      {
        "token": "iterm2",
        "version": "3.5.4,20240715",
        "url": "https://iterm2.com/downloads/iTerm2-3_5_4.zip",
        "sha256": "no_check",
        "artifacts": [{"app": ["iTerm.app", {"target": "iTerm2.app"}]}]
      },
      {
        "token": "insecure",
        "version": "9.0",
        "url": "http://example.com/Insecure.dmg",
        "sha256": "def",
        "artifacts": [{"app": ["Insecure.app"]}]
      },
      {"token": "broken", "version": 42, "artifacts": {"weird": true}},
      {"not_a_cask": true}
    ]
    """

    private func makeSource(http: MockHTTPClient) -> HomebrewCaskSource {
        HomebrewCaskSource(http: http, comparator: NumericStubComparator(), apiURL: apiURL)
    }

    private func makeHTTP() -> MockHTTPClient {
        MockHTTPClient(strings: [apiURL.absoluteString: Self.casks])
    }

    @Test func matchesCaskByAppFileName() async throws {
        let source = makeSource(http: makeHTTP())
        let app = TestApps.make(fileName: "Firefox.app", shortVersion: "130.0")
        let update = try #require(try await source.checkForUpdate(app))
        #expect(update.newVersion == "131.0.3")
        #expect(update.sha256 == "abc123")
        #expect(update.source == .homebrew)
        #expect(update.downloadURL == URL(string: "https://download.mozilla.org/firefox-131.0.3.dmg"))
    }

    @Test func stripsBuildSuffixAndNoCheck() async throws {
        let source = makeSource(http: makeHTTP())
        let app = TestApps.make(fileName: "iTerm.app", shortVersion: "3.5.0")
        let update = try #require(try await source.checkForUpdate(app))
        #expect(update.newVersion == "3.5.4")
        #expect(update.sha256 == nil)
    }

    @Test func returnsNilWhenUpToDateOrUnknownOrInsecure() async throws {
        let source = makeSource(http: makeHTTP())
        #expect(try await source.checkForUpdate(TestApps.make(fileName: "Firefox.app", shortVersion: "131.0.3")) == nil)
        #expect(try await source.checkForUpdate(TestApps.make(fileName: "Unknown.app")) == nil)
        #expect(try await source.checkForUpdate(TestApps.make(fileName: "Insecure.app", shortVersion: "1.0")) == nil)
    }

    @Test func fetchesIndexOncePerSession() async throws {
        let http = makeHTTP()
        let source = makeSource(http: http)
        async let first = source.checkForUpdate(TestApps.make(fileName: "Firefox.app", shortVersion: "1.0"))
        async let second = source.checkForUpdate(TestApps.make(fileName: "iTerm.app", shortVersion: "1.0"))
        _ = try await (first, second)
        _ = try await source.checkForUpdate(TestApps.make(fileName: "Unknown.app"))
        #expect(http.requestCount(for: apiURL) == 1)
    }

    @Test func retriesAfterFailedFetch() async {
        let http = MockHTTPClient(failures: [apiURL: .network("offline")])
        let source = makeSource(http: http)
        let app = TestApps.make(fileName: "Firefox.app")
        await #expect(throws: UpdaterError.network("offline")) { try await source.checkForUpdate(app) }
        await #expect(throws: UpdaterError.network("offline")) { try await source.checkForUpdate(app) }
        #expect(http.requestCount(for: apiURL) == 2)
    }

    @Test func canHandleExcludesAppStoreApps() {
        let source = makeSource(http: makeHTTP())
        #expect(source.canHandle(TestApps.make()))
        #expect(!source.canHandle(TestApps.make(isFromAppStore: true)))
    }

    // H-1: casks whose url is not dmg/zip/pkg are manual-only. no_check casks carry no checksum,
    // so the installed app's Team ID (enforced by AppInstaller) is the only publisher binding.
    @Test func nonPackageCaskURLIsManualOnlyAndNoCheckHasNoChecksum() async throws {
        let casks = """
        [{"token": "tool", "version": "2.0", "url": "https://example.com/Tool-2.0.tar.gz",
          "sha256": "no_check", "artifacts": [{"app": ["Tool.app"]}]}]
        """
        let source = makeSource(http: MockHTTPClient(strings: [apiURL.absoluteString: casks]))
        let update = try #require(try await source.checkForUpdate(TestApps.make(fileName: "Tool.app", shortVersion: "1.0")))
        #expect(update.sha256 == nil)
        #expect(InstallMethod(update: update) == .manualDownload)
        #expect(!UpdatePolicies(defaultPolicy: .autoInstall).shouldAutoInstall(update))
    }

    @Test func caskWithoutAppArtifactIsNotMatched() async throws {
        let casks = """
        [{"token": "suite", "version": "2.0", "url": "https://example.com/Suite.pkg",
          "sha256": "abc", "artifacts": [{"pkg": ["Suite.pkg"]}]}]
        """
        let source = makeSource(http: MockHTTPClient(strings: [apiURL.absoluteString: casks]))
        #expect(try await source.checkForUpdate(TestApps.make(fileName: "Suite.app", shortVersion: "1.0")) == nil)
    }
}
