import Foundation

/// An installed app the resolver can attribute jobs to.
public struct StartupAppCandidate: Sendable, Equatable {
    public let name: String
    public let bundleIdentifier: String
    public let url: URL

    public init(name: String, bundleIdentifier: String, url: URL) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.url = url
    }
}

/// Finds the app that owns a launchd job.
public struct StartupOwnerResolver: Sendable {
    /// Minimum shared reverse-DNS components for a fuzzy label match ("com.vendor").
    static let minimumSharedComponents = 2

    let apps: [StartupAppCandidate]

    public init(apps: [StartupAppCandidate]) {
        self.apps = apps
    }

    /// Order: the outermost `.app` in the executable path, `AssociatedBundleIdentifiers`,
    /// then the installed app whose bundle id best matches the label's reverse-DNS prefix.
    public func owner(executable: URL?, label: String, associated: [String]) -> (name: String, url: URL)? {
        if let bundle = executable.flatMap(Self.outermostAppBundle) {
            let name = apps.first { $0.url.standardizedFileURL == bundle.standardizedFileURL }?.name
            return (name ?? bundle.deletingPathExtension().lastPathComponent, bundle)
        }
        for identifier in associated {
            if let app = apps.first(where: { $0.bundleIdentifier.caseInsensitiveCompare(identifier) == .orderedSame }) {
                return (app.name, app.url)
            }
        }
        return bestLabelMatch(label).map { ($0.name, $0.url) }
    }

    /// `/Applications/Foo.app/Contents/Library/Helper.app/...` → `/Applications/Foo.app`.
    static func outermostAppBundle(in url: URL) -> URL? {
        var path = URL(fileURLWithPath: "/")
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            path.appendPathComponent(component)
            if component.lowercased().hasSuffix(".app") { return path }
        }
        return nil
    }

    private func bestLabelMatch(_ label: String) -> StartupAppCandidate? {
        let labelParts = Self.components(label)
        var best: (app: StartupAppCandidate, score: Int)?
        for app in apps {
            let appParts = Self.components(app.bundleIdentifier)
            let shared = zip(labelParts, appParts).prefix { $0 == $1 }.count
            guard shared >= Self.minimumSharedComponents else { continue }
            // A bundle id fully contained in the label beats a partial vendor match.
            let score = shared * 2 + (shared == appParts.count ? 1 : 0)
            if score > (best?.score ?? 0) { best = (app, score) }
        }
        return best?.app
    }

    private static func components(_ identifier: String) -> [String] {
        identifier.lowercased().split(separator: ".").map(String.init)
    }
}

// MARK: - Catalog

/// Lists `.app` bundles in the given folders (one level of subfolders, e.g. `Utilities`).
public enum StartupAppCatalog {
    public static func apps(in folders: [URL], fileManager: FileManager = .default) -> [StartupAppCandidate] {
        var result: [StartupAppCandidate] = []
        for folder in folders {
            for entry in contents(of: folder, fileManager) {
                if entry.pathExtension == "app" {
                    candidate(entry).map { result.append($0) }
                } else if entry.hasDirectoryPath {
                    result += contents(of: entry, fileManager).filter { $0.pathExtension == "app" }.compactMap(candidate)
                }
            }
        }
        return result
    }

    private static func contents(of folder: URL, _ fileManager: FileManager) -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
    }

    private static func candidate(_ url: URL) -> StartupAppCandidate? {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = plist["CFBundleIdentifier"] as? String else { return nil }
        let name = plist["CFBundleDisplayName"] as? String ?? plist["CFBundleName"] as? String
        return StartupAppCandidate(
            name: name ?? url.deletingPathExtension().lastPathComponent, bundleIdentifier: identifier, url: url
        )
    }
}
