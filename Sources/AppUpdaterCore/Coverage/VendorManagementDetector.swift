import Foundation

/// Detects apps whose updates are owned by a vendor tool. Pure rules plus `fileExists` / Info.plist
/// reads; `rootDirectory` and `homeDirectory` are injectable so tests can use fake directory trees.
public struct VendorManagementDetector: Sendable {
    public let rootDirectory: URL
    public let homeDirectory: URL

    /// Microsoft apps that update themselves instead of through MAU.
    static let microsoftSelfUpdating: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
    ]
    /// Google apps kept current by Keystone (Google Software Update).
    static let keystoneBundlePrefixes = ["com.google.Chrome", "com.google.drivefs", "com.google.EarthPro"]

    public init(
        rootDirectory: URL = URL(fileURLWithPath: "/"),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.rootDirectory = rootDirectory
        self.homeDirectory = homeDirectory
    }

    /// Nil when the app is not vendor-managed (App Store apps are never reported here).
    public func detect(_ app: InstalledApp) -> VendorManagement? {
        guard !app.isFromAppStore else { return nil }
        let rules: [(InstalledApp) -> VendorManagement?] = [
            setapp, jetBrainsToolbox, adobeCreativeCloud, microsoftAutoUpdate, googleKeystone,
        ]
        for rule in rules {
            if let management = rule(app) { return management }
        }
        return nil
    }

    // MARK: Rules

    private func setapp(_ app: InstalledApp) -> VendorManagement? {
        let inSetappFolder = Self.isPath(app.url, under: root("Applications/Setapp"))
        let bundleHint = app.bundleIdentifier.lowercased().hasSuffix("-setapp")
        guard inSetappFolder || bundleHint || Self.hasSetappPlistKey(app.url) else { return nil }
        return management(.setapp, updater: [root("Applications/Setapp.app")], app: app)
    }

    private func jetBrainsToolbox(_ app: InstalledApp) -> VendorManagement? {
        guard Self.isPath(app.url, under: home("Applications/JetBrains Toolbox")) else { return nil }
        let updaters = [home("Applications/JetBrains Toolbox.app"), root("Applications/JetBrains Toolbox.app")]
        return management(.jetBrainsToolbox, updater: updaters, app: app)
    }

    private func adobeCreativeCloud(_ app: InstalledApp) -> VendorManagement? {
        guard app.bundleIdentifier.hasPrefix("com.adobe.") else { return nil }
        let updaters = [
            root("Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app"),
            root("Applications/Adobe Creative Cloud/Adobe Creative Cloud.app"),
        ]
        let markers = updaters + [root("Library/Application Support/Adobe/Adobe Desktop Common")]
        guard markers.contains(where: Self.exists) else { return nil }
        return management(.adobeCreativeCloud, updater: updaters, app: app)
    }

    private func microsoftAutoUpdate(_ app: InstalledApp) -> VendorManagement? {
        guard app.bundleIdentifier.hasPrefix("com.microsoft."),
              !Self.microsoftSelfUpdating.contains(app.bundleIdentifier) else { return nil }
        let mauFolder = root("Library/Application Support/Microsoft/MAU2.0")
        guard Self.exists(mauFolder) else { return nil }
        let updater = mauFolder.appendingPathComponent("Microsoft AutoUpdate.app")
        return management(.microsoftAutoUpdate, updater: [updater], app: app)
    }

    private func googleKeystone(_ app: InstalledApp) -> VendorManagement? {
        guard Self.keystoneBundlePrefixes.contains(where: { app.bundleIdentifier.hasPrefix($0) }) else { return nil }
        let keystone = [home("Library/Google/GoogleSoftwareUpdate"), root("Library/Google/GoogleSoftwareUpdate")]
        guard keystone.contains(where: Self.exists) else { return nil }
        // Keystone has no UI of its own; the app's About window triggers the check.
        return VendorManagement(
            vendor: .googleKeystone, updaterName: VendorManagement.Vendor.googleKeystone.updaterName,
            openTarget: .application(app.url)
        )
    }

    // MARK: Helpers

    /// Opens the first updater that exists, otherwise the managed app itself.
    private func management(_ vendor: VendorManagement.Vendor, updater: [URL], app: InstalledApp) -> VendorManagement {
        let target = updater.first(where: Self.exists) ?? app.url
        return VendorManagement(vendor: vendor, updaterName: vendor.updaterName, openTarget: .application(target))
    }

    private func root(_ relative: String) -> URL { rootDirectory.appendingPathComponent(relative) }
    private func home(_ relative: String) -> URL { homeDirectory.appendingPathComponent(relative) }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func isPath(_ url: URL, under folder: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    /// Setapp builds carry Setapp-specific Info.plist keys (e.g. `SetappApp`, `SetappAppID`).
    static func hasSetappPlistKey(_ appURL: URL) -> Bool {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        return plist.keys.contains { $0.lowercased().hasPrefix("setapp") }
    }
}
