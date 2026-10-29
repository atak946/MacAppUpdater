import Foundation
import Testing
@testable import AppUpdaterCore

@Suite("VendorFeedSource")
struct VendorFeedSourceTests {
    private static let jetBrainsURL = URL(string: "https://data.services.jetbrains.com/products/releases?code=IIU&latest=true&type=release")!
    private static let firefoxURL = URL(string: "https://product-details.mozilla.org/1.0/firefox_versions.json")!
    private static let chromeURL = URL(string: "https://versionhistory.googleapis.com/v1/chrome/platforms/mac/channels/stable/versions/all/releases?filter=endtime=none")!

    private static let jetBrainsJSON = """
    {"IIU":[{"date":"2024-03-26","type":"release","version":"2024.1","build":"241.14494.240",
      "downloads":{"mac":{"link":"https://download.jetbrains.com/idea/ideaIU-2024.1.dmg","size":1},
                   "macM1":{"link":"https://download.jetbrains.com/idea/ideaIU-2024.1-aarch64.dmg","size":1}}}]}
    """
    private static let firefoxJSON = #"{"LATEST_FIREFOX_VERSION": "131.0.3", "FIREFOX_ESR": "128.3.1esr"}"#
    /// Staged rollout: 131 is a 0.5 % experiment and 130.0.6723.80 is below half; the
    /// majority version 130.0.6723.92 is what Chrome's own updater offers.
    private static let chromeJSON = """
    {"releases":[
      {"version":"130.0.6723.80","fraction":0.495},
      {"version":"131.0.6778.10","fraction":0.005},
      {"version":"130.0.6723.92","fraction":1}
    ]}
    """

    private static func http(_ extra: [String: String] = [:]) -> MockHTTPClient {
        MockHTTPClient(strings: [
            jetBrainsURL.absoluteString: jetBrainsJSON,
            firefoxURL.absoluteString: firefoxJSON,
            chromeURL.absoluteString: chromeJSON,
        ].merging(extra) { _, new in new })
    }

    private static func source(
        architecture: VendorFeedSource.Architecture = .appleSilicon,
        http: MockHTTPClient = http()
    ) throws -> VendorFeedSource {
        VendorFeedSource(
            definitions: try VendorFeedSource.bundledDefinitions(),
            http: http, comparator: NumericStubComparator(), architecture: architecture
        )
    }

    @Test("bundled catalog loads only valid HTTPS definitions with known Team IDs")
    func bundledCatalog() throws {
        let definitions = try VendorFeedSource.bundledDefinitions()
        #expect(definitions.count >= 3)
        #expect(definitions.allSatisfy { $0.isValid })
        let byID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.bundleIdentifier, $0) })
        #expect(byID["org.mozilla.firefox"]?.expectedTeamID == "43AQ936H96")
        #expect(byID["com.google.Chrome"]?.installStrategy == .openVendorUpdater)
        #expect(byID["com.jetbrains.intellij"]?.expectedTeamID == "2ZEFAR8TH3")
    }

    @Test("JetBrains: arm64 dmg on Apple Silicon, publishedAt from date")
    func jetBrainsAppleSilicon() async throws {
        let app = TestApps.make(bundleIdentifier: "com.jetbrains.intellij", shortVersion: "2023.3.4")
        let source = try Self.source()
        let update = try #require(try await source.lookup(app).update)
        #expect(update.source == .vendor)
        #expect(update.newVersion == "2024.1")
        #expect(update.downloadURL.lastPathComponent == "ideaIU-2024.1-aarch64.dmg")
        #expect(update.publishedAt == ReleaseDateParser.iso8601("2024-03-26"))
        #expect(source.installStrategy(for: update) == .inPlace)
        #expect(source.expectedTeamID(for: app.bundleIdentifier) == "2ZEFAR8TH3")
    }

    @Test("JetBrains: Intel dmg on Intel")
    func jetBrainsIntel() async throws {
        let app = TestApps.make(bundleIdentifier: "com.jetbrains.intellij", shortVersion: "2023.3.4")
        let update = try #require(try await Self.source(architecture: .intel).lookup(app).update)
        #expect(update.downloadURL.lastPathComponent == "ideaIU-2024.1.dmg")
    }

    @Test("Firefox: download URL from template, release notes URL")
    func firefoxTemplate() async throws {
        let app = TestApps.make(bundleIdentifier: "org.mozilla.firefox", shortVersion: "130.0")
        let update = try #require(try await Self.source().lookup(app).update)
        #expect(update.downloadURL.absoluteString
            == "https://download-installer.cdn.mozilla.net/pub/firefox/releases/131.0.3/mac/en-US/Firefox%20131.0.3.dmg")
        #expect(update.releaseNotesURL?.absoluteString == "https://www.mozilla.org/firefox/131.0.3/releasenotes/")
    }

    @Test("Chrome: openVendorUpdater with vendor page; up to date when equal")
    func chromeVendorUpdater() async throws {
        let source = try Self.source()
        let old = TestApps.make(bundleIdentifier: "com.google.Chrome", shortVersion: "129.0.1")
        let update = try #require(try await source.lookup(old).update)
        #expect(update.downloadURL.absoluteString == "https://www.google.com/chrome/")
        #expect(source.installStrategy(for: update) == .openVendorUpdater)

        let current = TestApps.make(bundleIdentifier: "com.google.Chrome", shortVersion: "130.0.6723.92")
        #expect(try await source.lookup(current) == .upToDate(latestVersion: "130.0.6723.92"))
    }

    @Test("Chrome: a release rolled out to the majority is offered; releases without a fraction count fully")
    func chromeRollout() async throws {
        let rolledOut = #"{"releases":[{"version":"130.0.6723.92","fraction":1},{"version":"131.0.6778.10","fraction":0.6}]}"#
        let source = try Self.source(http: Self.http([Self.chromeURL.absoluteString: rolledOut]))
        let app = TestApps.make(bundleIdentifier: "com.google.Chrome", shortVersion: "130.0.6723.92")
        #expect(try await source.lookup(app).update?.newVersion == "131.0.6778.10")

        let noFraction = #"{"releases":[{"version":"131.0.1"}]}"#
        let plain = try Self.source(http: Self.http([Self.chromeURL.absoluteString: noFraction]))
        #expect(try await plain.lookup(app).update?.newVersion == "131.0.1")
    }

    @Test("unknown and App Store apps are not handled")
    func notHandled() throws {
        let source = try Self.source()
        #expect(!source.canHandle(TestApps.make(bundleIdentifier: "com.unknown")))
        #expect(!source.canHandle(TestApps.make(bundleIdentifier: "org.mozilla.firefox", isFromAppStore: true)))
    }

    @Test("XML feeds resolve elements, repeated elements and attributes")
    func xmlFeed() async throws {
        let feedURL = "https://vendor.example.com/feed.xml"
        let xml = """
        <updates><release channel="stable"><version>5.1</version>
          <file arch="arm64" href="https://vendor.example.com/App-5.1-arm.zip"/>
          <file arch="x64" href="https://vendor.example.com/App-5.1.zip"/>
          <date>Tue, 05 Mar 2024 10:00:00 +0000</date></release></updates>
        """
        let definition = VendorFeedDefinition(
            bundleIdentifier: "com.example.vendor", name: "Vendor",
            feedURL: URL(string: feedURL)!, format: .xml,
            versionPath: "updates.release.version",
            downloadURLPath: "updates.release.file.1.@href",
            downloadURLPathArm64: "updates.release.file.0.@href",
            publishedAtPath: "updates.release.date"
        )
        let source = VendorFeedSource(
            definitions: [definition], http: MockHTTPClient(strings: [feedURL: xml]),
            comparator: NumericStubComparator(), architecture: .appleSilicon
        )
        let update = try #require(try await source.lookup(TestApps.make(bundleIdentifier: "com.example.vendor")).update)
        #expect(update.newVersion == "5.1")
        #expect(update.downloadURL.lastPathComponent == "App-5.1-arm.zip")
        #expect(update.publishedAt == ReleaseDateParser.rfc822("Tue, 05 Mar 2024 10:00:00 +0000"))
    }

    @Test("template rejects versions that could alter the URL")
    func templateRejectsUnsafeVersion() {
        #expect(VendorFeedSource.expand("https://x.example.com/{version}.dmg", version: "1.0/../../evil") == nil)
        #expect(VendorFeedSource.expand("https://x.example.com/{version}.dmg", version: "1.0?x=1") == nil)
        #expect(VendorFeedSource.expand("http://x.example.com/{version}.dmg", version: "1.0") == nil)
        #expect(VendorFeedSource.expand("https://x.example.com/{version}.dmg", version: "1.0-beta+2")?.absoluteString
            == "https://x.example.com/1.0-beta+2.dmg")
    }

    @Test("missing version path is a parsing error; non-HTTPS feed definitions are dropped")
    func invalidFeeds() async throws {
        let definitions = try VendorFeedSource.definitions(from: Data("""
        {"version":1,"feeds":[
          {"bundleIdentifier":"a","name":"A","feedURL":"http://a.example.com/f.json","format":"json",
           "versionPath":"v","downloadURLTemplate":"https://a.example.com/{version}","installStrategy":"inPlace"},
          {"bundleIdentifier":"b","name":"B","feedURL":"https://b.example.com/f.json","format":"json",
           "versionPath":"missing","downloadURLTemplate":"https://b.example.com/{version}","installStrategy":"inPlace"}
        ]}
        """.utf8))
        #expect(definitions.map(\.bundleIdentifier) == ["b"])
        let source = VendorFeedSource(
            definitions: definitions, http: MockHTTPClient(strings: ["https://b.example.com/f.json": #"{"v":"2"}"#]),
            comparator: NumericStubComparator()
        )
        await #expect(throws: UpdaterError.self) {
            try await source.lookup(TestApps.make(bundleIdentifier: "b"))
        }
    }
}
