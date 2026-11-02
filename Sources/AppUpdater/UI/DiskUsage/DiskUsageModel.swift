import AppKit
import Foundation
import MaintenanceCore
import Observation
import os
import UniformTypeIdentifiers

/// Drives the Disk Usage screen: scanning a folder into a size tree and browsing it like TreeSize.
@MainActor
@Observable
final class DiskUsageModel {
    enum State: Equatable {
        case idle
        case scanning(DiskUsageScanProgress?)
        case loaded
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Folder the last scan started from.
    private(set) var scanRoot: URL
    private(set) var root: DiskUsageNode?
    /// Breadcrumb from `root` down to the folder on screen; never empty once loaded.
    private(set) var trail: [DiskUsageNode] = []
    /// Last failed action, shown as a banner until dismissed.
    var actionError: String?
    /// Folders being measured again on their own; their rows show a spinner.
    private(set) var rescanningIDs: Set<String> = []

    private let scanner: any DiskUsageScanning
    private let cleaner: any CleanupPerforming
    private var scanTask: Task<Void, Never>?
    /// Bumped per scan so a superseded scan's late results are ignored.
    private var scanGeneration = 0
    private let logger = Logger(subsystem: "com.macappupdater", category: "DiskUsageModel")
    @ObservationIgnored private let iconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        return cache
    }()

    init(
        scanner: any DiskUsageScanning,
        cleaner: any CleanupPerforming,
        scanRoot: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.scanner = scanner
        self.cleaner = cleaner
        self.scanRoot = scanRoot
    }

    // MARK: Derived

    var current: DiskUsageNode? { trail.last ?? root }

    var isScanning: Bool {
        if case .scanning = state { return true }
        return false
    }

    var progress: DiskUsageScanProgress? {
        if case .scanning(let progress) = state { return progress }
        return nil
    }

    // MARK: Scanning

    func scan(_ folder: URL? = nil) {
        if let folder { scanRoot = folder }
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        state = .scanning(nil)
        let scanner = self.scanner
        let root = scanRoot
        let onProgress: @Sendable (DiskUsageScanProgress) -> Void = { [weak self] progress in
            Task { @MainActor in self?.report(progress, generation: generation) }
        }
        scanTask = Task { [weak self] in
            // The walk is synchronous file I/O; keep it off the main actor.
            let work = Task.detached(priority: .userInitiated) {
                try await scanner.scan(root, progress: onProgress)
            }
            do {
                let node = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
                self?.finish(node, generation: generation)
            } catch is CancellationError {
                self?.cancelled(generation: generation)
            } catch {
                self?.fail(error, generation: generation)
            }
        }
    }

    /// Scans and returns once the tree is on screen (screenshots, tests).
    func scanAndWait(_ folder: URL? = nil) async {
        scan(folder)
        await scanTask?.value
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    /// Asks for a folder and scans it.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = scanRoot
        panel.prompt = String(localized: "Scan")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scan(url)
    }

    private func report(_ progress: DiskUsageScanProgress, generation: Int) {
        guard generation == scanGeneration, case .scanning(let previous) = state else { return }
        // Reports hop to the main actor in separate tasks; never let the counts step backwards.
        if let previous, previous.itemsScanned > progress.itemsScanned, previous.foldersDone >= progress.foldersDone { return }
        state = .scanning(progress)
    }

    private func finish(_ node: DiskUsageNode, generation: Int) {
        guard generation == scanGeneration else { return }
        root = node
        trail = [node]
        state = .loaded
        scanTask = nil
    }

    private func cancelled(generation: Int) {
        guard generation == scanGeneration else { return }
        state = root == nil ? .idle : .loaded
        scanTask = nil
    }

    private func fail(_ error: Error, generation: Int) {
        guard generation == scanGeneration else { return }
        logger.error("Disk usage scan failed: \(error.localizedDescription, privacy: .public)")
        state = .failed(error.localizedDescription)
        scanTask = nil
    }

    // MARK: Navigation

    func open(_ node: DiskUsageNode) {
        guard node.isFolder, !node.children.isEmpty else { return }
        trail.append(node)
    }

    func goUp() {
        guard trail.count > 1 else { return }
        trail.removeLast()
    }

    /// Jumps back to the breadcrumb at `index`.
    func goTo(index: Int) {
        guard trail.indices.contains(index) else { return }
        trail = Array(trail.prefix(index + 1))
    }

    // MARK: Actions

    func reveal(_ node: DiskUsageNode) {
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    func openInFinder(_ node: DiskUsageNode) {
        NSWorkspace.shared.open(node.url)
    }

    func copyPath(_ node: DiskUsageNode) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.url.path, forType: .string)
    }

    func isRescanning(_ node: DiskUsageNode) -> Bool { rescanningIDs.contains(node.id) }

    /// Measures one folder again and splices the fresh result into the tree; every folder above it
    /// takes the difference. A folder that no longer exists is dropped from the tree.
    func rescan(_ node: DiskUsageNode) async {
        guard node.isFolder, !isScanning, !rescanningIDs.contains(node.id) else { return }
        rescanningIDs.insert(node.id)
        defer { rescanningIDs.remove(node.id) }
        // A full scan started meanwhile replaces the tree; this result would then be stale.
        let generation = scanGeneration
        let scanner = self.scanner
        let url = node.url
        let fresh: DiskUsageNode?
        do {
            fresh = try await Task.detached(priority: .userInitiated) {
                guard FileManager.default.fileExists(atPath: url.path) else { return nil as DiskUsageNode? }
                return try await scanner.scan(url) { _ in }
            }.value
        } catch {
            logger.error("Rescanning a folder failed: \(error.localizedDescription, privacy: .public)")
            actionError = error.localizedDescription
            return
        }
        guard generation == scanGeneration, let root else { return }
        let currentID = current?.id ?? root.id
        let updated = fresh.map { root.replacing(node.id, with: $0) } ?? root.removing(node.id)
        self.root = updated
        // Stay where the user was; if that folder is gone now, land on the rescanned one (or its parent).
        trail = updated.path(to: currentID) ?? updated.path(to: node.id) ?? [updated]
    }

    /// Moves `node` to the Trash (home folder only, protected folders refused) and drops it from the tree.
    func moveToTrash(_ node: DiskUsageNode) async {
        guard node.kind != .smallFiles, let root else { return }
        let item = CleanupItem(url: node.url, category: .largeOldFiles, displayName: node.name, sizeInBytes: node.sizeInBytes)
        let result = await cleaner.clean([item])
        if let failure = result.failed.first {
            actionError = failure.reason
            return
        }
        let updated = root.removing(node.id)
        self.root = updated
        // Rebuild the breadcrumb from the new tree so every level shows the smaller sizes.
        let currentID = current?.id ?? updated.id
        trail = updated.path(to: currentID) ?? [updated]
    }

    func icon(for node: DiskUsageNode) -> NSImage {
        let key = node.url.path as NSString
        if let cached = iconCache.object(forKey: key) { return cached }
        // A path that is gone (trashed since the scan) would get a blank document icon.
        let exists = FileManager.default.fileExists(atPath: node.url.path)
        let image = exists || !node.isFolder
            ? NSWorkspace.shared.icon(forFile: node.url.path)
            : NSWorkspace.shared.icon(for: .folder)
        iconCache.setObject(image, forKey: key)
        return image
    }
}
