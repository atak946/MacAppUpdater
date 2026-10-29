import Foundation
import Testing
@testable import AppUpdaterCore

@Suite("SecurityUpdateDetector")
struct SecurityUpdateDetectorTests {
    @Test("Security keywords flag the notes", arguments: [
        "Includes important security fixes.",
        "SECURITY: patched a crash",
        "Fixed a vulnerability in the PDF renderer",
        "Addresses several vulnerabilities",
        "Fixes an issue that could be exploited by a crafted file",
        "Patched a zero-day in the updater",
        "Security-related improvements",
    ])
    func keywordsFlag(text: String) {
        #expect(SecurityUpdateDetector.detect(inText: text) == SecurityUpdateInfo())
    }

    @Test("Look-alike words do not flag the notes", arguments: [
        "Warns when a site uses an insecure connection",
        "Restarts securityd less often",
        "Bug fixes and performance improvements",
        "",
    ])
    func lookAlikesIgnored(text: String) {
        #expect(SecurityUpdateDetector.detect(inText: text) == nil)
    }

    @Test func extractsUniqueUppercasedCVEsInOrder() {
        let text = "Fixes CVE-2024-12345 and cve-2023-0001; also CVE-2024-12345 again."
        let info = SecurityUpdateDetector.detect(inText: text)
        #expect(info?.cveIDs == ["CVE-2024-12345", "CVE-2023-0001"])
    }

    @Test func malformedCVEIsIgnored() {
        #expect(SecurityUpdateDetector.detect(inText: "See CVE-24-1 for details") == nil)
    }

    @Test func htmlTagsAreIgnored() {
        let html = #"<p class="security-note">Faster sync</p>"#
        #expect(SecurityUpdateDetector.detect(in: .html(html)) == nil)
        let flagged = #"<ul><li>Fixed <b>CVE-2025-1234</b></li></ul>"#
        #expect(SecurityUpdateDetector.detect(in: .html(flagged))?.cveIDs == ["CVE-2025-1234"])
    }

    @Test func markdownIsScanned() {
        #expect(SecurityUpdateDetector.detect(in: .markdown("## Security\n- Hardened sandbox")) != nil)
    }

    @Test func remoteOrMissingNotesAreNotFlagged() throws {
        let url = try #require(URL(string: "https://example.com/notes"))
        #expect(SecurityUpdateDetector.detect(in: .remote(url)) == nil)
        #expect(SecurityUpdateDetector.detect(in: nil) == nil)
    }

    @Test func availableUpdateCarriesTheResult() throws {
        let app = InstalledApp(
            bundleIdentifier: "com.example.app", name: "Example", url: URL(fileURLWithPath: "/Applications/Example.app"),
            shortVersion: "1.0", buildVersion: nil, sparkleFeedURL: nil, isFromAppStore: false
        )
        let download = try #require(URL(string: "https://example.com/app.zip"))
        let flagged = AvailableUpdate(
            app: app, newVersion: "1.1", downloadURL: download, source: .github,
            releaseNotes: .markdown("Fixes CVE-2025-9999")
        )
        let plain = AvailableUpdate(app: app, newVersion: "1.1", downloadURL: download, source: .github)
        #expect(flagged.securityInfo?.cveIDs == ["CVE-2025-9999"])
        #expect(plain.securityInfo == nil)
    }
}
