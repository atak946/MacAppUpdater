import AppUpdaterCore
import Foundation
import MaintenanceCore
import MonitorCore
import os

/// Throwaway defaults suite and temporary folder for one render run; both are removed afterwards.
@MainActor
final class DemoEnvironment {
    let defaults: UserDefaults
    let directory: URL
    private let suiteName: String
    private let logger = Logger(subsystem: "com.macappupdater", category: "Screenshots")

    init() throws {
        let token = UUID().uuidString
        suiteName = "com.macappupdater.screenshots.\(token)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw DemoError.defaultsUnavailable }
        self.defaults = defaults
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAppUpdaterScreenshots-\(token)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func subdirectory(_ name: String) -> URL {
        directory.appendingPathComponent(name, isDirectory: true)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        // Flush first, or cfprefsd recreates the plist after it was removed.
        CFPreferencesAppSynchronize(suiteName as CFString)
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suiteName).plist")
        try? FileManager.default.removeItem(at: plist)
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            logger.error("Could not remove the screenshot sandbox: \(error.localizedDescription, privacy: .public)")
        }
    }

    enum DemoError: Error {
        case defaultsUnavailable
    }
}

// MARK: - Updates

struct DemoScanner: AppScanning {
    let apps: [InstalledApp]
    func scan() async throws -> [InstalledApp] { apps }
}

struct DemoChecker: UpdateChecking {
    let updates: [AvailableUpdate]

    func checkAll(_ apps: [InstalledApp]) async -> [AvailableUpdate] {
        await checkAllDetailed(apps).compactMap(\.update)
    }

    func checkAllDetailed(_ apps: [InstalledApp]) async -> [UpdateCheckResult] {
        apps.map { app in
            let update = updates.first { $0.app.bundleIdentifier == app.bundleIdentifier }
            let source: UpdateSourceKind = app.isFromAppStore ? .appStore : (update?.source ?? .homebrew)
            return UpdateCheckResult(
                app: app, matchedSource: source, latestVersion: update?.newVersion ?? app.shortVersion, update: update
            )
        }
    }
}

/// Nothing is ever downloaded or installed in screenshot mode.
struct DemoRefusingInstaller: UpdateDownloading, UpdateInstalling {
    struct Refused: Error {}
    func download(_ update: AvailableUpdate) async throws -> URL { throw Refused() }
    func install(_ update: AvailableUpdate, from packageURL: URL) async throws { throw Refused() }
}

struct DemoHelper: HelperStatusProviding {
    var status: HelperStatus { get async { .enabled } }
}

actor DemoHistory: UpdateHistoryRecording {
    private var stored: [UpdateHistoryEntry]
    init(_ entries: [UpdateHistoryEntry]) { stored = entries }
    func entries() -> [UpdateHistoryEntry] { stored }
    func record(_ entry: UpdateHistoryEntry) throws { stored.insert(entry, at: 0) }
    func clear() throws { stored = [] }
}

struct DemoFirstSeen: FirstSeenRecording {
    func record(_ updates: [AvailableUpdate]) async -> [String: ReleaseDate] {
        Dictionary(updates.compactMap { update in
            ReleaseDate.resolve(for: update, firstSeen: nil).map { (update.id, $0) }
        }) { first, _ in first }
    }

    func releaseDate(for update: AvailableUpdate) async -> ReleaseDate? {
        ReleaseDate.resolve(for: update, firstSeen: nil)
    }
}

struct DemoSizeProbe: DownloadSizeProbing {
    let sizes: [URL: Int64]
    func size(of url: URL) async -> Int64? { sizes[url] }
}

struct DemoVendorDetector: VendorManagementDetecting {
    func detect(_ app: InstalledApp) -> VendorManagement? { nil }
}

struct DemoRunningApps: RunningAppChecking {
    func isRunning(bundleIdentifier: String) async -> Bool { false }
}

struct DemoConditions: SystemConditionsProvider {
    func snapshot() async -> SystemConditionsSnapshot { SystemConditionsSnapshot(runningBundleIdentifiers: []) }
}

struct DemoReleaseNotes: ReleaseNotesLoading {
    func load(_ notes: ReleaseNotes) async throws -> ReleaseNotesContent {
        switch notes {
        case .markdown(let text): .markdown(text)
        case .html(let html): .html(html, baseURL: nil)
        case .remote: .empty
        }
    }
}

struct DemoHomebrew: HomebrewFormulaManaging {
    var isAvailable: Bool { true }
    func outdatedFormulae() async throws -> [OutdatedFormula] { DemoFixtures.formulae }
    func upgrade(_ name: String) async throws {}
}

// MARK: - Maintenance

struct DemoCleanupScanner: CleanupScanning {
    let report: CleanupScanReport
    func scan(
        categories: Set<CleanupCategory>,
        progress: @escaping @Sendable (CleanupScanProgress) -> Void
    ) async throws -> CleanupScanReport { report }
}

struct DemoCleaner: CleanupPerforming {
    func clean(_ items: [CleanupItem]) async -> CleanupResult { CleanupResult(removed: [], failed: []) }
}

struct DemoStartupScanner: StartupScanning, StartupControlling {
    func scan() async -> StartupScanResult { StartupScanResult(items: [], loginItems: []) }
    func setEnabled(_ enabled: Bool, for item: StartupItem) async throws -> StartupItem { item }
}

struct DemoSecurityChecker: SecurityChecking, PermissionAuditing {
    func runChecks() async -> SecurityReport { SecurityReport(results: [], checkedAt: Date()) }
    func audit() async -> PermissionAudit { .entries([]) }
}

// MARK: - Monitor

/// Steps through `DemoMonitorFixtures` curves, one tick per call.
actor DemoSystemSampler: SystemSampling {
    private var tick = 0
    func sample() async -> SystemSnapshot {
        tick += 1
        return DemoMonitorFixtures.systemSnapshot(tick: tick, now: Date())
    }
}

actor DemoProcessSampler: ProcessSampling {
    private let bundleURLs: [String: URL]
    private var tick = 0

    init(bundleURLs: [String: URL]) { self.bundleURLs = bundleURLs }

    func sample() async -> [ProcessSnapshot] {
        tick += 1
        let start = Date().addingTimeInterval(-DemoMonitorFixtures.uptime / 3)
        return DemoMonitorFixtures.processes.map { process in
            let bundleURL = process.appBundleID.flatMap { bundleURLs[$0] }
            let jitter = 1 + 0.15 * DemoMonitorFixtures.wave(tick, seed: Double(process.pid % 97))
            return ProcessSnapshot(
                pid: process.pid, parentPID: process.parent, name: process.name,
                executablePath: bundleURL.map { $0.appendingPathComponent("Contents/MacOS/\(process.name)").path }
                    ?? "/usr/bin/\(process.name)",
                bundleURL: bundleURL, bundleIdentifier: process.appBundleID, userID: process.userID,
                cpuPercent: process.cpu * jitter, memoryBytes: UInt64(process.megabytes * 1_048_576),
                threadCount: process.threads, startDate: start, kind: process.kind
            )
        }
    }
}

struct DemoNetworkSampler: ProcessNetworkSampling {
    func sample() async -> [Int32: NetworkThroughput]? {
        Dictionary(uniqueKeysWithValues: DemoMonitorFixtures.processes.filter { $0.network > 0 }.map { process in
            (process.pid, NetworkThroughput(bytesInPerSecond: process.network * 0.85, bytesOutPerSecond: process.network * 0.15))
        })
    }
}

struct DemoPortScanner: PortScanning, ProcessTerminating {
    func listeningPorts() async -> [ListeningPort] {
        DemoMonitorFixtures.processes.flatMap { process in
            process.ports.map { ListeningPort(pid: process.pid, port: $0, transport: "TCP", address: "127.0.0.1") }
        }
    }

    func terminate(_ process: ProcessSnapshot, mode: TerminationMode) async throws(TerminationError) {
        throw .notPermitted
    }
}

/// Per-minute usage for the last 24 hours, with one sustained heavy stretch.
struct DemoUsageRecorder: ProcessUsageRecording {
    let bundleURLs: [String: URL]
    let now: Date

    func record(now minute: Date) async -> UsageMinute? {
        let hoursAgo = now.timeIntervalSince(minute) / 3600
        let index = Int(minute.timeIntervalSince1970 / 60)
        // Quieter at night (more than 10 hours ago), busy during the working day.
        let activity = hoursAgo > 10 && hoursAgo < 17 ? 0.15 : 1
        let apps = DemoMonitorFixtures.usageApps.map { app in
            var cpu = app.cpu * activity * (1 + 0.35 * DemoMonitorFixtures.wave(index, seed: Double(app.name.count)))
            if let stretch = app.busyStretch, hoursAgo <= stretch.0, hoursAgo >= stretch.1 { cpu = 92 }
            return AppUsageSample(
                id: app.bundleID, name: app.name, bundlePath: bundleURLs[app.bundleID]?.path,
                cpuPercent: max(0.1, cpu), memoryBytes: UInt64(app.megabytes * 1_048_576)
            )
        }
        return UsageMinute(timestamp: minute, seconds: 60, apps: apps)
    }
}
