import Foundation

/// Checks apps that embed Sparkle via their `SUFeedURL` appcast.
public struct SparkleSource: SourceMatching {
    /// Returns the extra Sparkle channels (e.g. `["beta"]`) an app is opted in to.
    /// The default channel (items without `sparkle:channel`) is always included.
    public typealias ChannelProvider = @Sendable (InstalledApp) -> Set<String>

    public static let defaultChannelsOnly: ChannelProvider = { _ in [] }

    public let kind: UpdateSourceKind = .sparkle

    private let http: any HTTPClient
    private let comparator: any VersionComparing
    private let systemVersion: OperatingSystemVersion
    private let allowedChannels: ChannelProvider

    public init(
        http: any HTTPClient,
        comparator: any VersionComparing,
        systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        allowedChannels: @escaping ChannelProvider = SparkleSource.defaultChannelsOnly
    ) {
        self.http = http
        self.comparator = comparator
        self.systemVersion = systemVersion
        self.allowedChannels = allowedChannels
    }

    public func canHandle(_ app: InstalledApp) -> Bool {
        app.sparkleFeedURL != nil && !app.isFromAppStore
    }

    public func checkForUpdate(_ app: InstalledApp) async throws -> AvailableUpdate? {
        try await lookup(app).update
    }

    /// A feed that downloads and parses counts as a match, even without eligible items.
    public func lookup(_ app: InstalledApp) async throws -> SourceLookup {
        guard canHandle(app), let feedURL = app.sparkleFeedURL else { return .notFound }
        let data = try await http.data(from: feedURL, maxBytes: HTTPFetchLimit.feed)
        let items = try SparkleAppcastParser.parse(data)
        let channels = allowedChannels(app)
        guard let best = newestItem(in: items, channels: channels),
              let downloadURL = best.downloadURL,
              let newVersion = best.displayVersion
        else { return .upToDate(latestVersion: app.shortVersion) }
        guard isNewer(best, than: app) else { return .upToDate(latestVersion: newVersion) }
        return .update(AvailableUpdate(
            app: app,
            newVersion: newVersion,
            downloadURL: downloadURL,
            source: .sparkle,
            releaseNotesURL: best.releaseNotesURL,
            edSignature: best.edSignature,
            releaseNotes: best.releaseNotes,
            minimumSystemVersion: best.minimumSystemVersion,
            publishedAt: best.publishedAt
        ))
    }

    func newestItem(in items: [SparkleAppcastItem], channels: Set<String> = []) -> SparkleAppcastItem? {
        items.filter { isEligible($0, channels: channels) }.reduce(nil) { best, item in
            guard let best, let bestVersion = best.comparableVersion,
                  let itemVersion = item.comparableVersion
            else { return item }
            return comparator.isNewer(itemVersion, than: bestVersion) ? item : best
        }
    }

    private func isEligible(_ item: SparkleAppcastItem, channels: Set<String>) -> Bool {
        guard item.downloadURL?.scheme?.lowercased() == "https",
              item.comparableVersion != nil,
              item.isOnChannel(in: channels)
        else { return false }
        guard let minimum = item.minimumSystemVersion else { return true }
        return SystemVersionRequirement.isSatisfied(minimum: minimum, current: systemVersion)
    }

    /// Compares build versions when both sides have one, otherwise marketing versions.
    private func isNewer(_ item: SparkleAppcastItem, than app: InstalledApp) -> Bool {
        if let itemBuild = item.version, let appBuild = app.buildVersion {
            return comparator.isNewer(itemBuild, than: appBuild)
        }
        guard let display = item.displayVersion else { return false }
        return comparator.isNewer(display, than: app.shortVersion)
    }
}
