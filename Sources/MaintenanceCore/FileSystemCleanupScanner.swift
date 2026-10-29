import Foundation
import os

/// Scans the user's home for reclaimable space, one category at a time, off the main actor.
public struct FileSystemCleanupScanner: CleanupScanning, @unchecked Sendable {
    // MARK: Dependencies

    private static let logger = Logger(subsystem: "com.macappupdater", category: "CleanupScanner")

    private let homeDirectory: URL
    private let fileManager: FileManager
    private let configuration: CleanupScanConfiguration
    private let now: @Sendable () -> Date
    private let installedApps: (any InstalledAppCataloging)?

    /// Creates a scanner. Defaults scan the current user's real home with production thresholds.
    /// Without `installedApps`, `.removedAppLeftovers` finds nothing: an unknown app list must never
    /// make everything look orphaned.
    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        configuration: CleanupScanConfiguration = CleanupScanConfiguration(),
        now: @escaping @Sendable () -> Date = { Date() },
        installedApps: (any InstalledAppCataloging)? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        self.configuration = configuration
        self.now = now
        self.installedApps = installedApps
    }

    // MARK: CleanupScanning

    /// Scans `categories` in a stable order, reporting progress after each one.
    public func scan(
        categories: Set<CleanupCategory>,
        progress: @escaping @Sendable (CleanupScanProgress) -> Void
    ) async throws -> CleanupScanReport {
        let ordered = CleanupCategory.allCases.filter(categories.contains)
        var scanner = makeCategoryScanner()
        if categories.contains(.removedAppLeftovers) {
            scanner.removedApps = try await makeRemovedAppFinder(inspector: scanner.inspector)
        }
        var groups: [CleanupGroup] = []
        var seenPaths = Set<String>()
        for (index, category) in ordered.enumerated() {
            let found = try await Self.scanOffActor(category, with: scanner)
            let unique = found.filter { seenPaths.insert($0.url.cleanupCanonicalPath).inserted }
            if let group = Self.makeGroup(category, items: unique) { groups.append(group) }
            progress(CleanupScanProgress(category: category, fractionCompleted: Double(index + 1) / Double(ordered.count)))
        }
        let report = CleanupScanReport(groups: Self.sortedGroups(groups), scannedAt: now())
        Self.logger.info("Cleanup scan found \(report.totalSize, privacy: .public) bytes in \(groups.count) groups")
        return report
    }

    // MARK: Helpers

    private func makeCategoryScanner() -> CleanupCategoryScanner {
        CleanupCategoryScanner(
            locations: CleanupLocations(home: homeDirectory),
            inspector: CleanupFileInspector(fileManager: fileManager),
            configuration: configuration,
            now: now()
        )
    }

    /// Nil (category skipped) when there is no catalog, it fails, or it lists no installed app at all.
    private func makeRemovedAppFinder(inspector: CleanupFileInspector) async throws -> RemovedAppLeftoverFinder? {
        guard let installedApps else { return nil }
        let snapshot: InstalledAppSnapshot
        do {
            snapshot = try await installedApps.snapshot()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.logger.error("Skipping removed-app leftovers: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard !snapshot.installedBundleIdentifiers.isEmpty else {
            Self.logger.notice("Skipping removed-app leftovers: no installed apps found")
            return nil
        }
        return RemovedAppLeftoverFinder(home: homeDirectory, snapshot: snapshot, catalog: installedApps, inspector: inspector)
    }

    /// Runs the blocking file work on the concurrent executor, never on the caller's actor.
    @concurrent
    private static func scanOffActor(
        _ category: CleanupCategory,
        with scanner: CleanupCategoryScanner
    ) async throws -> [CleanupItem] {
        try Task.checkCancellation()
        let items = try scanner.items(for: category)
        try Task.checkCancellation()
        return items
    }

    /// A group with items sorted by size (largest first), or `nil` when empty.
    static func makeGroup(_ category: CleanupCategory, items: [CleanupItem]) -> CleanupGroup? {
        guard !items.isEmpty else { return nil }
        let sorted = items.sorted { lhs, rhs in
            lhs.sizeInBytes != rhs.sizeInBytes ? lhs.sizeInBytes > rhs.sizeInBytes : lhs.displayName < rhs.displayName
        }
        return CleanupGroup(category: category, items: sorted)
    }

    /// Groups ordered by total size, largest first.
    static func sortedGroups(_ groups: [CleanupGroup]) -> [CleanupGroup] {
        groups.sorted { $0.totalSize > $1.totalSize }
    }
}
