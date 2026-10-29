import Foundation

public enum GitHubMappingError: Error, Sendable, Equatable, LocalizedError {
    case emptyBundleIdentifier
    case invalidRepository(String)

    public var errorDescription: String? {
        switch self {
        case .emptyBundleIdentifier: String(coreLocalized: "Choose an app first.")
        case .invalidRepository(let input): String(coreLocalized: "\"\(input)\" is not a valid owner/repo.")
        }
    }
}

/// Immutable bundle identifier → "owner/repo" mapping used by `GitHubReleasesSource`.
public struct GitHubRepositoryMappings: Sendable, Hashable, Codable {
    public let repositories: [String: String]

    public init(repositories: [String: String] = [:]) {
        self.repositories = repositories.filter { GitHubReleasesSource.isValidRepository($0.value) }
    }

    public func repository(for bundleIdentifier: String) -> String? {
        repositories[bundleIdentifier]
    }

    /// Returns a copy with the mapping added or replaced. Accepts "owner/repo" or a github.com URL.
    public func adding(repository input: String, for bundleIdentifier: String) throws(GitHubMappingError) -> Self {
        let bundleID = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else { throw .emptyBundleIdentifier }
        guard let repository = Self.normalizedRepository(input) else { throw .invalidRepository(input) }
        return Self(repositories: repositories.merging([bundleID: repository]) { _, new in new })
    }

    public func removing(bundleIdentifier: String) -> Self {
        Self(repositories: repositories.filter { $0.key != bundleIdentifier })
    }

    /// Normalises user input to "owner/repo", or nil when invalid.
    /// Accepts "owner/repo", "github.com/owner/repo", "https://github.com/owner/repo(.git)".
    public static func normalizedRepository(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "www.", "github.com/"] where value.lowercased().hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
        }
        if value.hasSuffix("/") { value = String(value.dropLast()) }
        if value.lowercased().hasSuffix(".git") { value = String(value.dropLast(4)) }
        return GitHubReleasesSource.isValidRepository(value) ? value : nil
    }

    /// Well-known open-source apps that publish installable macOS assets on GitHub Releases.
    public static let suggestions: [String: String] = [
        "com.knollsoft.Rectangle": "rxhanson/Rectangle",
        "com.colliderli.iina": "iina/iina",
        "org.alacritty": "alacritty/alacritty",
        "net.kovidgoyal.kitty": "kovidgoyal/kitty",
        "com.lwouis.alt-tab-macos": "lwouis/alt-tab-macos",
        "org.keepassxc.keepassxc": "keepassxreboot/keepassxc",
        "com.obsproject.obs-studio": "obsproject/obs-studio",
        "com.utmapp.UTM": "utmapp/UTM",
        "md.obsidian": "obsidianmd/obsidian-releases",
    ]

    public static func suggestion(for bundleIdentifier: String) -> String? {
        suggestions[bundleIdentifier]
    }
}

/// Persists GitHub mappings as JSON in UserDefaults (non-sensitive; the token lives in the Keychain).
public struct GitHubRepositoryStore: @unchecked Sendable {
    public static let defaultsKey = "githubRepositoryMappings"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> GitHubRepositoryMappings {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let mappings = try? JSONDecoder().decode(GitHubRepositoryMappings.self, from: data)
        else { return GitHubRepositoryMappings() }
        // Re-run validation in case the stored JSON was edited by hand.
        return GitHubRepositoryMappings(repositories: mappings.repositories)
    }

    public func save(_ mappings: GitHubRepositoryMappings) throws {
        defaults.set(try JSONEncoder().encode(mappings), forKey: Self.defaultsKey)
    }
}
