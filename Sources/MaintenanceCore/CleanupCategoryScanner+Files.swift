import Foundation

// MARK: - Downloads and home-folder categories

extension CleanupCategoryScanner {
    /// File extensions treated as installers or disk images.
    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "zip", "xip", "iso"]
    /// How many visited entries between cancellation checks during the home walk.
    private static let walkCancellationInterval = 256

    /// Installers directly inside `~/Downloads` older than the installer age threshold.
    func oldInstallers() throws -> [CleanupItem] {
        let cutoff = now.addingTimeInterval(-configuration.installerMinimumAge)
        return try inspector.children(of: locations.downloads).compactMap { url in
            guard Self.installerExtensions.contains(url.pathExtension.lowercased()),
                  inspector.isRegularFile(url),
                  let modified = inspector.modificationDate(of: url), modified < cutoff else { return nil }
            return try makeItem(url, category: .oldInstallers)
        }
    }

    /// Big files under home (outside Library, hidden folders and packages) not opened for a long time.
    func largeOldFiles() throws -> [CleanupItem] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .contentAccessDateKey, .contentModificationDateKey,
        ]
        guard let enumerator = inspector.fileManager.enumerator(
            at: locations.home,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }
        return try walk(enumerator, keys: Set(keys))
    }

    private func walk(_ enumerator: FileManager.DirectoryEnumerator, keys: Set<URLResourceKey>) throws -> [CleanupItem] {
        let libraryPath = locations.library.resolvingSymlinksInPath().standardizedFileURL.path
        let cutoff = now.addingTimeInterval(-configuration.largeFileMinimumIdleAge)
        var items: [CleanupItem] = []
        var visited = 0
        while let url = enumerator.nextObject() as? URL {
            visited += 1
            if visited % Self.walkCancellationInterval == 0 { try Task.checkCancellation() }
            if visited > configuration.largeFileMaximumVisitedEntries { break }
            if enumerator.level >= configuration.largeFileMaximumDepth { enumerator.skipDescendants() }
            if url.resolvingSymlinksInPath().standardizedFileURL.path == libraryPath {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if let item = try largeOldItem(url, values: values, cutoff: cutoff) { items.append(item) }
        }
        return items
    }

    private func largeOldItem(_ url: URL, values: URLResourceValues, cutoff: Date) throws -> CleanupItem? {
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.isPackage != true,
              url.pathExtension.lowercased() != "app" else { return nil }
        guard let accessed = values.contentAccessDate ?? values.contentModificationDate, accessed < cutoff else {
            return nil
        }
        return try makeItem(url, category: .largeOldFiles, minimumSize: configuration.largeFileMinimumSize)
    }
}
