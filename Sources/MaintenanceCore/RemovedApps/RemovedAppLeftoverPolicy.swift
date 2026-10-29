import Foundation

/// Decides whether a bundle identifier found in `~/Library` belongs to an app that is gone.
/// Every rule errs on the side of keeping data: when in doubt, the entry is skipped.
struct RemovedAppLeftoverPolicy: Sendable {
    /// Why an entry is not offered.
    enum SkipReason: Equatable {
        /// Not reverse-DNS, or fewer than `minimumComponents` parts (`com.vendor` is too vague).
        case notBundleIdentifier
        /// `com.apple.*` or this app's own data.
        case system
        /// An installed app has this identifier.
        case installed
        /// A running process has this identifier.
        case running
        /// An installed or running app shares the vendor namespace (helpers, updaters, shared data).
        case sameVendor
        /// A group container whose team prefix signs an installed app.
        case installedTeam
        /// LaunchServices still knows an app with this identifier.
        case knownToLaunchServices
    }

    /// `com.vendor.App` is the shortest accepted name.
    static let minimumComponents = 3
    /// Lowercased prefixes that are never offered.
    private static let excludedPrefixes = ["com.apple.", "com.macappupdater"]

    private let installed: Set<String>
    private let running: Set<String>
    private let vendors: Set<String>
    private let teams: Set<String>
    private let isKnownToLaunchServices: @Sendable (String) -> Bool

    init(snapshot: InstalledAppSnapshot, isKnownToLaunchServices: @escaping @Sendable (String) -> Bool) {
        // Bundle identifiers are case-insensitive for LaunchServices; compare them lowercased.
        installed = Set(snapshot.installedBundleIdentifiers.map { $0.lowercased() })
        running = Set(snapshot.runningBundleIdentifiers.map { $0.lowercased() })
        vendors = Set(installed.union(running).compactMap { Self.vendor(of: $0) })
        teams = snapshot.teamIdentifiers
        self.isKnownToLaunchServices = isKnownToLaunchServices
    }

    /// Nil when the entry is a leftover of a removed app, otherwise the first rule that keeps it.
    func skipReason(bundleIdentifier id: String, team: String?) -> SkipReason? {
        let lowered = id.lowercased()
        guard Self.isLongBundleIdentifier(id) else { return .notBundleIdentifier }
        if Self.excludedPrefixes.contains(where: lowered.hasPrefix) { return .system }
        if installed.contains(lowered) { return .installed }
        if running.contains(lowered) { return .running }
        if let vendor = Self.vendor(of: lowered), vendors.contains(vendor) { return .sameVendor }
        if let team, teams.contains(team) { return .installedTeam }
        // Last, as it asks the system: LaunchServices also knows helpers and apps outside the scanned folders.
        if isKnownToLaunchServices(id) { return .knownToLaunchServices }
        return nil
    }

    /// Reverse-DNS with at least `minimumComponents` non-empty parts of letters, digits, `-` and `_`.
    static func isLongBundleIdentifier(_ name: String) -> Bool {
        CleanupCategoryScanner.looksLikeBundleIdentifier(name)
            && name.split(separator: ".", omittingEmptySubsequences: false).count >= minimumComponents
    }

    /// `com.vendor` for `com.vendor.App.Helper`.
    private static func vendor(of id: String) -> String? {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        return parts.prefix(2).joined(separator: ".")
    }
}
