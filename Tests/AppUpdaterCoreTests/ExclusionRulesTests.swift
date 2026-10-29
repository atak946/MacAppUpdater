import Foundation
import Testing
@testable import AppUpdaterCore

@Suite("ExclusionRules")
struct ExclusionRulesTests {
    private func makeUpdate(_ bundleID: String = "com.example.app", version: String = "2.0", url: String = "https://example.com/App.zip") -> AvailableUpdate {
        let app = InstalledApp(
            bundleIdentifier: bundleID,
            name: "App",
            url: URL(fileURLWithPath: "/Applications/App.app"),
            shortVersion: "1.0",
            buildVersion: nil,
            sparkleFeedURL: nil,
            isFromAppStore: false
        )
        return AvailableUpdate(app: app, newVersion: version, downloadURL: URL(string: url)!, source: .sparkle)
    }

    @Test func ignoredAppIsExcludedForAnyVersion() {
        let rules = ExclusionRules().ignoring("com.example.app")
        #expect(rules.isExcluded(makeUpdate(version: "2.0")))
        #expect(rules.isExcluded(makeUpdate(version: "3.0")))
        #expect(!rules.isExcluded(makeUpdate("com.other.app")))
    }

    @Test func skippedVersionOnlyExcludesThatVersion() {
        let rules = ExclusionRules().skipping(version: "2.0", of: "com.example.app")
        #expect(rules.isExcluded(makeUpdate(version: "2.0")))
        #expect(!rules.isExcluded(makeUpdate(version: "2.1")))
    }

    @Test func includingRemovesIgnoreAndSkip() {
        let rules = ExclusionRules()
            .ignoring("com.example.app")
            .skipping(version: "2.0", of: "com.example.app")
            .including("com.example.app")
        #expect(rules == ExclusionRules())
    }

    @Test func mutationsReturnNewValues() {
        let original = ExclusionRules()
        _ = original.ignoring("com.example.app")
        #expect(original.ignoredBundleIdentifiers.isEmpty)
    }

    @Test func storeRoundTrips() throws {
        let suite = "ExclusionRulesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsExclusionRulesStore(defaults: defaults)
        let rules = ExclusionRules().ignoring("a").skipping(version: "1.2", of: "b")

        try store.save(rules)

        #expect(store.load() == rules)
    }

    @Test func storeReturnsEmptyRulesWhenNothingSaved() throws {
        let suite = "ExclusionRulesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(UserDefaultsExclusionRulesStore(defaults: defaults).load() == ExclusionRules())
    }

    @Test("Install method from source and extension", arguments: [
        ("https://example.com/App.pkg", UpdateSourceKind.sparkle, InstallMethod.installerPackage),
        ("https://example.com/App.dmg", .homebrew, .automatic),
        ("https://example.com/App.zip", .github, .automatic),
        ("https://example.com/App.mpkg", .homebrew, .installerPackage),
        // H-1: anything outside the dmg/zip/pkg allowlist is manual-only (never opened or auto-installed).
        ("https://example.com/download", .github, .manualDownload),
        ("https://example.com/App.tar.gz", .sparkle, .manualDownload),
        ("https://example.com/Update.terminal", .sparkle, .manualDownload),
        ("https://example.com/Update.webloc", .vendor, .manualDownload),
        ("macappstore://apps.apple.com/app/id1", .appStore, .appStore),
    ])
    func installMethod(url: String, source: UpdateSourceKind, expected: InstallMethod) {
        let base = makeUpdate(url: url)
        let update = AvailableUpdate(app: base.app, newVersion: base.newVersion, downloadURL: base.downloadURL, source: source)
        #expect(InstallMethod(update: update) == expected)
    }
    // MARK: Version ceilings

    @Test("Ceiling keeps the app on a version line", arguments: [
        ("5", "5.9", false), ("5", "5.0b1", false), ("5", "6.0", true), ("5", "6.0b1", true),
        ("5", "4.2", false), ("5.2", "5.2.7", false), ("5.2", "5.3", true), ("5.2", "5.10", true),
        ("v5", "5.1", false), ("5", "50.0", true),
    ])
    func ceiling(ceiling: String, version: String, excluded: Bool) {
        let rules = ExclusionRules().capping("com.example.app", at: ceiling)
        #expect(rules.isExcluded(makeUpdate(version: version)) == excluded)
        #expect(!rules.isExcluded(makeUpdate("com.other.app", version: version)))
    }

    @Test func ceilingReasonMentionsLine() throws {
        let rules = ExclusionRules().capping("com.example.app", at: "5")
        let reason = try #require(rules.exclusionReason(for: makeUpdate(version: "6.0")))
        #expect(reason.contains("5.x"))
        #expect(rules.exclusionReason(for: makeUpdate(version: "5.1")) == nil)
    }

    @Test func cappingWithNilOrBlankRemovesCeiling() {
        let rules = ExclusionRules().capping("a", at: "5")
        #expect(rules.ceiling(for: "a") == "5")
        #expect(rules.capping("a", at: nil).versionCeilings.isEmpty)
        #expect(rules.capping("a", at: "  ").versionCeilings.isEmpty)
    }

    @Test func includingClearsCeilingAndOtherSettersKeepIt() {
        let rules = ExclusionRules().capping("com.example.app", at: "5")
        #expect(rules.ignoring("x").skipping(version: "1", of: "y").ceiling(for: "com.example.app") == "5")
        #expect(rules.including("com.example.app") == ExclusionRules())
    }

    @Test("unignoring removes the ignore and skipped version but keeps the ceiling")
    func unignoringKeepsCeiling() {
        let rules = ExclusionRules()
            .ignoring("com.example.app")
            .skipping(version: "5.3", of: "com.example.app")
            .capping("com.example.app", at: "5")
            .ignoring("other")
        let result = rules.unignoring("com.example.app")
        #expect(!result.isIgnored("com.example.app"))
        #expect(result.skippedVersions["com.example.app"] == nil)
        #expect(result.ceiling(for: "com.example.app") == "5")
        #expect(result.isIgnored("other"))
    }

    @Test func decodesLegacyJSONWithoutCeilings() throws {
        let json = #"{"ignoredBundleIdentifiers":["a"],"skippedVersions":{"b":"1.2"}}"#
        let rules = try JSONDecoder().decode(ExclusionRules.self, from: Data(json.utf8))
        #expect(rules == ExclusionRules(ignoredBundleIdentifiers: ["a"], skippedVersions: ["b": "1.2"]))
        #expect(rules.versionCeilings.isEmpty)
    }

    @Test func ceilingsRoundTripThroughStore() throws {
        let suite = "ExclusionRulesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsExclusionRulesStore(defaults: defaults)
        let rules = ExclusionRules().capping("a", at: "5.2")
        try store.save(rules)
        #expect(store.load() == rules)
    }
}
