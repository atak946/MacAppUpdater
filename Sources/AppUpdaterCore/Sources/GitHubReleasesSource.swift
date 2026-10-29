import Foundation

/// Finds updates from the latest GitHub release of a configured repository.
public struct GitHubReleasesSource: SourceMatching {
    /// Returns the GitHub API token to send, or nil for anonymous requests.
    public typealias TokenProvider = @Sendable () -> String?

    public enum Architecture: Sendable {
        case appleSilicon
        case intel

        public static var current: Architecture {
            #if arch(arm64)
            .appleSilicon
            #else
            .intel
            #endif
        }
    }

    public let kind: UpdateSourceKind = .github

    private static let packageExtensions: Set<String> = ["dmg", "zip", "pkg", "mpkg"]
    private static let repositoryCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-"))

    private let repositories: [String: String]
    private let http: any HTTPClient
    private let comparator: any VersionComparing
    private let architecture: Architecture
    private let token: TokenProvider

    /// - Parameters:
    ///   - repositories: bundle identifier -> "owner/repo". Invalid entries are dropped.
    ///   - token: read per request; sent as `Authorization: Bearer` only when non-empty
    ///     and `http` also conforms to `HTTPRequestClient`.
    public init(
        repositories: [String: String],
        http: any HTTPClient,
        comparator: any VersionComparing,
        architecture: Architecture = .current,
        token: @escaping TokenProvider = { nil }
    ) {
        self.repositories = repositories.filter { Self.isValidRepository($0.value) }
        self.http = http
        self.comparator = comparator
        self.architecture = architecture
        self.token = token
    }

    public func canHandle(_ app: InstalledApp) -> Bool {
        !app.isFromAppStore && repositories[app.bundleIdentifier] != nil
    }

    public func checkForUpdate(_ app: InstalledApp) async throws -> AvailableUpdate? {
        try await lookup(app).update
    }

    public func lookup(_ app: InstalledApp) async throws -> SourceLookup {
        guard canHandle(app),
              let repository = repositories[app.bundleIdentifier],
              let apiURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
        else { return .notFound }
        let release = try decodeRelease(from: try await fetch(apiURL))
        let version = Self.normalizedVersion(release.tagName)
        guard !release.draft, !release.prerelease,
              let asset = preferredAsset(in: release.assets),
              comparator.isNewer(version, than: app.shortVersion)
        else { return .upToDate(latestVersion: version) }
        return .update(AvailableUpdate(
            app: app,
            newVersion: version,
            downloadURL: asset.browserDownloadURL,
            source: .github,
            releaseNotesURL: release.htmlURL,
            releaseNotes: release.body.map(ReleaseNotes.markdown),
            publishedAt: release.publishedAt
        ))
    }

    private func fetch(_ url: URL) async throws -> Data {
        try await http.data(from: url, headers: Self.headers(token: token()), maxBytes: HTTPFetchLimit.feed)
    }

    static func headers(token: String?) -> [String: String] {
        let base = ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"]
        guard let token = KeychainTokenStore.sanitized(token) else { return base }
        return base.merging(["Authorization": "Bearer \(token)"]) { _, new in new }
    }

    /// Accepts only "owner/repo" made of safe characters (no path traversal or query injection).
    static func isValidRepository(_ repository: String) -> Bool {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".."
                && part.unicodeScalars.allSatisfy { $0.isASCII && repositoryCharacters.contains($0) }
        }
    }

    static func normalizedVersion(_ tag: String) -> String {
        guard let first = tag.first, first == "v" || first == "V" else { return tag }
        return String(tag.dropFirst())
    }

    func preferredAsset(in assets: [GitHubRelease.Asset]) -> GitHubRelease.Asset? {
        let candidates = assets.filter { asset in
            let ext = URL(fileURLWithPath: asset.name).pathExtension.lowercased()
            return Self.packageExtensions.contains(ext)
                && asset.browserDownloadURL.scheme?.lowercased() == "https"
        }
        // max(by:) keeps the last max on ties, so iterate reversed to favour the first.
        return candidates.reversed().max { architecture.score(fileName: $0.name) < architecture.score(fileName: $1.name) }
    }


    private func decodeRelease(from data: Data) throws -> GitHubRelease {
        do {
            return try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdaterError.parsing("Invalid GitHub release: \(error.localizedDescription)")
        }
    }
}

struct GitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable, Equatable {
        let name: String
        let browserDownloadURL: URL

        private enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let htmlURL: URL?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    /// Markdown release notes; nil when absent or blank.
    let body: String?
    /// `published_at` (ISO 8601).
    let publishedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case draft, prerelease, assets, body
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        htmlURL = try? container.decodeIfPresent(URL.self, forKey: .htmlURL)
        draft = (try? container.decodeIfPresent(Bool.self, forKey: .draft)) ?? false
        prerelease = (try? container.decodeIfPresent(Bool.self, forKey: .prerelease)) ?? false
        assets = (try? container.decodeIfPresent([Asset].self, forKey: .assets)) ?? []
        let rawBody = (try? container.decodeIfPresent(String.self, forKey: .body)) ?? nil
        body = rawBody?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? rawBody : nil
        let rawPublished = (try? container.decodeIfPresent(String.self, forKey: .publishedAt)) ?? nil
        publishedAt = ReleaseDateParser.iso8601(rawPublished)
    }
}
