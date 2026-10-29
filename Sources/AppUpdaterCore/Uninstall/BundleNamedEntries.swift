import Foundation

/// An entry directly inside an allowlisted `~/Library` folder whose name encodes a bundle identifier,
/// e.g. `Preferences/com.vendor.App.plist`. Found without knowing which app it belongs to.
public struct BundleNamedEntry: Sendable, Hashable {
    public let url: URL
    public let bundleIdentifier: String
    /// The 10-character team prefix of a group container (`<TEAM>.<id>`); nil elsewhere.
    public let teamIdentifier: String?

    public init(url: URL, bundleIdentifier: String, teamIdentifier: String?) {
        self.url = url
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
    }
}

extension LeftoverRules {
    /// Folders searched for leftovers of apps that are no longer installed. Cookies and ByHost
    /// preferences are left out: they are only ever matched against a known app.
    static let bundleNamedFolders: [Folder] = [
        .applicationSupport, .caches, .preferences, .containers, .groupContainers,
        .savedState, .httpStorages, .webKit, .logs, .launchAgents,
    ]

    /// The inverse of `match`: the bundle identifier (and group team) that `name` is named after,
    /// or nil when the folder's naming rule doesn't apply. The result still goes through `match`.
    static func encodedIdentifier(of name: String, in folder: Folder) -> (id: String, team: String?)? {
        guard isSafeComponent(name) else { return nil }
        switch folder {
        case .applicationSupport, .caches, .logs, .containers, .httpStorages, .webKit:
            return (name, nil)
        case .preferences, .launchAgents:
            return stripping(".plist", from: name).map { ($0, nil) }
        case .savedState:
            return stripping(".savedState", from: name).map { ($0, nil) }
        case .groupContainers:
            guard let dot = name.firstIndex(of: ".") else { return nil }
            let team = String(name[..<dot]), id = String(name[name.index(after: dot)...])
            guard team.wholeMatch(of: /[A-Z0-9]{10}/) != nil, !id.isEmpty else { return nil }
            return (id, team)
        case .byHostPreferences, .cookies:
            return nil
        }
    }

    private static func stripping(_ suffix: String, from name: String) -> String? {
        guard name.hasSuffix(suffix), name.count > suffix.count else { return nil }
        return String(name.dropLast(suffix.count))
    }
}

extension LeftoverScanner {
    /// Dry run: every entry of `LeftoverRules.bundleNamedFolders` whose name encodes a bundle identifier.
    /// Names are only decoded here; callers re-check each survivor with `validate` (exact rule,
    /// no symlinks, launch agent `Label`) before showing or trashing it. Never modifies anything.
    public func bundleNamedEntries() -> [BundleNamedEntry] {
        LeftoverRules.bundleNamedFolders.flatMap { folder in
            listing(of: folderURL(folder)).compactMap { url -> BundleNamedEntry? in
                guard let decoded = LeftoverRules.encodedIdentifier(of: url.lastPathComponent, in: folder),
                      LeftoverRules.isSafeComponent(decoded.id) else { return nil }
                return BundleNamedEntry(url: url, bundleIdentifier: decoded.id, teamIdentifier: decoded.team)
            }
        }
    }
}
