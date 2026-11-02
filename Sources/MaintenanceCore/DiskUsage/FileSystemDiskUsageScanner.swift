import Foundation
import os

/// Walks a folder like TreeSize: allocated sizes per folder, largest first.
/// Never follows symbolic links and never crosses into another mounted volume.
public struct FileSystemDiskUsageScanner: DiskUsageScanning, @unchecked Sendable {
    // MARK: Constants

    /// Files listed one by one per folder; the rest are folded into a "smaller files" row.
    public static let defaultFilesPerFolder = 40
    /// Entries between cancellation checks.
    private static let cancellationCheckInterval = 256

    private static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .isVolumeKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]
    private static let logger = Logger(subsystem: "com.macappupdater", category: "DiskUsageScanner")

    private let fileManager: FileManager
    private let filesPerFolder: Int

    public init(fileManager: FileManager = .default, filesPerFolder: Int = defaultFilesPerFolder) {
        self.fileManager = fileManager
        self.filesPerFolder = max(1, filesPerFolder)
    }

    // MARK: DiskUsageScanning

    public func scan(
        _ root: URL,
        progress: @escaping @Sendable (DiskUsageScanProgress) -> Void
    ) async throws -> DiskUsageNode {
        let counter = ScanCounter(report: progress)
        let root = root.standardizedFileURL
        // Top-level folders are read in parallel; everything below them depth-first.
        let entries = try children(of: root)
        var folders: [URL] = []
        var files: [DiskUsageNode] = []
        for entry in entries.urls {
            switch try classify(entry, counter: counter) {
            case .folder: folders.append(entry)
            case .file(let node): files.append(node)
            case .skipped: continue
            }
        }
        counter.start(foldersTotal: folders.count)
        let subfolders = try await withThrowingTaskGroup(of: DiskUsageNode.self) { group in
            for folder in folders {
                group.addTask { try self.folderNode(folder, counter: counter) }
            }
            var nodes: [DiskUsageNode] = []
            for try await node in group {
                nodes.append(node)
                counter.finished(node)
            }
            return nodes
        }
        let node = makeFolder(root, name: displayName(of: root), subfolders: subfolders, files: files, isPartial: entries.isPartial)
        Self.logger.info("Disk usage scan of \(root.path, privacy: .private) read \(counter.items) items")
        return node
    }

    // MARK: Walking

    private enum Entry {
        case folder
        case file(DiskUsageNode)
        case skipped
    }

    private func folderNode(_ folder: URL, counter: ScanCounter) throws -> DiskUsageNode {
        let entries = try children(of: folder)
        var subfolders: [DiskUsageNode] = []
        var files: [DiskUsageNode] = []
        for entry in entries.urls {
            switch try classify(entry, counter: counter) {
            case .folder: subfolders.append(try folderNode(entry, counter: counter))
            case .file(let node): files.append(node)
            case .skipped: continue
            }
        }
        counter.folderRead()
        return makeFolder(folder, name: folder.lastPathComponent, subfolders: subfolders, files: files, isPartial: entries.isPartial)
    }

    private func classify(_ url: URL, counter: ScanCounter) throws -> Entry {
        if counter.tick() % Self.cancellationCheckInterval == 0 { try Task.checkCancellation() }
        guard let values = try? url.resourceValues(forKeys: Self.keys), values.isSymbolicLink != true else {
            return .skipped
        }
        if values.isDirectory == true {
            // A mount point (other disk, /System/Volumes/Data firmlink target) is another volume.
            return values.isVolume == true ? .skipped : .folder
        }
        let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        counter.add(bytes: size)
        return .file(DiskUsageNode(url: url, name: url.lastPathComponent, kind: .file, sizeInBytes: size, fileCount: 1))
    }

    private func children(of folder: URL) throws -> (urls: [URL], isPartial: Bool) {
        try Task.checkCancellation()
        do {
            let urls = try fileManager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: Array(Self.keys), options: []
            )
            return (urls, false)
        } catch {
            // Usually a privacy-protected folder (Mail, Safari, another user's home).
            return ([], true)
        }
    }

    private func makeFolder(
        _ url: URL, name: String, subfolders: [DiskUsageNode], files: [DiskUsageNode], isPartial: Bool
    ) -> DiskUsageNode {
        let sortedFiles = files.sorted(by: DiskUsageNode.largestFirst)
        var children = subfolders + sortedFiles.prefix(filesPerFolder)
        let rest = sortedFiles.dropFirst(filesPerFolder)
        if !rest.isEmpty {
            children.append(DiskUsageNode(
                url: url, name: name, kind: .smallFiles,
                sizeInBytes: rest.reduce(0) { $0 + $1.sizeInBytes }, fileCount: rest.count
            ))
        }
        let all = subfolders + files
        return DiskUsageNode(
            url: url, name: name, kind: .folder,
            sizeInBytes: all.reduce(0) { $0 + $1.sizeInBytes },
            fileCount: all.reduce(0) { $0 + $1.fileCount },
            children: children.sorted(by: DiskUsageNode.largestFirst),
            isPartial: isPartial || subfolders.contains(where: \.isPartial)
        )
    }

    private func displayName(of url: URL) -> String {
        url.path == "/" ? (fileManager.displayName(atPath: "/")) : url.lastPathComponent
    }
}

// MARK: - Progress counter

/// Shared by the parallel top-level walks; reports progress on a timer, not per folder,
/// so the screen updates a few times per second however fast the disk is.
private final class ScanCounter: @unchecked Sendable {
    private struct State {
        var items = 0
        var bytes: Int64 = 0
        var foldersTotal = 0
        var finished: [DiskUsageScanProgress.Folder] = []
        var lastReport: ContinuousClock.Instant?
    }

    /// Minimum time between timer-driven reports.
    private static let reportInterval: Duration = .milliseconds(250)
    /// Finished folders carried in each report.
    private static let reportedFolders = 8

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let report: @Sendable (DiskUsageScanProgress) -> Void

    init(report: @escaping @Sendable (DiskUsageScanProgress) -> Void) {
        self.report = report
    }

    var items: Int { state.withLock { $0.items } }

    /// Counts one entry and returns the running total.
    func tick() -> Int {
        state.withLock { state in
            state.items += 1
            return state.items
        }
    }

    func add(bytes: Int64) {
        state.withLock { $0.bytes += bytes }
    }

    func start(foldersTotal: Int) {
        let snapshot = state.withLock { state in
            state.foldersTotal = foldersTotal
            return Self.snapshot(&state)
        }
        report(snapshot)
    }

    /// Reports when the last report is older than the interval.
    func folderRead() {
        let snapshot: DiskUsageScanProgress? = state.withLock { state in
            if let last = state.lastReport, last.duration(to: .now) < Self.reportInterval { return nil }
            return Self.snapshot(&state)
        }
        if let snapshot { report(snapshot) }
    }

    /// A top-level folder is done: always reported, so the list of finished folders fills in.
    func finished(_ node: DiskUsageNode) {
        let snapshot = state.withLock { state in
            state.finished.append(DiskUsageScanProgress.Folder(name: node.name, sizeInBytes: node.sizeInBytes))
            return Self.snapshot(&state)
        }
        report(snapshot)
    }

    private static func snapshot(_ state: inout State) -> DiskUsageScanProgress {
        state.lastReport = .now
        let largest = state.finished.sorted { $0.sizeInBytes > $1.sizeInBytes }.prefix(reportedFolders)
        return DiskUsageScanProgress(
            itemsScanned: state.items, bytesScanned: state.bytes,
            foldersTotal: state.foldersTotal, foldersDone: state.finished.count,
            finishedFolders: Array(largest)
        )
    }
}
