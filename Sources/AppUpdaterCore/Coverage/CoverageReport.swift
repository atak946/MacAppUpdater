import Foundation

public enum CoverageConstants {
    /// GitHub "owner/repo" that receives "Report Missing App" issues.
    /// CHANGE THIS to the real repository before shipping.
    public static let issueRepository = "OWNER/MacAppUpdater"
    /// Label applied to prefilled missing-app issues.
    public static let issueLabel = "missing-app"
    /// Homebrew's formulae site accepts `?search=` on its home page.
    public static let homebrewSearchBase = "https://formulae.brew.sh/"

    /// Search page on formulae.brew.sh for `query` (usually the app name).
    public static func homebrewSearchURL(for query: String) -> URL? {
        var components = URLComponents(string: homebrewSearchBase)
        components?.percentEncodedQueryItems = [
            URLQueryItem(name: "search", value: PercentEncoding.queryValue(query)),
        ]
        return components?.url
    }
}

/// Apps one source tracks.
public struct SourceCoverage: Sendable, Hashable, Identifiable {
    public var id: UpdateSourceKind { source }
    public let source: UpdateSourceKind
    public let apps: [InstalledApp]
}

/// An app for which at least one source threw while checking.
public struct FailedCoverageCheck: Sendable, Hashable, Identifiable {
    public var id: String { app.bundleIdentifier }
    public let app: InstalledApp
    /// "<source>: <message>" strings from `UpdateCheckResult.errors`.
    public let errors: [String]
    /// The source that still matched despite the errors, if any.
    public let fallbackSource: UpdateSourceKind?
}

/// Which installed apps the update sources cover. Built purely from `[UpdateCheckResult]`.
///
/// - tracked: `matchedSource != nil` (App Store apps included).
/// - untracked: no source matched and no source failed — nothing knows the app.
/// - failed: any result with errors (may overlap with tracked via `fallbackSource`).
public struct CoverageReport: Sendable, Hashable {
    public let totalApps: Int
    public let bySource: [SourceCoverage]
    public let untracked: [InstalledApp]
    public let failed: [FailedCoverageCheck]
    public let appStoreApps: [InstalledApp]
    /// Untracked apps the user chose to ignore (hidden from `untracked`, still not tracked).
    public let ignoredCount: Int

    public var trackedCount: Int { bySource.reduce(0) { $0 + $1.apps.count } }

    /// Share of apps tracked by some source, 0...1 (0 when there are no apps).
    public var trackedFraction: Double {
        totalApps == 0 ? 0 : Double(trackedCount) / Double(totalApps)
    }

    /// Rounded percentage, 0...100.
    public var trackedPercentage: Int { Int((trackedFraction * 100).rounded()) }

    public init(results: [UpdateCheckResult], ignoredBundleIdentifiers: Set<String> = []) {
        let byName: (InstalledApp, InstalledApp) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let unmatched = results.filter { $0.matchedSource == nil && $0.errors.isEmpty }.map(\.app)
        let ignored = unmatched.filter { ignoredBundleIdentifiers.contains($0.bundleIdentifier) }

        totalApps = results.count
        bySource = Self.groupBySource(results, sort: byName)
        untracked = unmatched.filter { !ignoredBundleIdentifiers.contains($0.bundleIdentifier) }.sorted(by: byName)
        ignoredCount = ignored.count
        failed = results.filter { !$0.errors.isEmpty }
            .map { FailedCoverageCheck(app: $0.app, errors: $0.errors, fallbackSource: $0.matchedSource) }
            .sorted { byName($0.app, $1.app) }
        appStoreApps = results
            .filter { $0.matchedSource == .appStore || $0.app.isFromAppStore }
            .map(\.app).sorted(by: byName)
    }

    /// Sources in `UpdateSourceKind.allCases` order, empty ones dropped.
    private static func groupBySource(
        _ results: [UpdateCheckResult], sort: (InstalledApp, InstalledApp) -> Bool
    ) -> [SourceCoverage] {
        let grouped = Dictionary(grouping: results.compactMap { result in
            result.matchedSource.map { ($0, result.app) }
        }, by: \.0)
        return UpdateSourceKind.allCases.compactMap { kind in
            guard let entries = grouped[kind], !entries.isEmpty else { return nil }
            return SourceCoverage(source: kind, apps: entries.map(\.1).sorted(by: sort))
        }
    }
}

/// RFC 3986 unreserved-only encoding; safe for query values (encodes `&`, `=`, `+`, `#`).
enum PercentEncoding {
    static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func queryValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}
