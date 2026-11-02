import Foundation
import MaintenanceCore
import Testing
@testable import AppUpdater

/// Scanner answering each folder with a canned tree; records which folders were scanned.
private final class FakeDiskUsageScanner: DiskUsageScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var trees: [String: DiskUsageNode]
    private var scanned: [String] = []

    init(_ trees: [String: DiskUsageNode]) { self.trees = trees }

    var scannedPaths: [String] { lock.withLock { scanned } }

    func set(_ tree: DiskUsageNode, for url: URL) { lock.withLock { trees[url.path] = tree } }

    func scan(
        _ root: URL,
        progress: @escaping @Sendable (DiskUsageScanProgress) -> Void
    ) async throws -> DiskUsageNode {
        lock.withLock {
            scanned.append(root.path)
            return trees[root.path] ?? DiskUsageNode(url: root, name: root.lastPathComponent, kind: .folder, sizeInBytes: 0, fileCount: 0)
        }
    }
}

private struct NoopCleaner: CleanupPerforming {
    func clean(_ items: [CleanupItem]) async -> CleanupResult { CleanupResult(removed: items, failed: []) }
}

@MainActor
@Suite("Disk usage model")
struct DiskUsageModelTests {
    private let base: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("DiskUsageModelTests-\(UUID().uuidString)")
        for name in ["A/B", "C"] {
            try FileManager.default.createDirectory(at: base.appendingPathComponent(name), withIntermediateDirectories: true)
        }
    }

    private func file(_ path: String, _ size: Int64) -> DiskUsageNode {
        let url = base.appendingPathComponent(path)
        return DiskUsageNode(url: url, name: url.lastPathComponent, kind: .file, sizeInBytes: size, fileCount: 1)
    }

    private func folder(_ path: String, _ children: [DiskUsageNode]) -> DiskUsageNode {
        let url = path.isEmpty ? base : base.appendingPathComponent(path)
        return DiskUsageNode(
            url: url, name: url.lastPathComponent, kind: .folder,
            sizeInBytes: children.reduce(0) { $0 + $1.sizeInBytes }, fileCount: children.reduce(0) { $0 + $1.fileCount },
            children: children.sorted(by: DiskUsageNode.largestFirst)
        )
    }

    @Test("rescanning a folder updates it and every folder above, and keeps the user's place")
    func rescanSplicesSubtree() async throws {
        let folderB = folder("A/B", [file("A/B/x", 10)])
        let tree = folder("", [folder("A", [folderB]), folder("C", [file("C/y", 50)])])
        let scanner = FakeDiskUsageScanner([base.path: tree])
        let model = DiskUsageModel(scanner: scanner, cleaner: NoopCleaner(), scanRoot: base)
        await model.scanAndWait()
        let folderA = try #require(model.root?.children.first { $0.name == "A" })
        model.open(folderA)

        scanner.set(folder("A/B", [file("A/B/x", 10), file("A/B/new", 90)]), for: folderB.url)
        await model.rescan(folderB)

        #expect(scanner.scannedPaths == [base.path, folderB.url.path])
        #expect(model.root?.sizeInBytes == 150)
        #expect(model.root?.children.map(\.name) == ["A", "C"])
        #expect(model.trail.map(\.name) == [base.lastPathComponent, "A"])
        #expect(model.current?.sizeInBytes == 100)
        #expect(!model.isRescanning(folderB))
    }

    @Test("a folder deleted since the scan is dropped from the tree")
    func rescanDropsMissingFolder() async throws {
        let ghost = folder("Gone", [file("Gone/z", 40)])
        let tree = folder("", [ghost, folder("C", [file("C/y", 5)])])
        let model = DiskUsageModel(scanner: FakeDiskUsageScanner([base.path: tree]), cleaner: NoopCleaner(), scanRoot: base)
        await model.scanAndWait()

        await model.rescan(ghost)

        #expect(model.root?.children.map(\.name) == ["C"])
        #expect(model.root?.sizeInBytes == 5)
    }
}
