import Foundation

/// Finds the cask token and App Store ID of installed apps for an export.
public protocol MigrationResolving: Sendable {
    func caskToken(for app: InstalledApp) async -> String?
    func appStoreID(for app: InstalledApp) async -> Int?
}

extension MigrationResolving {
    /// One entry per app, in the given order. Lookups run concurrently; a failed lookup
    /// only means the app is exported without that mapping.
    public func entries(for apps: [InstalledApp]) async -> [MigrationEntry] {
        await withTaskGroup(of: (Int, MigrationEntry).self) { group in
            for (index, app) in apps.enumerated() {
                group.addTask {
                    let token = app.isFromAppStore ? nil : await caskToken(for: app)
                    let storeID = app.isFromAppStore ? await appStoreID(for: app) : nil
                    return (index, MigrationEntry(app: app, caskToken: token, appStoreID: storeID))
                }
            }
            var results: [(Int, MigrationEntry)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Cask tokens of the installed apps, used to tell which imported casks are already here.
    public func installedCaskTokens(for apps: [InstalledApp]) async -> Set<String> {
        Set(await entries(for: apps.filter { !$0.isFromAppStore }).compactMap(\.caskToken))
    }
}

/// Uses the same Homebrew cask index and App Store lookup as the update check.
public struct LiveMigrationResolver: MigrationResolving {
    private let caskSource: HomebrewCaskSource
    private let appStoreSource: AppStoreSource

    public init(caskSource: HomebrewCaskSource, appStoreSource: AppStoreSource) {
        self.caskSource = caskSource
        self.appStoreSource = appStoreSource
    }

    public func caskToken(for app: InstalledApp) async -> String? {
        try? await caskSource.caskToken(for: app)
    }

    public func appStoreID(for app: InstalledApp) async -> Int? {
        try? await appStoreSource.appStoreID(for: app)
    }
}
