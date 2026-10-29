import Foundation
import os

/// Locates `MacAppUpdater_AppUpdaterCore.bundle` without the SPM-generated `Bundle.module`,
/// which calls `fatalError` when the bundle is missing (e.g. a packaging mistake).
/// Searches the same places SPM does, plus the executable's directory, and returns nil instead of trapping.
enum CoreResourceBundle {
    static let bundleName = "MacAppUpdater_AppUpdaterCore.bundle"
    private static let logger = Logger(subsystem: "com.macappupdater", category: "Resources")

    private final class BundleFinder {}

    /// Cached: the lookup touches the file system.
    static let bundle: Bundle? = locate()

    static func locate(candidates: [URL] = defaultCandidates()) -> Bundle? {
        for directory in candidates {
            let url = directory.appendingPathComponent(bundleName, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path), let bundle = Bundle(url: url) {
                logger.debug("Core resources at \(url.path, privacy: .public)")
                return bundle
            }
        }
        logger.error("\(bundleName, privacy: .public) not found; bundled resources are unavailable")
        return nil
    }

    static func url(forResource name: String, withExtension ext: String) -> URL? {
        bundle?.url(forResource: name, withExtension: ext)
    }

    static func defaultCandidates() -> [URL] {
        let override = environmentOverride(ProcessInfo.processInfo.environment)
        let finder = Bundle(for: BundleFinder.self)
        let candidates: [URL?] = [
            override,
            // Inside AppUpdater.app: Contents/Resources.
            Bundle.main.resourceURL,
            finder.resourceURL,
            // Command-line builds (.build/debug) and test bundles: next to the binary.
            Bundle.main.bundleURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
            finder.bundleURL.deletingLastPathComponent(),
        ]
        return candidates.compactMap { $0 }
    }

    /// `PACKAGE_RESOURCE_BUNDLE_PATH` is a development aid only: in release builds (the app
    /// and the root helper) it would let the environment swap `vendor-feeds.json`.
    static func environmentOverride(_ environment: [String: String]) -> URL? {
        #if DEBUG
        environment["PACKAGE_RESOURCE_BUNDLE_PATH"].map { URL(fileURLWithPath: $0) }
        #else
        nil
        #endif
    }
}
