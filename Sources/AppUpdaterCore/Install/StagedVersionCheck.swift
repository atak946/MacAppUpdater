import Foundation

/// Downgrade / version-spoofing guard for staged bundles (M-2).
///
/// The feed's version string alone decides that an update is "newer"; this check reads the
/// staged bundle's own Info.plist instead:
/// 1. the staged (short version, build) must be newer than the installed one
///    (builds are compared only when the short versions are equal);
/// 2. when the advertised version is a plain dotted number (`1.2.3`, `v2.0`), it must equal the
///    staged short version or build, or refine the short version (Homebrew lists Android Studio
///    as `2026.2.2.8` while the bundle says `2026.2`). Free-form versions skip this step.
///
/// The explicit rollback path (`BackupStore.restore`) never runs this check.
struct StagedVersionCheck: Sendable {
    private let comparator = VersionComparator()

    func validate(
        staged: (shortVersion: String, build: String?),
        installed: (shortVersion: String, build: String?),
        advertised: String?
    ) throws {
        let order = comparator.compare(
            shortVersion: staged.shortVersion, build: staged.build,
            to: installed.shortVersion, build: installed.build
        )
        guard order == .orderedDescending else {
            throw UpdaterError.installFailed(
                "Update is not newer than the installed version (\(Self.describe(staged)) vs \(Self.describe(installed)))"
            )
        }
        guard let advertised, Self.isComparable(advertised) else { return }
        let matches = comparator.compare(advertised, staged.shortVersion) == .orderedSame
            || staged.build.map { comparator.compare(advertised, $0) == .orderedSame } == true
            || Self.isRefinement(advertised, of: staged.shortVersion)
        guard matches else {
            throw UpdaterError.installFailed(
                "Downloaded version \(Self.describe(staged)) does not match the advertised version \(advertised)"
            )
        }
    }

    /// True when `advertised` extends the staged short version's numeric components
    /// (`2026.2.2.8` refines `2026.2`); the staged version must have at least two components.
    static func isRefinement(_ advertised: String, of stagedShort: String) -> Bool {
        let long = numericComponents(advertised)
        let short = numericComponents(stagedShort)
        guard let long, let short, short.count >= 2, long.count > short.count else { return false }
        return Array(long.prefix(short.count)) == short
    }

    private static func numericComponents(_ version: String) -> [Int]? {
        guard isComparable(version) else { return nil }
        var text = Substring(version.trimmingCharacters(in: .whitespaces))
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        let parts = text.split(separator: ".").compactMap { Int($0) }
        return parts.isEmpty ? nil : parts
    }

    /// `v`? followed by 1–6 dot-separated numbers.
    static func isComparable(_ version: String) -> Bool {
        var text = Substring(version.trimmingCharacters(in: .whitespaces))
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return (1...6).contains(parts.count) && parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
        }
    }

    private static func describe(_ version: (shortVersion: String, build: String?)) -> String {
        version.build.map { "\(version.shortVersion) (\($0))" } ?? version.shortVersion
    }
}

public extension VersionComparator {
    /// `2026.2.2.8` refines `2026.2`: the advertised version adds components the bundle omits.
    func isRefinement(_ advertised: String, of shortVersion: String) -> Bool {
        StagedVersionCheck.isRefinement(advertised, of: shortVersion)
    }
}
