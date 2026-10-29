import Foundation
import Testing
@testable import AppUpdaterCore

@Suite("Brewfile")
struct BrewfileTests {
    static let manifest = MigrationManifest(
        apps: [
            MigrationEntry(
                bundleIdentifier: "org.mozilla.firefox", name: "Firefox", version: "131.0",
                source: .homebrew, caskToken: "firefox"
            ),
            MigrationEntry(
                bundleIdentifier: "com.example.notes", name: "Notes \"Pro\" #1", version: "2.0",
                source: .appStore, appStoreID: 123_456_789
            ),
            MigrationEntry(bundleIdentifier: "com.example.tool", name: "Tool", version: "1.0", source: .manual),
            MigrationEntry(bundleIdentifier: "com.example.store", name: "Store Only", version: "3", source: .appStore),
        ],
        formulae: ["wget", "node@20"]
    )

    @Test func rendersAllSections() {
        let text = Brewfile.render(Self.manifest)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.contains(#"brew "mas""#))
        #expect(lines.contains(#"brew "wget""#))
        #expect(lines.contains(#"brew "node@20""#))
        #expect(lines.contains(#"cask "firefox""#))
        #expect(lines.contains(##"mas "Notes \"Pro\" \#1", id: 123456789"##))
        #expect(lines.contains("# Tool (com.example.tool): no Homebrew cask, install manually"))
        #expect(lines.contains("# Store Only (com.example.store): no App Store ID, install from the App Store"))
        #expect(text.hasSuffix("\n"))
    }

    @Test func masFormulaIsNotAddedWithoutStoreApps() {
        let manifest = MigrationManifest(apps: [Self.manifest.apps[0]])
        #expect(!Brewfile.render(manifest).contains(#"brew "mas""#))
    }

    @Test func roundTripsThroughParse() {
        let parsed = Brewfile.parse(Brewfile.render(Self.manifest))
        #expect(parsed.formulae == ["mas", "wget", "node@20"])
        #expect(parsed.apps.compactMap(\.caskToken) == ["firefox"])
        let store = parsed.apps.first { $0.appStoreID != nil }
        #expect(store?.name == "Notes \"Pro\" #1")
        #expect(store?.appStoreID == 123_456_789)
        let manual = parsed.apps.filter { $0.caskToken == nil && $0.appStoreID == nil }
        #expect(manual.map(\.bundleIdentifier) == ["com.example.tool", "com.example.store"])
        #expect(manual.map(\.source) == [.manual, .appStore])
    }

    @Test func newlinesInNamesCannotEscapeTheCommentLine() {
        let entry = MigrationEntry(
            bundleIdentifier: "com.example.evil", name: "Evil\nsystem(\"id\")", version: nil, source: .manual
        )
        let text = Brewfile.render(MigrationManifest(apps: [entry]))
        #expect(text.split(separator: "\n").allSatisfy { $0.hasPrefix("#") })
    }

    @Test func rubyInterpolationIsEscaped() {
        #expect(Brewfile.quoted("a#{`id`}") == ##""a\#{`id`}""##)
        #expect(Brewfile.quoted(#"back\slash"#) == #""back\\slash""#)
    }

    @Test func parsesCommonBrewfileSyntax() {
        let text = """
        tap "homebrew/bundle"
        brew 'git'
        brew "postgresql@16", restart_service: true
        cask "visual-studio-code" # editor
        cask 'homebrew/cask-versions/firefox-developer-edition'
        cask "google-chrome", args: { appdir: "~/Applications" }
        mas "Some App", id: 42
        whalebrew "whalebrew/wget"
        # a regular comment
        """
        let parsed = Brewfile.parse(text)
        #expect(parsed.formulae == ["git", "postgresql@16"])
        #expect(parsed.apps.compactMap(\.caskToken) == [
            "visual-studio-code", "homebrew/cask-versions/firefox-developer-edition", "google-chrome",
        ])
        #expect(parsed.apps.compactMap(\.appStoreID) == [42])
    }

    @Test func rejectsInvalidTokensAndIDs() {
        let text = """
        cask "evil; rm -rf ~"
        cask "--force"
        cask "Upper"
        cask "a/../b"
        brew "-x"
        mas "Zero", id: 0
        mas "Huge", id: 1234567890123
        """
        let parsed = Brewfile.parse(text)
        #expect(parsed.apps.isEmpty)
        #expect(parsed.formulae.isEmpty)
    }
}
