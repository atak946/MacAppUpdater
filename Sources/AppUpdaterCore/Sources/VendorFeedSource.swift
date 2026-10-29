import Foundation
import os

/// One generic source for many official vendor release feeds (`vendor-feeds.json`).
/// Adding a vendor is a data change, not a code change.
///
/// Updates with `VendorInstallStrategy.openVendorUpdater` carry the vendor's download page as
/// `downloadURL`; callers must check `installStrategy(for:)` and open it instead of installing.
public struct VendorFeedSource: SourceMatching {
    public typealias Architecture = GitHubReleasesSource.Architecture

    public let kind: UpdateSourceKind = .vendor

    /// Characters allowed in a feed version substituted into URL templates.
    private static let versionCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-+"))
    private static let logger = Logger(subsystem: "com.macappupdater", category: "VendorFeedSource")

    private let definitions: [String: VendorFeedDefinition]
    private let http: any HTTPClient
    private let comparator: any VersionComparing
    private let architecture: Architecture

    /// Invalid definitions are dropped; for duplicate bundle identifiers the first one wins.
    public init(
        definitions: [VendorFeedDefinition],
        http: any HTTPClient,
        comparator: any VersionComparing,
        architecture: Architecture = .current
    ) {
        let valid = definitions.filter(\.isValid).map { ($0.bundleIdentifier, $0) }
        self.definitions = Dictionary(valid) { first, _ in first }
        self.http = http
        self.comparator = comparator
        self.architecture = architecture
    }

    /// Uses the definitions bundled with AppUpdaterCore; an unreadable catalog yields no definitions.
    public static func bundled(
        http: any HTTPClient,
        comparator: any VersionComparing,
        architecture: Architecture = .current
    ) -> VendorFeedSource {
        let definitions: [VendorFeedDefinition]
        do {
            definitions = try bundledDefinitions()
            logger.notice("Loaded \(definitions.count, privacy: .public) bundled vendor feed definitions")
        } catch {
            logger.error("Loading vendor feeds failed: \(error.localizedDescription, privacy: .public)")
            definitions = []
        }
        return VendorFeedSource(definitions: definitions, http: http, comparator: comparator, architecture: architecture)
    }

    public static func bundledDefinitions() throws -> [VendorFeedDefinition] {
        try VendorFeedCatalog.bundled()
    }

    public static func definitions(from catalogJSON: Data) throws -> [VendorFeedDefinition] {
        try VendorFeedCatalog.decode(catalogJSON)
    }

    public func definition(for bundleIdentifier: String) -> VendorFeedDefinition? {
        definitions[bundleIdentifier]
    }

    /// Nil when the update did not come from this source.
    public func installStrategy(for update: AvailableUpdate) -> VendorInstallStrategy? {
        guard update.source == .vendor else { return nil }
        return definitions[update.app.bundleIdentifier]?.installStrategy
    }

    public func expectedTeamID(for bundleIdentifier: String) -> String? {
        definitions[bundleIdentifier]?.expectedTeamID
    }

    public func canHandle(_ app: InstalledApp) -> Bool {
        !app.isFromAppStore && definitions[app.bundleIdentifier] != nil
    }

    public func checkForUpdate(_ app: InstalledApp) async throws -> AvailableUpdate? {
        try await lookup(app).update
    }

    /// The plain `versionPath`, or — for staged-rollout feeds (Chrome) — the highest version
    /// among releases served to at least `minimumRolloutFraction` of users. Versions on a
    /// 0.5 % experiment are not "the latest" for the user: their own updater won't offer them.
    func latestVersion(in document: VendorFeedDocument, definition: VendorFeedDefinition) -> String? {
        guard let releasesPath = definition.releasesPath else {
            return document.string(at: definition.versionPath)
        }
        let minimum = definition.minimumRolloutFraction ?? 0
        let versions = document.elements(at: releasesPath).compactMap { release -> String? in
            let fraction = definition.rolloutFractionKey
                .flatMap { release.string(at: $0) }
                .flatMap(Double.init) ?? 1
            guard fraction >= minimum else { return nil }
            return release.string(at: definition.versionPath)
        }
        return versions.reduce(nil as String?) { best, candidate in
            guard let best else { return candidate }
            return comparator.isNewer(candidate, than: best) ? candidate : best
        }
    }

    public func lookup(_ app: InstalledApp) async throws -> SourceLookup {
        guard canHandle(app), let definition = definitions[app.bundleIdentifier] else { return .notFound }
        let document = try VendorFeedDocument(data: try await http.data(from: definition.feedURL), format: definition.format)
        guard let version = latestVersion(in: document, definition: definition) else {
            throw UpdaterError.parsing("\(definition.name) feed has no version at \(definition.versionPath)")
        }
        guard comparator.isNewer(version, than: app.shortVersion) else { return .upToDate(latestVersion: version) }
        guard let downloadURL = downloadURL(definition, document: document, version: version) else {
            throw UpdaterError.parsing("\(definition.name) feed has no usable HTTPS download URL")
        }
        return .update(AvailableUpdate(
            app: app,
            newVersion: version,
            downloadURL: downloadURL,
            source: .vendor,
            releaseNotesURL: definition.releaseNotesURLTemplate.flatMap { Self.expand($0, version: version) },
            publishedAt: definition.publishedAtPath.flatMap { ReleaseDateParser.any(document.string(at: $0)) },
            expectedTeamID: definition.expectedTeamID
        ))
    }

    func downloadURL(_ definition: VendorFeedDefinition, document: VendorFeedDocument, version: String) -> URL? {
        let paths = [architecture == .appleSilicon ? definition.downloadURLPathArm64 : nil, definition.downloadURLPath]
        let fromFeed = paths.compactMap { $0 }.lazy
            .compactMap { document.string(at: $0).flatMap(URLValidation.httpsURL) }
            .first
        return fromFeed ?? definition.downloadURLTemplate.flatMap { Self.expand($0, version: version) }
    }

    /// Substitutes `{version}` after checking the version cannot alter the URL structure.
    static func expand(_ template: String, version: String) -> URL? {
        guard !version.isEmpty,
              version.unicodeScalars.allSatisfy({ $0.isASCII && versionCharacters.contains($0) })
        else { return nil }
        return URLValidation.httpsURL(template.replacingOccurrences(of: "{version}", with: version))
    }
}
