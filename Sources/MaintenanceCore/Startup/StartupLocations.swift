import Foundation

/// Folders the startup scanner reads. Injected so tests can point at a temporary tree.
public struct StartupLocations: Sendable {
    public let userAgents: URL
    public let globalAgents: URL
    public let daemons: URL
    /// Folders searched for owning apps.
    public let applicationFolders: [URL]
    public let backgroundItemsFile: URL

    public init(
        userAgents: URL, globalAgents: URL, daemons: URL, applicationFolders: [URL], backgroundItemsFile: URL
    ) {
        self.userAgents = userAgents
        self.globalAgents = globalAgents
        self.daemons = daemons
        self.applicationFolders = applicationFolders
        self.backgroundItemsFile = backgroundItemsFile
    }

    /// The real locations for the current user.
    public static func live(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> StartupLocations {
        StartupLocations(
            userAgents: home.appendingPathComponent("Library/LaunchAgents", isDirectory: true),
            globalAgents: URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true),
            daemons: URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true),
            applicationFolders: [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                home.appendingPathComponent("Applications", isDirectory: true),
            ],
            backgroundItemsFile: home.appendingPathComponent(
                "Library/Application Support/com.apple.backgroundtaskmanagementagent/backgrounditems.btm"
            )
        )
    }

    func folder(for kind: StartupItemKind) -> URL {
        switch kind {
        case .userAgent: userAgents
        case .globalAgent: globalAgents
        case .daemon: daemons
        }
    }
}

/// launchd domain targets for the current user.
public enum LaunchdDomain {
    public static let launchctl = "/bin/launchctl"

    public static func gui(uid: uid_t) -> String { "gui/\(uid)" }

    public static func domain(for kind: StartupItemKind, uid: uid_t) -> String {
        kind.isAgent ? gui(uid: uid) : "system"
    }

    public static func service(_ label: String, kind: StartupItemKind, uid: uid_t) -> String {
        "\(domain(for: kind, uid: uid))/\(label)"
    }
}
