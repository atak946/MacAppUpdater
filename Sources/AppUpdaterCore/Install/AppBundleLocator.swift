import Foundation

/// Finds an `.app` bundle inside an extracted archive or mounted image and reads its metadata.
struct AppBundleLocator: Sendable {
    /// How many directory levels below the root to search (zips often wrap the app in a folder).
    private static let maxDepth = 2

    /// Returns the app matching `bundleIdentifier`, falling back to `preferredName`,
    /// then to the only app found.
    func locateApp(in directory: URL, bundleIdentifier: String, preferredName: String) throws -> URL {
        let candidates = findApps(in: directory, depth: 0)
        if let match = candidates.first(where: { Self.bundleIdentifier(of: $0) == bundleIdentifier }) {
            return match
        }
        if let match = candidates.first(where: { $0.lastPathComponent == preferredName }) {
            return match
        }
        if candidates.count == 1, let only = candidates.first {
            return only
        }
        throw UpdaterError.installFailed("No matching .app bundle found in package")
    }

    private func findApps(in directory: URL, depth: Int) -> [URL] {
        let listing = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )) ?? []
        // Keep Finder-hidden bundles (Parallels ships its app with the hidden flag set),
        // but skip dot-files such as `.Trashes` or `.background`.
        let entries = listing.filter { !$0.lastPathComponent.hasPrefix(".") }

        let apps = entries.filter { $0.pathExtension.lowercased() == "app" && Self.isRealDirectory($0) }
        guard depth < Self.maxDepth else { return apps }

        let nested = entries
            .filter { $0.pathExtension.lowercased() != "app" && Self.isRealDirectory($0) }
            .flatMap { findApps(in: $0, depth: depth + 1) }
        return apps + nested
    }

    /// Excludes symlinks such as the `/Applications` alias commonly placed in DMGs.
    private static func isRealDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    /// Clears the Finder "hidden" flag and FinderInfo some vendors set on the bundle in their
    /// disk image, so the installed app stays visible in /Applications.
    static func unhide(_ appURL: URL) {
        var url = appURL
        var values = URLResourceValues()
        values.isHidden = false
        try? url.setResourceValues(values)
        _ = appURL.withUnsafeFileSystemRepresentation { path in
            path.map { removexattr($0, "com.apple.FinderInfo", XATTR_NOFOLLOW) }
        }
    }

    /// Reads CFBundleIdentifier directly from Info.plist (avoids `Bundle` caching).
    static func bundleIdentifier(of appURL: URL) -> String? {
        infoDictionary(of: appURL)?["CFBundleIdentifier"] as? String
    }

    /// (CFBundleShortVersionString, CFBundleVersion) from Info.plist; nil without a short version.
    static func version(of appURL: URL) -> (shortVersion: String, build: String?)? {
        guard let info = infoDictionary(of: appURL),
              let short = (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String),
              !short.isEmpty else { return nil }
        return (short, info["CFBundleVersion"] as? String)
    }

    private static func infoDictionary(of appURL: URL) -> [String: Any]? {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            return nil
        }
        return plist as? [String: Any]
    }
}
