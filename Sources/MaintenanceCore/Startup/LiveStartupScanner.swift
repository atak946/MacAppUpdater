import Foundation
import os

/// Discovers launchd jobs and their state.
public protocol StartupScanning: Sendable {
    func scan() async -> StartupScanResult
}

/// Reads LaunchAgents/LaunchDaemons plists and asks `launchctl` for their state.
public struct LiveStartupScanner: StartupScanning {
    private static let logger = Logger(subsystem: "com.macappupdater", category: "StartupScanner")
    /// launchd's default search path for relative `Program` values.
    static let searchPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin", "/opt/homebrew/bin"]

    private let locations: StartupLocations
    private let runner: any StartupCommandRunning
    private let signatures: any StartupSignatureReading
    private let uid: uid_t

    public init(
        locations: StartupLocations = .live(),
        runner: any StartupCommandRunning = ProcessCommandRunner(),
        signatures: any StartupSignatureReading = SecStaticCodeSignatureReader(),
        uid: uid_t = getuid()
    ) {
        self.locations = locations
        self.runner = runner
        self.signatures = signatures
        self.uid = uid
    }

    public func scan() async -> StartupScanResult {
        let resolver = StartupOwnerResolver(apps: StartupAppCatalog.apps(in: locations.applicationFolders))
        async let userOverrides = disabledOverrides(domain: LaunchdDomain.gui(uid: uid))
        async let systemOverrides = disabledOverrides(domain: "system")
        let definitions = StartupItemKind.allCases.flatMap { kind in
            plists(in: locations.folder(for: kind)).compactMap { url in definition(at: url).map { (url, kind, $0) } }
        }
        let overrides = (gui: await userOverrides, system: await systemOverrides)
        let items = await withTaskGroup(of: StartupItem.self) { group in
            for (url, kind, job) in definitions {
                let override = kind.isAgent ? overrides.gui[job.label] : overrides.system[job.label]
                group.addTask {
                    await makeItem(url: url, kind: kind, job: job, enabledOverride: override, resolver: resolver)
                }
            }
            var collected: [StartupItem] = []
            for await item in group { collected.append(item) }
            return collected
        }
        let sorted = items.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        return StartupScanResult(items: sorted, loginItems: BackgroundItemsReader.loginItems(at: locations.backgroundItemsFile))
    }

    // MARK: Building items

    private func makeItem(
        url: URL, kind: StartupItemKind, job: LaunchdJobDefinition, enabledOverride: Bool?,
        resolver: StartupOwnerResolver
    ) async -> StartupItem {
        let executable = Self.resolveExecutable(job.executablePath) { FileManager.default.fileExists(atPath: $0) }
        let owner = resolver.owner(executable: executable, label: job.label, associated: job.associatedBundleIdentifiers)
        let signature = executable.flatMap { FileManager.default.fileExists(atPath: $0.path) ? signatures.signature(of: $0) : nil }
        return StartupItem(
            plistURL: url, label: job.label, kind: kind, executableURL: executable,
            arguments: Array(job.programArguments.dropFirst(job.program == nil ? 1 : 0)),
            appName: owner?.name, appBundleURL: owner?.url, signature: signature, runAtLoad: job.runAtLoad,
            keepAlive: job.keepAlive, schedule: job.schedule, isEnabled: enabledOverride ?? !job.isDisabled,
            isLoaded: await isLoaded(job.label, kind: kind)
        )
    }

    /// Absolute paths are kept; bare names are looked up in launchd's default search path.
    static func resolveExecutable(_ path: String?, fileExists: (String) -> Bool) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        guard !expanded.contains("/") else { return nil }
        return searchPath.map { "\($0)/\(expanded)" }.first(where: fileExists).map(URL.init(fileURLWithPath:))
    }

    // MARK: Disk

    private func plists(in folder: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return entries.filter { $0.pathExtension == "plist" }
    }

    private func definition(at url: URL) -> LaunchdJobDefinition? {
        do {
            return try LaunchdJobDefinition.parse(Data(contentsOf: url))
        } catch {
            Self.logger.notice("Skipping \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: launchctl

    private func disabledOverrides(domain: String) async -> [String: Bool] {
        do {
            let output = try await runner.run(LaunchdDomain.launchctl, ["print-disabled", domain])
            return LaunchctlOutputParser.parseDisabledOverrides(output.standardOutput)
        } catch {
            Self.logger.error("print-disabled \(domain, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    private func isLoaded(_ label: String, kind: StartupItemKind) async -> Bool {
        let service = LaunchdDomain.service(label, kind: kind, uid: uid)
        return (try? await runner.run(LaunchdDomain.launchctl, ["print", service]))?.succeeded ?? false
    }
}
