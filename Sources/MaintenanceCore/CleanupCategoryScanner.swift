import Foundation

/// Finds the items of one `CleanupCategory`. Synchronous; callers run it off the main actor.
struct CleanupCategoryScanner: Sendable {
    // MARK: Constants

    /// Prefixes of cache folders that are never offered (system-managed or this app's own).
    private static let excludedCachePrefixes = ["com.apple.", "com.macappupdater"]
    /// Minimum length of the hash suffix Xcode appends to DerivedData folder names.
    private static let derivedDataHashMinimumLength = 10

    let locations: CleanupLocations
    let inspector: CleanupFileInspector
    let configuration: CleanupScanConfiguration
    let now: Date
    /// Nil when no app catalog is available; `.removedAppLeftovers` then finds nothing.
    var removedApps: RemovedAppLeftoverFinder?

    // MARK: Dispatch

    /// Items for `category`, unsorted. Throws `CancellationError` when the task is cancelled.
    func items(for category: CleanupCategory) throws -> [CleanupItem] {
        try Task.checkCancellation()
        switch category {
        case .userCaches: return try userCaches()
        case .logs: return try logs()
        case .xcodeDerivedData: return try derivedData()
        case .xcodeArchives: return try archives()
        case .deviceSupport: return try deviceSupport()
        case .simulatorCaches: return try childItems(of: locations.simulatorCaches, category: .simulatorCaches)
        case .packageManagerCaches: return try packageManagerCaches()
        case .trash: return try childItems(of: locations.trash, category: .trash)
        case .oldInstallers: return try oldInstallers()
        case .largeOldFiles: return try largeOldFiles()
        case .removedAppLeftovers: return try removedApps?.items() ?? []
        }
    }

    // MARK: Library categories

    private func userCaches() throws -> [CleanupItem] {
        let packageNames = locations.packageManagerCacheNamesInCaches
        return try inspector.children(of: locations.caches).compactMap { url in
            let name = url.lastPathComponent
            let lowered = name.lowercased()
            if Self.excludedCachePrefixes.contains(where: lowered.hasPrefix) || packageNames.contains(name) {
                return nil
            }
            return try makeItem(
                url, category: .userCaches, displayName: name,
                minimumSize: configuration.minimumCacheSize,
                owner: Self.looksLikeBundleIdentifier(name) ? name : nil
            )
        }
    }

    private func logs() throws -> [CleanupItem] {
        let reportsPath = locations.diagnosticReports.standardizedFileURL.path
        var items: [CleanupItem] = []
        for url in inspector.children(of: locations.logs) {
            if url.standardizedFileURL.path == reportsPath {
                items += try diagnosticReports()
            } else if let item = try makeItem(url, category: .logs) {
                items.append(item)
            }
        }
        return items
    }

    private func diagnosticReports() throws -> [CleanupItem] {
        let cutoff = now.addingTimeInterval(-configuration.diagnosticReportMinimumAge)
        return try inspector.children(of: locations.diagnosticReports).compactMap { url in
            guard inspector.isRegularFile(url), let modified = inspector.modificationDate(of: url),
                  modified < cutoff else { return nil }
            return try makeItem(url, category: .logs, displayName: "DiagnosticReports/\(url.lastPathComponent)")
        }
    }

    private func derivedData() throws -> [CleanupItem] {
        try inspector.children(of: locations.derivedData).compactMap { url in
            try makeItem(url, category: .xcodeDerivedData, displayName: Self.derivedDataName(url.lastPathComponent))
        }
    }

    private func archives() throws -> [CleanupItem] {
        try inspector.children(of: locations.archives).filter(inspector.isDirectory).flatMap { dateFolder in
            try inspector.children(of: dateFolder).compactMap { archive in
                try makeItem(archive, category: .xcodeArchives, displayName: archive.deletingPathExtension().lastPathComponent)
            }
        }
    }

    private func deviceSupport() throws -> [CleanupItem] {
        try CleanupLocations.deviceSupportFolders.flatMap { entry in
            try inspector.children(of: locations.xcode.appendingPathComponent(entry.folder)).compactMap { url in
                try makeItem(url, category: .deviceSupport, displayName: "\(entry.platform) — \(url.lastPathComponent)")
            }
        }
    }

    private func packageManagerCaches() throws -> [CleanupItem] {
        try CleanupLocations.packageManagerCaches.compactMap { cache in
            let url = locations.url(cache.relativePath)
            guard inspector.isDirectory(url) else { return nil }
            return try makeItem(url, category: .packageManagerCaches, displayName: cache.displayName)
        }
    }

    // MARK: Helpers

    /// One item per direct child of `directory`.
    func childItems(of directory: URL, category: CleanupCategory) throws -> [CleanupItem] {
        try inspector.children(of: directory).compactMap { try makeItem($0, category: category) }
    }

    /// Builds an item when `url` is inside home and at least `minimumSize` bytes (and not empty).
    func makeItem(
        _ url: URL,
        category: CleanupCategory,
        displayName: String? = nil,
        minimumSize: Int64 = 1,
        owner: String? = nil
    ) throws -> CleanupItem? {
        guard url.cleanupIsStrictlyInside(locations.home) else { return nil }
        let size = try inspector.allocatedSize(of: url)
        guard size >= max(minimumSize, 1) else { return nil }
        return CleanupItem(
            url: url,
            category: category,
            displayName: displayName ?? url.lastPathComponent,
            sizeInBytes: size,
            lastAccessed: inspector.lastAccessDate(of: url),
            ownerBundleIdentifier: owner
        )
    }

    /// Whether `name` has the reverse-DNS shape of a bundle identifier, e.g. `com.example.App`.
    static func looksLikeBundleIdentifier(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
    }

    /// "MyApp-abcdefghijklmnop" becomes "MyApp"; names without an Xcode hash are kept.
    static func derivedDataName(_ folderName: String) -> String {
        guard let dash = folderName.lastIndex(of: "-") else { return folderName }
        let hash = folderName[folderName.index(after: dash)...]
        let isHash = hash.count >= derivedDataHashMinimumLength && hash.allSatisfy { $0.isLowercase && $0.isLetter }
        return isHash && dash > folderName.startIndex ? String(folderName[..<dash]) : folderName
    }
}
