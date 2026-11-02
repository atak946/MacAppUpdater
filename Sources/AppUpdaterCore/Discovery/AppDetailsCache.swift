import Foundation

/// Remembers `AppDetails` per installed bundle so Insights does not walk every bundle on disk
/// and re-validate every code signature on each launch.
///
/// The key covers the bundle id, version and the modification dates of `Contents`, the main
/// executable and `_CodeSignature/CodeResources`: reinstalling, updating or re-signing an app
/// rewrites at least one of them, so a changed signer is still read (and warned about) on the
/// next collection. Entries for apps that are no longer installed are dropped by `retain(only:)`.
public actor AppDetailsCache {
    public enum Storage: Sendable {
        case memory
        case standardDefaults
        case defaultsSuite(String)
    }

    public static let defaultsKey = "insights.appDetails.v1"

    private var entries: [String: AppDetails]
    private var isDirty = false
    private let defaults: UserDefaults?

    public init(storage: Storage = .memory) {
        let defaults: UserDefaults? = switch storage {
        case .memory: nil
        case .standardDefaults: .standard
        case .defaultsSuite(let name): UserDefaults(suiteName: name)
        }
        self.defaults = defaults
        entries = defaults?.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([String: AppDetails].self, from: $0) } ?? [:]
    }

    /// Cached details for the bundle as it is on disk now, else `read()` and remember the result.
    func details(for app: InstalledApp, read: @Sendable () async -> AppDetails) async -> AppDetails {
        let key = Self.key(for: app)
        if let cached = entries[key] { return cached }
        let details = await read()
        entries = entries.merging([key: details]) { _, new in new }
        isDirty = true
        return details
    }

    /// Drops entries of apps (or versions) that are gone and writes the cache once per collection.
    func retain(only apps: [InstalledApp]) {
        let current = Set(apps.map(Self.key(for:)))
        let kept = entries.filter { current.contains($0.key) }
        if kept.count != entries.count {
            entries = kept
            isDirty = true
        }
        persist()
    }

    static func key(for app: InstalledApp) -> String {
        let contents = app.url.appendingPathComponent("Contents")
        let watched = [
            contents,
            Bundle(url: app.url)?.executableURL,
            contents.appendingPathComponent("_CodeSignature/CodeResources"),
        ]
        let stamps = watched.map { url -> String in
            let modified = url.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]) }?
                .contentModificationDate
            return modified.map { String(Int($0.timeIntervalSince1970)) } ?? "-"
        }
        return ([app.bundleIdentifier, app.shortVersion] + stamps).joined(separator: "@")
    }

    private func persist() {
        guard isDirty, let defaults else { return }
        isDirty = false
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
