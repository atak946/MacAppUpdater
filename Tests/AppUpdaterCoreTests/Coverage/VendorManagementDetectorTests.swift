import Foundation
import Testing
@testable import AppUpdaterCore

/// Each test builds a throwaway root + home tree so real system folders are never consulted.
struct FakeSystem: ~Copyable {
    let base: URL
    var root: URL { base.appendingPathComponent("root") }
    var home: URL { base.appendingPathComponent("home") }
    var detector: VendorManagementDetector { VendorManagementDetector(rootDirectory: root, homeDirectory: home) }

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("vendor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: base) }

    func makeDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func makeApp(at folder: URL, name: String, plist: [String: Any] = [:]) throws -> URL {
        let appURL = folder.appendingPathComponent("\(name).app")
        try makeDir(appURL.appendingPathComponent("Contents"))
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: appURL.appendingPathComponent("Contents/Info.plist"))
        return appURL
    }

    func app(_ id: String, url: URL, appStore: Bool = false) -> InstalledApp {
        InstalledApp(bundleIdentifier: id, name: url.deletingPathExtension().lastPathComponent, url: url,
                     shortVersion: "1", buildVersion: nil, sparkleFeedURL: nil, isFromAppStore: appStore)
    }
}

@Suite("VendorManagementDetector")
struct VendorManagementDetectorTests {
    /// Compares by path: Foundation may add a trailing slash to directory URLs.
    func openedPath(_ management: VendorManagement) -> String? {
        guard case .application(let url) = management.openTarget else { return nil }
        return url.standardizedFileURL.path
    }

    @Test("Setapp folder, opens Setapp.app when present")
    func setappFolder() throws {
        let sys = try FakeSystem()
        let setappApp = try sys.makeApp(at: sys.root.appendingPathComponent("Applications"), name: "Setapp")
        let url = try sys.makeApp(at: sys.root.appendingPathComponent("Applications/Setapp"), name: "CleanShot X")
        let result = try #require(sys.detector.detect(sys.app("pl.maketheweb.cleanshotx", url: url)))
        #expect(result.vendor == .setapp)
        #expect(result.updaterName == "Setapp")
        #expect(openedPath(result) == setappApp.standardizedFileURL.path)
    }

    @Test("Setapp bundle suffix and Info.plist key hints")
    func setappHints() throws {
        let sys = try FakeSystem()
        let apps = sys.root.appendingPathComponent("Applications")
        let suffixed = try sys.makeApp(at: apps, name: "One")
        let keyed = try sys.makeApp(at: apps, name: "Two", plist: ["SetappAppID": "123"])
        let plain = try sys.makeApp(at: apps, name: "Three", plist: ["CFBundleName": "Three"])
        #expect(sys.detector.detect(sys.app("com.one.app-setapp", url: suffixed))?.vendor == .setapp)
        #expect(sys.detector.detect(sys.app("com.two.app", url: keyed))?.vendor == .setapp)
        #expect(sys.detector.detect(sys.app("com.three.app", url: plain)) == nil)
    }

    @Test("Adobe requires Creative Cloud to be installed")
    func adobe() throws {
        let sys = try FakeSystem()
        let url = try sys.makeApp(at: sys.root.appendingPathComponent("Applications"), name: "Photoshop")
        let photoshop = sys.app("com.adobe.Photoshop", url: url)
        #expect(sys.detector.detect(photoshop) == nil)
        try sys.makeDir(sys.root.appendingPathComponent("Library/Application Support/Adobe/Adobe Desktop Common"))
        let result = try #require(sys.detector.detect(photoshop))
        #expect(result.vendor == .adobeCreativeCloud)
        #expect(openedPath(result) == url.standardizedFileURL.path, "falls back to the app when no CC app exists")
    }

    @Test("Microsoft AutoUpdate when MAU2.0 exists, except self-updating VS Code")
    func microsoft() throws {
        let sys = try FakeSystem()
        let apps = sys.root.appendingPathComponent("Applications")
        let word = sys.app("com.microsoft.Word", url: try sys.makeApp(at: apps, name: "Microsoft Word"))
        let code = sys.app("com.microsoft.VSCode", url: try sys.makeApp(at: apps, name: "Visual Studio Code"))
        #expect(sys.detector.detect(word) == nil)
        let mau = sys.root.appendingPathComponent("Library/Application Support/Microsoft/MAU2.0")
        try sys.makeDir(mau.appendingPathComponent("Microsoft AutoUpdate.app"))
        let result = try #require(sys.detector.detect(word))
        #expect(result.vendor == .microsoftAutoUpdate)
        #expect(openedPath(result) == mau.appendingPathComponent("Microsoft AutoUpdate.app").standardizedFileURL.path)
        #expect(sys.detector.detect(code) == nil)
    }

    @Test("Google Keystone in the user's or system Library")
    func keystone() throws {
        let sys = try FakeSystem()
        let url = try sys.makeApp(at: sys.root.appendingPathComponent("Applications"), name: "Google Chrome")
        let chrome = sys.app("com.google.Chrome", url: url)
        #expect(sys.detector.detect(chrome) == nil)
        try sys.makeDir(sys.home.appendingPathComponent("Library/Google/GoogleSoftwareUpdate"))
        let result = try #require(sys.detector.detect(chrome))
        #expect(result.vendor == .googleKeystone)
        #expect(result.updaterName == "Google Software Update")
        #expect(sys.detector.detect(sys.app("com.google.android.studio", url: url)) == nil)
    }

    @Test("JetBrains Toolbox-managed IDEs")
    func toolbox() throws {
        let sys = try FakeSystem()
        let toolbox = try sys.makeApp(at: sys.home.appendingPathComponent("Applications"), name: "JetBrains Toolbox")
        let ide = try sys.makeApp(at: sys.home.appendingPathComponent("Applications/JetBrains Toolbox"), name: "IntelliJ IDEA")
        let result = try #require(sys.detector.detect(sys.app("com.jetbrains.intellij", url: ide)))
        #expect(result.vendor == .jetBrainsToolbox)
        #expect(openedPath(result) == toolbox.standardizedFileURL.path)
        #expect(sys.detector.detect(sys.app("com.jetbrains.toolbox", url: toolbox)) == nil)
    }

    @Test("App Store apps are never vendor-managed")
    func appStore() throws {
        let sys = try FakeSystem()
        try sys.makeDir(sys.root.appendingPathComponent("Library/Application Support/Microsoft/MAU2.0"))
        let url = try sys.makeApp(at: sys.root.appendingPathComponent("Applications"), name: "Microsoft Excel")
        #expect(sys.detector.detect(sys.app("com.microsoft.Excel", url: url, appStore: true)) == nil)
    }
}

@Suite("ResolvedInstallMethod")
struct ResolvedInstallMethodTests {
    static let management = VendorManagement(
        vendor: .setapp, updaterName: "Setapp", openTarget: .url(URL(string: "setapp://")!)
    )

    static func update(_ url: String, source: UpdateSourceKind = .sparkle) -> AvailableUpdate {
        AvailableUpdate(app: CoverageFixtures.app("com.x"), newVersion: "2", downloadURL: URL(string: url)!, source: source)
    }

    @Test("vendor management overrides regular install paths")
    func vendorWins() {
        let resolved = ResolvedInstallMethod(update: Self.update("https://x.com/a.dmg"), vendorManagement: Self.management)
        #expect(resolved == .vendorManaged(Self.management))
        #expect(resolved.standardMethod == nil)
        #expect(!resolved.isAutomatic)
    }

    @Test("without vendor management it mirrors InstallMethod")
    func standard() {
        #expect(InstallMethod.resolve(update: Self.update("https://x.com/a.pkg"), vendorManagement: nil) == .standard(.installerPackage))
        #expect(ResolvedInstallMethod(update: Self.update("https://x.com/a.zip"), vendorManagement: nil).isAutomatic)
    }

    @Test("App Store stays App Store")
    func appStore() {
        let update = Self.update("macappstore://x", source: .appStore)
        #expect(ResolvedInstallMethod(update: update, vendorManagement: Self.management) == .standard(.appStore))
    }
}
