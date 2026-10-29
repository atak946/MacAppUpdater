import Foundation

/// Minimal projection of a cask from the Homebrew formulae API.
struct HomebrewCask: Sendable, Equatable, Decodable {
    let token: String
    let version: String?
    let url: String?
    let sha256: String?
    let appNames: [String]

    private enum CodingKeys: String, CodingKey {
        case token, version, url, sha256, artifacts
    }

    init(token: String, version: String?, url: String?, sha256: String?, appNames: [String]) {
        self.token = token
        self.version = version
        self.url = url
        self.sha256 = sha256
        self.appNames = appNames
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        version = try? container.decodeIfPresent(String.self, forKey: .version)
        url = try? container.decodeIfPresent(String.self, forKey: .url)
        sha256 = try? container.decodeIfPresent(String.self, forKey: .sha256)
        let artifacts = (try? container.decodeIfPresent([CaskArtifact].self, forKey: .artifacts)) ?? []
        appNames = artifacts.flatMap(\.appNames)
    }

    /// Version without the ",build" suffix Homebrew appends for some casks.
    var comparableVersion: String? {
        guard let version, version != "latest" else { return nil }
        return version.split(separator: ",", maxSplits: 1).first.map(String.init)
    }

    var verifiedSHA256: String? {
        guard let sha256, sha256 != "no_check", !sha256.isEmpty else { return nil }
        return sha256
    }
}

/// One entry of the heterogeneous `artifacts` array; only `app` stanzas are kept.
private struct CaskArtifact: Decodable {
    let appNames: [String]

    private enum CodingKeys: String, CodingKey { case app }

    init(from decoder: any Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self),
              let entries = try? container.decodeIfPresent([LossyString].self, forKey: .app)
        else {
            appNames = []
            return
        }
        appNames = entries.compactMap(\.value).filter { $0.lowercased().hasSuffix(".app") }
    }
}

/// Decodes a string, or nil for any other JSON shape (e.g. `{"target": ...}`).
private struct LossyString: Decodable {
    let value: String?

    init(from decoder: any Decoder) throws {
        value = try? decoder.singleValueContainer().decode(String.self)
    }
}

/// Decodes an element, or nil when that element is malformed.
private struct Lossy<Element: Decodable>: Decodable {
    let value: Element?

    init(from decoder: any Decoder) throws {
        value = try? Element(from: decoder)
    }
}

/// Session-wide cache of the cask index keyed by lowercased `.app` filename.
actor HomebrewCaskIndex {
    private let http: any HTTPClient
    private let apiURL: URL
    private var loadTask: Task<[String: HomebrewCask], any Error>?

    init(http: any HTTPClient, apiURL: URL) {
        self.http = http
        self.apiURL = apiURL
    }

    func cask(forAppFileName fileName: String) async throws -> HomebrewCask? {
        try await index()[fileName.lowercased()]
    }

    private func index() async throws -> [String: HomebrewCask] {
        if let loadTask { return try await loadTask.value }
        let task = Task { [http, apiURL] in
            try Self.buildIndex(from: try await http.data(from: apiURL, maxBytes: HTTPFetchLimit.caskIndex))
        }
        loadTask = task
        do {
            return try await task.value
        } catch {
            loadTask = nil
            throw error
        }
    }

    static func buildIndex(from data: Data) throws -> [String: HomebrewCask] {
        let casks: [Lossy<HomebrewCask>]
        do {
            casks = try JSONDecoder().decode([Lossy<HomebrewCask>].self, from: data)
        } catch {
            throw UpdaterError.parsing("Invalid Homebrew cask index: \(error.localizedDescription)")
        }
        var index: [String: HomebrewCask] = [:]
        for cask in casks.compactMap(\.value) {
            for name in cask.appNames where index[name.lowercased()] == nil {
                index[name.lowercased()] = cask
            }
        }
        return index
    }
}

/// Finds updates by matching installed bundles to Homebrew casks.
public struct HomebrewCaskSource: SourceMatching {
    public static let defaultAPIURL = URL(string: "https://formulae.brew.sh/api/cask.json")!

    public let kind: UpdateSourceKind = .homebrew

    private let index: HomebrewCaskIndex
    private let comparator: any VersionComparing

    public init(
        http: any HTTPClient,
        comparator: any VersionComparing,
        apiURL: URL = HomebrewCaskSource.defaultAPIURL
    ) {
        self.index = HomebrewCaskIndex(http: http, apiURL: apiURL)
        self.comparator = comparator
    }

    public func canHandle(_ app: InstalledApp) -> Bool {
        !app.isFromAppStore
    }

    /// Casks often append the bundle build to the short version (Parallels: `27.0.3-58680` for
    /// 27.0.3 build 58680). With a numeric build, the cask is only newer than "short.build".
    static func isInstalledBuild(_ caskVersion: String, of app: InstalledApp, comparator: any VersionComparing) -> Bool {
        guard let build = app.buildVersion, !build.isEmpty, build.allSatisfy(\.isNumber) else { return false }
        return !comparator.isNewer(caskVersion, than: "\(app.shortVersion).\(build)")
    }

    public func checkForUpdate(_ app: InstalledApp) async throws -> AvailableUpdate? {
        try await lookup(app).update
    }

    /// Token of the cask that installs this bundle (for a Brewfile export), or nil when none does.
    public func caskToken(for app: InstalledApp) async throws -> String? {
        guard canHandle(app) else { return nil }
        return try await index.cask(forAppFileName: app.url.lastPathComponent)?.token
    }

    /// A cask listing the app's bundle counts as a match even when it is not newer
    /// or uses `version :latest` (which cannot be compared).
    public func lookup(_ app: InstalledApp) async throws -> SourceLookup {
        guard canHandle(app),
              let cask = try await index.cask(forAppFileName: app.url.lastPathComponent)
        else { return .notFound }
        guard let version = cask.comparableVersion,
              let urlString = cask.url,
              let downloadURL = URL(string: urlString),
              downloadURL.scheme?.lowercased() == "https",
              comparator.isNewer(version, than: app.shortVersion),
              !Self.isInstalledBuild(version, of: app, comparator: comparator)
        else { return .upToDate(latestVersion: cask.comparableVersion ?? cask.version ?? "latest") }
        return .update(AvailableUpdate(
            app: app,
            newVersion: version,
            downloadURL: downloadURL,
            source: .homebrew,
            sha256: cask.verifiedSHA256
        ))
    }
}
