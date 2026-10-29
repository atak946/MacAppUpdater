import Foundation
import Testing
@testable import AppUpdaterCore

@Suite("publishedAt population")
struct PublishedAtTests {
    private static func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    @Test("ReleaseDateParser handles ISO 8601, day-only and RFC 822")
    func parser() {
        #expect(ReleaseDateParser.iso8601("2024-05-01T10:20:30Z") == Self.utc(2024, 5, 1, 10, 20, 30))
        #expect(ReleaseDateParser.iso8601("2024-05-01T10:20:30.500Z")?.timeIntervalSince(Self.utc(2024, 5, 1, 10, 20, 30)) == 0.5)
        #expect(ReleaseDateParser.iso8601("2024-03-26") == Self.utc(2024, 3, 26))
        #expect(ReleaseDateParser.rfc822("Wed, 09 Jan 2019 10:00:00 +0000") == Self.utc(2019, 1, 9, 10))
        #expect(ReleaseDateParser.rfc822("Wed, 09 Jan 2019 12:00:00 +0200") == Self.utc(2019, 1, 9, 10))
        #expect(ReleaseDateParser.iso8601("nonsense") == nil)
        #expect(ReleaseDateParser.rfc822(nil) == nil)
    }

    @Test("Sparkle pubDate")
    func sparkle() async throws {
        let feedURL = URL(string: "https://example.com/appcast.xml")!
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
          <pubDate>Mon, 01 Jan 2018 00:00:00 +0000</pubDate>
          <item><title>2.0</title><pubDate>Wed, 09 Jan 2019 10:00:00 +0000</pubDate>
            <enclosure url="https://example.com/A-2.0.zip" sparkle:version="2.0"/></item>
        </channel></rss>
        """
        let source = SparkleSource(
            http: MockHTTPClient(strings: [feedURL.absoluteString: xml]), comparator: NumericStubComparator()
        )
        let app = TestApps.make(shortVersion: "1.0", buildVersion: "1.0", sparkleFeedURL: feedURL)
        let update = try #require(try await source.lookup(app).update)
        #expect(update.publishedAt == Self.utc(2019, 1, 9, 10))
    }

    @Test("GitHub published_at")
    func github() async throws {
        let apiURL = "https://api.github.com/repos/acme/tool/releases/latest"
        let json = """
        {"tag_name":"v2.0.0","draft":false,"prerelease":false,"published_at":"2024-02-03T04:05:06Z",
         "assets":[{"name":"Tool-2.0.0.dmg","browser_download_url":"https://github.com/acme/tool/releases/download/v2.0.0/Tool-2.0.0.dmg"}]}
        """
        let source = GitHubReleasesSource(
            repositories: ["com.acme.tool": "acme/tool"],
            http: MockHTTPClient(strings: [apiURL: json]), comparator: NumericStubComparator()
        )
        let update = try #require(try await source.lookup(TestApps.make(bundleIdentifier: "com.acme.tool")).update)
        #expect(update.publishedAt == Self.utc(2024, 2, 3, 4, 5, 6))
    }

    @Test("App Store currentVersionReleaseDate")
    func appStore() async throws {
        let base = URL(string: "https://itunes.example.com/lookup")!
        let source = AppStoreSource(http: MockHTTPClient(), comparator: NumericStubComparator(), lookupBaseURL: base)
        let lookupURL = try #require(source.lookupURL(for: "com.acme.store"))
        let json = """
        {"results":[{"version":"3.0","trackViewUrl":"https://apps.apple.com/app/id1","bundleId":"com.acme.store",
          "currentVersionReleaseDate":"2024-06-07T08:09:10Z"}]}
        """
        let configured = AppStoreSource(
            http: MockHTTPClient(strings: [lookupURL.absoluteString: json]),
            comparator: NumericStubComparator(), lookupBaseURL: base
        )
        let app = TestApps.make(bundleIdentifier: "com.acme.store", isFromAppStore: true)
        let update = try #require(try await configured.lookup(app).update)
        #expect(update.publishedAt == Self.utc(2024, 6, 7, 8, 9, 10))
    }
}
