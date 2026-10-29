import Foundation
import os

/// Reads the state of the built-in macOS protections with system tools and preference files.
/// Everything is read-only and works without administrator rights; unreadable settings are `.unknown`.
public struct SystemSecurityChecker: SecurityChecking {
    /// Locations read by the checker; overridable for tests.
    public struct Paths: Sendable {
        public var softwareUpdatePreferences: URL
        /// XProtect bundles, newest one wins (macOS 15+ updates the one under /private/var/protected).
        public var xprotectBundles: [URL]

        public init(softwareUpdatePreferences: URL, xprotectBundles: [URL]) {
            self.softwareUpdatePreferences = softwareUpdatePreferences
            self.xprotectBundles = xprotectBundles
        }

        public static let system = Paths(
            softwareUpdatePreferences: URL(fileURLWithPath: "/Library/Preferences/com.apple.SoftwareUpdate.plist"),
            xprotectBundles: [
                URL(fileURLWithPath: "/Library/Apple/System/Library/CoreServices/XProtect.bundle"),
                URL(fileURLWithPath: "/private/var/protected/xprotect/XProtect.bundle"),
            ]
        )
    }

    private enum Tool {
        static let fdesetup = "/usr/bin/fdesetup"
        static let socketFilter = "/usr/libexec/ApplicationFirewall/socketfilterfw"
        static let csrutil = "/usr/bin/csrutil"
        static let spctl = "/usr/sbin/spctl"
        static let sysadminctl = "/usr/sbin/sysadminctl"
        static let launchctl = "/bin/launchctl"
    }

    private static let logger = Logger(subsystem: "com.macappupdater", category: "SecurityChecker")
    private let runner: any SecurityCommandRunning
    private let paths: Paths
    private let now: @Sendable () -> Date

    public init(
        runner: any SecurityCommandRunning = ProcessSecurityCommandRunner(),
        paths: Paths = .system,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.runner = runner
        self.paths = paths
        self.now = now
    }

    public func runChecks() async -> SecurityReport {
        let results = await withTaskGroup(of: SecurityCheckResult.self) { group in
            for kind in SecurityCheckKind.allCases {
                group.addTask { await check(kind) }
            }
            var collected: [SecurityCheckResult] = []
            for await result in group { collected.append(result) }
            return collected
        }
        let order = SecurityCheckKind.allCases
        let sorted = results.sorted { order.firstIndex(of: $0.kind)! < order.firstIndex(of: $1.kind)! }
        Self.logger.info("Security checks finished, score \(SecurityScore.score(for: sorted) ?? -1, privacy: .public)")
        return SecurityReport(results: sorted, checkedAt: now())
    }

    // MARK: Checks

    private func check(_ kind: SecurityCheckKind) async -> SecurityCheckResult {
        switch kind {
        case .fileVault:
            return await tool(kind, Tool.fdesetup, ["status"], SecurityOutputParser.fileVault)
        case .firewall:
            return await tool(kind, Tool.socketFilter, ["--getglobalstate"], SecurityOutputParser.firewall)
        case .firewallStealth:
            return await tool(kind, Tool.socketFilter, ["--getstealthmode"], SecurityOutputParser.stealthMode)
        case .systemIntegrityProtection:
            return await tool(kind, Tool.csrutil, ["status"], SecurityOutputParser.systemIntegrityProtection)
        case .gatekeeper:
            return await tool(kind, Tool.spctl, ["--status"], SecurityOutputParser.gatekeeper)
        case .screenLock:
            guard let output = await runner.run(Tool.sysadminctl, arguments: ["-screenLock", "status"]) else {
                return SecurityCheckResult(kind: kind, status: .unknown)
            }
            let parsed = SecurityOutputParser.screenLock(output.text)
            return SecurityCheckResult(kind: kind, status: parsed.status, detail: parsed.delaySeconds.map(String.init))
        case .remoteLogin:
            guard let output = await runner.run(Tool.launchctl, arguments: ["print", "system/com.openssh.sshd"]) else {
                return SecurityCheckResult(kind: kind, status: .unknown)
            }
            let status = SecurityOutputParser.remoteLogin(exitStatus: output.status, output: output.text)
            return SecurityCheckResult(kind: kind, status: status)
        case .automaticUpdates:
            return automaticUpdates()
        case .xprotect:
            return xprotect()
        }
    }

    private func tool(
        _ kind: SecurityCheckKind, _ executable: String, _ arguments: [String],
        _ parse: (String) -> SecurityCheckStatus
    ) async -> SecurityCheckResult {
        guard let output = await runner.run(executable, arguments: arguments) else {
            return SecurityCheckResult(kind: kind, status: .unknown)
        }
        return SecurityCheckResult(kind: kind, status: parse(output.text))
    }

    private func automaticUpdates() -> SecurityCheckResult {
        let preferences = (try? Data(contentsOf: paths.softwareUpdatePreferences)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        }
        let installsMacOS = SecurityOutputParser.installsMacOSUpdates(preferences)
        return SecurityCheckResult(
            kind: .automaticUpdates,
            status: SecurityOutputParser.automaticUpdates(preferences),
            detail: installsMacOS.map { $0 ? "installsMacOS" : "downloadsOnly" }
        )
    }

    private func xprotect() -> SecurityCheckResult {
        let newest = paths.xprotectBundles.compactMap(Self.xprotectVersion).max { $0.date < $1.date }
        return SecurityCheckResult(
            kind: .xprotect,
            status: SecurityOutputParser.xprotect(updatedAt: newest?.date, now: now()),
            detail: newest?.version,
            date: newest?.date
        )
    }

    /// Version and modification date of an XProtect bundle's `version.plist`.
    private static func xprotectVersion(_ bundle: URL) -> (version: String?, date: Date)? {
        let plist = bundle.appending(path: "Contents/version.plist")
        guard let date = try? plist.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            return nil
        }
        let info = (try? Data(contentsOf: plist)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        }
        return (info?["CFBundleShortVersionString"] as? String, date)
    }
}
