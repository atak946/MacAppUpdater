import Foundation

/// Layers administrator-forced ignores on top of the user's exclusion rules.
///
/// - `load()` returns the user's rules plus every forced ignored bundle identifier.
/// - `save(_:)` persists only the user's own choices: forced identifiers are never
///   written (unless the user had already ignored them before management), so removing
///   the profile restores exactly what the user had. Forced ignores cannot be removed:
///   the next `load()` always adds them back.
public struct ManagedExclusionRulesStore: ExclusionRulesStoring {
    private let base: any ExclusionRulesStoring
    private let configuration: ManagedConfiguration

    public init(base: any ExclusionRulesStoring, configuration: ManagedConfiguration) {
        self.base = base
        self.configuration = configuration
    }

    public var forcedIgnoredBundleIdentifiers: Set<String> {
        configuration.ignoredBundleIdentifiers
    }

    public func isForced(_ bundleIdentifier: String) -> Bool {
        configuration.isIgnoreLocked(bundleIdentifier)
    }

    public func load() -> ExclusionRules {
        forcedIgnoredBundleIdentifiers.reduce(base.load()) { rules, bundleID in
            rules.ignoring(bundleID)
        }
    }

    public func save(_ rules: ExclusionRules) throws {
        let forced = forcedIgnoredBundleIdentifiers
        guard !forced.isEmpty else { return try base.save(rules) }
        let stored = base.load()
        let userIgnored = rules.ignoredBundleIdentifiers.subtracting(forced)
            .union(stored.ignoredBundleIdentifiers.intersection(forced))
        try base.save(Self.replacingIgnored(in: rules, with: userIgnored))
    }

    /// Swaps the ignored set while keeping every other rule.
    ///
    /// Extension point: when `ExclusionRules` gains fields, pass them through here
    /// so they survive a save.
    static func replacingIgnored(in rules: ExclusionRules, with ignored: Set<String>) -> ExclusionRules {
        ExclusionRules(
            ignoredBundleIdentifiers: ignored,
            skippedVersions: rules.skippedVersions,
            versionCeilings: rules.versionCeilings
        )
    }
}
