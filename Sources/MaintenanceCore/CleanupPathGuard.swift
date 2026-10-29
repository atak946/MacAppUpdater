import Foundation

/// Why a cleanup item was refused before touching the disk.
enum CleanupPathError: LocalizedError, Equatable {
    case outsideHome
    case homeDirectory
    case protectedFolder(String)
    case permanentDeletionOutsideTrash

    var errorDescription: String? {
        switch self {
        case .outsideHome: "The item is outside the home folder."
        case .homeDirectory: "The home folder itself cannot be removed."
        case .protectedFolder(let name): "The \(name) folder is protected and cannot be removed."
        case .permanentDeletionOutsideTrash: "Only items inside the Trash can be deleted permanently."
        }
    }
}

/// Validates that a URL is safe to remove: strictly inside home and not a protected top-level folder.
struct CleanupPathGuard: Sendable {
    private let home: URL
    private let homePath: String
    private let protectedPaths: [String: String]

    init(home: URL) {
        let locations = CleanupLocations(home: home)
        self.home = locations.home
        self.homePath = locations.home.cleanupCanonicalPath
        self.protectedPaths = Dictionary(uniqueKeysWithValues: CleanupLocations.protectedRelativePaths.map { relative in
            (locations.url(relative).cleanupCanonicalPath, relative)
        })
    }

    /// Throws a `CleanupPathError` when `url` must not be removed.
    func validate(_ url: URL) throws {
        let path = url.cleanupCanonicalPath
        if path == homePath { throw CleanupPathError.homeDirectory }
        guard url.cleanupIsStrictlyInside(home) else { throw CleanupPathError.outsideHome }
        if let name = protectedPaths[path] { throw CleanupPathError.protectedFolder(name) }
    }

    /// Throws unless `url` is safe and inside `~/.Trash`.
    func validatePermanentDeletion(_ url: URL) throws {
        try validate(url)
        guard url.cleanupIsStrictlyInside(CleanupLocations(home: home).trash) else {
            throw CleanupPathError.permanentDeletionOutsideTrash
        }
    }
}
