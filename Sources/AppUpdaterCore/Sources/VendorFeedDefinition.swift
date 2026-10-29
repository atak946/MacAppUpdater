import Foundation

public enum VendorFeedFormat: String, Codable, Sendable, Hashable {
    case json
    case xml
}

/// How an update from a vendor feed should be applied.
public enum VendorInstallStrategy: String, Codable, Sendable, Hashable {
    /// `downloadURL` is a package (dmg/zip/pkg) the normal installer can apply.
    case inPlace
    /// The vendor ships its own updater (e.g. Chrome/Keystone); `downloadURL` is the vendor's
    /// download page. Treat like manual guidance: open it, never install.
    case openVendorUpdater
}

/// Data-only description of an official, documented release feed.
///
/// Key paths are dot-separated; numeric components index arrays (`IIU.0.version`).
/// For XML feeds the document root element is the first component, repeated elements become
/// arrays, attributes are `@name` and mixed text is `#text`.
public struct VendorFeedDefinition: Codable, Sendable, Hashable {
    public let bundleIdentifier: String
    public let name: String
    public let feedURL: URL
    public let format: VendorFeedFormat
    public let versionPath: String
    /// Key path of the download URL in the feed.
    public let downloadURLPath: String?
    /// Used instead of `downloadURLPath` on Apple Silicon when present.
    public let downloadURLPathArm64: String?
    /// `{version}` is replaced by the feed version. Used when no download path resolves.
    public let downloadURLTemplate: String?
    public let publishedAtPath: String?
    /// `{version}` is replaced by the feed version.
    public let releaseNotesURLTemplate: String?
    /// Apple Team ID the vendor signs with; the install must match it.
    public let expectedTeamID: String?
    public let installStrategy: VendorInstallStrategy
    /// Staged-rollout feeds: key path of an array of releases. When set, `versionPath` is read
    /// inside each release and the highest version that reached `minimumRolloutFraction` wins.
    public let releasesPath: String?
    /// Key of the rollout fraction (`0...1`) inside each release; releases without it count as 1.
    public let rolloutFractionKey: String?
    public let minimumRolloutFraction: Double?

    public init(
        bundleIdentifier: String,
        name: String,
        feedURL: URL,
        format: VendorFeedFormat = .json,
        versionPath: String,
        downloadURLPath: String? = nil,
        downloadURLPathArm64: String? = nil,
        downloadURLTemplate: String? = nil,
        publishedAtPath: String? = nil,
        releaseNotesURLTemplate: String? = nil,
        expectedTeamID: String? = nil,
        installStrategy: VendorInstallStrategy = .inPlace,
        releasesPath: String? = nil,
        rolloutFractionKey: String? = nil,
        minimumRolloutFraction: Double? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.feedURL = feedURL
        self.format = format
        self.versionPath = versionPath
        self.downloadURLPath = downloadURLPath
        self.downloadURLPathArm64 = downloadURLPathArm64
        self.downloadURLTemplate = downloadURLTemplate
        self.publishedAtPath = publishedAtPath
        self.releaseNotesURLTemplate = releaseNotesURLTemplate
        self.expectedTeamID = expectedTeamID
        self.installStrategy = installStrategy
        self.releasesPath = releasesPath
        self.rolloutFractionKey = rolloutFractionKey
        self.minimumRolloutFraction = minimumRolloutFraction
    }

    /// HTTPS feed with at least one way to build a download URL.
    public var isValid: Bool {
        feedURL.scheme?.lowercased() == "https"
            && !bundleIdentifier.isEmpty
            && !versionPath.isEmpty
            && (downloadURLPath != nil || downloadURLTemplate != nil)
    }
}

/// Top-level shape of `vendor-feeds.json`.
struct VendorFeedCatalog: Codable, Sendable {
    let version: Int
    let feeds: [VendorFeedDefinition]

    static let resourceName = "vendor-feeds"

    static func decode(_ data: Data) throws -> [VendorFeedDefinition] {
        do {
            return try JSONDecoder().decode(VendorFeedCatalog.self, from: data).feeds.filter(\.isValid)
        } catch {
            throw UpdaterError.parsing("Invalid vendor feed catalog: \(error.localizedDescription)")
        }
    }

    /// Definitions bundled with AppUpdaterCore.
    static func bundled() throws -> [VendorFeedDefinition] {
        // Not `Bundle.module`: it traps when the resource bundle is missing from the app.
        guard let url = CoreResourceBundle.url(forResource: resourceName, withExtension: "json") else {
            throw UpdaterError.parsing("vendor-feeds.json is missing from the AppUpdaterCore bundle")
        }
        return try decode(try Data(contentsOf: url))
    }
}
