import Foundation
import Testing
@testable import AppUpdaterCore

@Suite("VendorFeedSource edge cases")
struct VendorFeedSourceEdgeTests {
    private static let feedURL = "https://data.services.jetbrains.com/products/releases?code=IIU&latest=true&type=release"

    private static func source(feed: String) -> VendorFeedSource {
        VendorFeedSource.bundled(http: MockHTTPClient(strings: [feedURL: feed]), comparator: NumericStubComparator(),
                                 architecture: .intel)
    }

    private static let app = TestApps.make(bundleIdentifier: "com.jetbrains.intellij", shortVersion: "2023.3")

    @Test("a feed offering only plain-HTTP downloads is rejected, never downgraded")
    func rejectsHTTPDownloads() async {
        let feed = #"{"IIU":[{"version":"2024.1","downloads":{"mac":{"link":"http://download.jetbrains.com/idea.dmg"}}}]}"#

        await #expect(throws: UpdaterError.parsing("IntelliJ IDEA feed has no usable HTTPS download URL")) {
            try await Self.source(feed: feed).checkForUpdate(Self.app)
        }
    }

    @Test("a feed without a version at the configured path is a parsing error")
    func missingVersion() async {
        await #expect(throws: UpdaterError.parsing("IntelliJ IDEA feed has no version at IIU.0.version")) {
            try await Self.source(feed: #"{"IIU":[]}"#).checkForUpdate(Self.app)
        }
    }

    @Test("checkForUpdate returns nil when up to date, and the Intel link otherwise")
    func checkForUpdate() async throws {
        let feed = #"{"IIU":[{"version":"2024.1","downloads":{"mac":{"link":"https://download.jetbrains.com/idea.dmg"},"macM1":{"link":"https://download.jetbrains.com/idea-arm.dmg"}}}]}"#
        let source = Self.source(feed: feed)
        let current = TestApps.make(bundleIdentifier: "com.jetbrains.intellij", shortVersion: "2024.1")

        let update = try await source.checkForUpdate(Self.app)

        #expect(update?.downloadURL.lastPathComponent == "idea.dmg")
        #expect(try await source.checkForUpdate(current) == nil)
        #expect(source.definition(for: "com.jetbrains.intellij")?.name == "IntelliJ IDEA")
        #expect(source.definition(for: "com.unknown") == nil)
    }

    @Test("unknown and App Store apps are not handled")
    func notHandled() async throws {
        let source = Self.source(feed: "{}")
        let store = TestApps.make(bundleIdentifier: "com.jetbrains.intellij", isFromAppStore: true)

        #expect(!source.canHandle(store))
        #expect(try await source.lookup(TestApps.make(bundleIdentifier: "com.unknown")) == .notFound)
        #expect(source.installStrategy(for: AvailableUpdate(
            app: Self.app, newVersion: "1", downloadURL: URL(string: "https://x.com/a.dmg")!, source: .homebrew
        )) == nil)
    }

    @Test("template expansion refuses versions that could alter the URL", arguments: [
        ("1.2.3", "https://x.com/app-1.2.3.dmg"),
        ("1.0+beta_2", "https://x.com/app-1.0+beta_2.dmg"),
        ("1.0-rc1", "https://x.com/app-1.0-rc1.dmg"),
        ("", nil),
        ("1/../../evil", nil),
        ("1?x=1", nil),
        ("1#frag", nil),
        ("1.0é", nil),
    ] as [(String, String?)])
    func expandValidatesVersion(version: String, expected: String?) {
        let url = VendorFeedSource.expand("https://x.com/app-{version}.dmg", version: version)

        #expect(url?.absoluteString == expected)
    }

    @Test("templates that are not HTTPS never expand")
    func expandRequiresHTTPS() {
        #expect(VendorFeedSource.expand("http://x.com/{version}.dmg", version: "1.0") == nil)
        #expect(VendorFeedSource.expand("https:///{version}.dmg", version: "1.0") == nil)
    }
}
