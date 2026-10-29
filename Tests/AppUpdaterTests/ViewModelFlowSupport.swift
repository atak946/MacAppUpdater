import AppUpdaterCore
import Foundation
@testable import AppUpdater

// Extra collaborators for view-model flow tests (gating, failures, backups).

/// A one-shot latch: `wait()` suspends until `open()` is called (or returns at once afterwards).
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Yields the main actor until `condition` holds (bounded, no sleeps). Returns the final value.
@MainActor
func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<10_000 where !condition() {
        await Task.yield()
    }
    return condition()
}

struct FailingScanner: AppScanning {
    struct Failure: LocalizedError {
        var errorDescription: String? { "Disk unreadable" }
    }

    func scan() async throws -> [InstalledApp] { throw Failure() }
}

/// Scans only after the gate opens, so a refresh can be observed mid-flight.
struct GatedScanner: AppScanning {
    let apps: [InstalledApp]
    let gate: Gate

    func scan() async throws -> [InstalledApp] {
        await gate.wait()
        return apps
    }
}

/// Reports `fractions`, then waits for the gate before returning the file.
struct GatedProgressDownloader: ProgressReportingDownloading {
    let fractions: [Double]
    let gate: Gate
    var file = URL(fileURLWithPath: "/tmp/stub-progress.dmg")

    func download(_ update: AvailableUpdate) async throws -> URL {
        try await download(update) { _ in }
    }

    func download(_ update: AvailableUpdate, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        fractions.forEach(progress)
        await gate.wait()
        return file
    }
}

struct FailingDownloader: UpdateDownloading {
    let error: any Error
    func download(_ update: AvailableUpdate) async throws -> URL { throw error }
}

/// Fixed downloaded file (e.g. a `.pkg` inside an `AppUpdater-<UUID>` folder).
struct FileDownloader: UpdateDownloading {
    let file: URL
    func download(_ update: AvailableUpdate) async throws -> URL { file }
}

actor StubBackupStore: AppBackupStoring {
    struct Failure: LocalizedError {
        var errorDescription: String? { "Backup is damaged" }
    }

    private var stored: [String: [AppBackup]]
    private let failRestore: Bool
    private(set) var restored: [AppBackup] = []

    init(_ backups: [AppBackup] = [], failRestore: Bool = false) {
        stored = Dictionary(grouping: backups, by: \.bundleIdentifier)
            .mapValues { $0.sorted { $0.createdAt > $1.createdAt } }
        self.failRestore = failRestore
    }

    func backUp(_ app: InstalledApp) async throws -> AppBackup { throw Failure() }
    func backups(for bundleIdentifier: String) async throws -> [AppBackup] { stored[bundleIdentifier] ?? [] }
    func restore(_ backup: AppBackup, over app: InstalledApp) async throws {
        if failRestore { throw Failure() }
        restored.append(backup)
        stored[backup.bundleIdentifier] = stored[backup.bundleIdentifier]?.filter { $0 != backup }
    }
    func delete(_ backup: AppBackup) async throws {}
    func pruneAll() async throws {}
}

/// History whose writes always fail but which still serves `seed`.
actor FailingHistory: UpdateHistoryRecording {
    struct Failure: Error {}
    private let seed: [UpdateHistoryEntry]

    init(seed: [UpdateHistoryEntry] = []) { self.seed = seed }

    func entries() -> [UpdateHistoryEntry] { seed }
    func record(_ entry: UpdateHistoryEntry) throws { throw Failure() }
    func clear() throws { throw Failure() }
}

final class FailingExclusions: ExclusionRulesStoring, @unchecked Sendable {
    struct Failure: Error {}
    private let rules: ExclusionRules
    init(_ rules: ExclusionRules = ExclusionRules()) { self.rules = rules }
    func load() -> ExclusionRules { rules }
    func save(_ rules: ExclusionRules) throws { throw Failure() }
}

/// Counts scans so tests can tell whether a refresh ran.
final class CountingScanner: AppScanning, @unchecked Sendable {
    private let apps: [InstalledApp]
    private let lock = NSLock()
    private var count = 0

    init(apps: [InstalledApp]) { self.apps = apps }
    var scans: Int { lock.withLock { count } }

    func scan() async throws -> [InstalledApp] {
        lock.withLock { count += 1 }
        return apps
    }
}

enum BackupFixtures {
    static func backup(_ id: String, version: String, age: TimeInterval) -> AppBackup {
        AppBackup(
            bundleIdentifier: id, appName: id.capitalized, version: version,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000 - age),
            bundleURL: URL(fileURLWithPath: "/tmp/backups/\(id)-\(version).app")
        )
    }
}

extension UpdatesViewModel.InstallState {
    var isManualAction: Bool {
        if case .needsManualAction = self { return true }
        return false
    }
}
