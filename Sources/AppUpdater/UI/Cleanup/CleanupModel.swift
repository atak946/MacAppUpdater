import Foundation
import MaintenanceCore
import Observation
import os

/// Drives the Cleanup screen: scan, selection and moving items to the Trash.
@MainActor
@Observable
final class CleanupModel {
    enum State: Equatable {
        case idle
        /// `progress` is 0...1; `category` is the one being scanned, nil before the first report.
        case scanning(progress: Double, category: CleanupCategory?)
        case ready(CleanupScanReport)
        case cleaning
        case finished(CleanupResult)
        case failed(String)
    }

    /// Selection of a whole category.
    enum GroupSelection: Equatable {
        case none
        case some
        case all
    }

    private(set) var state: State = .idle
    /// Latest successful scan; survives cleaning so "Done" can go back to it.
    private(set) var report: CleanupScanReport?
    private(set) var selection: Set<CleanupItem.ID> = []

    private let scanner: any CleanupScanning
    private let cleaner: any CleanupPerforming
    private let logger = Logger(subsystem: "com.macappupdater", category: "CleanupModel")
    /// Bumped on every scan or cancel so stale progress callbacks and results are ignored.
    private var generation = 0
    private var scanTask: Task<CleanupScanReport, any Error>?

    init(scanner: any CleanupScanning, cleaner: any CleanupPerforming) {
        self.scanner = scanner
        self.cleaner = cleaner
    }

    // MARK: Derived

    var isScanning: Bool {
        if case .scanning = state { return true }
        return false
    }

    var isBusy: Bool { isScanning || state == .cleaning }

    var selectedItems: [CleanupItem] {
        guard let report else { return [] }
        return report.groups.flatMap(\.items).filter { selection.contains($0.id) }
    }

    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.sizeInBytes } }

    /// True when the selection contains Trash items, which are deleted permanently.
    var selectionIncludesTrash: Bool { selectedItems.contains { $0.category == .trash } }

    func isSelected(_ item: CleanupItem) -> Bool { selection.contains(item.id) }

    func selectionState(of group: CleanupGroup) -> GroupSelection {
        selectionState(of: group.items)
    }

    /// Selection of any subset of items, e.g. one removed app's leftovers.
    func selectionState(of items: [CleanupItem]) -> GroupSelection {
        let count = items.lazy.filter { self.selection.contains($0.id) }.count
        if count == 0 { return .none }
        return count == items.count ? .all : .some
    }

    func selectedSize(of group: CleanupGroup) -> Int64 {
        group.items.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.sizeInBytes }
    }

    // MARK: Selection

    func toggle(_ item: CleanupItem) {
        if selection.contains(item.id) {
            selection = selection.subtracting([item.id])
        } else {
            selection = selection.union([item.id])
        }
    }

    /// Selects every item of the group, or clears it when everything is already selected.
    func toggleGroup(_ group: CleanupGroup) {
        toggleItems(group.items)
    }

    /// Selects every one of `items`, or clears them when all are already selected.
    func toggleItems(_ items: [CleanupItem]) {
        let ids = Set(items.map(\.id))
        selection = selectionState(of: items) == .all ? selection.subtracting(ids) : selection.union(ids)
    }

    // MARK: Scanning

    /// Fire-and-forget entry point for buttons.
    func startScan() {
        Task { await scan() }
    }

    /// Scans every category; progress arrives one category at a time.
    func scan() async {
        guard !isBusy else { return }
        generation += 1
        let current = generation
        state = .scanning(progress: 0, category: nil)
        let scanner = scanner
        let onProgress: @Sendable (CleanupScanProgress) -> Void = { [weak self] progress in
            Task { @MainActor in self?.apply(progress, generation: current) }
        }
        let task = Task {
            try await scanner.scan(categories: Set(CleanupCategory.allCases), progress: onProgress)
        }
        scanTask = task
        defer { if current == generation { scanTask = nil } }
        do {
            let report = try await task.value
            guard current == generation, !task.isCancelled else { return }
            show(report)
        } catch {
            guard current == generation, !task.isCancelled, !(error is CancellationError) else { return }
            logger.error("Cleanup scan failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    /// Stops a running scan and returns to the previous report, or to the start screen.
    func cancel() {
        guard isScanning else { return }
        generation += 1
        scanTask?.cancel()
        scanTask = nil
        state = report.map(State.ready) ?? .idle
    }

    private func apply(_ progress: CleanupScanProgress, generation: Int) {
        guard generation == self.generation, isScanning else { return }
        state = .scanning(progress: min(max(progress.fractionCompleted, 0), 1), category: progress.category)
    }

    private func show(_ report: CleanupScanReport) {
        self.report = report
        selection = Self.defaultSelection(for: report)
        state = .ready(report)
    }

    static func defaultSelection(for report: CleanupScanReport) -> Set<CleanupItem.ID> {
        Set(report.groups.filter(\.category.isSelectedByDefault).flatMap(\.items).map(\.id))
    }

    // MARK: Cleaning

    /// Moves the selection to the Trash, then rescans so the report reflects the disk again.
    func cleanSelected() async {
        let items = selectedItems
        guard !items.isEmpty, !isBusy else { return }
        state = .cleaning
        state = .finished(await clean(items))
    }

    /// Categories an unattended run (Shortcuts) may clean: the cache-like defaults. Logs and the
    /// Trash are preselected on screen too, but logs aren't caches and the Trash is deleted for good.
    static let unattendedCategories: Set<CleanupCategory> = Set(
        CleanupCategory.allCases.filter(\.isSelectedByDefault)
    ).subtracting([.logs, .trash])

    /// Shortcuts path: scans `unattendedCategories` and cleans what the screen would preselect.
    /// Returns nil when a scan or clean is already running.
    func cleanUnattended() async throws -> CleanupResult? {
        guard !isBusy else { return nil }
        state = .cleaning
        let scanned: CleanupScanReport
        do {
            scanned = try await scanner.scan(categories: Self.unattendedCategories) { _ in }
        } catch {
            logger.error("Unattended cleanup scan failed: \(error.localizedDescription, privacy: .public)")
            state = report.map(State.ready) ?? .idle
            throw error
        }
        let selected = Self.defaultSelection(for: scanned)
        let items = scanned.groups
            .filter { Self.unattendedCategories.contains($0.category) }
            .flatMap(\.items)
            .filter { selected.contains($0.id) }
        let result = await clean(items)
        state = .finished(result)
        return result
    }

    /// Moves `items` to the Trash, logs failures and refreshes the report.
    private func clean(_ items: [CleanupItem]) async -> CleanupResult {
        let result = items.isEmpty ? CleanupResult(removed: [], failed: []) : await cleaner.clean(items)
        for failure in result.failed {
            logger.error("Cleanup failed for \(failure.item.url.path, privacy: .public): \(failure.reason, privacy: .public)")
        }
        await rescanQuietly()
        return result
    }

    /// "Done" on the result screen: back to the fresh report.
    func dismissResult() {
        state = report.map(State.ready) ?? .idle
    }

    private func rescanQuietly() async {
        generation += 1
        do {
            let fresh = try await scanner.scan(categories: Set(CleanupCategory.allCases)) { _ in }
            report = fresh
            selection = Self.defaultSelection(for: fresh)
        } catch {
            logger.error("Cleanup rescan failed: \(error.localizedDescription, privacy: .public)")
            report = nil
            selection = []
        }
    }

    #if DEBUG
    /// Shows a canned report so the screen can be reviewed before the engine finds anything.
    func loadSample() {
        guard !isBusy else { return }
        show(CleanupSample.report)
    }
    #endif
}
