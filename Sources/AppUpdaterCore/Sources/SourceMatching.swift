import Foundation

/// Outcome of asking a source about one app.
public enum SourceLookup: Sendable, Hashable {
    /// The source does not know this app (no cask, no repository mapping, not handled).
    case notFound
    /// The source recognised the app and its latest release is not newer than the installed one.
    case upToDate(latestVersion: String)
    /// The source recognised the app and offers a newer release.
    case update(AvailableUpdate)

    public var update: AvailableUpdate? {
        guard case .update(let update) = self else { return nil }
        return update
    }

    public var isMatch: Bool { self != .notFound }
}

/// An `UpdateSource` that can distinguish "recognised & up to date" from "unknown app".
public protocol SourceMatching: UpdateSource {
    func lookup(_ app: InstalledApp) async throws -> SourceLookup
}
