import Foundation

/// Detects Mac App Store updates via the iTunes lookup API.
/// The returned `downloadURL` is the store page; the UI opens it instead of installing.
public struct AppStoreSource: SourceMatching {
    public let kind: UpdateSourceKind = .appStore

    private static let allowedSchemes: Set<String> = ["https", "macappstore"]

    private let http: any HTTPClient
    private let comparator: any VersionComparing
    private let lookupBaseURL: URL

    public init(
        http: any HTTPClient,
        comparator: any VersionComparing,
        lookupBaseURL: URL = URL(string: "https://itunes.apple.com/lookup")!
    ) {
        self.http = http
        self.comparator = comparator
        self.lookupBaseURL = lookupBaseURL
    }

    public func canHandle(_ app: InstalledApp) -> Bool {
        app.isFromAppStore
    }

    public func checkForUpdate(_ app: InstalledApp) async throws -> AvailableUpdate? {
        try await lookup(app).update
    }

    public func lookup(_ app: InstalledApp) async throws -> SourceLookup {
        guard canHandle(app), let url = lookupURL(for: app.bundleIdentifier) else { return .notFound }
        let response = try decode(try await http.data(from: url))
        // The lookup is keyed by bundle ID, but never trust a result that does not echo it back:
        // a missing or different `bundleId` is treated as "not found" (L-10).
        guard let result = response.results.first(where: { $0.bundleId == app.bundleIdentifier })
        else { return .notFound }
        // iPhone/iPad apps that also run on the Mac (kind "software", e.g. TestFlight) report
        // their iOS version, which the Mac App Store may not offer: never claim an update.
        guard result.isMacSoftware else { return .upToDate(latestVersion: app.shortVersion) }
        guard let storeURL = URL(string: result.trackViewUrl),
              let scheme = storeURL.scheme?.lowercased(), Self.allowedSchemes.contains(scheme),
              comparator.isNewer(result.version, than: app.shortVersion)
        else { return .upToDate(latestVersion: result.version) }
        let releaseNotes = result.releaseNotes?.isEmpty == false ? result.releaseNotes.map(ReleaseNotes.markdown) : nil
        return .update(AvailableUpdate(
            app: app,
            newVersion: result.version,
            downloadURL: storeURL,
            source: .appStore,
            releaseNotes: releaseNotes,
            minimumSystemVersion: result.minimumOsVersion,
            publishedAt: ReleaseDateParser.iso8601(result.currentVersionReleaseDate)
        ))
    }

    /// The store's numeric ID for this app (`mas "Name", id: N`), or nil when the lookup
    /// does not echo the bundle ID back.
    public func appStoreID(for app: InstalledApp) async throws -> Int? {
        guard canHandle(app), let url = lookupURL(for: app.bundleIdentifier) else { return nil }
        let response = try decode(try await http.data(from: url))
        return response.results.first(where: { $0.bundleId == app.bundleIdentifier })?.trackId
    }

    func lookupURL(for bundleIdentifier: String) -> URL? {
        var components = URLComponents(url: lookupBaseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleIdentifier),
            URLQueryItem(name: "entity", value: "macSoftware"),
        ]
        return components?.url
    }

    private func decode(_ data: Data) throws -> LookupResponse {
        do {
            return try JSONDecoder().decode(LookupResponse.self, from: data)
        } catch {
            throw UpdaterError.parsing("Invalid App Store lookup response: \(error.localizedDescription)")
        }
    }
}

private struct LookupResponse: Decodable {
    struct Result: Decodable {
        let version: String
        let trackViewUrl: String
        let trackId: Int?
        let bundleId: String?
        let releaseNotes: String?
        let minimumOsVersion: String?
        let currentVersionReleaseDate: String?
        /// "mac-software" for Mac apps; "software" for iOS apps (also listed for Apple silicon).
        let kind: String?

        /// A missing kind keeps the old behaviour (older responses and test fixtures).
        var isMacSoftware: Bool { kind.map { $0 == "mac-software" } ?? true }
    }

    let results: [Result]
}
