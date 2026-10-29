import Foundation
import os

/// A file or folder that belongs to an app and can be moved to the Trash.
public struct LeftoverItem: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case appBundle, applicationSupport, caches, preferences, byHostPreferences, container
        case groupContainer, savedState, logs, httpStorage, webKit, cookies, launchAgent

        public var displayName: String {
            switch self {
            case .appBundle: String(coreLocalized: "Application")
            case .applicationSupport: String(coreLocalized: "Application Support")
            case .caches: String(coreLocalized: "Caches")
            case .preferences: String(coreLocalized: "Preferences")
            case .byHostPreferences: String(coreLocalized: "Preferences (ByHost)")
            case .container: String(coreLocalized: "Sandbox Container")
            case .groupContainer: String(coreLocalized: "Group Container")
            case .savedState: String(coreLocalized: "Saved Window State")
            case .logs: String(coreLocalized: "Logs")
            case .httpStorage: String(coreLocalized: "HTTP Storage")
            case .webKit: String(coreLocalized: "WebKit Data")
            case .cookies: String(coreLocalized: "Cookies")
            case .launchAgent: String(coreLocalized: "Launch Agent")
            }
        }
    }

    public enum Confidence: String, Sendable, Hashable {
        /// Named exactly after the bundle identifier.
        case exact
        /// Named after the app's display name (or a team-prefixed group); verify before trashing.
        case possible
    }

    public var id: URL { url }
    public let url: URL
    public let kind: Kind
    public let sizeInBytes: Int64
    public let confidence: Confidence

    public init(url: URL, kind: Kind, sizeInBytes: Int64, confidence: Confidence) {
        self.url = url
        self.kind = kind
        self.sizeInBytes = sizeInBytes
        self.confidence = confidence
    }
}

/// Finds an app's leftovers inside a fixed allowlist of `~/Library` subfolders.
///
/// Matching is exact (bundle identifier, or app name for a few folders marked `.possible`);
/// substrings and prefixes never match. Symbolic links are never reported.
public struct LeftoverScanner: Sendable {
    public let homeDirectory: URL
    private static let logger = Logger(subsystem: "com.macappupdater", category: "LeftoverScanner")

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    var libraryURL: URL { homeDirectory.appendingPathComponent("Library", isDirectory: true) }

    /// Dry run: every existing, allowlisted leftover for the app, with sizes. Never modifies anything.
    public func scan(bundleIdentifier: String, appName: String) -> [LeftoverItem] {
        guard LeftoverRules.isSafeComponent(bundleIdentifier) else {
            Self.logger.warning("Refusing to scan for unsafe bundle id \(bundleIdentifier, privacy: .public)")
            return []
        }
        let candidates = candidateURLs(bundleIdentifier: bundleIdentifier, appName: appName)
        var seen = Set<String>()
        return candidates.compactMap { url in
            guard seen.insert(url.path).inserted else { return nil }
            return try? validate(url, bundleIdentifier: bundleIdentifier, appName: appName)
        }
    }

    /// Re-checks a single path right before trashing: must exist, sit directly inside an allowlisted
    /// folder, match a rule for that folder and not be (or resolve through) a symlink.
    public func validate(
        _ url: URL,
        bundleIdentifier: String,
        appName: String
    ) throws(UninstallError) -> LeftoverItem {
        let url = url.standardizedFileURL
        let name = url.lastPathComponent
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard LeftoverRules.isSafeComponent(bundleIdentifier),
              let folder = LeftoverRules.Folder.allCases.first(where: { folderURL($0).path == parent.path }),
              let match = LeftoverRules.match(name: name, in: folder, bundleIdentifier: bundleIdentifier, appName: appName)
        else { throw .outsideAllowlist(url) }

        guard (try? url.checkResourceIsReachable()) == true || isSymlink(url) else { throw .itemMissing(url) }
        try checkNoSymlinkEscape(url, folder: folder)

        if match.kind == .launchAgent, !LeftoverRules.launchAgentLabel(at: url, equals: bundleIdentifier) {
            throw .outsideAllowlist(url)
        }
        return LeftoverItem(url: url, kind: match.kind, sizeInBytes: Self.size(of: url), confidence: match.confidence)
    }

    // MARK: Candidates

    private func candidateURLs(bundleIdentifier id: String, appName: String) -> [URL] {
        let direct = LeftoverRules.Folder.allCases.flatMap { folder in
            LeftoverRules.directNames(in: folder, bundleIdentifier: id, appName: appName)
                .map { folderURL(folder).appendingPathComponent($0) }
        }
        let listed = LeftoverRules.Folder.allCases.filter(\.requiresListing).flatMap { folder in
            listing(of: folderURL(folder))
        }
        return direct + listed
    }

    func listing(of folder: URL) -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        } catch {
            Self.logger.debug(
                """
                Cannot list \(folder.lastPathComponent, privacy: .public) \
                (\(folder.path, privacy: .private)): \(error.localizedDescription, privacy: .private)
                """
            )
            return []
        }
    }

    func folderURL(_ folder: LeftoverRules.Folder) -> URL {
        libraryURL.appendingPathComponent(folder.rawValue, isDirectory: true).standardizedFileURL
    }

    // MARK: Safety

    private func checkNoSymlinkEscape(_ url: URL, folder: LeftoverRules.Folder) throws(UninstallError) {
        if isSymlink(url) { throw .symlinkEscape(url) }
        let resolvedLibrary = libraryURL.resolvingSymlinksInPath().path
        let resolvedFolder = folderURL(folder).resolvingSymlinksInPath().path
        let resolvedItem = url.resolvingSymlinksInPath()
        guard resolvedFolder.hasPrefix(resolvedLibrary + "/"),
              resolvedItem.deletingLastPathComponent().path == resolvedFolder,
              resolvedItem.lastPathComponent == url.lastPathComponent
        else { throw .symlinkEscape(url) }
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    /// Allocated size of a file, or the sum over a folder (symlinks are not followed).
    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey, .isDirectoryKey]
        let values = try? url.resourceValues(forKeys: keys)
        guard values?.isDirectory == true else {
            return Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else {
            return 0
        }
        return enumerator.compactMap { $0 as? URL }.reduce(Int64(0)) { total, fileURL in
            let fileValues = try? fileURL.resourceValues(forKeys: keys)
            guard fileValues?.isRegularFile == true else { return total }
            return total + Int64(fileValues?.totalFileAllocatedSize ?? fileValues?.fileSize ?? 0)
        }
    }
}
