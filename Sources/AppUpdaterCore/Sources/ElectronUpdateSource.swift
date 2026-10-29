import Foundation
import os

/// Checks electron-builder apps: `Contents/Resources/app-update.yml` names the provider,
/// whose `latest-mac.yml` lists the latest version, files and base64 SHA-512 digests.
///
/// SHA-512 digests are registered in `checksumStore` under `AvailableUpdate.id`; give the
/// downloader the same store's `lookup` so the download is verified against it.
public struct ElectronUpdateSource: SourceMatching {
    public typealias Architecture = GitHubReleasesSource.Architecture

    public let kind: UpdateSourceKind = .electron

    static let configRelativePath = "Contents/Resources/app-update.yml"
    static let maximumConfigSize = 64 * 1024

    private static let logger = Logger(subsystem: "com.macappupdater", category: "ElectronUpdateSource")

    private let http: any HTTPClient
    private let comparator: any VersionComparing
    private let checksumStore: ChecksumStore?
    private let architecture: Architecture

    public init(
        http: any HTTPClient,
        comparator: any VersionComparing,
        checksumStore: ChecksumStore? = nil,
        architecture: Architecture = .current
    ) {
        self.http = http
        self.comparator = comparator
        self.checksumStore = checksumStore
        self.architecture = architecture
    }

    public func canHandle(_ app: InstalledApp) -> Bool {
        !app.isFromAppStore && FileManager.default.fileExists(atPath: Self.configURL(for: app).path)
    }

    public func checkForUpdate(_ app: InstalledApp) async throws -> AvailableUpdate? {
        try await lookup(app).update
    }

    /// `.notFound` for unsupported providers; a parsed feed counts as a match.
    public func lookup(_ app: InstalledApp) async throws -> SourceLookup {
        guard canHandle(app), let feedURL = try Self.feedURL(for: app) else { return .notFound }
        guard !Self.isBoilerplateFeed(feedURL) else {
            Self.logger.notice("Ignoring boilerplate update feed for \(app.bundleIdentifier, privacy: .public)")
            return .notFound
        }
        let feed = try ElectronFeedParser.parseFeed(try await http.data(from: feedURL))
        guard comparator.isNewer(feed.version, than: app.shortVersion),
              let (file, downloadURL) = preferredFile(in: feed, feedURL: feedURL)
        else { return .upToDate(latestVersion: feed.version) }
        let update = AvailableUpdate(
            app: app,
            newVersion: feed.version,
            downloadURL: downloadURL,
            source: .electron,
            releaseNotes: feed.releaseNotes.map(Self.releaseNotes),
            minimumSystemVersion: feed.minimumSystemVersion,
            publishedAt: feed.releaseDate
        )
        if let sha512 = file.sha512 ?? (file.url == feed.path ? feed.sha512 : nil) {
            await checksumStore?.register(ExpectedChecksum(algorithm: .sha512, value: sha512), forUpdateID: update.id)
        } else {
            Self.logger.notice("No sha512 for \(update.id, privacy: .public)")
        }
        return .update(update)
    }

    /// Starter-template repositories whose `app-update.yml` some apps ship unchanged; their feeds
    /// advertise the template's own builds (e.g. AnythingLLM → electron-vite-react 9.9.9).
    static let boilerplateFeedRepositories: Set<String> = [
        "electron-vite/electron-vite-react",
        "electron-vite/electron-vite-vue",
        "electron-react-boilerplate/electron-react-boilerplate",
        "electron-userland/electron-builder",
        "electron-userland/electron-webpack-quick-start",
        "alex8088/electron-vite-boilerplate",
    ]

    static func isBoilerplateFeed(_ feedURL: URL) -> Bool {
        guard feedURL.host?.lowercased() == "github.com" else { return false }
        let parts = feedURL.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return false }
        return boilerplateFeedRepositories.contains("\(parts[0])/\(parts[1])".lowercased())
    }

    static func configURL(for app: InstalledApp) -> URL {
        app.url.appendingPathComponent(configRelativePath)
    }

    static func feedURL(for app: InstalledApp) throws -> URL? {
        let url = configURL(for: app)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maximumConfigSize else {
            throw UpdaterError.parsing("app-update.yml is too large")
        }
        return try ElectronFeedParser.feedURL(fromUpdateConfig: try Data(contentsOf: url))
    }

    // MARK: File selection

    /// HTTPS zip/dmg files only; zip beats dmg (installs in place), then architecture fit.
    func preferredFile(in feed: ElectronFeed, feedURL: URL) -> (ElectronFeedFile, URL)? {
        let candidates = feed.allFiles.compactMap { file -> (ElectronFeedFile, URL, Int)? in
            guard let url = URL(string: file.url, relativeTo: feedURL)?.absoluteURL,
                  url.scheme?.lowercased() == "https"
            else { return nil }
            let format = PackageFormat(fileURL: url)
            guard format == .zip || format == .dmg else { return nil }
            let score = (format == .zip ? 10 : 0) + architecture.score(fileName: url.lastPathComponent)
            return (file, url, score)
        }
        // max(by:) keeps the last max on ties, so iterate reversed to favour the first.
        guard let best = candidates.reversed().max(by: { $0.2 < $1.2 }) else { return nil }
        return (best.0, best.1)
    }


    static func releaseNotes(_ text: String) -> ReleaseNotes {
        let htmlMarkers = ["<p>", "<p ", "<ul", "<ol", "<li", "<br", "<h1", "<h2", "<h3", "<div", "<a "]
        let lowered = text.lowercased()
        return htmlMarkers.contains(where: lowered.contains) ? .html(text) : .markdown(text)
    }
}
