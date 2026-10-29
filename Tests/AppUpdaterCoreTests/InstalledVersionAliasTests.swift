import Foundation
import Testing
@testable import AppUpdaterCore

@Suite("InstalledVersionAliasStore")
struct InstalledVersionAliasTests {
    private let suite = "alias-tests-\(UUID().uuidString)"

    /// A fresh `UserDefaults` handle per store (not Sendable, so never shared across isolation).
    private func makeStore() -> InstalledVersionAliasStore {
        InstalledVersionAliasStore(defaults: UserDefaults(suiteName: suite)!)
    }

    private static func update(short: String, build: String?, newVersion: String, url: URL? = nil) -> AvailableUpdate {
        let app = InstalledApp(
            bundleIdentifier: "com.google.android.studio", name: "Android Studio",
            url: url ?? URL(fileURLWithPath: "/Applications/Android Studio.app"),
            shortVersion: short, buildVersion: build, sparkleFeedURL: nil, isFromAppStore: false
        )
        return AvailableUpdate(
            app: app, newVersion: newVersion,
            downloadURL: URL(string: "https://dl.example.com/studio.dmg")!, source: .homebrew
        )
    }

    private static func result(_ update: AvailableUpdate) -> UpdateCheckResult {
        UpdateCheckResult(app: update.app, matchedSource: .homebrew, latestVersion: update.newVersion, update: update)
    }

    @Test("an installed bundle that never shows the advertised version is up to date")
    func reconcilesInstalledAlias() async {
        let store = makeStore()
        await store.record(
            InstalledVersionAlias(advertisedVersion: "2026.2.2.8", shortVersion: "2026.2", buildVersion: "AI-262.10968"),
            for: "com.google.android.studio"
        )
        let installed = Self.update(short: "2026.2", build: "AI-262.10968", newVersion: "2026.2.2.8")

        let reconciled = await store.reconcile([Self.result(installed)])

        #expect(reconciled.first?.update == nil)
        #expect(reconciled.first?.isUpToDate == true)
        #expect(reconciled.first?.latestVersion == "2026.2.2.8")
    }

    @Test("a newer advertised version or a different bundle build is still offered")
    func keepsRealUpdates() async {
        let store = makeStore()
        await store.record(
            InstalledVersionAlias(advertisedVersion: "2026.2.2.8", shortVersion: "2026.2", buildVersion: "AI-262.10968"),
            for: "com.google.android.studio"
        )
        let newer = Self.update(short: "2026.2", build: "AI-262.10968", newVersion: "2026.2.3.1")
        let replacedBundle = Self.update(short: "2026.2", build: "AI-262.9437", newVersion: "2026.2.2.8")

        let reconciled = await store.reconcile([Self.result(newer), Self.result(replacedBundle)])

        #expect(reconciled.map { $0.update?.newVersion } == ["2026.2.3.1", "2026.2.2.8"])
    }

    @Test("recordInstall reads the installed bundle and survives a new store instance")
    func recordsFromBundle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("alias-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = directory.appendingPathComponent("Studio.app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleShortVersionString": "2026.2", "CFBundleVersion": "AI-262.10968"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))

        await makeStore()
            .recordInstall(of: Self.update(short: "2026.2", build: "AI-262.9437", newVersion: "2026.2.2.8", url: bundle))

        let alias = await makeStore().alias(for: "com.google.android.studio")
        #expect(alias == InstalledVersionAlias(advertisedVersion: "2026.2.2.8", shortVersion: "2026.2", buildVersion: "AI-262.10968"))
    }
}

@Suite("HomebrewCaskSource build suffix")
struct HomebrewBuildSuffixTests {
    private static func app(short: String, build: String?) -> InstalledApp {
        InstalledApp(
            bundleIdentifier: "com.parallels.desktop.console", name: "Parallels Desktop",
            url: URL(fileURLWithPath: "/Applications/Parallels Desktop.app"),
            shortVersion: short, buildVersion: build, sparkleFeedURL: nil, isFromAppStore: false
        )
    }

    @Test("short-build cask versions match the installed build", arguments: [
        ("27.0.3-58680", "27.0.3", "58680", true),
        ("27.0.3-58700", "27.0.3", "58680", false),
        ("27.1.0-60000", "27.0.3", "58680", false),
        ("2026.2.2.8", "2026.2", "AI-262.10968", false),
        ("1.2.3", "1.2", nil, false),
    ] as [(String, String, String?, Bool)])
    func installedBuild(cask: String, short: String, build: String?, expected: Bool) {
        let result = HomebrewCaskSource.isInstalledBuild(cask, of: Self.app(short: short, build: build), comparator: VersionComparator())
        #expect(result == expected)
    }

    @Test("Content-Length is parsed; missing or zero is unknown")
    func contentLength() {
        func response(_ headers: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://x.example")!, statusCode: 200, httpVersion: nil, headerFields: headers)!
        }
        #expect(DownloadSizeProbe.contentLength(of: response(["Content-Length": "1524936162"])) == 1_524_936_162)
        #expect(DownloadSizeProbe.contentLength(of: response(["Content-Length": "0"])) == nil)
        #expect(DownloadSizeProbe.contentLength(of: response([:])) == nil)
    }
}
