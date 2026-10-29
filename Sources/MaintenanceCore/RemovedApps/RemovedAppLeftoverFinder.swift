import AppUpdaterCore
import Foundation

/// Finds `~/Library` data of apps that are no longer installed (`.removedAppLeftovers`).
///
/// Candidates come from the uninstaller's allowlist (`LeftoverScanner.bundleNamedEntries`), then
/// pass three gates: `RemovedAppLeftoverPolicy` (nothing installed, running or related owns the id),
/// `CleanupPathGuard`, and `LeftoverScanner.validate` (exact name rule, no symlinks, launch agent label).
struct RemovedAppLeftoverFinder: Sendable {
    let leftoverScanner: LeftoverScanner
    let pathGuard: CleanupPathGuard
    let policy: RemovedAppLeftoverPolicy
    let inspector: CleanupFileInspector

    init(home: URL, snapshot: InstalledAppSnapshot, catalog: any InstalledAppCataloging, inspector: CleanupFileInspector) {
        leftoverScanner = LeftoverScanner(homeDirectory: home)
        pathGuard = CleanupPathGuard(home: home)
        policy = RemovedAppLeftoverPolicy(snapshot: snapshot) { catalog.isKnownToLaunchServices($0) }
        self.inspector = inspector
    }

    /// Items owned by removed apps, unsorted. Throws `CancellationError` when the task is cancelled.
    func items() throws -> [CleanupItem] {
        try leftoverScanner.bundleNamedEntries().compactMap { entry in
            try Task.checkCancellation()
            return item(for: entry)
        }
    }

    private func item(for entry: BundleNamedEntry) -> CleanupItem? {
        guard policy.skipReason(bundleIdentifier: entry.bundleIdentifier, team: entry.teamIdentifier) == nil,
              (try? pathGuard.validate(entry.url)) != nil,
              // Empty app name: only exact bundle-identifier rules apply, never a display-name match.
              let leftover = try? leftoverScanner.validate(entry.url, bundleIdentifier: entry.bundleIdentifier, appName: ""),
              leftover.sizeInBytes > 0
        else { return nil }
        return CleanupItem(
            url: leftover.url,
            category: .removedAppLeftovers,
            displayName: "\(leftover.kind.displayName) — \(leftover.url.lastPathComponent)",
            sizeInBytes: leftover.sizeInBytes,
            lastAccessed: inspector.lastAccessDate(of: leftover.url),
            ownerBundleIdentifier: entry.bundleIdentifier,
            lastModified: inspector.modificationDate(of: leftover.url)
        )
    }
}
