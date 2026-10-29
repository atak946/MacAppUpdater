import Foundation
@testable import MaintenanceCore

// MARK: - Fake home

/// A throwaway home directory in the temporary folder, removed on deinit.
final class FakeHome {
    static let megabyte = Int(CleanupScanConfiguration.megabyte)
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    let url: URL
    private let fileManager = FileManager.default

    init() throws {
        url = fileManager.temporaryDirectory
            .appendingPathComponent("MaintenanceCoreTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? fileManager.removeItem(at: url)
    }

    /// Writes a file of `bytes` zero bytes at `relativePath`, creating parent folders.
    @discardableResult
    func file(_ relativePath: String, bytes: Int = 16, ageInDays: Double? = nil) throws -> URL {
        let fileURL = url.appendingPathComponent(relativePath)
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: fileURL)
        if let ageInDays { try setAge(fileURL, days: ageInDays) }
        return fileURL
    }

    /// Creates an empty folder at `relativePath`.
    @discardableResult
    func folder(_ relativePath: String) throws -> URL {
        let folderURL = url.appendingPathComponent(relativePath, isDirectory: true)
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        return folderURL
    }

    /// Sets both the modification and access dates to `days` before `FakeHome.now`.
    func setAge(_ fileURL: URL, days: Double) throws {
        var values = URLResourceValues()
        let date = Self.now.addingTimeInterval(-days * CleanupScanConfiguration.day)
        values.contentModificationDate = date
        values.contentAccessDate = date
        var mutableURL = fileURL
        try mutableURL.setResourceValues(values)
    }

    /// A scanner rooted at this home with a fixed clock.
    func scanner(configuration: CleanupScanConfiguration = CleanupScanConfiguration()) -> FileSystemCleanupScanner {
        FileSystemCleanupScanner(homeDirectory: url, configuration: configuration, now: { FakeHome.now })
    }

    /// Scans `categories` and returns the report.
    func scan(
        _ categories: Set<CleanupCategory>,
        configuration: CleanupScanConfiguration = CleanupScanConfiguration()
    ) async throws -> CleanupScanReport {
        try await scanner(configuration: configuration).scan(categories: categories) { _ in }
    }
}

extension CleanupScanReport {
    /// Items of `category`, or an empty array when the group was omitted.
    func items(_ category: CleanupCategory) -> [CleanupItem] {
        groups.first { $0.category == category }?.items ?? []
    }

    /// Last path components of the items of `category`.
    func names(_ category: CleanupCategory) -> [String] {
        items(category).map(\.url.lastPathComponent)
    }
}

// MARK: - Recording remover

/// Records removal calls instead of touching the disk; can be told to fail.
final class RecordingRemover: CleanupItemRemoving, @unchecked Sendable {
    struct Failure: LocalizedError {
        var errorDescription: String? { "Simulated failure" }
    }

    private let lock = NSLock()
    private var trashedURLs: [URL] = []
    private var deletedURLs: [URL] = []
    private let failingNames: Set<String>

    init(failingNames: Set<String> = []) {
        self.failingNames = failingNames
    }

    var trashed: [URL] { lock.withLock { trashedURLs } }
    var deleted: [URL] { lock.withLock { deletedURLs } }

    func moveToTrash(_ url: URL) throws {
        if failingNames.contains(url.lastPathComponent) { throw Failure() }
        lock.withLock { trashedURLs.append(url) }
    }

    func removePermanently(_ url: URL) throws {
        if failingNames.contains(url.lastPathComponent) { throw Failure() }
        lock.withLock { deletedURLs.append(url) }
    }
}
