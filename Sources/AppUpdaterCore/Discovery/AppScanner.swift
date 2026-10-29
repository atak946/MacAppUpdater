import Foundation
import os

/// Result of a scan: one app per bundle identifier, plus the bundles that lost the dedupe.
public struct AppScanResult: Sendable, Equatable {
    public let apps: [InstalledApp]
    /// Bundle identifier → other bundles on disk that claim the same identifier and were not chosen.
    public let duplicates: [String: [URL]]

    public init(apps: [InstalledApp], duplicates: [String: [URL]]) {
        self.apps = apps
        self.duplicates = duplicates
    }
}

/// Finds every bundle on disk that claims a bundle identifier (used to warn about look-alikes).
public protocol DuplicateBundleFinding: Sendable {
    func bundles(withIdentifier bundleIdentifier: String) async -> [URL]
}

/// Discovers installed `.app` bundles in a set of directories.
///
/// Each directory is scanned one level deep, plus one nested folder level
/// (e.g. /Applications/Utilities). Results are deduplicated by bundle identifier and sorted by name.
/// When several bundles claim the same identifier, the first one (in search order) with a valid
/// code signature and Team ID wins; if none is validly signed, the earliest one wins. Signatures are
/// only checked for such collisions, so a normal scan stays cheap.
public struct AppScanner: AppScanning, DuplicateBundleFinding {
    public let searchDirectories: [URL]
    private let reader: BundleInfoReader
    private let signatureVerifier: any SignatureVerifying

    private static let logger = Logger(subsystem: "com.macappupdater", category: "AppScanner")
    private static let appExtension = "app"

    public static var defaultSearchDirectories: [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    public init(
        searchDirectories: [URL] = AppScanner.defaultSearchDirectories,
        reader: BundleInfoReader = BundleInfoReader(),
        signatureVerifier: any SignatureVerifying = CodeSignatureVerifier()
    ) {
        self.searchDirectories = searchDirectories
        self.reader = reader
        self.signatureVerifier = signatureVerifier
    }

    public func scan() async throws -> [InstalledApp] {
        try await scanResult().apps
    }

    /// Like `scan()`, but also reports bundles that were dropped because of a duplicate identifier.
    public func scanResult() async throws -> AppScanResult {
        let candidates = try await readAllBundles()
        let groups = Dictionary(grouping: candidates, by: \.bundleIdentifier)
        var apps: [InstalledApp] = []
        var duplicates: [String: [URL]] = [:]

        for (identifier, group) in groups {
            try Task.checkCancellation()
            guard group.count > 1 else {
                apps.append(contentsOf: group)
                continue
            }
            let chosen = await preferredBundle(in: group)
            apps.append(chosen)
            duplicates[identifier] = group.filter { $0.url != chosen.url }.map(\.url)
            logDuplicates(identifier: identifier, chosen: chosen, all: group)
        }

        let sorted = apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return AppScanResult(apps: sorted, duplicates: duplicates)
    }

    public func bundles(withIdentifier bundleIdentifier: String) async -> [URL] {
        let candidates = (try? await readAllBundles()) ?? []
        return candidates.filter { $0.bundleIdentifier == bundleIdentifier }.map(\.url)
    }

    // MARK: Dedupe

    /// First bundle (search order) with a valid signature and Team ID, else the first bundle.
    private func preferredBundle(in group: [InstalledApp]) async -> InstalledApp {
        for app in group where await hasValidTeamSignature(app.url) {
            return app
        }
        return group[0]
    }

    private func hasValidTeamSignature(_ url: URL) async -> Bool {
        do {
            _ = try await signatureVerifier.teamIdentifier(of: url)
            return true
        } catch {
            return false
        }
    }

    private func logDuplicates(identifier: String, chosen: InstalledApp, all: [InstalledApp]) {
        let others = all.filter { $0.url != chosen.url }.map(\.url.path).joined(separator: ", ")
        Self.logger.notice(
            """
            Duplicate bundle id \(identifier, privacy: .public): using \
            \(chosen.url.lastPathComponent, privacy: .public) (\(chosen.url.path, privacy: .private)), \
            ignoring \(others, privacy: .private)
            """
        )
    }

    // MARK: Filesystem

    /// All readable bundles in search order (earlier directories first). Blocking work runs detached.
    private func readAllBundles() async throws -> [InstalledApp] {
        try await Task.detached(priority: .utility) { [self] in
            var apps: [InstalledApp] = []
            for directory in searchDirectories {
                try Task.checkCancellation()
                apps.append(contentsOf: appBundleURLs(in: directory).compactMap(readApp))
            }
            return apps
        }.value
    }

    /// `.app` bundles directly inside `directory`, plus those inside its plain subfolders.
    private func appBundleURLs(in directory: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            Self.logger.debug("Search directory does not exist: \(directory.path, privacy: .private)")
            return []
        }

        return contents(of: directory).flatMap { entry -> [URL] in
            if isAppBundle(entry) { return [entry] }
            guard isDirectory(entry) else { return [] }
            return contents(of: entry).filter(isAppBundle)
        }
    }

    private func readApp(at url: URL) -> InstalledApp? {
        do {
            return try reader.read(appAt: url)
        } catch {
            Self.logger.warning(
                """
                Skipping unreadable bundle \(url.lastPathComponent, privacy: .public) \
                (\(url.path, privacy: .private)): \(error.localizedDescription, privacy: .private)
                """
            )
            return nil
        }
    }

    private func contents(of directory: URL) -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            Self.logger.error(
                """
                Cannot list \(directory.lastPathComponent, privacy: .public) \
                (\(directory.path, privacy: .private)): \(error.localizedDescription, privacy: .private)
                """
            )
            return []
        }
    }

    private func isAppBundle(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == Self.appExtension && isDirectory(url)
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
