import Foundation
import Testing
@testable import AppUpdaterCore

@Suite("MissingAppReport")
struct MissingAppReportTests {
    static let home = "/Users/alice"

    static func report(_ app: InstalledApp, team: String? = "ABCDE12345") -> MissingAppReport {
        MissingAppReport(
            app: app, hasElectronUpdateConfig: true, teamIdentifier: team,
            homeDirectory: home, userName: "alice"
        )
    }

    static func decodedQuery(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test("issue URL is prefilled with the safe facts")
    func prefilled() throws {
        let app = CoverageFixtures.app("com.example.tool", name: "Tool", feed: URL(string: "https://example.com/appcast.xml"))
        let url = try #require(Self.report(app).issueURL(repository: "acme/updater"))
        #expect(url.absoluteString.hasPrefix("https://github.com/acme/updater/issues/new?"))
        let query = Self.decodedQuery(url)
        #expect(query["title"] == "Missing app: Tool (com.example.tool)")
        #expect(query["labels"] == "missing-app")
        let body = try #require(query["body"])
        #expect(body.contains("`com.example.tool`"))
        #expect(body.contains("1.2.3 (42)"))
        #expect(body.contains("SUFeedURL):** yes"))
        #expect(body.contains("app-update.yml:** yes"))
        #expect(body.contains("ABCDE12345"))
    }

    @Test("home path and user name never leak")
    func noPII() throws {
        let app = CoverageFixtures.app(
            "com.alice.private", name: "alice /Users/alice/Secret",
            path: "\(Self.home)/Applications/Secret.app", feed: URL(string: "https://alice.example/feed")
        )
        let url = try #require(Self.report(app).issueURL())
        let decoded = try #require(url.absoluteString.removingPercentEncoding)
        #expect(!decoded.contains(Self.home))
        #expect(!decoded.lowercased().contains("alice"))
        #expect(!decoded.contains("/Applications"))
        #expect(!decoded.contains("alice.example"))
    }

    @Test("reserved characters are percent-encoded")
    func encoding() throws {
        let app = CoverageFixtures.app("com.x.y", name: "A&B=C+D#E?")
        let url = try #require(Self.report(app).issueURL())
        let titlePart = try #require(url.absoluteString.components(separatedBy: "title=").last?.components(separatedBy: "&").first)
        #expect(!titlePart.contains("+") && !titlePart.contains("#") && !titlePart.contains("="))
        #expect(Self.decodedQuery(url)["title"] == "Missing app: A&B=C+D#E? (com.x.y)")
    }

    @Test("URL length is capped and fields are truncated")
    func capped() throws {
        let app = CoverageFixtures.app("com.long", name: String(repeating: "ğ", count: 5_000))
        let report = Self.report(app)
        #expect(report.name.count == MissingAppReport.maxFieldLength)
        let url = try #require(report.issueURL())
        #expect(url.absoluteString.count <= MissingAppReport.maxURLLength)
    }

    @Test("missing team id reads as unknown, control characters stripped")
    func unknownTeam() {
        let app = CoverageFixtures.app("com.x\n.y", name: "Na\u{0007}me")
        let report = Self.report(app, team: "")
        #expect(report.teamIdentifier == nil)
        #expect(report.body.contains("Team ID:** unknown"))
        #expect(report.name == "Name")
        #expect(report.bundleIdentifier == "com.x.y")
    }

    @Test("detects app-update.yml on disk")
    func electronDetection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let appURL = dir.appendingPathComponent("E.app")
        let resources = appURL.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        #expect(!MissingAppReport.electronConfigExists(in: appURL))
        try Data("provider: github".utf8).write(to: resources.appendingPathComponent("app-update.yml"))
        #expect(MissingAppReport.electronConfigExists(in: appURL))
    }
}
