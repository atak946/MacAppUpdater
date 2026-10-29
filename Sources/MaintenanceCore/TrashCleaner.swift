import Foundation
import os

/// Performs the actual removal of a file or folder. Injected so tests never touch the real Trash.
public protocol CleanupItemRemoving: Sendable {
    /// Moves `url` to the user's Trash (recoverable).
    func moveToTrash(_ url: URL) throws
    /// Deletes `url` permanently.
    func removePermanently(_ url: URL) throws
}

/// `FileManager`-backed remover used in production.
public struct FileManagerItemRemover: CleanupItemRemoving, @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func moveToTrash(_ url: URL) throws {
        try fileManager.trashItem(at: url, resultingItemURL: nil)
    }

    public func removePermanently(_ url: URL) throws {
        try fileManager.removeItem(at: url)
    }
}

/// Moves cleanup items to the Trash; items of the `.trash` category are deleted permanently.
public struct TrashCleaner: CleanupPerforming {
    // MARK: Dependencies

    private static let logger = Logger(subsystem: "com.macappupdater", category: "TrashCleaner")

    private let pathGuard: CleanupPathGuard
    private let remover: any CleanupItemRemoving

    /// Creates a cleaner. Defaults operate on the current user's home with `FileManager`.
    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        remover: any CleanupItemRemoving = FileManagerItemRemover()
    ) {
        self.pathGuard = CleanupPathGuard(home: homeDirectory)
        self.remover = remover
    }

    // MARK: CleanupPerforming

    /// Removes each item independently, collecting failures instead of stopping.
    public func clean(_ items: [CleanupItem]) async -> CleanupResult {
        var removed: [CleanupItem] = []
        var failed: [CleanupFailure] = []
        for item in items {
            do {
                try remove(item)
                removed.append(item)
            } catch {
                Self.logger.error("Cleanup failed for \(item.url.path, privacy: .private): \(error.localizedDescription, privacy: .public)")
                failed.append(CleanupFailure(item: item, reason: error.localizedDescription))
            }
        }
        Self.logger.info("Cleanup removed \(removed.count) items, \(failed.count) failed")
        return CleanupResult(removed: removed, failed: failed)
    }

    // MARK: Helpers

    private func remove(_ item: CleanupItem) throws {
        if item.category == .trash {
            try pathGuard.validatePermanentDeletion(item.url)
            try remover.removePermanently(item.url)
        } else {
            try pathGuard.validate(item.url)
            try remover.moveToTrash(item.url)
        }
    }
}
