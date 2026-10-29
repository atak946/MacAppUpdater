import Foundation
import MaintenanceCore
import Testing
@testable import AppUpdater

/// Scanner returning queued reports (or an error), reporting fixed progress first.
final class FakeCleanupScanner: CleanupScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [CleanupScanReport]
    private let error: (any Error)?
    private var calls = 0

    init(reports: [CleanupScanReport] = [], error: (any Error)? = nil) {
        self.reports = reports
        self.error = error
    }

    var scanCount: Int { lock.withLock { calls } }

    func scan(
        categories: Set<CleanupCategory>,
        progress: @escaping @Sendable (CleanupScanProgress) -> Void
    ) async throws -> CleanupScanReport {
        progress(CleanupScanProgress(category: .userCaches, fractionCompleted: 0.5))
        if let error { throw error }
        return lock.withLock {
            calls += 1
            return reports.count > 1 ? reports.removeFirst() : (reports.first ?? CleanupScanReport(groups: [], scannedAt: Date()))
        }
    }
}

/// Cleaner that removes everything except the given ids, recording what it was asked to clean.
final class FakeCleanupCleaner: CleanupPerforming, @unchecked Sendable {
    private let lock = NSLock()
    private let failing: Set<String>
    private var received: [CleanupItem] = []

    init(failing: Set<String> = []) { self.failing = failing }

    var cleaned: [CleanupItem] { lock.withLock { received } }

    func clean(_ items: [CleanupItem]) async -> CleanupResult {
        lock.withLock { received = items }
        return CleanupResult(
            removed: items.filter { !failing.contains($0.id) },
            failed: items.filter { failing.contains($0.id) }.map { CleanupFailure(item: $0, reason: "Locked") }
        )
    }
}

private struct ScanError: Error, LocalizedError {
    var errorDescription: String? { "Disk unavailable" }
}

@MainActor
@Suite("CleanupModel")
struct CleanupModelTests {
    private static func item(_ name: String, _ category: CleanupCategory, size: Int64) -> CleanupItem {
        CleanupItem(url: URL(fileURLWithPath: "/tmp/cleanup/\(name)"), category: category, displayName: name, sizeInBytes: size)
    }

    private static let caches = CleanupGroup(category: .userCaches, items: [item("a", .userCaches, size: 100), item("b", .userCaches, size: 50)])
    private static let archives = CleanupGroup(category: .xcodeArchives, items: [item("c", .xcodeArchives, size: 1_000)])
    private static let report = CleanupScanReport(groups: [archives, caches], scannedAt: Date())

    @Test("scan shows the report and preselects only safe categories")
    func scanSelectsDefaults() async {
        let model = CleanupModel(scanner: FakeCleanupScanner(reports: [Self.report]), cleaner: FakeCleanupCleaner())

        await model.scan()

        #expect(model.state == .ready(Self.report))
        #expect(model.selection == ["/tmp/cleanup/a", "/tmp/cleanup/b"])
        #expect(model.selectedSize == 150)
        #expect(model.selectionState(of: Self.caches) == .all)
        #expect(model.selectionState(of: Self.archives) == .none)
    }

    @Test("scan failures surface as the failed state")
    func scanFailure() async {
        let model = CleanupModel(scanner: FakeCleanupScanner(error: ScanError()), cleaner: FakeCleanupCleaner())

        await model.scan()

        #expect(model.state == .failed("Disk unavailable"))
        #expect(model.report == nil)
    }

    @Test("toggling items and groups updates selection and the tri-state")
    func toggling() async {
        let model = CleanupModel(scanner: FakeCleanupScanner(reports: [Self.report]), cleaner: FakeCleanupCleaner())
        await model.scan()

        model.toggle(Self.caches.items[0])
        #expect(model.selectionState(of: Self.caches) == .some)
        #expect(model.selectedSize(of: Self.caches) == 50)

        model.toggleGroup(Self.caches)
        #expect(model.selectionState(of: Self.caches) == .all)

        model.toggleGroup(Self.caches)
        #expect(model.selectionState(of: Self.caches) == .none)

        model.toggleGroup(Self.archives)
        #expect(model.selectedSize == 1_000)
    }

    @Test("cleaning passes the selection, rescans and reports the result")
    func cleanSelected() async {
        let after = CleanupScanReport(groups: [Self.archives], scannedAt: Date())
        let scanner = FakeCleanupScanner(reports: [Self.report, after])
        let cleaner = FakeCleanupCleaner(failing: ["/tmp/cleanup/b"])
        let model = CleanupModel(scanner: scanner, cleaner: cleaner)
        await model.scan()

        await model.cleanSelected()

        #expect(Set(cleaner.cleaned.map(\.id)) == ["/tmp/cleanup/a", "/tmp/cleanup/b"])
        guard case .finished(let result) = model.state else {
            Issue.record("expected finished state, got \(model.state)")
            return
        }
        #expect(result.reclaimedBytes == 100)
        #expect(result.failed.map(\.item.id) == ["/tmp/cleanup/b"])
        #expect(scanner.scanCount == 2)

        model.dismissResult()
        #expect(model.state == .ready(after))
        #expect(model.selection.isEmpty)
    }

    @Test("cleaning with nothing selected does nothing")
    func cleanNothing() async {
        let cleaner = FakeCleanupCleaner()
        let model = CleanupModel(scanner: FakeCleanupScanner(reports: [Self.report]), cleaner: cleaner)
        await model.scan()
        model.toggleGroup(Self.caches)

        await model.cleanSelected()

        #expect(cleaner.cleaned.isEmpty)
        #expect(model.state == .ready(Self.report))
    }

    @Test("cancel returns to idle, or to the previous report")
    func cancel() async {
        let model = CleanupModel(scanner: FakeCleanupScanner(reports: [Self.report]), cleaner: FakeCleanupCleaner())

        model.cancel()
        #expect(model.state == .idle)

        await model.scan()
        model.startScan()
        await Task.yield()
        if model.isScanning { model.cancel() }
        #expect(model.state == .ready(Self.report))
    }
}
