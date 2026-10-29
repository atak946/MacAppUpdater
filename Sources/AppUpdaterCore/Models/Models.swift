import Foundation

/// An application bundle discovered on disk.
public struct InstalledApp: Sendable, Hashable, Identifiable {
    public var id: String { bundleIdentifier }

    public let bundleIdentifier: String
    public let name: String
    public let url: URL
    /// CFBundleShortVersionString
    public let shortVersion: String
    /// CFBundleVersion
    public let buildVersion: String?
    /// SUFeedURL from Info.plist, when the app embeds Sparkle.
    public let sparkleFeedURL: URL?
    /// True when Contents/_MASReceipt exists.
    public let isFromAppStore: Bool

    public init(
        bundleIdentifier: String,
        name: String,
        url: URL,
        shortVersion: String,
        buildVersion: String?,
        sparkleFeedURL: URL?,
        isFromAppStore: Bool
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.url = url
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.sparkleFeedURL = sparkleFeedURL
        self.isFromAppStore = isFromAppStore
    }
}

public enum UpdateSourceKind: String, Sendable, Codable, CaseIterable {
    case sparkle
    case homebrew
    case github
    case appStore
    /// electron-builder apps (`app-update.yml` → `latest-mac.yml`).
    case electron
    /// Declarative vendor feeds (official JSON/XML release APIs).
    case vendor
}

public enum PackageFormat: String, Sendable, Codable {
    case dmg
    case zip
    case pkg
    case unknown

    public init(fileURL: URL) {
        switch fileURL.pathExtension.lowercased() {
        case "dmg": self = .dmg
        case "zip": self = .zip
        case "pkg", "mpkg": self = .pkg
        default: self = .unknown
        }
    }
}

/// Release notes as published by the source.
public enum ReleaseNotes: Sendable, Hashable {
    /// Inline HTML (Sparkle `<description>`).
    case html(String)
    /// Markdown body (GitHub release `body`).
    case markdown(String)
    /// Remote page to fetch/open (Sparkle `releaseNotesLink`).
    case remote(URL)
}

/// An available update for an installed app.
public struct AvailableUpdate: Sendable, Hashable, Identifiable {
    public var id: String { "\(app.bundleIdentifier)@\(newVersion)" }

    public let app: InstalledApp
    public let newVersion: String
    public let downloadURL: URL
    public let source: UpdateSourceKind
    public let releaseNotesURL: URL?
    /// Base64 EdDSA signature (Sparkle `sparkle:edSignature`), if provided.
    public let edSignature: String?
    /// Hex SHA-256 of the download (Homebrew `sha256`), if provided.
    public let sha256: String?
    public let releaseNotes: ReleaseNotes?
    /// LSMinimumSystemVersion required by the new release, when the source publishes it.
    public let minimumSystemVersion: String?
    /// When the release was published (appcast pubDate, GitHub published_at, …), if known.
    public let publishedAt: Date?
    /// Developer Team ID the new release must be signed with, when the source knows it
    /// (vendor feed `expectedTeamID`, curated data). Enforced on install when present.
    public let expectedTeamID: String?
    /// Set when the inline release notes mention security fixes; derived once here so list
    /// sorting and row redraws don't rescan the notes.
    public let securityInfo: SecurityUpdateInfo?

    public init(
        app: InstalledApp,
        newVersion: String,
        downloadURL: URL,
        source: UpdateSourceKind,
        releaseNotesURL: URL? = nil,
        edSignature: String? = nil,
        sha256: String? = nil,
        releaseNotes: ReleaseNotes? = nil,
        minimumSystemVersion: String? = nil,
        publishedAt: Date? = nil,
        expectedTeamID: String? = nil
    ) {
        self.publishedAt = publishedAt
        self.expectedTeamID = expectedTeamID
        self.releaseNotes = releaseNotes
        self.securityInfo = SecurityUpdateDetector.detect(in: releaseNotes)
        self.minimumSystemVersion = minimumSystemVersion
        self.app = app
        self.newVersion = newVersion
        self.downloadURL = downloadURL
        self.source = source
        self.releaseNotesURL = releaseNotesURL
        self.edSignature = edSignature
        self.sha256 = sha256
    }
}

public enum UpdaterError: Error, Sendable, Equatable, LocalizedError {
    case invalidBundle(URL)
    case network(String)
    case parsing(String)
    case checksumMismatch
    case signatureInvalid(String)
    case teamIdentifierMismatch(expected: String, actual: String)
    case installFailed(String)
    case unsupportedFormat(String)
    case commandFailed(command: String, status: Int32, output: String)

    public var errorDescription: String? {
        switch self {
        case .invalidBundle(let url): String(coreLocalized: "Invalid application bundle at \(url.path)")
        case .network(let message): String(coreLocalized: "Network error: \(message)")
        case .parsing(let message): String(coreLocalized: "Parsing error: \(message)")
        case .checksumMismatch: String(coreLocalized: "Downloaded file checksum does not match")
        case .signatureInvalid(let message): String(coreLocalized: "Code signature invalid: \(message)")
        case .teamIdentifierMismatch(let expected, let actual):
            String(coreLocalized: "Team identifier mismatch (expected \(expected), got \(actual))")
        case .installFailed(let message): String(coreLocalized: "Install failed: \(message)")
        case .unsupportedFormat(let format): String(coreLocalized: "Unsupported package format: \(format)")
        case .commandFailed(let command, let status, let output):
            String(coreLocalized: "\(command) exited with \(status): \(output)")
        }
    }
}
