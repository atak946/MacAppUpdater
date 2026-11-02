import Foundation

/// Finds space Claude apps leave behind (`.claudeLeftovers`): superseded Claude Code builds,
/// the Cowork VM image and the Claude desktop app's Chromium caches.
/// The Claude Code build `~/.local/bin/claude` points to, and the desktop app's newest bundled
/// Claude Code, are never offered.
struct ClaudeLeftoverFinder: Sendable {
    // MARK: Constants

    /// Claude Code CLI builds, one file per version.
    static let cliVersions = ".local/share/claude/versions"
    /// The `claude` command; a symlink into `cliVersions`.
    static let cliLauncher = ".local/bin/claude"
    static let desktopSupport = "Library/Application Support/Claude"
    /// Claude Code builds bundled by the desktop app, one folder per version.
    static let desktopClaudeCode = "\(desktopSupport)/claude-code"
    /// Cowork's virtual machine image (about 12 GB); downloaded again when Cowork is used.
    static let coworkVM = "\(desktopSupport)/vm_bundles"
    /// Chromium cache folders the desktop app rebuilds on demand.
    static let desktopCacheNames = [
        "Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache", "GPUPersistentCache",
    ]

    let locations: CleanupLocations
    let inspector: CleanupFileInspector
    let makeItem: @Sendable (URL, String) throws -> CleanupItem?

    func items() throws -> [CleanupItem] {
        try oldCLIVersions() + oldDesktopClaudeCode() + coworkVM() + desktopCaches()
    }

    // MARK: Claude Code builds

    private func oldCLIVersions() throws -> [CleanupItem] {
        let builds = inspector.children(of: locations.url(Self.cliVersions))
        let inUse = locations.url(Self.cliLauncher).resolvingSymlinksInPath().lastPathComponent
        return try superseded(builds, keeping: inUse).compactMap { build in
            try makeItem(build, "Claude Code \(build.lastPathComponent)")
        }
    }

    private func oldDesktopClaudeCode() throws -> [CleanupItem] {
        let builds = inspector.children(of: locations.url(Self.desktopClaudeCode)).filter(inspector.isDirectory)
        return try superseded(builds, keeping: nil).compactMap { build in
            try makeItem(build, "Claude Desktop — Claude Code \(build.lastPathComponent)")
        }
    }

    /// Every build except the newest version and `keeping` (the one in use).
    private func superseded(_ builds: [URL], keeping inUse: String?) -> [URL] {
        let newest = builds.map(\.lastPathComponent).max { Self.isOlder($0, than: $1) }
        return builds.filter { build in
            let name = build.lastPathComponent
            return name != newest && name != inUse
        }
    }

    /// Numeric version order: 2.1.99 is older than 2.1.300.
    static func isOlder(_ lhs: String, than rhs: String) -> Bool {
        lhs.compare(rhs, options: .numeric) == .orderedAscending
    }

    // MARK: Desktop app

    private func coworkVM() throws -> [CleanupItem] {
        try inspector.children(of: locations.url(Self.coworkVM)).compactMap { bundle in
            try makeItem(bundle, "Cowork VM — \(bundle.lastPathComponent)")
        }
    }

    /// Top-level caches plus those of each web partition (`Partitions/<name>/Cache`).
    private func desktopCaches() throws -> [CleanupItem] {
        let support = locations.url(Self.desktopSupport)
        let partitions = inspector.children(of: support.appendingPathComponent("Partitions")).filter(inspector.isDirectory)
        return try ([support] + partitions).flatMap { folder in
            try Self.desktopCacheNames.compactMap { name in
                let url = folder.appendingPathComponent(name, isDirectory: true)
                guard inspector.isDirectory(url) else { return nil }
                let owner = folder == support ? "" : "\(folder.lastPathComponent)/"
                return try makeItem(url, "Claude Desktop — \(owner)\(name)")
            }
        }
    }
}
