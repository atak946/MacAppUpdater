import Foundation
import Testing
@testable import AppUpdaterCore

struct SparkleSourceTests {
    private let feedURL = URL(string: "https://example.com/appcast.xml")!
    private let systemVersion = OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0)

    private static let appcast = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <title>Example</title>
        <item>
          <title>Version 2.0</title>
          <sparkle:releaseNotesLink>https://example.com/notes/2.0.html</sparkle:releaseNotesLink>
          <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
          <enclosure url="https://example.com/Example-2.0.zip" sparkle:version="200"
                     sparkle:shortVersionString="2.0" sparkle:edSignature="c2lnMg==" length="1024"
                     type="application/octet-stream"/>
        </item>
        <item>
          <title>Version 1.5</title>
          <sparkle:version>150</sparkle:version>
          <sparkle:shortVersionString>1.5</sparkle:shortVersionString>
          <enclosure url="https://example.com/Example-1.5.zip" length="900"/>
        </item>
        <item>
          <title>Version 3.0 (needs future macOS)</title>
          <sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion>
          <enclosure url="https://example.com/Example-3.0.zip" sparkle:version="300" sparkle:shortVersionString="3.0"/>
        </item>
        <item>
          <title>Version 4.0 (insecure)</title>
          <enclosure url="http://example.com/Example-4.0.zip" sparkle:version="400" sparkle:shortVersionString="4.0"/>
        </item>
        <item>
          <title>Version 5.0 beta</title>
          <sparkle:channel>beta</sparkle:channel>
          <enclosure url="https://example.com/Example-5.0.zip" sparkle:version="500" sparkle:shortVersionString="5.0"/>
        </item>
      </channel>
    </rss>
    """

    private func makeSource(_ xml: String = appcast) -> SparkleSource {
        SparkleSource(
            http: MockHTTPClient(strings: [feedURL.absoluteString: xml]),
            comparator: NumericStubComparator(),
            systemVersion: systemVersion
        )
    }

    @Test func parsesAttributeAndElementStyles() throws {
        let items = try SparkleAppcastParser.parse(Data(Self.appcast.utf8))
        #expect(items.count == 5)
        #expect(items[0].version == "200")
        #expect(items[0].shortVersionString == "2.0")
        #expect(items[0].edSignature == "c2lnMg==")
        #expect(items[0].length == 1024)
        #expect(items[0].releaseNotesURL == URL(string: "https://example.com/notes/2.0.html"))
        #expect(items[1].version == "150")
        #expect(items[1].shortVersionString == "1.5")
    }

    @Test func picksNewestCompatibleSecureItem() async throws {
        let app = TestApps.make(shortVersion: "1.0", buildVersion: "100", sparkleFeedURL: feedURL)
        let update = try #require(try await makeSource().checkForUpdate(app))
        #expect(update.newVersion == "2.0")
        #expect(update.downloadURL == URL(string: "https://example.com/Example-2.0.zip"))
        #expect(update.edSignature == "c2lnMg==")
        #expect(update.source == .sparkle)
        #expect(update.releaseNotesURL == URL(string: "https://example.com/notes/2.0.html"))
    }

    @Test func returnsNilWhenUpToDateByBuildVersion() async throws {
        let app = TestApps.make(shortVersion: "2.0", buildVersion: "200", sparkleFeedURL: feedURL)
        #expect(try await makeSource().checkForUpdate(app) == nil)
    }

    @Test func fallsBackToShortVersionWithoutBuildVersion() async throws {
        let app = TestApps.make(shortVersion: "1.9", buildVersion: nil, sparkleFeedURL: feedURL)
        let update = try await makeSource().checkForUpdate(app)
        #expect(update?.newVersion == "2.0")
    }

    @Test func canHandleRequiresFeedAndNonAppStore() {
        let source = makeSource()
        #expect(source.canHandle(TestApps.make(sparkleFeedURL: feedURL)))
        #expect(!source.canHandle(TestApps.make(sparkleFeedURL: nil)))
        #expect(!source.canHandle(TestApps.make(sparkleFeedURL: feedURL, isFromAppStore: true)))
    }

    @Test func invalidXMLThrowsParsingError() async {
        let app = TestApps.make(sparkleFeedURL: feedURL)
        await #expect(throws: UpdaterError.self) {
            try await makeSource("<rss><channel><item></channel>").checkForUpdate(app)
        }
    }

    @Test func minimumSystemVersionComparison() {
        let current = OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0)
        #expect(SystemVersionRequirement.isSatisfied(minimum: "10.13", current: current))
        #expect(SystemVersionRequirement.isSatisfied(minimum: "14.5", current: current))
        #expect(!SystemVersionRequirement.isSatisfied(minimum: "14.5.1", current: current))
        #expect(!SystemVersionRequirement.isSatisfied(minimum: "15", current: current))
    }

    private static let notesAppcast = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <description>Feed description must be ignored</description>
        <item>
          <title>Version 2.0</title>
          <description><![CDATA[<h2>New</h2><ul><li>Faster</li></ul>]]></description>
          <sparkle:releaseNotesLink>https://example.com/notes/2.0.html</sparkle:releaseNotesLink>
          <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
          <enclosure url="https://example.com/E-2.0.zip" sparkle:version="200" sparkle:shortVersionString="2.0"/>
        </item>
        <item>
          <title>Version 2.5 beta</title>
          <sparkle:channel>beta</sparkle:channel>
          <sparkle:releaseNotesLink>https://example.com/notes/2.5.html</sparkle:releaseNotesLink>
          <enclosure url="https://example.com/E-2.5.zip" sparkle:version="250" sparkle:shortVersionString="2.5b1"/>
        </item>
        <item>
          <title>Version 2.6 nightly</title>
          <sparkle:channel>nightly</sparkle:channel>
          <enclosure url="https://example.com/E-2.6.zip" sparkle:version="260" sparkle:shortVersionString="2.6n"/>
        </item>
      </channel>
    </rss>
    """

    private func makeChannelSource(_ channels: Set<String>) -> SparkleSource {
        SparkleSource(
            http: MockHTTPClient(strings: [feedURL.absoluteString: Self.notesAppcast]),
            comparator: NumericStubComparator(),
            systemVersion: systemVersion,
            allowedChannels: { _ in channels }
        )
    }

    @Test func inlineDescriptionBecomesHTMLNotes() async throws {
        let app = TestApps.make(shortVersion: "1.0", buildVersion: "100", sparkleFeedURL: feedURL)
        let update = try #require(try await makeChannelSource([]).checkForUpdate(app))
        #expect(update.newVersion == "2.0")
        #expect(update.releaseNotes == .html("<h2>New</h2><ul><li>Faster</li></ul>"))
        #expect(update.minimumSystemVersion == "13.0")
    }

    @Test func releaseNotesLinkBecomesRemoteNotes() async throws {
        let app = TestApps.make(shortVersion: "1.0", buildVersion: "100", sparkleFeedURL: feedURL)
        let update = try #require(try await makeSource().checkForUpdate(app))
        #expect(update.releaseNotes == .remote(URL(string: "https://example.com/notes/2.0.html")!))
        #expect(update.minimumSystemVersion == "13.0")
    }

    @Test func betaChannelOptInSelectsBetaItemOnly() async throws {
        let app = TestApps.make(shortVersion: "1.0", buildVersion: "100", sparkleFeedURL: feedURL)
        let beta = try #require(try await makeChannelSource(["beta"]).checkForUpdate(app))
        #expect(beta.newVersion == "2.5b1")
        #expect(beta.releaseNotes == .remote(URL(string: "https://example.com/notes/2.5.html")!))
        let nightly = try #require(try await makeChannelSource(["beta", "nightly"]).checkForUpdate(app))
        #expect(nightly.newVersion == "2.6n")
    }

    @Test func channelProviderReceivesApp() async throws {
        let store = BetaChannelStore(defaults: makeIsolatedDefaults())
        store.setOptedIn(true, for: "com.beta")
        let source = SparkleSource(
            http: MockHTTPClient(strings: [feedURL.absoluteString: Self.notesAppcast]),
            comparator: NumericStubComparator(), systemVersion: systemVersion,
            allowedChannels: store.channelProvider
        )
        let betaApp = TestApps.make(bundleIdentifier: "com.beta", buildVersion: "100", sparkleFeedURL: feedURL)
        let stableApp = TestApps.make(bundleIdentifier: "com.stable", buildVersion: "100", sparkleFeedURL: feedURL)
        #expect(try await source.checkForUpdate(betaApp)?.newVersion == "2.5b1")
        #expect(try await source.checkForUpdate(stableApp)?.newVersion == "2.0")
    }

    @Test func lookupReportsUpToDateForParsedFeed() async throws {
        let current = TestApps.make(shortVersion: "2.0", buildVersion: "200", sparkleFeedURL: feedURL)
        #expect(try await makeSource().lookup(current) == .upToDate(latestVersion: "2.0"))
        let empty = "<rss><channel></channel></rss>"
        #expect(try await makeSource(empty).lookup(current) == .upToDate(latestVersion: "2.0"))
        #expect(try await makeSource().lookup(TestApps.make()) == .notFound)
    }

    // H-1: an enclosure outside the dmg/zip/pkg allowlist is reported, but only as a manual download.
    @Test("unknown enclosure formats become manual-only updates", arguments: ["Update.terminal", "Update.tar.xz", "download"])
    func unknownEnclosureIsManualOnly(fileName: String) async throws {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
          <enclosure url="https://example.com/\(fileName)" sparkle:version="200" sparkle:shortVersionString="2.0"/>
        </item></channel></rss>
        """
        let app = TestApps.make(shortVersion: "1.0", buildVersion: "100", sparkleFeedURL: feedURL)
        let update = try #require(try await makeSource(xml).checkForUpdate(app))
        #expect(InstallMethod(update: update) == .manualDownload)
        #expect(InstallMethod.manualDownloadPage(for: update) == update.downloadURL)
    }
}
