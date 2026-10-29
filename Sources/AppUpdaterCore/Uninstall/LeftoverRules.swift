import Foundation

/// The allowlist: which `~/Library` subfolders may contain leftovers and which names match.
/// Every rule is an exact name comparison — never a substring or loose prefix.
enum LeftoverRules {
    enum Folder: String, CaseIterable, Sendable {
        case applicationSupport = "Application Support"
        case caches = "Caches"
        case preferences = "Preferences"
        case byHostPreferences = "Preferences/ByHost"
        case containers = "Containers"
        case groupContainers = "Group Containers"
        case savedState = "Saved Application State"
        case logs = "Logs"
        case httpStorages = "HTTPStorages"
        case webKit = "WebKit"
        case cookies = "Cookies"
        case launchAgents = "LaunchAgents"

        /// Folders whose matches can't be derived from the id alone and must be listed.
        var requiresListing: Bool {
            switch self {
            case .byHostPreferences, .groupContainers, .launchAgents: true
            default: false
            }
        }

        /// Folders where an item named exactly after the app's display name is a "possible" match.
        var allowsNameMatch: Bool {
            switch self {
            case .applicationSupport, .caches, .logs: true
            default: false
            }
        }
    }

    struct Match: Equatable {
        let kind: LeftoverItem.Kind
        let confidence: LeftoverItem.Confidence
    }

    private static let maxComponentLength = 255
    private static let minimumNameLength = 2

    /// A single, non-hidden path component without separators.
    static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= maxComponentLength
            && !value.hasPrefix(".")
            && !value.contains("/")
            && !value.contains(":")
            && !value.contains("\0")
    }

    private static func isSafeAppName(_ name: String, bundleIdentifier: String) -> Bool {
        isSafeComponent(name) && name.count >= minimumNameLength && name != bundleIdentifier
    }

    /// Names to probe directly (no directory listing needed).
    static func directNames(in folder: Folder, bundleIdentifier id: String, appName: String) -> [String] {
        let nameMatch = folder.allowsNameMatch && isSafeAppName(appName, bundleIdentifier: id) ? [appName] : []
        switch folder {
        case .applicationSupport, .caches, .logs: return [id] + nameMatch
        case .containers, .httpStorages, .webKit: return [id]
        case .preferences: return ["\(id).plist"]
        case .savedState: return ["\(id).savedState"]
        case .cookies: return ["\(id).binarycookies"]
        case .byHostPreferences, .groupContainers, .launchAgents: return []
        }
    }

    /// Whether `name` (an entry directly inside `folder`) belongs to the app.
    static func match(name: String, in folder: Folder, bundleIdentifier id: String, appName: String) -> Match? {
        guard isSafeComponent(name), isSafeComponent(id) else { return nil }
        switch folder {
        case .applicationSupport: return idOrName(name, id, appName, folder, .applicationSupport)
        case .caches: return idOrName(name, id, appName, folder, .caches)
        case .logs: return idOrName(name, id, appName, folder, .logs)
        case .containers: return name == id ? Match(kind: .container, confidence: .exact) : nil
        case .httpStorages: return name == id ? Match(kind: .httpStorage, confidence: .exact) : nil
        case .webKit: return name == id ? Match(kind: .webKit, confidence: .exact) : nil
        case .preferences: return name == "\(id).plist" ? Match(kind: .preferences, confidence: .exact) : nil
        case .savedState: return name == "\(id).savedState" ? Match(kind: .savedState, confidence: .exact) : nil
        case .cookies: return name == "\(id).binarycookies" ? Match(kind: .cookies, confidence: .exact) : nil
        case .byHostPreferences:
            return isByHostName(name, id) ? Match(kind: .byHostPreferences, confidence: .exact) : nil
        case .groupContainers:
            return isTeamGroupName(name, id) ? Match(kind: .groupContainer, confidence: .possible) : nil
        case .launchAgents:
            return isLaunchAgentName(name, id) ? Match(kind: .launchAgent, confidence: .exact) : nil
        }
    }

    private static func idOrName(
        _ name: String, _ id: String, _ appName: String, _ folder: Folder, _ kind: LeftoverItem.Kind
    ) -> Match? {
        if name == id { return Match(kind: kind, confidence: .exact) }
        if folder.allowsNameMatch, isSafeAppName(appName, bundleIdentifier: id), name == appName {
            return Match(kind: kind, confidence: .possible)
        }
        return nil
    }

    /// `<id>.<HOST-UUID>.plist` or `<id>.<12-hex MAC>.plist`.
    private static func isByHostName(_ name: String, _ id: String) -> Bool {
        let prefix = "\(id).", suffix = ".plist"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix), name.count > prefix.count + suffix.count else {
            return false
        }
        let host = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        return host.wholeMatch(of: /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/) != nil
            || host.wholeMatch(of: /[0-9A-Fa-f]{12}/) != nil
    }

    /// `<TEAMID>.<id>` where TEAMID is the 10-character Apple team identifier.
    private static func isTeamGroupName(_ name: String, _ id: String) -> Bool {
        let suffix = ".\(id)"
        guard name.hasSuffix(suffix) else { return false }
        let team = String(name.dropLast(suffix.count))
        return team.wholeMatch(of: /[A-Z0-9]{10}/) != nil
    }

    /// Candidate file name only; the plist's `Label` must also equal the id (see `launchAgentLabel`).
    private static func isLaunchAgentName(_ name: String, _ id: String) -> Bool {
        name == "\(id).plist" || (name.hasPrefix("\(id).") && name.hasSuffix(".plist"))
    }

    static func launchAgentLabel(at url: URL, equals id: String) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        return plist["Label"] as? String == id
    }
}
