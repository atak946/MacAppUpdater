import Foundation

/// Well-known locations inside a (possibly injected) home directory.
struct CleanupLocations: Sendable {
    // MARK: Package managers

    /// A package-manager cache folder and its user-facing name.
    struct PackageManagerCache: Sendable {
        let relativePath: String
        let displayName: String
    }

    /// Package-manager caches reported under `.packageManagerCaches`.
    static let packageManagerCaches: [PackageManagerCache] = [
        PackageManagerCache(relativePath: ".npm/_cacache", displayName: "npm cache"),
        PackageManagerCache(relativePath: "Library/Caches/Yarn", displayName: "Yarn cache"),
        PackageManagerCache(relativePath: "Library/pnpm/store", displayName: "pnpm store"),
        PackageManagerCache(relativePath: ".gradle/caches", displayName: "Gradle caches"),
        PackageManagerCache(relativePath: ".nuget/packages", displayName: "NuGet packages"),
        PackageManagerCache(relativePath: "Library/Caches/CocoaPods", displayName: "CocoaPods cache"),
        PackageManagerCache(relativePath: "Library/Caches/org.swift.swiftpm", displayName: "SwiftPM cache"),
        PackageManagerCache(relativePath: "Library/Caches/Homebrew", displayName: "Homebrew downloads"),
    ]

    /// Device support folder names under `~/Library/Developer/Xcode`, with their platform label.
    static let deviceSupportFolders: [(folder: String, platform: String)] = [
        ("iOS DeviceSupport", "iOS"),
        ("watchOS DeviceSupport", "watchOS"),
        ("tvOS DeviceSupport", "tvOS"),
        ("visionOS DeviceSupport", "visionOS"),
    ]

    /// Home-relative folders that must never be removed themselves.
    static let protectedRelativePaths = ["Library", "Library/Caches", "Downloads", "Documents", "Desktop", ".Trash"]

    // MARK: Paths

    let home: URL

    init(home: URL) {
        self.home = home.standardizedFileURL
    }

    /// Builds a URL below home from a slash-separated relative path.
    func url(_ relativePath: String) -> URL {
        home.appendingPathComponent(relativePath, isDirectory: true)
    }

    var library: URL { url("Library") }
    var caches: URL { url("Library/Caches") }
    var logs: URL { url("Library/Logs") }
    var diagnosticReports: URL { url("Library/Logs/DiagnosticReports") }
    var xcode: URL { url("Library/Developer/Xcode") }
    var derivedData: URL { url("Library/Developer/Xcode/DerivedData") }
    var archives: URL { url("Library/Developer/Xcode/Archives") }
    var simulatorCaches: URL { url("Library/Developer/CoreSimulator/Caches") }
    var trash: URL { url(".Trash") }
    var downloads: URL { url("Downloads") }

    /// Names of `~/Library/Caches` children that belong to `.packageManagerCaches`.
    var packageManagerCacheNamesInCaches: Set<String> {
        let prefix = "Library/Caches/"
        return Set(Self.packageManagerCaches.compactMap { cache in
            cache.relativePath.hasPrefix(prefix) ? String(cache.relativePath.dropFirst(prefix.count)) : nil
        })
    }
}
