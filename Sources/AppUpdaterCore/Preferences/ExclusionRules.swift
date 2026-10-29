import Foundation

/// User-defined exclusions: whole apps that are never updated, single skipped versions,
/// and version ceilings that keep an app on a major/minor line (D3).
public struct ExclusionRules: Sendable, Codable, Equatable {
    public let ignoredBundleIdentifiers: Set<String>
    /// bundleIdentifier → skipped version. A newer release than the skipped one shows up again.
    public let skippedVersions: [String: String]
    /// bundleIdentifier → version prefix to stay on: "5" keeps 5.x, "5.2" keeps 5.2.x.
    public let versionCeilings: [String: String]

    public init(
        ignoredBundleIdentifiers: Set<String> = [],
        skippedVersions: [String: String] = [:],
        versionCeilings: [String: String] = [:]
    ) {
        self.ignoredBundleIdentifiers = ignoredBundleIdentifiers
        self.skippedVersions = skippedVersions
        self.versionCeilings = versionCeilings
    }

    /// Accepts JSON stored before version ceilings existed.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            ignoredBundleIdentifiers: try container.decodeIfPresent(Set<String>.self, forKey: .ignoredBundleIdentifiers) ?? [],
            skippedVersions: try container.decodeIfPresent([String: String].self, forKey: .skippedVersions) ?? [:],
            versionCeilings: try container.decodeIfPresent([String: String].self, forKey: .versionCeilings) ?? [:]
        )
    }

    public func isExcluded(_ update: AvailableUpdate) -> Bool {
        exclusionReason(for: update) != nil
    }

    /// Why `update` is excluded (English, user-facing), or `nil` when it is allowed.
    public func exclusionReason(for update: AvailableUpdate) -> String? {
        let bundleID = update.app.bundleIdentifier
        if ignoredBundleIdentifiers.contains(bundleID) { return String(coreLocalized: "Updates for this app are ignored") }
        if skippedVersions[bundleID] == update.newVersion { return String(coreLocalized: "Version \(update.newVersion) is skipped") }
        if let ceiling = versionCeilings[bundleID], Self.exceeds(update.newVersion, ceiling: ceiling) {
            return String(coreLocalized: "Version \(update.newVersion) is above the \(ceiling).x ceiling")
        }
        return nil
    }

    public func isIgnored(_ bundleIdentifier: String) -> Bool {
        ignoredBundleIdentifiers.contains(bundleIdentifier)
    }

    public func ceiling(for bundleIdentifier: String) -> String? {
        versionCeilings[bundleIdentifier]
    }

    public func ignoring(_ bundleIdentifier: String) -> ExclusionRules {
        copy(ignoredBundleIdentifiers: ignoredBundleIdentifiers.union([bundleIdentifier]))
    }

    public func skipping(version: String, of bundleIdentifier: String) -> ExclusionRules {
        copy(skippedVersions: skippedVersions.merging([bundleIdentifier: version]) { _, new in new })
    }

    /// Keeps `bundleIdentifier` on `prefix` (e.g. "5" or "5.2"). `nil` or blank removes the ceiling.
    public func capping(_ bundleIdentifier: String, at prefix: String?) -> ExclusionRules {
        let trimmed = prefix?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let newCeilings = trimmed.isEmpty
            ? versionCeilings.filter { $0.key != bundleIdentifier }
            : versionCeilings.merging([bundleIdentifier: trimmed]) { _, new in new }
        return copy(versionCeilings: newCeilings)
    }

    /// "Stop Ignoring" / "Include Again": removes the app-level ignore and any skipped version,
    /// but keeps a version ceiling the user set ("Stay on 5.x" is a separate, deliberate choice).
    public func unignoring(_ bundleIdentifier: String) -> ExclusionRules {
        copy(
            ignoredBundleIdentifiers: ignoredBundleIdentifiers.subtracting([bundleIdentifier]),
            skippedVersions: skippedVersions.filter { $0.key != bundleIdentifier }
        )
    }

    /// Removes every rule for the app: the ignore, any skipped version **and** the version ceiling.
    /// Only for an explicit "reset everything" action; "Stop Ignoring" uses `unignoring(_:)`.
    public func including(_ bundleIdentifier: String) -> ExclusionRules {
        ExclusionRules(
            ignoredBundleIdentifiers: ignoredBundleIdentifiers.subtracting([bundleIdentifier]),
            skippedVersions: skippedVersions.filter { $0.key != bundleIdentifier },
            versionCeilings: versionCeilings.filter { $0.key != bundleIdentifier }
        )
    }

    /// True when `version` is newer than the ceiling line and does not start with its components.
    /// "5.9" and "5.0b1" stay under "5"; "6.0" and "6.0b1" exceed it.
    public static func exceeds(_ version: String, ceiling: String) -> Bool {
        let ceilingTokens = VersionComparator.tokenize(ceiling)
        guard !ceilingTokens.isEmpty else { return false }
        let versionTokens = VersionComparator.tokenize(version)
        if Array(versionTokens.prefix(ceilingTokens.count)) == ceilingTokens { return false }
        return VersionComparator().isNewer(version, than: ceiling)
    }

    private func copy(
        ignoredBundleIdentifiers: Set<String>? = nil,
        skippedVersions: [String: String]? = nil,
        versionCeilings: [String: String]? = nil
    ) -> ExclusionRules {
        ExclusionRules(
            ignoredBundleIdentifiers: ignoredBundleIdentifiers ?? self.ignoredBundleIdentifiers,
            skippedVersions: skippedVersions ?? self.skippedVersions,
            versionCeilings: versionCeilings ?? self.versionCeilings
        )
    }
}

public protocol ExclusionRulesStoring: Sendable {
    func load() -> ExclusionRules
    func save(_ rules: ExclusionRules) throws
}

/// Persists exclusion rules as JSON in UserDefaults (non-sensitive preferences).
public struct UserDefaultsExclusionRulesStore: ExclusionRulesStoring, @unchecked Sendable {
    private static let key = "exclusionRules"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> ExclusionRules {
        guard let data = defaults.data(forKey: Self.key),
              let rules = try? JSONDecoder().decode(ExclusionRules.self, from: data)
        else { return ExclusionRules() }
        return rules
    }

    public func save(_ rules: ExclusionRules) throws {
        defaults.set(try JSONEncoder().encode(rules), forKey: Self.key)
    }
}
