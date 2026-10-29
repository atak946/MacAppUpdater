import Foundation

/// Synchronous file-system helpers used by the category scanners. Never follows symbolic links.
struct CleanupFileInspector: @unchecked Sendable {
    // MARK: Constants

    /// How many enumerated entries between cancellation checks.
    private static let cancellationCheckInterval = 512
    /// Finder metadata files that are never reported.
    private static let ignoredNames: Set<String> = [".DS_Store", ".localized"]

    static let sizeKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]

    let fileManager: FileManager

    // MARK: Listing

    /// Direct children of `directory`, excluding symlinks and Finder metadata. Empty when unreadable.
    func children(of directory: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey]
        guard let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else {
            return []
        }
        return urls
            .filter { !Self.ignoredNames.contains($0.lastPathComponent) && !isSymbolicLink($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Whether `url` exists as a directory (symlinks are not followed).
    func isDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    /// Whether `url` is a regular file (not a folder, package or symlink).
    func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    // MARK: Dates

    func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Last access date, falling back to the modification date.
    func lastAccessDate(of url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey])
        return values?.contentAccessDate ?? values?.contentModificationDate
    }

    // MARK: Sizes

    /// Allocated size of a file, or of a folder and everything inside it.
    func allocatedSize(of url: URL) throws -> Int64 {
        guard let values = try? url.resourceValues(forKeys: Self.sizeKeys) else { return 0 }
        if values.isSymbolicLink == true { return 0 }
        if values.isRegularFile == true { return Self.size(from: values) }
        return try directorySize(of: url)
    }

    private func directorySize(of directory: URL) throws -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(Self.sizeKeys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }
        var total: Int64 = 0
        var visited = 0
        while let url = enumerator.nextObject() as? URL {
            visited += 1
            if visited % Self.cancellationCheckInterval == 0 { try Task.checkCancellation() }
            guard let values = try? url.resourceValues(forKeys: Self.sizeKeys),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            total += Self.size(from: values)
        }
        return total
    }

    private static func size(from values: URLResourceValues) -> Int64 {
        Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }
}

// MARK: - Path containment

extension URL {
    /// Absolute path with `..`, `.` and symlinks in the parent folders resolved; the last component is kept as is.
    var cleanupCanonicalPath: String {
        let standardized = standardizedFileURL
        let name = standardized.lastPathComponent
        let parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
        if standardized.path == "/" { return "/" }
        return parent.appendingPathComponent(name).path
    }

    /// Whether this URL is strictly inside `directory` (never equal to it).
    func cleanupIsStrictlyInside(_ directory: URL) -> Bool {
        let base = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return cleanupCanonicalPath.hasPrefix(prefix)
    }
}
