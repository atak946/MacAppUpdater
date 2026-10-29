import Foundation

/// Pure rules for bundle resolution and process kind.
enum ProcessClassifier {
    /// Processes that must never be terminated.
    static let criticalNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "logd", "opendirectoryd", "configd",
        "coreservicesd", "securityd", "notifyd", "diskarbitrationd", "powerd", "syslogd", "fseventsd",
        "kextd", "watchdogd", "runningboardd",
    ]

    /// Path prefixes owned by macOS itself.
    static let systemPathPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/usr/bin/", "/bin/"]

    // MARK: - Bundles

    /// The outermost `.app` bundle enclosing `path`
    /// (`/A/Foo.app/Contents/Frameworks/X.framework/Helpers/Helper.app/…` → `/A/Foo.app`).
    static func outermostAppURL(forExecutablePath path: String) -> URL? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let index = components.dropLast().firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else { return nil }
        let bundlePath = "/" + components[...index].joined(separator: "/")
        return URL(fileURLWithPath: bundlePath, isDirectory: true)
    }

    /// True when `path` is the bundle's main executable directory (`Foo.app/Contents/MacOS/<exe>`).
    static func isMainExecutable(_ path: String?, of bundleURL: URL) -> Bool {
        guard let path else { return false }
        let prefix = bundleURL.path.hasSuffix("/") ? bundleURL.path : bundleURL.path + "/"
        let macOSDir = prefix + "Contents/MacOS/"
        guard path.hasPrefix(macOSDir) else { return false }
        return !path.dropFirst(macOSDir.count).contains("/")
    }

    // MARK: - Kind

    /// Classifies a process: critical set and pid ≤ 1 first, then the catalog, then path and owner.
    static func kind(name: String, path: String?, userID: UInt32, pid: Int32) -> ProcessKind {
        if pid <= 1 || criticalNames.contains(name) { return .critical }
        if let known = KnownProcessCatalog.info(forProcessNamed: name) { return known.kind }
        if let path, systemPathPrefixes.contains(where: path.hasPrefix) { return .system }
        if userID == 0 { return .system }
        return .user
    }

    /// Protection order used when merging kinds: critical > system > user.
    static func protectionRank(_ kind: ProcessKind) -> Int {
        switch kind {
        case .user: 0
        case .system: 1
        case .critical: 2
        }
    }
}
