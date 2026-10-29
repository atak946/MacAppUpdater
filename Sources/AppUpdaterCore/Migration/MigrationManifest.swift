import Foundation

/// Where an exported app can be installed from on the new Mac.
public enum MigrationSource: String, Sendable, Hashable, Codable {
    /// A Homebrew cask lists the bundle (`caskToken` is set).
    case homebrew
    /// The Mac App Store (`appStoreID` is set when the store lookup knew the app).
    case appStore
    /// Neither: the user has to download it by hand.
    case manual
}

/// One app of a migration list, as written to JSON or read back from JSON or a Brewfile.
///
/// Entries parsed from a Brewfile have no bundle ID (a `cask` line only names the token).
public struct MigrationEntry: Sendable, Hashable, Codable, Identifiable {
    public var id: String {
        if let bundleIdentifier { return bundleIdentifier }
        if let caskToken { return "cask:\(caskToken)" }
        if let appStoreID { return "mas:\(appStoreID)" }
        return "name:\(name)"
    }

    public let bundleIdentifier: String?
    public let name: String
    public let version: String?
    public let source: MigrationSource
    public let caskToken: String?
    public let appStoreID: Int?

    public init(
        bundleIdentifier: String?,
        name: String,
        version: String?,
        source: MigrationSource,
        caskToken: String? = nil,
        appStoreID: Int? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.version = version
        self.source = source
        self.caskToken = caskToken
        self.appStoreID = appStoreID
    }

    /// Builds the entry for an installed app from what the lookups found.
    public init(app: InstalledApp, caskToken: String?, appStoreID: Int?) {
        let token = caskToken.flatMap { MigrationValidation.isValidCaskToken($0) ? $0 : nil }
        let storeID = appStoreID.flatMap { MigrationValidation.isValidAppStoreID($0) ? $0 : nil }
        let source: MigrationSource = app.isFromAppStore ? .appStore : (token != nil ? .homebrew : .manual)
        self.init(
            bundleIdentifier: app.bundleIdentifier, name: app.name, version: app.shortVersion,
            source: source, caskToken: app.isFromAppStore ? nil : token, appStoreID: storeID
        )
    }

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier, name, version, source, caskToken, appStoreID
    }

    /// Lenient on optional fields, strict on what could reach a command line: an invalid cask
    /// token or App Store ID is dropped rather than kept.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let bundleID = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
            .map(MigrationValidation.sanitizedText)
        let token = try container.decodeIfPresent(String.self, forKey: .caskToken)
        let storeID = try container.decodeIfPresent(Int.self, forKey: .appStoreID)
        self.bundleIdentifier = bundleID?.isEmpty == false ? bundleID : nil
        self.name = MigrationValidation.sanitizedText(try container.decode(String.self, forKey: .name))
        self.version = try container.decodeIfPresent(String.self, forKey: .version).map(MigrationValidation.sanitizedText)
        self.caskToken = token.flatMap { MigrationValidation.isValidCaskToken($0) ? $0 : nil }
        self.appStoreID = storeID.flatMap { MigrationValidation.isValidAppStoreID($0) ? $0 : nil }
        let decodedSource = try container.decodeIfPresent(MigrationSource.self, forKey: .source)
        self.source = decodedSource ?? (appStoreID != nil ? .appStore : (caskToken != nil ? .homebrew : .manual))
    }
}

/// The whole exported list: apps plus, when known, Homebrew formulae.
public struct MigrationManifest: Sendable, Hashable, Codable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let exportedAt: Date?
    public let apps: [MigrationEntry]
    public let formulae: [String]

    public init(
        apps: [MigrationEntry],
        formulae: [String] = [],
        exportedAt: Date? = nil,
        formatVersion: Int = MigrationManifest.currentFormatVersion
    ) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.apps = apps
        self.formulae = formulae
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, exportedAt, apps, formulae
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? Self.currentFormatVersion
        exportedAt = try? container.decodeIfPresent(Date.self, forKey: .exportedAt)
        apps = try container.decode([MigrationEntry].self, forKey: .apps)
        formulae = (try container.decodeIfPresent([String].self, forKey: .formulae) ?? [])
            .filter(HomebrewCLI.isValidFormulaName)
    }
}
